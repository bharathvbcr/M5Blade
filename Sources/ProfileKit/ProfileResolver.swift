import Foundation
import FanKit

public enum ResolutionSource: Sendable, Equatable {
    case emergency
    case manualPin
    case rule(id: UUID, name: String)
    case defaultProfile

    public var displayReason: String {
        switch self {
        case .emergency:        return "Emergency"
        case .manualPin:        return "Manual"
        case .rule(_, let n):   return "Auto · rule \"\(n)\""
        case .defaultProfile:   return "Default"
        }
    }
}

public struct Resolution: Sendable, Equatable {
    public let profileID: UUID
    public let source: ResolutionSource
    /// Set when EMERGENCY fires — the ceiling is released regardless of profile.
    public let releaseCeiling: Bool
}

public struct ManualPin: Sendable, Equatable {
    public var profileID: UUID
    public var setAt: Date
    public var expiresAt: Date?
    /// Unplugging clears the pin, so a Performance pin doesn't follow you onto battery.
    public var clearOnPowerSourceChange: Bool
    public var powerSourceAtPin: PowerSource

    public init(profileID: UUID, setAt: Date, expiresAt: Date? = nil,
                clearOnPowerSourceChange: Bool = true,
                powerSourceAtPin: PowerSource) {
        self.profileID = profileID
        self.setAt = setAt
        self.expiresAt = expiresAt
        self.clearOnPowerSourceChange = clearOnPowerSourceChange
        self.powerSourceAtPin = powerSourceAtPin
    }

    public func isValid(at now: Date, state: SystemState) -> Bool {
        if let expiry = expiresAt, now >= expiry { return false }
        if clearOnPowerSourceChange && state.powerSource != powerSourceAtPin { return false }
        return true
    }
}

/// Resolves which profile should be active.
///
/// Strict precedence, per DESIGN 2.4:
///   1. EMERGENCY  2. MANUAL PIN  3. RULES  4. DEFAULT
///
/// Deliberately a value type holding only dwell/debounce bookkeeping, so
/// `resolve` is deterministic given its inputs.
public struct ProfileResolver: Sendable {
    public var defaultProfileID: UUID
    public var emergencyProfileID: UUID

    private var activeRuleID: UUID?
    private var activeRuleSince: Date?
    private var candidateRuleID: UUID?
    private var candidateSince: Date?

    public init(defaultProfileID: UUID,
                emergencyProfileID: UUID = Profile.maxCoolingID) {
        self.defaultProfileID = defaultProfileID
        self.emergencyProfileID = emergencyProfileID
    }

    public mutating func reset() {
        activeRuleID = nil
        activeRuleSince = nil
        candidateRuleID = nil
        candidateSince = nil
    }

    public mutating func resolve(state: SystemState,
                                 rules: [Rule],
                                 pin: ManualPin?,
                                 floor: SafetyFloor,
                                 now: Date) -> Resolution {

        // 1. EMERGENCY — cannot be overridden by anything below.
        let temp = state.maxTempC ?? 0
        if floor.requiresEmergency(tempC: temp, pressure: state.thermalPressure) {
            return Resolution(profileID: emergencyProfileID,
                              source: .emergency,
                              releaseCeiling: true)
        }

        // 2. MANUAL PIN
        if let pin, pin.isValid(at: now, state: state) {
            return Resolution(profileID: pin.profileID,
                              source: .manualPin,
                              releaseCeiling: false)
        }

        // 3. RULES — first match wins, with debounce on entry and dwell on exit.
        let matching = rules.first { $0.matches(state) }

        // Dwell holds a rule whose *conditions* stopped matching. It must not
        // hold a rule the user just switched off or deleted: turning a rule off
        // and watching it keep driving the fans for another 30 seconds reads as
        // the switch being broken.
        if let active = activeRuleID, !rules.contains(where: { $0.id == active && $0.enabled }) {
            activeRuleID = nil
            activeRuleSince = nil
        }

        if let active = activeRuleID,
           let since = activeRuleSince,
           let rule = rules.first(where: { $0.id == active }) {
            let heldLongEnough = now.timeIntervalSince(since) >= rule.minDwell
            if !heldLongEnough {
                return Resolution(profileID: rule.targetProfileID,
                                  source: .rule(id: rule.id, name: rule.name),
                                  releaseCeiling: false)
            }
            if matching?.id == active {
                return Resolution(profileID: rule.targetProfileID,
                                  source: .rule(id: rule.id, name: rule.name),
                                  releaseCeiling: false)
            }
        }

        if let candidate = matching {
            // Start tracking a newly-seen candidate, then test its debounce in the
            // same pass. Testing only on a *later* pass would make `debounce: 0`
            // mean "one tick", so a zero-debounce rule could never win on the first
            // sample that matched it.
            if candidateRuleID != candidate.id {
                candidateRuleID = candidate.id
                candidateSince = now
            }

            if let since = candidateSince, now.timeIntervalSince(since) >= candidate.debounce {
                activeRuleID = candidate.id
                activeRuleSince = now
                candidateRuleID = nil
                candidateSince = nil
                return Resolution(profileID: candidate.targetProfileID,
                                  source: .rule(id: candidate.id, name: candidate.name),
                                  releaseCeiling: false)
            }

            // Still debouncing — hold whatever we had.
            if let active = activeRuleID,
               let rule = rules.first(where: { $0.id == active }) {
                return Resolution(profileID: rule.targetProfileID,
                                  source: .rule(id: rule.id, name: rule.name),
                                  releaseCeiling: false)
            }
            return Resolution(profileID: defaultProfileID,
                              source: .defaultProfile,
                              releaseCeiling: false)
        }

        // 4. DEFAULT
        candidateRuleID = nil
        candidateSince = nil
        activeRuleID = nil
        activeRuleSince = nil
        return Resolution(profileID: defaultProfileID,
                          source: .defaultProfile,
                          releaseCeiling: false)
    }
}
