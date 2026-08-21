import Foundation
import FanKit

/// Notices sudden thermal rises and measures them.
///
/// `ThrottleDetector` answers "did the machine run out of cooling headroom?" and
/// needs sustained heavy load before it will say anything. That deliberately
/// misses the event people actually complain about: the fans ramping hard out of
/// nowhere for a minute or two. This detector watches the *shape* of the
/// temperature trace instead of its absolute level — a climb of at least
/// `riseThresholdC` inside `riseWindow`, ending somewhere worth caring about.
///
/// A pure value type, like `ThrottleDetector`: the same inputs always produce
/// the same spikes, so the thresholds can be argued with in a test rather than
/// on a hot Mac.
public struct SpikeDetector: Sendable {

    public struct Configuration: Sendable {
        /// How far back the baseline is taken from. Long enough to contain a
        /// whole ramp, short enough that a slow afternoon warm-up never
        /// accumulates into one.
        public var riseWindow: TimeInterval
        /// The climb that makes it a spike rather than drift.
        public var riseThresholdC: Double
        /// Below this the machine is not hot by any definition, and a 12-degree
        /// climb from 30 °C is a laptop waking up.
        public var minimumPeakC: Double
        /// Fraction of the climb that has to be given back before it counts as
        /// over. Half, so a spike that settles onto a new plateau still closes.
        public var settleFraction: Double
        /// How long it must stay settled, so one cool sample can't end it early.
        public var clearSeconds: TimeInterval
        /// A gap longer than this is sleep, a stall, or a clock correction — the
        /// baseline is discarded rather than letting a wake read as an instant
        /// 30-degree rise.
        public var maximumGap: TimeInterval
        /// A rise that never comes back down is a sustained workload, which is
        /// the throttle detector's subject, not this one's. Closed at this age so
        /// the record cannot read "still rising" for the rest of the day.
        public var maximumDuration: TimeInterval
        /// How many applications to attribute a spike to.
        public var attributionCount: Int
        /// Distinct process names tracked at once, so the accumulator's size is
        /// set by the bound rather than by whatever the machine happened to run.
        public var attributionCapacity: Int
        /// Trailing samples held at once. Time trims the window, but a
        /// pathological sample rate can outrun that between trims — the same
        /// bound `LiveWindow` keeps, for the same reason.
        public var trailCapacity: Int

        /// Every bound is clamped rather than trusted.
        ///
        /// These are internal knobs today, but a zero `riseWindow` gives a
        /// detector with no baseline and a zero `riseThresholdC` declares a
        /// spike on every sample that is not a new minimum. A detector
        /// configured into nonsense must fail closed — quiet — rather than
        /// filling the database with events that never happened.
        public init(riseWindow: TimeInterval = 120,
                    riseThresholdC: Double = 12,
                    minimumPeakC: Double = 70,
                    settleFraction: Double = 0.5,
                    clearSeconds: TimeInterval = 30,
                    maximumGap: TimeInterval = 60,
                    maximumDuration: TimeInterval = 30 * 60,
                    attributionCount: Int = 3,
                    attributionCapacity: Int = 256,
                    trailCapacity: Int = 4_096) {
            self.riseWindow = max(1, riseWindow)
            self.riseThresholdC = max(0.1, riseThresholdC)
            self.minimumPeakC = minimumPeakC
            // Strictly inside 0…1. At 0 a spike closes the instant it stops
            // climbing; at 1 it can never settle at all.
            self.settleFraction = min(0.95, max(0.05, settleFraction))
            self.clearSeconds = max(0, clearSeconds)
            self.maximumGap = max(1, maximumGap)
            // Never shorter than the window it is measured over, or a spike
            // would be closed for age before it could finish being declared.
            self.maximumDuration = max(self.riseWindow, maximumDuration)
            self.attributionCount = max(1, attributionCount)
            self.attributionCapacity = max(self.attributionCount, attributionCapacity)
            self.trailCapacity = max(2, trailCapacity)
        }
    }

    /// When it is worth *collecting* attribution.
    ///
    /// Walking every pid costs real CPU, so the app only pays it when a spike
    /// might be forming. These are deliberately more sensitive than the
    /// thresholds above: they decide whether names are gathered, never whether a
    /// spike happened. Owned here so the app cannot drift from the detector
    /// about what "starting to climb" means.
    public enum Attribution {
        /// A climb of this much, over this window, arms collection.
        public static let armRiseC: Double = 5
        public static let armWindow: TimeInterval = 60
        /// Or load alone, high enough that something is clearly running.
        public static let armCPUPercent: Double = 50
    }

    public struct Input: Sendable {
        public var date: Date
        /// Nil when no sensor reported. A tick with no temperature cannot open,
        /// extend, or close a spike — it is a hole in the trace, not a reading.
        public var maxTempC: Double?
        public var cpuPercent: Double
        /// `SensorCategory` raw value of the hottest sensor, or "" if unknown.
        public var hottestGroup: String
        public var fanRPM: Double
        public var fanDutyPercent: Double
        public var profileName: String
        public var onBattery: Bool
        /// Empty unless the user opted into attribution (DESIGN §5.4).
        public var processes: [ProcessLoad]

        public init(date: Date,
                    maxTempC: Double?,
                    cpuPercent: Double,
                    hottestGroup: String = "",
                    fanRPM: Double = 0,
                    fanDutyPercent: Double = 0,
                    profileName: String = "",
                    onBattery: Bool = false,
                    processes: [ProcessLoad] = []) {
            self.date = date
            self.maxTempC = maxTempC
            self.cpuPercent = cpuPercent
            self.hottestGroup = hottestGroup
            self.fanRPM = fanRPM
            self.fanDutyPercent = fanDutyPercent
            self.profileName = profileName
            self.onBattery = onBattery
            self.processes = processes
        }
    }

    public enum Event: Sendable, Equatable {
        case none
        /// A rise just crossed the threshold. No id yet.
        case opened(Spike)
        /// Still elevated; the payload carries the accumulators so far.
        case updated(Spike)
        case closed(Spike)
    }

    public var configuration: Configuration

    /// The spike in progress, if any. Its `end` is nil until it closes.
    public private(set) var current: Spike?

    /// Trailing (date, temperature, load) inside `riseWindow`, oldest first.
    /// The baseline a rise is measured against is the coolest entry in it.
    private var trail: [(date: Date, celsius: Double, cpuPercent: Double)] = []
    private var lastInput: Date?
    /// Last instant the spike was *not* settled, which is where it ends.
    private var lastUnsettled: Date?
    private var attribution: ProcessAttribution
    private var recordsProcessNames = false

    /// Raw attribution totals for the spike in progress. Internal: callers only
    /// ever need the shares on the record itself.
    var accumulatedCPUSeconds: [String: Double] { attribution.cpuSecondsByProcess }

    /// Trailing samples currently held. Internal, so a stress test can assert
    /// the bound rather than trusting the trim.
    var trailCount: Int { trail.count }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.attribution = ProcessAttribution(capacity: configuration.attributionCapacity,
                                              topCount: configuration.attributionCount)
    }

    public mutating func update(_ input: Input) -> Event {
        // A sleep/wake gap invalidates the baseline *and* any spike in progress:
        // we have no idea what happened in between, so closing at the last
        // sample we actually saw is the only honest end.
        let gap = lastInput.map { input.date.timeIntervalSince($0) } ?? 0
        let discontinuity = gap > configuration.maximumGap || gap < 0
        // Time since the *previous sample*, which is what a CPU-seconds
        // accumulator needs. Zero on the first sample and across a gap, so a
        // wake cannot credit a process with ten minutes of work it never did.
        let dt = discontinuity ? 0 : max(0, gap)
        lastInput = input.date

        if discontinuity {
            trail.removeAll()
            if let spike = current { return closeCurrent(at: lastUnsettled ?? spike.peak) }
        }

        // No reading — missing, or a number that cannot be a temperature. Hold
        // everything as it is rather than treating it as a cool sample, which
        // would close a live spike.
        //
        // `isFinite` alone was not enough. A sensor reporting 1e9 is finite, and
        // it landed in the trailing window as a baseline no real reading could
        // ever be measured against: the next sample was a billion degrees below
        // it, which is a spike by any threshold. The sensor layer filters this
        // at the point of reading, but a detector that trusts its input because
        // something upstream is supposed to have checked it breaks the day it
        // acquires a second caller.
        guard let celsius = PlausibleTemperature.validated(input.maxTempC) else { return .none }

        if current != nil {
            let event = extend(input, celsius: celsius, dt: dt)
            // The trail keeps filling during a spike so the next one is measured
            // from where this one left off — except when this sample closed it,
            // in which case `closeCurrent` has just emptied the trail and the
            // closing sample is the first entry of the new baseline.
            appendToTrail(input, celsius: celsius)
            return event
        }

        appendToTrail(input, celsius: celsius)

        guard let baseline = trail.min(by: { $0.celsius < $1.celsius }),
              baseline.date < input.date,
              celsius - baseline.celsius >= configuration.riseThresholdC,
              celsius >= configuration.minimumPeakC else { return .none }

        current = Spike(start: baseline.date,
                        peak: input.date,
                        fromTempC: baseline.celsius,
                        peakTempC: celsius,
                        cpuAtStartPercent: baseline.cpuPercent,
                        peakCPUPercent: max(baseline.cpuPercent, input.cpuPercent),
                        hottestGroup: input.hottestGroup,
                        peakFanRPM: input.fanRPM,
                        peakFanDutyPercent: input.fanDutyPercent,
                        profileName: input.profileName,
                        onBattery: input.onBattery,
                        recordedProcessNames: recordsProcessNames)
        lastUnsettled = input.date
        attribution.reset()
        return .opened(current!)
    }

    /// Tells the detector whether names are being collected, so each record can
    /// say for itself whether an empty attribution list means "nothing measured"
    /// or "not recorded". Set from the recorder, which owns the setting.
    ///
    /// Switching it off **discards what has already been collected** for the
    /// spike in progress, rather than merely stopping collection. Without that,
    /// names gathered before the user said stop stayed on the open record and
    /// went on being written to the database on every subsequent tick.
    public mutating func setRecordsProcessNames(_ enabled: Bool) {
        recordsProcessNames = enabled
        current?.recordedProcessNames = enabled
        guard !enabled else { return }
        attribution.reset()
        current?.processes = []
    }

    private mutating func appendToTrail(_ input: Input, celsius: Double) {
        trail.append((date: input.date, celsius: celsius, cpuPercent: input.cpuPercent))
        let cutoff = input.date.addingTimeInterval(-configuration.riseWindow)
        if let firstFresh = trail.firstIndex(where: { $0.date >= cutoff }), firstFresh > 0 {
            trail.removeFirst(firstFresh)
        }
        // Time trims the window, but a sample rate high enough to fit thousands
        // of readings inside it outruns that. `LiveWindow` keeps the same hard
        // cap for the same reason: a bound that depends on the caller's timing
        // is not a bound.
        if trail.count > configuration.trailCapacity {
            trail.removeFirst(trail.count - configuration.trailCapacity)
        }
    }

    private mutating func extend(_ input: Input, celsius: Double, dt: TimeInterval) -> Event {
        guard var spike = current else { return .none }

        if celsius > spike.peakTempC {
            spike.peakTempC = celsius
            spike.peak = input.date
            spike.hottestGroup = input.hottestGroup
            spike.peakFanRPM = input.fanRPM
            spike.peakFanDutyPercent = input.fanDutyPercent
        }
        spike.peakCPUPercent = max(spike.peakCPUPercent, input.cpuPercent)
        if input.profileName != spike.profileName {
            spike.profileChanged = true
            spike.profileName = input.profileName
        }
        attribution.add(input.processes, dt: dt)
        spike.processes = attribution.top()
        current = spike

        let settleTo = spike.fromTempC + spike.riseC * configuration.settleFraction
        if celsius > settleTo { lastUnsettled = input.date }

        if input.date.timeIntervalSince(spike.start) >= configuration.maximumDuration {
            // Still elevated after half an hour: this is a workload, not a
            // spike. It ends now, at the last sample, rather than never.
            return closeCurrent(at: input.date)
        }
        if let lastUnsettled,
           input.date.timeIntervalSince(lastUnsettled) >= configuration.clearSeconds {
            return closeCurrent(at: lastUnsettled)
        }
        return .updated(spike)
    }

    private mutating func closeCurrent(at end: Date) -> Event {
        guard var spike = current else { return .none }
        // Never before it started: `end` comes from a recorded instant, but a
        // negative-length record is a bug someone would have to debug later.
        spike.end = max(end, spike.start)
        // Never before the peak either: `peak` is the instant a rate is measured
        // from, and a record whose peak sits outside its own span would make
        // every derived number nonsense.
        spike.peak = min(max(spike.peak, spike.start), spike.end ?? spike.peak)
        spike.processes = attribution.top()
        current = nil
        lastUnsettled = nil
        attribution.reset()
        // The baseline this spike rose from is spent. Kept, it would still be
        // sitting in the trailing window a minute later and declare the *same*
        // heat all over again — a machine that stayed hot for an hour produced a
        // chain of spikes, each one measured from a temperature it had left long
        // ago. The next rise is measured from where this one left the machine.
        trail.removeAll()
        return .closed(spike)
    }
}
