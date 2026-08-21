import Foundation
import FanKit

/// Declares thermal throttle episodes by signal fusion (DESIGN §3.2).
///
/// The trap this avoids: on Apple Silicon macOS routinely runs cores below
/// maximum frequency for reasons that have nothing to do with heat, so
/// "clock below max ⇒ throttling" produces constant false positives. Instead a
/// sustained-demand **gate** must hold, and then either `thermalState ≥ serious`
/// — Apple telling us directly, so it gets a fast path — or at least two
/// supporting signals agreeing.
///
/// A pure value type: given the same inputs it produces the same episodes, which
/// is what makes it testable without a hot Mac.
public struct ThrottleDetector: Sendable {

    public struct Configuration: Sendable {
        /// Demand gate — episodes are only declared under real load.
        public var gateCPUPercent: Double
        public var gateSeconds: TimeInterval
        /// Supporting signal. Per-model in principle; 95 °C is the conservative
        /// Apple Silicon package figure and is deliberately not the *only* thing
        /// that can declare an episode.
        public var packageTempThresholdC: Double
        /// A fan within this fraction of its maximum counts as "at the ceiling".
        public var fanCeilingFraction: Double
        /// How long the declaring condition must stay false before the episode
        /// is closed, so a one-sample dip doesn't split it in two.
        public var clearSeconds: TimeInterval
        /// How many processes to attribute an episode to.
        public var attributionCount: Int
        /// Distinct process names tracked at once. A build system spawns a great
        /// many short-lived processes under different names, and an episode can
        /// run for hours — without a bound the accumulator grows with the
        /// *variety* of what ran rather than with what mattered.
        public var attributionCapacity: Int

        public init(gateCPUPercent: Double = 70,
                    gateSeconds: TimeInterval = 20,
                    packageTempThresholdC: Double = 95,
                    fanCeilingFraction: Double = 0.95,
                    clearSeconds: TimeInterval = 15,
                    attributionCount: Int = 3,
                    attributionCapacity: Int = 256) {
            self.gateCPUPercent = gateCPUPercent
            self.gateSeconds = gateSeconds
            self.packageTempThresholdC = packageTempThresholdC
            self.fanCeilingFraction = fanCeilingFraction
            self.clearSeconds = clearSeconds
            self.attributionCount = max(1, attributionCount)
            self.attributionCapacity = max(attributionCount, attributionCapacity)
        }
    }

    /// Kept as a nested name so existing call sites read the same; there is only
    /// one type behind it.
    public typealias ProcessLoad = HistoryKit.ProcessLoad

    public struct Input: Sendable {
        public var date: Date
        public var cpuPercent: Double
        public var pressure: ThermalPressure
        public var maxTempC: Double?
        public var fanRPM: [Int: Double]
        /// True when any fan is at or near its maximum — a fan that has run out
        /// of headroom is corroborating evidence, not proof.
        public var fanNearCeiling: Bool
        public var profileName: String
        public var onBattery: Bool
        public var externalDisplayCount: Int
        /// Empty unless the user opted into attribution (DESIGN §5.4).
        public var processes: [ProcessLoad]

        public init(date: Date,
                    cpuPercent: Double,
                    pressure: ThermalPressure,
                    maxTempC: Double?,
                    fanRPM: [Int: Double] = [:],
                    fanNearCeiling: Bool = false,
                    profileName: String = "",
                    onBattery: Bool = false,
                    externalDisplayCount: Int = 0,
                    processes: [ProcessLoad] = []) {
            self.date = date
            self.cpuPercent = cpuPercent
            self.pressure = pressure
            self.maxTempC = maxTempC
            self.fanRPM = fanRPM
            self.fanNearCeiling = fanNearCeiling
            self.profileName = profileName
            self.onBattery = onBattery
            self.externalDisplayCount = externalDisplayCount
            self.processes = processes
        }
    }

    public enum Event: Sendable, Equatable {
        case none
        /// An episode just started. The payload has no end and no id yet.
        case opened(ThrottleEpisode)
        /// Still running; the payload carries the accumulators so far.
        case updated(ThrottleEpisode)
        case closed(ThrottleEpisode)
    }

    public var configuration: Configuration

    /// The episode in progress, if any. Its `end` is nil until it closes.
    public private(set) var current: ThrottleEpisode?

    private var gateSince: Date?
    private var lastDeclared: Date?
    private var lastInput: Date?
    private var cpuSum: Double = 0
    private var cpuSamples: Int = 0
    private var attribution: ProcessAttribution

    /// Raw attribution totals for the episode in progress. Internal rather than
    /// public: the app only ever needs the shares on the episode itself.
    var accumulatedCPUSeconds: [String: Double] { attribution.cpuSecondsByProcess }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.attribution = ProcessAttribution(capacity: configuration.attributionCapacity,
                                              topCount: configuration.attributionCount)
    }

    /// Whether application names may be retained (DESIGN §5.4).
    ///
    /// Switching it off **discards what has already been collected** for the
    /// episode in progress, rather than merely stopping collection. Without
    /// that, names gathered before the user said stop stayed on the open record
    /// and went on being written to the database on every subsequent tick.
    public mutating func setRecordsProcessNames(_ enabled: Bool) {
        guard !enabled else { return }
        attribution.reset()
        current?.processes = []
    }

    public mutating func update(_ input: Input) -> Event {
        // A sleep/wake gap must not be counted as CPU-seconds, so dt is clamped
        // to something a sampling tick could plausibly be.
        let dt = lastInput.map { min(max(0, input.date.timeIntervalSince($0)), 60) } ?? 0
        lastInput = input.date

        // A number that cannot be a temperature is not a missing reading and not
        // a hot one — it is nothing, and it must not be able to supply the
        // supporting signal that declares an episode or become a `peakTempC` the
        // History window then draws. Validated once here so every use below
        // reads the same value.
        var input = input
        input.maxTempC = PlausibleTemperature.validated(input.maxTempC)

        if input.cpuPercent >= configuration.gateCPUPercent {
            if gateSince == nil { gateSince = input.date }
        } else {
            gateSince = nil
        }
        let gateHolds = gateSince.map {
            input.date.timeIntervalSince($0) >= configuration.gateSeconds
        } ?? false

        var supporting = 0
        if let temp = input.maxTempC, temp >= configuration.packageTempThresholdC { supporting += 1 }
        if input.fanNearCeiling { supporting += 1 }

        let declaring = gateHolds && (input.pressure >= .serious || supporting >= 2)

        if declaring {
            lastDeclared = input.date
            if current == nil {
                begin(input)
                return .opened(current!)
            }
            accumulate(input, dt: dt)
            return .updated(current!)
        }

        guard var episode = current else { return .none }
        guard let lastDeclared,
              input.date.timeIntervalSince(lastDeclared) >= configuration.clearSeconds else {
            return .none
        }
        // End at the last instant the condition actually held, not at the moment
        // we became confident it had stopped.
        episode.end = lastDeclared
        episode.processes = attribution.top()
        current = nil
        reset()
        return .closed(episode)
    }

    private mutating func begin(_ input: Input) {
        cpuSum = 0
        cpuSamples = 0
        attribution.reset()
        current = ThrottleEpisode(start: input.date,
                                  peakTempC: input.maxTempC,
                                  peakPressure: input.pressure.rawValue,
                                  meanCPUPercent: input.cpuPercent,
                                  profileName: input.profileName,
                                  onBattery: input.onBattery,
                                  externalDisplayCount: input.externalDisplayCount,
                                  fanRPMAtPeak: input.fanRPM)
        cpuSum = input.cpuPercent
        cpuSamples = 1
    }

    private mutating func accumulate(_ input: Input, dt: TimeInterval) {
        guard var episode = current else { return }

        // Fan speeds are captured at the temperature peak, so the record answers
        // "how hard were the fans working when it was worst?" rather than
        // "what were they doing when it ended?".
        if let temp = input.maxTempC, temp > (episode.peakTempC ?? -.infinity) {
            episode.peakTempC = temp
            episode.fanRPMAtPeak = input.fanRPM
        }
        episode.peakPressure = max(episode.peakPressure, input.pressure.rawValue)

        cpuSum += input.cpuPercent
        cpuSamples += 1
        episode.meanCPUPercent = cpuSum / Double(cpuSamples)

        attribution.add(input.processes, dt: dt)
        episode.processes = attribution.top()
        current = episode
    }

    private mutating func reset() {
        lastDeclared = nil
        cpuSum = 0
        cpuSamples = 0
        attribution.reset()
    }
}
