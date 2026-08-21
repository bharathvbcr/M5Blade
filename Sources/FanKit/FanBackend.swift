import Foundation

/// What returning the fans to macOS actually achieved.
///
/// `releaseAll` is the panic path: the watchdog, every signal handler, and every
/// fallback in the app end here. It therefore does not throw — a panic path that
/// can abort halfway is not a panic path — but it must never report success it
/// did not achieve. "No fans to release" is its own case precisely because it
/// used to be indistinguishable from "released every fan".
public struct ReleaseOutcome: Sendable, Equatable {
    public var released: [Int] = []
    /// Fan index -> why. A write that failed, or a fan still under manual
    /// control after the write.
    public var failed: [Int: String] = [:]
    /// Written successfully, but the mode could not be read back to confirm it.
    public var unverified: [Int] = []
    /// The backend knows of no fans. Not success.
    public var hadNoFans: Bool = false

    public init() {}

    public var isComplete: Bool { failed.isEmpty && !hadNoFans }

    public var summary: String {
        if hadNoFans { return "no fans known to the backend — nothing was released" }
        var parts: [String] = []
        if !released.isEmpty { parts.append("released \(released.sorted().map(String.init).joined(separator: ","))") }
        if !unverified.isEmpty { parts.append("unverified \(unverified.sorted().map(String.init).joined(separator: ","))") }
        for (fan, why) in failed.sorted(by: { $0.key < $1.key }) { parts.append("fan \(fan) failed: \(why)") }
        return parts.joined(separator: "; ")
    }
}

/// What the hardware supports, probed at runtime rather than inferred from the
/// model name.
public struct FanCapabilities: Sendable, Equatable {
    public let modeKeySuffix: String?
    public let hasFtstUnlock: Bool
    public let fanCount: Int

    public init(modeKeySuffix: String?, hasFtstUnlock: Bool, fanCount: Int) {
        self.modeKeySuffix = modeKeySuffix
        self.hasFtstUnlock = hasFtstUnlock
        self.fanCount = fanCount
    }

    public var generationHint: String {
        switch (modeKeySuffix, hasFtstUnlock) {
        case ("md", false): return "M5-style: direct mode writes, no unlock needed"
        case ("Md", true):  return "M3/M4-style: Ftst unlock required"
        case ("Md", false): return "M1/M2 or Intel: direct mode writes"
        default:            return "unrecognised — proceed in monitor-only mode"
        }
    }
}

/// Everything the control loop needs from hardware. Two implementations:
/// `SMCFanBackend` (real) and `SimulatedFanBackend` (tests, CI, demo mode).
public protocol FanBackend: Sendable {
    func discoverFans() async throws -> [FanDescriptor]
    func readFan(_ index: Int) async throws -> FanReading
    func setMode(_ mode: FanMode, fan: Int) async throws
    func setTarget(rpm: Double, fan: Int) async throws
    func releaseAll() async -> ReleaseOutcome
    func capabilities() async -> FanCapabilities
}

/// First-order thermal model. Heat in from a synthetic load, heat out
/// proportional to airflow. Enough to exercise the control loop end to end.
public actor SimulatedFanBackend: FanBackend {
    public struct Config: Sendable {
        public var fanCount: Int = 2
        public var minRPM: Double = 1200
        public var maxRPM: Double = 8400
        public var ambientC: Double = 24
        public var heatPerLoad: Double = 55      // °C at full load, no airflow
        public var coolingCoefficient: Double = 0.9
        public var thermalTimeConstant: Double = 12   // seconds
        public var spinUpTimeConstant: Double = 1.5
        public init() {}
    }

    /// Injected hardware faults, so the fail-closed paths can be exercised
    /// without unplugging anything. Every one of these is a real SMC behaviour:
    /// writes rejected while `thermalmonitord` holds the fan, keys that vanish,
    /// and mode writes that report success but do not take.
    public struct Faults: Sendable, Equatable {
        public var rejectTargetWrites = false
        public var rejectModeWrites = false
        /// Mode writes report success but the fan stays where it was.
        public var modeWritesSilentlyIgnored = false
        /// `readFan` throws — the mode cannot be verified.
        public var readsFail = false
        public init() {}
    }

    public enum SimulatedError: Error, Equatable { case writeRejected, readFailed }

    private var config: Config
    private var temp: Double
    private var load: Double = 0
    private var modes: [Int: FanMode] = [:]
    private var targets: [Int: Double] = [:]
    private var actuals: [Int: Double] = [:]
    private var faults = Faults()

    public init(config: Config = Config()) {
        self.config = config
        self.temp = config.ambientC
        for i in 0..<config.fanCount {
            modes[i] = .system
            targets[i] = 0
            actuals[i] = 0
        }
    }

    public func setFaults(_ value: Faults) { faults = value }
    public func mode(of fan: Int) -> FanMode? { modes[fan] }
    public func target(of fan: Int) -> Double? { targets[fan] }
    public func setTemperature(_ value: Double) { temp = value }

    public func setLoad(_ value: Double) { load = max(0, min(1, value)) }
    public var currentTemp: Double { temp }

    /// Advance the simulation. In system mode the model applies a crude stock
    /// policy so "released to system" is not the same as "no cooling".
    public func advance(_ dt: TimeInterval) {
        for i in 0..<config.fanCount {
            let commanded: Double
            if modes[i] == .manual {
                commanded = targets[i] ?? 0
            } else {
                let t = max(0, min(1, (temp - 60) / 35))
                commanded = t <= 0 ? 0 : config.minRPM + t * (config.maxRPM - config.minRPM)
            }
            let current = actuals[i] ?? 0
            let k = min(1, dt / config.spinUpTimeConstant)
            actuals[i] = current + (commanded - current) * k
        }

        let meanRPM = actuals.values.reduce(0, +) / Double(max(1, config.fanCount))
        let airflow = meanRPM / config.maxRPM
        let equilibrium = config.ambientC
            + load * config.heatPerLoad
            - airflow * config.coolingCoefficient * config.heatPerLoad * 0.75
        let k = min(1, dt / config.thermalTimeConstant)
        temp += (max(config.ambientC, equilibrium) - temp) * k
    }

    // MARK: FanBackend

    public func discoverFans() -> [FanDescriptor] {
        (0..<config.fanCount).map {
            FanDescriptor(index: $0, minRPM: config.minRPM,
                          maxRPM: config.maxRPM, modeKeyName: "F\($0)md")
        }
    }

    public func readFan(_ index: Int) throws -> FanReading {
        if faults.readsFail { throw SimulatedError.readFailed }
        return FanReading(index: index,
                          actualRPM: actuals[index] ?? 0,
                          targetRPM: targets[index],
                          mode: modes[index])
    }

    public func setMode(_ mode: FanMode, fan: Int) throws {
        if faults.rejectModeWrites { throw SimulatedError.writeRejected }
        if faults.modeWritesSilentlyIgnored { return }
        modes[fan] = mode
    }

    public func setTarget(rpm: Double, fan: Int) throws {
        if faults.rejectTargetWrites { throw SimulatedError.writeRejected }
        targets[fan] = rpm
    }

    public func releaseAll() -> ReleaseOutcome {
        var outcome = ReleaseOutcome()
        guard config.fanCount > 0 else {
            outcome.hadNoFans = true
            return outcome
        }
        for i in 0..<config.fanCount {
            do {
                try setMode(.system, fan: i)
            } catch {
                outcome.failed[i] = String(describing: error)
                continue
            }
            guard !faults.readsFail else {
                outcome.unverified.append(i)
                targets[i] = 0
                continue
            }
            if modes[i]?.isUserControlled == true {
                outcome.failed[i] = "still under manual control after the write"
            } else {
                outcome.released.append(i)
                targets[i] = 0
            }
        }
        return outcome
    }

    public func capabilities() -> FanCapabilities {
        FanCapabilities(modeKeySuffix: "md", hasFtstUnlock: false, fanCount: config.fanCount)
    }
}
