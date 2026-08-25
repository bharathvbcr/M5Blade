import Foundation
import SMCKit

/// The firmware charge-limit state, decoded from the keys Apple's own
/// utilities use.
///
/// Byte semantics verified against `zackelia/bclm` (the reference
/// implementation) and independent community documentation:
///
/// * **CHWA** (Apple Silicon, ui8): `0x01` engages the native 80 % limit,
///   `0x00` releases it. The limit lives in firmware — it survives sleep and
///   reboot with no daemon holding it. Only 80 and 100 are expressible, and
///   firmware ≥ 13.0 is required.
/// * **BCLM** (Intel, ui8): the percent itself, 50–100.
///
/// On macOS ≥ 15 the kernel refuses these writes to processes without an
/// Apple entitlement regardless of root (the reason `bclm` stopped working),
/// so a successful *read* never implies a permitted *write*; every write is
/// followed by a read-back that says what actually took.
public enum ChargeLimitState: Equatable, Sendable {
    /// Neither key exists on this machine — the common case on current
    /// Macs, where charging is managed by the gauge and macOS's own Charge
    /// Limit in System Settings.
    case unsupported
    /// The firmware holds charging at 80 %.
    case limitedTo80
    /// No firmware limit: charge to full.
    case fullCharge
    /// A byte this decoder does not know. Reported rather than guessed at.
    case unknown(raw: UInt8)

    public var isKnown: Bool {
        switch self {
        case .limitedTo80, .fullCharge: return true
        default: return false
        }
    }

    /// 80 or 100 when known; nil for unknown/unsupported states.
    public var percent: Int? {
        switch self {
        case .limitedTo80: return 80
        case .fullCharge: return 100
        case .unsupported, .unknown: return nil
        }
    }
}

/// Which firmware keys this machine exposes.
public struct ChargeLimitSupport: Equatable, Sendable {
    public var hasAppleSiliconKey = false   // CHWA
    public var hasIntelKey = false          // BCLM

    public var isSupported: Bool { hasAppleSiliconKey || hasIntelKey }

    public init(hasAppleSiliconKey: Bool = false, hasIntelKey: Bool = false) {
        self.hasAppleSiliconKey = hasAppleSiliconKey
        self.hasIntelKey = hasIntelKey
    }
}

public enum ChargeLimit {

    /// CHWA byte → state. Unknown bytes are carried through verbatim: the SMC
    /// adds meanings between firmware generations and inventing one here would
    /// present a guess as a measurement.
    public static func state(fromAppleSiliconByte byte: UInt8) -> ChargeLimitState {
        switch byte {
        case 0x00: return .fullCharge
        case 0x01: return .limitedTo80
        default: return .unknown(raw: byte)
        }
    }

    /// BCLM stores the percent directly.
    public static func state(fromIntelByte byte: UInt8) -> ChargeLimitState {
        switch byte {
        case 0...79:      return .unknown(raw: byte)
        case 80...99:     return .limitedTo80
        case 100:         return .fullCharge
        default:          return .unknown(raw: byte)
        }
    }

    /// The byte to write for a requested percent on this machine's key.
    /// Anything other than 80/100 is refused by construction — DESIGN §6.3's
    /// "detect first" rule applied to our own callers as well as the OS.
    public static func byte(forPercent percent: Int,
                            appleSiliconKey: Bool) -> UInt8? {
        guard percent == 80 || percent == 100 else { return nil }
        if appleSiliconKey {
            return percent == 80 ? 0x01 : 0x00
        }
        return UInt8(percent)
    }
}
