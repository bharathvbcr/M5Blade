import Foundation

/// FourCC SMC key, e.g. "F0Ac". Stored as the big-endian packed UInt32 the SMC expects.
public struct SMCKey: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: UInt32

    public init(_ string: String) {
        let bytes = Array(string.utf8.prefix(4))
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(i < bytes.count ? bytes[i] : 0x20)
        }
        self.raw = value
    }

    public init(stringLiteral value: String) { self.init(value) }
    public init(raw: UInt32) { self.raw = raw }

    public var description: String {
        let b = [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
                 UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        return String(decoding: b, as: UTF8.self)
    }

    /// Fan keys are indexed: F0Ac, F1Ac, …
    ///
    /// Returns nil for an index that does not fit. A FourCC is exactly four
    /// bytes, so fan 10 composes "F10Ac" and the truncating initializer above
    /// would silently turn it into "F10A" — a different key, which the SMC would
    /// happily read or *write*. Refusing is the only safe answer: there is no
    /// four-character spelling of fan 10 to fall back to.
    public static func fan(_ index: Int, _ suffix: String) -> SMCKey? {
        let composed = "F\(index)\(suffix)"
        guard index >= 0, composed.utf8.count == 4 else { return nil }
        return SMCKey(composed)
    }
}

/// SMC value data types, as reported by `readKeyInfo`.
public enum SMCDataType: UInt32, Sendable {
    case flt  = 0x666c7420  // "flt " — IEEE-754 float, little-endian (Apple Silicon)
    case fpe2 = 0x66706532  // "fpe2" — 14.2 fixed point, big-endian (Intel fans)
    case fp1f = 0x66703166
    case ui8  = 0x75693820  // "ui8 "
    case ui16 = 0x75693136
    case ui32 = 0x75693332
    case si8  = 0x73693820
    case si16 = 0x73693136
    case sp78 = 0x73703738  // "sp78" — 8.8 signed fixed point (Intel temps)
    case ch8  = 0x63682a20
    case flag = 0x666c6167
    // "ioft" — IOFloat: 8 bytes, little-endian unsigned, scaled by 65536.
    //
    // Nine keys on this Mac report this type and every one of them is a real
    // temperature: the six `TG*` battery-gauge sensors and `TR0Z`/`TR1d`/`TR2d`.
    // Without it they decode to nil and drop out of the sensor list silently.
    // Verified against the HID hub, which surfaces the same hardware: SMC `TG0B`
    // and HID `TG0B` read 33.30/33.30, then 33.20/33.20, at the same instants.
    case ioft = 0x696f6674

    public init?(fourCC: UInt32) { self.init(rawValue: fourCC) }
}

/// Metadata returned by command 9 (read key info).
public struct SMCKeyInfo: Sendable {
    public let dataSize: UInt32
    public let dataType: UInt32
    public let attributes: UInt8

    public init(dataSize: UInt32, dataType: UInt32, attributes: UInt8) {
        self.dataSize = dataSize
        self.dataType = dataType
        self.attributes = attributes
    }

    public var type: SMCDataType? { SMCDataType(fourCC: dataType) }

    /// Per-key permission bits documented by the VirtualSMC SDK.
    public var isReadable: Bool { attributes & 0x80 != 0 }
    public var isWritable: Bool { attributes & 0x40 != 0 }

    public var typeString: String {
        let b = [UInt8((dataType >> 24) & 0xff), UInt8((dataType >> 16) & 0xff),
                 UInt8((dataType >> 8) & 0xff), UInt8(dataType & 0xff)]
        return String(decoding: b, as: UTF8.self)
    }
}

/// A decoded SMC value plus the raw bytes it came from.
public struct SMCValue: Sendable {
    public let key: SMCKey
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    public init(key: SMCKey, info: SMCKeyInfo, bytes: [UInt8]) {
        self.key = key
        self.info = info
        self.bytes = bytes
    }

    /// Decode to a Double using the key's *reported* type. Never infer from host
    /// architecture — the reported type is the robust discriminator (AUDIT A-11).
    public var doubleValue: Double? {
        guard let type = info.type else { return nil }
        switch type {
        case .flt:
            guard bytes.count >= 4 else { return nil }
            // Little-endian IEEE-754 on Apple Silicon.
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                     | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case .fpe2:
            guard bytes.count >= 2 else { return nil }
            let v = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(v) / 4.0
        case .fp1f:
            guard bytes.count >= 2 else { return nil }
            let v = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(v) / 32768.0
        case .sp78:
            guard bytes.count >= 2 else { return nil }
            let v = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(v) / 256.0
        case .ui8, .flag:
            guard let b = bytes.first else { return nil }
            return Double(b)
        case .si8:
            guard let b = bytes.first else { return nil }
            return Double(Int8(bitPattern: b))
        case .ui16:
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case .si16:
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case .ui32:
            guard bytes.count >= 4 else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v = (v << 8) | UInt32(bytes[i]) }
            return Double(v)
        case .ch8:
            return bytes.first.map(Double.init)
        case .ioft:
            guard bytes.count >= 8 else { return nil }
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = (v << 8) | UInt64(bytes[i]) }
            return Double(v) / 65536.0
        }
    }

    public var hexString: String {
        bytes.prefix(Int(info.dataSize)).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

public enum SMCError: Error, CustomStringConvertible, Sendable {
    case serviceNotFound
    case openFailed(kern_return_t)
    case notConnected
    case callFailed(kern_return_t)
    case smcError(UInt8)
    case keyNotFound(SMCKey)
    case notWritable(SMCKey)
    case unsupportedType(String)
    case structLayoutMismatch(Int)
    /// A fan index with no four-character key spelling.
    case unaddressableFan(Int)
    /// A target that is NaN or infinite. Refused rather than encoded, because
    /// the fixed-point encoders turn it into the maximum.
    case nonFiniteTarget(Int)

    public var description: String {
        switch self {
        case .serviceNotFound:            return "AppleSMC service not found"
        case .openFailed(let k):          return "IOServiceOpen failed: 0x\(String(k, radix: 16))"
        case .notConnected:               return "Not connected to AppleSMC"
        case .callFailed(let k):
            if k == kIOReturnNotPrivileged { return "Not privileged — this operation requires root" }
            return "IOConnectCallStructMethod failed: 0x\(String(UInt32(bitPattern: k), radix: 16))"
        case .smcError(let c):
            switch c {
            case 0x82: return "SMC rejected the command (0x82) — firmware refused this write"
            case 0x84: return "SMC key not found (0x84)"
            case 0x85: return "SMC key not readable (0x85)"
            default:   return "SMC error 0x\(String(c, radix: 16))"
            }
        case .keyNotFound(let k):         return "Key \(k) not present on this hardware"
        case .notWritable(let k):         return "Key \(k) is not writable"
        case .unsupportedType(let t):     return "Unsupported SMC data type '\(t)'"
        case .structLayoutMismatch(let n): return "SMCKeyData_t is \(n) bytes, expected 80 — struct layout is wrong"
        case .unaddressableFan(let i):
            return "fan \(i) has no four-character SMC key — this hardware reports more fans than the key space allows"
        case .nonFiniteTarget(let i):
            return "refused a non-finite target for fan \(i)"
        }
    }
}
