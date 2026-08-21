import Foundation

public enum FanMode: UInt8, Sendable, Codable {
    case auto = 0
    case manual = 1
    case forced = 2      // legacy T2 only
    case system = 3      // Apple Silicon default; thermalmonitord is in charge

    public var isUserControlled: Bool { self == .manual || self == .forced }
}

/// A physical fan discovered at runtime. Ranges come from the hardware but are
/// advisory — the SMC accepts targets outside them, including 0 rpm.
public struct FanDescriptor: Sendable, Codable, Identifiable, Equatable {
    public let index: Int
    public let minRPM: Double?
    public let maxRPM: Double?
    /// The mode key actually present on this machine. Casing varies by
    /// generation: uppercase "F0Md" through M4, lowercase "F0md" on M5.
    public let modeKeyName: String

    public var id: Int { index }

    public init(index: Int, minRPM: Double?, maxRPM: Double?, modeKeyName: String) {
        self.index = index
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.modeKeyName = modeKeyName
    }

    /// Conservative fallbacks when the hardware doesn't report a usable range.
    ///
    /// "Usable" is doing real work here. `minRPM`/`maxRPM` come straight from
    /// `F0Mn`/`F0Mx`, and a read that half-fails yields a `Double` that is NaN,
    /// negative, or inverted rather than a missing value. Any of those poisons
    /// everything downstream: NaN propagates through `rpm(forPercent:)` into a
    /// target, and the SMC encoders turn NaN into the *maximum* because every
    /// comparison against it is false. An inverted range is quieter and worse —
    /// `percent(forRPM:)` and `rpm(forPercent:)` stop being inverses, so the
    /// control loop's slew limiting and the safety floor disagree about which
    /// direction is faster. Both are normalised here, at the single place that
    /// defines what a fan's range *is*.
    public var effectiveMin: Double { Self.usable(minRPM) ?? 1200 }

    public var effectiveMax: Double {
        // Never below the minimum: a degenerate range yields a fan pinned to its
        // minimum, which is a coherent (if useless) fan, rather than percentages
        // that run backwards.
        Swift.max(Self.usable(maxRPM) ?? 4000, effectiveMin)
    }

    private static func usable(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// True only when the hardware reported a range that can actually be used.
    /// A NaN or inverted pair is not a reported range; treating it as one is how
    /// the UI came to show "1350–NaN rpm".
    public var hasReportedRange: Bool {
        guard let low = Self.usable(minRPM), let high = Self.usable(maxRPM) else { return false }
        return high > low
    }

    public func rpm(forPercent percent: Double) -> Double {
        let p = max(0, min(100, percent)) / 100
        return effectiveMin + p * (effectiveMax - effectiveMin)
    }

    /// Position within the *controllable* range: 0% is the fan's minimum, not a
    /// stopped fan. This is the control abstraction curves are authored in, and
    /// the inverse of `rpm(forPercent:)`.
    ///
    /// Do not show this to a user as "fan speed" — a fan idling at its 1350 rpm
    /// minimum is genuinely spinning but reports 0% here. Use `dutyPercent` for
    /// anything a person reads.
    public func percent(forRPM rpm: Double) -> Double {
        let span = effectiveMax - effectiveMin
        guard span > 0 else { return 0 }
        return max(0, min(100, (rpm - effectiveMin) / span * 100))
    }

    /// Speed as a fraction of this fan's maximum — what "the fan is at 40%"
    /// means to a person reading a dashboard.
    public func dutyPercent(forRPM rpm: Double) -> Double {
        guard effectiveMax > 0 else { return 0 }
        return max(0, min(100, rpm / effectiveMax * 100))
    }
}

public struct FanReading: Sendable, Equatable {
    public let index: Int
    public let actualRPM: Double
    public let targetRPM: Double?
    public let mode: FanMode?

    public init(index: Int, actualRPM: Double, targetRPM: Double?, mode: FanMode?) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }
}

/// Apple's public thermal signal. The most trustworthy input in the system —
/// it is the OS telling you directly (AUDIT A-1).
public enum ThermalPressure: Int, Sendable, Codable, Comparable {
    case nominal = 0, fair = 1, serious = 2, critical = 3

    public static func < (a: ThermalPressure, b: ThermalPressure) -> Bool {
        a.rawValue < b.rawValue
    }
}
