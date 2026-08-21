import Foundation
import FanKit

public enum MacOSPowerMode: String, Sendable, Codable {
    case low, automatic, high
}

public struct Profile: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var isBuiltIn: Bool
    /// Per-fan curves, keyed by fan index (AUDIT A-3).
    public var fanCurves: [Int: FanCurve]
    public var settings: ControlSettings
    /// When true the profile hands control back to macOS entirely.
    public var releasesToSystem: Bool

    public init(id: UUID = UUID(),
                name: String,
                isBuiltIn: Bool = false,
                fanCurves: [Int: FanCurve] = [:],
                settings: ControlSettings = ControlSettings(),
                releasesToSystem: Bool = false) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.fanCurves = fanCurves
        self.settings = settings
        self.releasesToSystem = releasesToSystem
    }

    /// The curve driving a given fan.
    ///
    /// The fallback is the lowest-numbered curve, not `values.first`: dictionary
    /// iteration order is unspecified and varies between runs of the same
    /// binary, so a machine with a fan the config predates was picking one of
    /// its curves at random on every launch. A control path must not have a
    /// nondeterministic input.
    public func curve(forFan index: Int) -> FanCurve {
        if let exact = fanCurves[index] { return exact }
        if let lowest = fanCurves.keys.min(), let curve = fanCurves[lowest] { return curve }
        return .balanced
    }

    /// Corrects anything in this profile that the control loop cannot act on,
    /// returning what was changed. Called on every load, so a hand-edited file
    /// and the running behaviour never diverge silently.
    mutating func repair() -> [String] {
        var corrections: [String] = []

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            name = "Unnamed profile"
            corrections.append("A profile had no name and was renamed “Unnamed profile”.")
        } else if trimmed != name {
            name = trimmed
        }

        let sanitized = settings.sanitized()
        if sanitized != settings {
            corrections.append("Out-of-range control settings on “\(name)” were clamped.")
            settings = sanitized
        }

        for index in fanCurves.keys.sorted() where index < 0 {
            fanCurves[index] = nil
            corrections.append("Dropped a curve on “\(name)” for negative fan index \(index).")
        }

        // Stock has no curves by design; every other profile needs at least one
        // usable curve or it silently commands 0% at every temperature.
        guard !releasesToSystem else { return corrections }

        for (index, curve) in fanCurves where !curve.isUsable {
            fanCurves[index] = .balanced
            corrections.append("Curve for fan \(index + 1) on “\(name)” had no points; reset to Balanced.")
        }
        if fanCurves.isEmpty {
            fanCurves[0] = .balanced
            corrections.append("“\(name)” had no fan curves; gave it the Balanced curve.")
        }
        return corrections
    }

    // MARK: Built-ins

    public static func builtIns(fanCount: Int) -> [Profile] {
        func spread(_ curve: FanCurve) -> [Int: FanCurve] {
            Dictionary(uniqueKeysWithValues: (0..<max(1, fanCount)).map { ($0, curve) })
        }
        return [
            Profile(id: Profile.silentID, name: "Silent", isBuiltIn: true,
                    fanCurves: spread(.silent),
                    settings: ControlSettings(ceilingPercent: 60)),
            Profile(id: Profile.balancedID, name: "Balanced", isBuiltIn: true,
                    fanCurves: spread(.balanced),
                    settings: ControlSettings(ceilingPercent: 95)),
            Profile(id: Profile.performanceID, name: "Performance", isBuiltIn: true,
                    fanCurves: spread(.performance),
                    settings: ControlSettings(ceilingPercent: 95, hysteresisC: 2,
                                              slewUpRPMPerSec: 400)),
            Profile(id: Profile.maxCoolingID, name: "Max cooling", isBuiltIn: true,
                    fanCurves: spread(.maxCooling),
                    settings: ControlSettings(ceilingPercent: 100, hysteresisC: 2,
                                              slewUpRPMPerSec: 600)),
            Profile(id: Profile.stockID, name: "Stock", isBuiltIn: true,
                    releasesToSystem: true),
        ]
    }

    public static let silentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let balancedID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public static let performanceID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    public static let maxCoolingID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    /// The panic target. Every fallback path leads here.
    public static let stockID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
}
