import Foundation
import FanKit

public enum PowerSource: String, Sendable, Codable { case ac, battery }

public enum ProcessMatch: Sendable, Codable, Equatable {
    case bundleID(String)
    case executableName(String)

    public func matches(bundleID: String?, executable: String?) -> Bool {
        switch self {
        case .bundleID(let id):     return bundleID == id
        case .executableName(let n): return executable == n
        }
    }
}

public enum Condition: Sendable, Codable, Equatable {
    case powerSource(PowerSource)
    case batteryBelow(percent: Int)
    case thermalAtLeast(ThermalPressure)
    case processActive(match: ProcessMatch, sustainedCPU: Double?, forSeconds: TimeInterval?)
    case foregroundApp(bundleID: String)
    case displaysAsleep(Bool)
    case externalDisplayCount(atLeast: Int)
    case macOSPowerMode(MacOSPowerMode)
    case sustainedLoad(cpuPercent: Double, forSeconds: TimeInterval)

    public func isSatisfied(by state: SystemState) -> Bool {
        switch self {
        case .powerSource(let want):
            return state.powerSource == want
        case .batteryBelow(let pct):
            return (state.batteryPercent ?? 100) < Double(pct)
        case .thermalAtLeast(let level):
            return state.thermalPressure >= level
        case .processActive(let match, let cpu, let seconds):
            guard let p = state.processes.first(where: {
                match.matches(bundleID: $0.bundleID, executable: $0.executableName)
            }) else { return false }
            if let cpu, p.cpuPercent < cpu { return false }
            if let seconds, p.activeFor < seconds { return false }
            return true
        case .foregroundApp(let id):
            return state.foregroundBundleID == id
        case .displaysAsleep(let want):
            return state.displaysAsleep == want
        case .externalDisplayCount(let n):
            return state.externalDisplayCount >= n
        case .macOSPowerMode(let mode):
            return state.macOSPowerMode == mode
        case .sustainedLoad(let pct, let seconds):
            return state.cpuPercent >= pct && state.loadSustainedFor >= seconds
        }
    }
}

public struct Rule: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// Evaluated top to bottom; first match wins. Order is the priority.
    public var conditions: [Condition]
    public var targetProfileID: UUID
    public var minDwell: TimeInterval
    public var debounce: TimeInterval

    public init(id: UUID = UUID(),
                name: String,
                enabled: Bool = true,
                conditions: [Condition],
                targetProfileID: UUID,
                minDwell: TimeInterval = 30,
                debounce: TimeInterval = 5) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.targetProfileID = targetProfileID
        self.minDwell = minDwell
        self.debounce = debounce
    }

    /// All conditions must hold.
    public func matches(_ state: SystemState) -> Bool {
        enabled && !conditions.isEmpty && conditions.allSatisfy { $0.isSatisfied(by: state) }
    }
}
