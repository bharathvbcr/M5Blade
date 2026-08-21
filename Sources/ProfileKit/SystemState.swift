import Foundation
import FanKit

public struct ProcessSnapshot: Sendable, Codable, Equatable {
    public var pid: Int32
    public var executableName: String
    public var bundleID: String?
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    /// How long this process has been continuously busy — that is, continuously
    /// present and above `activityThresholdPercent`. Paired with a rule's own
    /// `sustainedCPU`, which is checked against the instantaneous `cpuPercent`:
    /// "has been working for a while, and is working hard right now".
    public var activeFor: TimeInterval

    /// The bar for "this process is doing something", used only for the sustain
    /// clock. Deliberately low: it marks the start of a busy stretch, while the
    /// rule's own threshold decides whether that stretch is hot enough to act on.
    public static let activityThresholdPercent: Double = 5

    public init(pid: Int32, executableName: String, bundleID: String? = nil,
                cpuPercent: Double, memoryBytes: UInt64 = 0, activeFor: TimeInterval = 0) {
        self.pid = pid
        self.executableName = executableName
        self.bundleID = bundleID
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.activeFor = activeFor
    }
}

/// Everything the resolver needs. A plain value type, so the resolver is a pure
/// function and the whole precedence system is testable without hardware.
public struct SystemState: Sendable, Equatable {
    public var timestamp: Date
    public var maxTempC: Double?
    public var thermalPressure: ThermalPressure
    public var cpuPercent: Double
    /// Seconds the machine has been continuously above
    /// `loadActivityThresholdPercent`. Same pairing as `ProcessSnapshot.activeFor`:
    /// the rule's own `cpuPercent` is checked against the instantaneous reading.
    public var loadSustainedFor: TimeInterval
    public var powerSource: PowerSource
    public var batteryPercent: Double?
    public var displaysAsleep: Bool
    public var externalDisplayCount: Int
    public var macOSPowerMode: MacOSPowerMode
    public var foregroundBundleID: String?
    public var processes: [ProcessSnapshot]

    public init(timestamp: Date = Date(),
                maxTempC: Double? = nil,
                thermalPressure: ThermalPressure = .nominal,
                cpuPercent: Double = 0,
                loadSustainedFor: TimeInterval = 0,
                powerSource: PowerSource = .ac,
                batteryPercent: Double? = nil,
                displaysAsleep: Bool = false,
                externalDisplayCount: Int = 0,
                macOSPowerMode: MacOSPowerMode = .automatic,
                foregroundBundleID: String? = nil,
                processes: [ProcessSnapshot] = []) {
        self.timestamp = timestamp
        self.maxTempC = maxTempC
        self.thermalPressure = thermalPressure
        self.cpuPercent = cpuPercent
        self.loadSustainedFor = loadSustainedFor
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.displaysAsleep = displaysAsleep
        self.externalDisplayCount = externalDisplayCount
        self.macOSPowerMode = macOSPowerMode
        self.foregroundBundleID = foregroundBundleID
        self.processes = processes
    }

    /// The bar for "this machine is under load", used only for the sustain clock.
    public static let loadActivityThresholdPercent: Double = 50
}
