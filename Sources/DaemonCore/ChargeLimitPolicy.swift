import Foundation
import PowerKit

/// The policy for firmware charge-limit requests (DESIGN §6.3).
///
/// Pure, so the whole refusal surface is testable without root, hardware, or
/// an XPC listener — the same seam every other daemon decision sits behind.
///
/// The rules, from the design's own recommendation:
/// * Only 80 or 100 may be written. The firmware accepts nothing else and a
///   passthrough would make this interface an arbitrary-byte write.
/// * A machine with no charge-limit key refuses before touching anything.
/// * No battery, nothing to limit.
/// Why a set-charge-limit request did not take. A distinct type rather than a
/// bare string so callers can pattern-match without parsing prose.
public struct ChargeLimitWriteFailure: Error, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var localizedDescription: String { reason }
}

public enum ChargeLimitPolicy {

    public static let allowedPercents: [Int] = [80, 100]

    public enum Rejection: Error, Equatable, Sendable {
        case unsupportedPercent(Int)
        case noFirmwareKey
        case noBattery
    }

    /// Validates one request against what the machine reports. Returns the
    /// byte to write on success — encoding lives here too, so there is one
    /// place that knows both halves of the transaction.
    public static func validate(percent: Int,
                                support: ChargeLimitSupport,
                                batteryInstalled: Bool?)
        -> Result<(percent: Int, keyName: String), Rejection> {
        guard allowedPercents.contains(percent) else {
            return .failure(.unsupportedPercent(percent))
        }
        guard support.isSupported else {
            return .failure(.noFirmwareKey)
        }
        // Nil means "not reported", which is not "present": a desktop with a
        // CHWA key would still have nothing to limit — and writing firmware
        // state on a machine whose battery cannot even be seen is not a write
        // anyone asked for.
        if batteryInstalled != true {
            return .failure(.noBattery)
        }
        return .success((percent: percent,
                         keyName: support.hasAppleSiliconKey ? "CHWA" : "BCLM"))
    }
}
