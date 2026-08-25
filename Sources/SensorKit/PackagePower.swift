import Foundation
import CIOReport

/// CPU and GPU package power via IOReport "Energy Model" counters.
///
/// The channels accumulate energy since subscription; power over an interval
/// is the counter delta divided by the time between the two snapshots. This is
/// how macOS fills its own Energy gauges (`powermetrics` reads the same
/// daemon), and it needs no privilege.
///
/// Every step degrades to nil rather than throwing: a macOS release that
/// renamed or froze a channel costs us a chart series, not a crash, and the UI
/// already knows how to present a reading that does not exist. Callers must
/// treat nil as "no data", never as zero watts — a chart that drew zero watts
/// for a dead counter would show an idle-cool machine while it cooked.
///
/// Three failure shapes are handled, each measured on real hardware:
///
/// * *The silent counter.* A channel can answer with a value that never
///   moves — exact-zero deltas for minutes while cores spin (macOS 27 beta /
///   M5 Pro; Apple's own `powermetrics` reports 0 mW for every Energy Model
///   rail there, so the fault is below our plumbing). An idle SoC still burns
///   milliwatts, so a run of *exact* zeros is firmware silence, not idleness,
///   and a zero delta is therefore published as "no data", never as 0 W.
///   After enough silent samples the series is withdrawn and goes dormant,
///   probing once per retry interval in case an OS update revives it.
/// * *Per-series independence.* Each channel carries its own state. One dead
///   channel used to keep its neighbour's zombie alive because withdrawal
///   required *both* channels to freeze simultaneously — precisely the
///   arrangement that pinned a broken CPU reading at 0 W beside a live GPU.
/// * *The lazy flush.* Counters can also move, but rarely: bursts separated
///   by many silent ticks. Differencing a burst against the previous tick
///   attributes minutes of energy to one second. Each series therefore
///   remembers when its counter last moved and divides the burst by the whole
///   quiet span — an average over the flush period, which is the truth the
///   hardware chose to give — capped at `maximumAveragingInterval`, beyond
///   which the window is abandoned rather than smeared.
///
/// The first call establishes the baseline and returns nils — there is no
/// interval to difference over yet, which is the same contract
/// `SystemMetrics.cpuUsage()` follows.
public final class PackagePower: @unchecked Sendable {

    public struct Sample: Sendable, Equatable {
        /// Whole-package CPU power in watts, or nil while unavailable.
        public var cpuWatts: Double?
        /// Whole-GPU power in watts, or nil under the same conditions.
        public var gpuWatts: Double?

        public static let unavailable = Sample(cpuWatts: nil, gpuWatts: nil)

        public var isUnavailable: Bool { cpuWatts == nil && gpuWatts == nil }
    }

    /// One channel's differencing state, exposed as a value type so the whole
    /// state machine can be driven from a test without root or hardware. The
    /// reader owns two of these and feeds each the raw counter it sampled.
    ///
    /// All decisions live in `observe`; the reader adds nothing but the query.
    public struct Series: Sendable {
        /// A differencing anchor: the counter's latest value, when observing
        /// began (`since` — the value may have accrued over many silent
        /// observations before a flush surfaced it), and when it last differed
        /// from its predecessor (`lastMoved`, nil while it never yet has).
        private struct Held: Sendable {
            var counter: Int64
            var since: ContinuousClock.Instant
            var lastMoved: ContinuousClock.Instant?
        }

        private var baseline: Held?
        /// Consecutive observations in which the channel answered but yielded
        /// no usable watt reading — silent (zero delta) or implausible (moved,
        /// but past the physical ceiling). Either shape sustained means the
        /// channel is not being maintained.
        public private(set) var frozenStreak = 0
        /// When withdrawn, sampling pauses until this instant; one probe then
        /// re-baselines. An OS update can revive a frozen counter, and these
        /// counters reset across sleep anyway, so wake is when change shows.
        public private(set) var dormantUntil: ContinuousClock.Instant?

        public init() {}

        /// True once at least one counter observation is held as a baseline —
        /// i.e. the channel exists and has been sampled at all.
        public var hasBaseline: Bool { baseline != nil }

        /// True while the series is withdrawn and its next probe is not due —
        /// the reader may skip the query entirely when every series agrees.
        /// Writers only ever push the deadline later or clear it, so a racing
        /// reader's worst case is one extra probe.
        public func isDormant(at now: ContinuousClock.Instant) -> Bool {
            guard let until = dormantUntil else { return false }
            return now < until
        }

        /// Feed one raw observation. Returns the published watts, or nil when
        /// the observation produced no measurement — which is most outcomes,
        /// and every one of them is stated by the guards below.
        public mutating func observe(counter: Int64?,
                                     at now: ContinuousClock.Instant) -> Double? {
            // The channel did not answer: the platform changed underneath us.
            // Drop the baseline rather than difference across the gap.
            guard let counter else {
                baseline = nil
                return nil
            }

            if let until = dormantUntil {
                guard now >= until else { return nil }   // still withdrawn
                // Probe due: re-baseline and answer on the next call. Ten
                // minutes may have passed; dividing across it would report
                // microwatts or megawatts depending on which way it broke.
                dormantUntil = nil
                frozenStreak = 0
                baseline = Held(counter: counter, since: now, lastMoved: nil)
                return nil
            }

            guard let held = baseline else {
                // First look, or first look since the channel vanished.
                baseline = Held(counter: counter, since: now, lastMoved: nil)
                return nil
            }

            guard counter >= held.counter else {
                // Counters reset across sleep. No measurement exists for
                // the interval; restart the accumulation window from here.
                baseline = Held(counter: counter, since: now, lastMoved: now)
                return nil
            }

            if counter == held.counter {
                // Silence. One still interval is unremarkable; a run of
                // them is a dead counter wearing a live channel's clothes.
                // Zero watts would be a claim that the package consumed
                // nothing — the idle-cool lie this class refuses to draw.
                frozenStreak += 1
                if frozenStreak >= PackagePower.frozenSampleLimit {
                    dormantUntil = now.advanced(by: .seconds(PackagePower.dormantRetryInterval))
                }
                // The anchor must survive the silent ticks untouched: the
                // value being held began accruing back at `held.since`.
                return nil
            }

            // The counter moved. Attribute the burst to the whole span since
            // it last moved — or since the value was first held, when it
            // never yet has — not to the single tick it arrived in, which is
            // how a lazy flush renders as an absurd spike.
            let windowStart = held.lastMoved ?? held.since
            let elapsedNS = PackagePower.nanoseconds(from: windowStart, to: now)

            defer { baseline = Held(counter: counter, since: now, lastMoved: now) }

            if elapsedNS > 0, elapsedNS <= PackagePower.maximumAveragingIntervalNS,
               let watts = PackagePower.watts(delta: counter - held.counter, elapsedNS: elapsedNS) {
                frozenStreak = 0
                return watts
            }
            if elapsedNS <= 0 {
                // Same-instant resample: no window worth dividing over.
                // The deferred re-anchor below starts measuring from here.
                return nil
            }
            if elapsedNS > PackagePower.maximumAveragingIntervalNS {
                // Too stale to attribute honestly. Abandon the window;
                // the next movement starts a fresh, measurable one.
                return nil
            }
            // Moved, but into implausible territory — the scale these
            // channels use has changed before. Sustained nonsense
            // disqualifies the series exactly like silence does.
            frozenStreak += 1
            if frozenStreak >= PackagePower.frozenSampleLimit {
                dormantUntil = now.advanced(by: .seconds(PackagePower.dormantRetryInterval))
            }
            return nil
        }
    }

    private var cpu = Series()
    private var gpu = Series()
    private let lock = NSLock()

    public init() {}

    /// True once the system accepted our channel subscription.
    public var isAvailable: Bool { subscribe() == 0 }

    /// One line for the diagnostics report: what each series is doing right
    /// now. "Why are the watts missing?" must be answerable from inside the
    /// app, not only by strace-ing powermetrics.
    public func diagnosticSummary(now: ContinuousClock.Instant = ContinuousClock().now) -> String {
        guard subscribe() == 0 else { return "unavailable (IOReport subscription refused)" }
        return lock.withLock {
            func describe(_ name: String, _ series: Series) -> String {
                if !series.hasBaseline { return "\(name) no channel data" }
                if series.isDormant(at: now) {
                    return "\(name) withdrawn — counter silent or implausible"
                }
                if series.frozenStreak > 0 {
                    return "\(name) \(series.frozenStreak)/\(PackagePower.frozenSampleLimit) silent samples"
                }
                return "\(name) live"
            }
            return [describe("CPU", cpu), describe("GPU", gpu)].joined(separator: "; ")
        }
    }

    /// One reading.
    ///
    /// The whole body runs under the lock, query included: the readers (one
    /// app tick, one CLI invocation) are strictly sequential, so the simple
    /// discipline costs nothing and leaves no unlocked state to reason about.
    public func sample(now: ContinuousClock.Instant = ContinuousClock().now) -> Sample {
        guard subscribe() == 0 else { return .unavailable }

        return lock.withLock {
            // Dormancy exists to avoid paying the query for a foregone
            // answer. Only when *every* series is withdrawn and no probe is
            // due may the question be skipped outright.
            if cpu.isDormant(at: now), gpu.isDormant(at: now) { return .unavailable }

            var cpuCounter: Int64 = 0
            var gpuCounter: Int64 = 0
            let mask = CIOReportSampleCounters(&cpuCounter, &gpuCounter)

            return Sample(
                cpuWatts: cpu.observe(counter: mask & 0b01 != 0 ? cpuCounter : nil, at: now),
                gpuWatts: gpu.observe(counter: mask & 0b10 != 0 ? gpuCounter : nil, at: now))
        }
    }

    // MARK: - Arithmetic (pure, unit-tested directly)

    /// Counters reset across sleep; a backwards delta is no measurement at all,
    /// so it maps to nil ("no data") rather than to 0 or to negative power.
    public static func delta(_ current: Int64, since previous: Int64?) -> Int64? {
        guard let previous else { return nil }
        return current >= previous ? current - previous : nil
    }

    /// Millijoules over an interval → watts: W = (mJ ÷ 1000) ÷ (ns × 10⁻⁹)
    /// = mJ × 10⁶ ÷ ns.
    ///
    /// Nil for anything that is not a measurement:
    /// * a nil or negative delta — the latter is a counter reset, not physics;
    /// * an exact-zero delta over a real interval. The counters resolve to one
    ///   millijoule, an idle package burns tens of them per second, so zero
    ///   accrued over a second is firmware silence masquerading as idleness;
    /// * a non-positive or non-finite interval;
    /// * anything outside physical range. The scale these channels use has
    ///   changed before and will again, and a nonsense number must arrive as
    ///   "no data".
    public static func watts(delta millijoules: Int64?, elapsedNS: Double) -> Double? {
        guard let millijoules, millijoules > 0 else { return nil }
        guard elapsedNS.isFinite, elapsedNS > 0 else { return nil }
        let watts = Double(millijoules) * 1_000_000 / elapsedNS
        guard watts.isFinite, watts <= plausibleWattsCeiling else {
            return nil
        }
        return watts
    }

    public static func nanoseconds(from start: ContinuousClock.Instant,
                             to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) * 1e9
            + Double(duration.components.attoseconds) / 1e9
    }

    // MARK: - Tuning

    /// How many consecutive disqualified observations withdraw a series.
    public static let frozenSampleLimit = 10
    /// How long a withdrawn series stops asking the question before probing
    /// once to see if anything changed.
    public static let dormantRetryInterval: TimeInterval = 600
    /// Longest span a counter burst may be averaged across. Bounds the
    /// lazy-flush attribution above: past this, energy accrued over an unknown
    /// fraction of a very long window is dropped rather than smeared.
    public static let maximumAveragingInterval: TimeInterval = 120
    static let maximumAveragingIntervalNS: Double = maximumAveragingInterval * 1e9
    /// Anything above this is not physics. An M5 Max pulls well under 200 W;
    /// 500 W leaves margin for future silicon while rejecting unit mix-ups,
    /// which otherwise render as megawatts.
    public static let plausibleWattsCeiling = 500.0

    // MARK: - Mechanics

    private func subscribe() -> Int32 {
        CIOReportSubscribe()
    }
}
