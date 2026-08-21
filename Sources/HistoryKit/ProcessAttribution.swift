import Foundation

/// One process's instantaneous CPU share, as handed to a detector each tick.
///
/// Top-level rather than nested, because both detectors consume it — the same
/// reason `ProcessShare` is. Empty unless the user opted in (DESIGN §5.4).
public struct ProcessLoad: Sendable, Equatable {
    public let name: String
    public let cpuPercent: Double

    public init(name: String, cpuPercent: Double) {
        self.name = name
        self.cpuPercent = cpuPercent
    }
}

/// CPU-seconds per process across one event, bounded, with one way to discard.
///
/// Both detectors had this written out separately: the same accumulate loop and
/// the same `topProcesses()` sort. Two copies of "which app was responsible?" is
/// two places for the privacy rule to be enforced, and only one of them would
/// have been fixed.
///
/// Three properties this type is responsible for:
///
/// - **CPU-seconds, not peak percent.** A process that ran for the whole event
///   outweighs one that briefly touched 100%.
/// - **Bounded.** A build system spawns a great many short-lived processes under
///   different names and an event can run for half an hour, so the accumulator
///   would otherwise grow with the *variety* of what ran rather than with what
///   mattered.
/// - **Forgettable.** Turning attribution off has to drop what was already
///   collected, not merely stop collecting. See `reset()`.
struct ProcessAttribution {

    /// Distinct names tracked at once. Past this, the smallest are dropped.
    let capacity: Int
    /// How many names an event is attributed to.
    let topCount: Int

    private var cpuSeconds: [String: Double] = [:]

    init(capacity: Int = 256, topCount: Int = 3) {
        self.topCount = max(1, topCount)
        self.capacity = max(self.topCount, capacity)
    }

    /// Raw totals. Internal, for tests and for the detectors' own accessors —
    /// callers only ever need `top()`.
    var cpuSecondsByProcess: [String: Double] { cpuSeconds }

    var isEmpty: Bool { cpuSeconds.isEmpty }

    /// - Parameter dt: seconds since the previous sample. Zero or negative adds
    ///   nothing: a duplicate timestamp, a first sample, or a wake must not
    ///   credit a process with work it did not do.
    mutating func add(_ processes: [ProcessLoad], dt: TimeInterval) {
        guard dt > 0, !processes.isEmpty else { return }
        for process in processes {
            // A negative or non-finite percent is not a measurement. Admitting
            // one would poison the total and make every share meaningless —
            // including the shares of processes that were measured correctly.
            guard process.cpuPercent.isFinite, process.cpuPercent > 0 else { continue }
            cpuSeconds[process.name, default: 0] += process.cpuPercent * dt / 100
        }
        evictIfOverCapacity()
    }

    /// Drops the smallest contributors when the map outgrows its bound.
    ///
    /// Safe in the sense that matters: an entry small enough to be evicted could
    /// not have been in the top `topCount`. A process that is evicted and later
    /// grows re-enters from zero and so understates itself — accepted, because
    /// the alternative is an accumulator whose size is set by whatever the
    /// machine happened to run.
    private mutating func evictIfOverCapacity() {
        guard cpuSeconds.count > capacity else { return }
        let keep = max(topCount, capacity / 2)
        let survivors = cpuSeconds.sorted(by: Self.ranked).prefix(keep)
        cpuSeconds = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    /// Largest first, ties broken by name. Eviction and `top()` share it, so an
    /// entry can never be evicted that `top()` would have kept.
    private static func ranked(_ a: (key: String, value: Double),
                               _ b: (key: String, value: Double)) -> Bool {
        a.value == b.value ? a.key < b.key : a.value > b.value
    }

    /// Share of the event's CPU-seconds, which is what makes the record
    /// actionable — "your Mac throttled" is noise, "swift-frontend accounted for
    /// 71% of it" is not.
    ///
    /// Ties break on name so the order is stable between calls; a list that
    /// reshuffled between two ticks would be written to the database twice with
    /// different contents for the same event.
    func top() -> [ProcessShare] {
        let ranked = cpuSeconds.sorted(by: Self.ranked)
        // Totalled in that order, not the dictionary's. Swift seeds its hashing
        // per process, so iteration order differs from one launch to the next,
        // and floating-point addition is not associative: the same event summed
        // to a total that differed in its last bits between runs, and every
        // percentage derived from it with it. The shares are what get written to
        // the database and shown as "71% of it" — the same event has to produce
        // the same row twice.
        let total = ranked.reduce(0) { $0 + $1.value }
        guard total > 0, total.isFinite else { return [] }
        return ranked
            .prefix(topCount)
            .map { ProcessShare(name: $0.key, percent: $0.value / total * 100) }
    }

    /// Forget everything collected so far.
    ///
    /// Called when an event ends *and* when the user switches attribution off
    /// mid-event. The second is the one that matters: without it, names already
    /// gathered stayed on the in-flight record and went on being written to the
    /// database after the user had said stop. Switching it off means "forget
    /// this", not "stop adding to it".
    mutating func reset() {
        cpuSeconds.removeAll(keepingCapacity: false)
    }
}
