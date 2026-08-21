import Foundation
import FanKit

/// The editable shape of a `Condition`, so the UI can enumerate what a user may
/// author without a switch over associated values in every view.
public enum ConditionKind: String, CaseIterable, Identifiable, Sendable {
    case thermalAtLeast
    case processActive
    case foregroundApp
    case sustainedLoad
    case powerSource
    case batteryBelow
    case externalDisplayCount
    case displaysAsleep
    case macOSPowerMode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thermalAtLeast:       return "Thermal pressure is at least"
        case .processActive:        return "An app is running and busy"
        case .foregroundApp:        return "Frontmost app is"
        case .sustainedLoad:        return "CPU has been under sustained load"
        case .powerSource:          return "Power source is"
        case .batteryBelow:         return "Battery is below"
        case .externalDisplayCount: return "External displays connected"
        case .displaysAsleep:       return "Displays are asleep"
        case .macOSPowerMode:       return "macOS power mode is"
        }
    }

    /// A sensible starting value when the user picks this kind.
    public var defaultCondition: Condition {
        switch self {
        case .thermalAtLeast:       return .thermalAtLeast(.fair)
        case .processActive:        return .processActive(match: .executableName(""),
                                                          sustainedCPU: 50, forSeconds: 15)
        case .foregroundApp:        return .foregroundApp(bundleID: "")
        case .sustainedLoad:        return .sustainedLoad(cpuPercent: 70, forSeconds: 60)
        case .powerSource:          return .powerSource(.ac)
        case .batteryBelow:         return .batteryBelow(percent: 20)
        case .externalDisplayCount: return .externalDisplayCount(atLeast: 1)
        case .displaysAsleep:       return .displaysAsleep(true)
        case .macOSPowerMode:       return .macOSPowerMode(.low)
        }
    }
}

extension ThermalPressure {
    public var label: String {
        switch self {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        }
    }
}

extension Condition {
    public var kind: ConditionKind {
        switch self {
        case .powerSource:          return .powerSource
        case .batteryBelow:         return .batteryBelow
        case .thermalAtLeast:       return .thermalAtLeast
        case .processActive:        return .processActive
        case .foregroundApp:        return .foregroundApp
        case .displaysAsleep:       return .displaysAsleep
        case .externalDisplayCount: return .externalDisplayCount
        case .macOSPowerMode:       return .macOSPowerMode
        case .sustainedLoad:        return .sustainedLoad
        }
    }

    /// One-line human description, used wherever a rule is listed. Keeping this
    /// beside the model means the list and the editor can never disagree.
    public var summary: String {
        switch self {
        case .powerSource(let source):
            return source == .ac ? "On AC power" : "On battery"
        case .batteryBelow(let pct):
            return "Battery below \(pct)%"
        case .thermalAtLeast(let level):
            return "Thermal pressure ≥ \(level.label)"
        case .processActive(let match, let cpu, let seconds):
            var text = "\(match.displayName) running"
            if let cpu { text += " above \(Int(cpu))% CPU" }
            if let seconds { text += " for \(Int(seconds))s" }
            return text
        case .foregroundApp(let id):
            return "Frontmost app is \(id.isEmpty ? "—" : id)"
        case .displaysAsleep(let asleep):
            return asleep ? "Displays asleep" : "Displays awake"
        case .externalDisplayCount(let n):
            return "\(n)+ external display\(n == 1 ? "" : "s")"
        case .macOSPowerMode(let mode):
            return "macOS power mode is \(mode.rawValue)"
        case .sustainedLoad(let pct, let seconds):
            return "CPU ≥ \(Int(pct))% for \(Int(seconds))s"
        }
    }

    /// True when the condition can never match as written, so the editor can
    /// flag it instead of leaving the user with a rule that silently never fires.
    public var isIncomplete: Bool {
        switch self {
        case .processActive(let match, _, _): return match.displayName.isEmpty
        case .foregroundApp(let id):          return id.isEmpty
        default:                              return false
        }
    }
}

extension ProcessMatch {
    public var displayName: String {
        switch self {
        case .bundleID(let id):       return id
        case .executableName(let n):  return n
        }
    }
}

extension Rule {
    public var summary: String {
        conditions.isEmpty ? "No conditions — never matches"
                           : conditions.map(\.summary).joined(separator: " · ")
    }

    /// A rule with no conditions matches nothing (`Rule.matches` requires a
    /// non-empty list), which is worth saying out loud in the UI.
    public var isIncomplete: Bool {
        conditions.isEmpty || conditions.contains(where: \.isIncomplete)
    }
}
