import Foundation
#if canImport(IOKit)
import IOKit

// MARK: - C-compatible SMC structures
//
// The AppleSMC user client expects an 80-byte struct. `SMCConnection.open()`
// asserts the size at runtime — if this ever fails, nothing below is trustworthy
// and every call must be refused.

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                           0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private enum SMCSelector {
    static let handleYPCEvent: UInt32 = 2
}

private enum SMCCommand {
    static let readBytes: UInt8 = 5
    static let writeBytes: UInt8 = 6
    static let readKeyByIndex: UInt8 = 8
    static let readKeyInfo: UInt8 = 9
}

/// Serialized access to the AppleSMC user client.
///
/// IOKit connections are **not** thread-safe. Every call in the process must go
/// through this actor (AUDIT A-4). Reads work unprivileged; writes to fan keys
/// require root.
public actor SMCConnection {
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]

    public init() {}

    public var isOpen: Bool { connection != 0 }

    public func open() throws {
        guard connection == 0 else { return }

        let layout = MemoryLayout<SMCKeyData>.stride
        guard layout == 80 else { throw SMCError.structLayoutMismatch(layout) }

        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(result) }
        connection = conn
    }

    public func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
        infoCache.removeAll()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Primitive call

    private func call(_ input: inout SMCKeyData) throws -> SMCKeyData {
        guard connection != 0 else { throw SMCError.notConnected }

        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let inSize = MemoryLayout<SMCKeyData>.stride

        let result = withUnsafePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(connection,
                                          SMCSelector.handleYPCEvent,
                                          inPtr, inSize,
                                          outPtr, &outSize)
            }
        }

        guard result == kIOReturnSuccess else { throw SMCError.callFailed(result) }
        guard output.result == 0 else { throw SMCError.smcError(output.result) }
        return output
    }

    // MARK: - Key info

    public func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        if let cached = infoCache[key.raw] { return cached }

        var input = SMCKeyData()
        input.key = key.raw
        input.data8 = SMCCommand.readKeyInfo

        let output: SMCKeyData
        do {
            output = try call(&input)
        } catch SMCError.smcError(0x84) {
            throw SMCError.keyNotFound(key)
        }

        let info = SMCKeyInfo(dataSize: output.keyInfo.dataSize,
                              dataType: output.keyInfo.dataType,
                              attributes: output.keyInfo.dataAttributes)
        infoCache[key.raw] = info
        return info
    }

    /// True when the key exists on this hardware. Used for runtime capability
    /// probing — never assume a key from the model name.
    public func exists(_ key: SMCKey) -> Bool {
        (try? keyInfo(key)) != nil
    }

    // MARK: - Enumeration

    /// How many keys this SMC exposes, from the `#KEY` pseudo-key.
    ///
    /// 3603 on this Mac. The count is the loop bound for `key(at:)` — the SMC
    /// has no "end of list" sentinel, so asking past it is the caller's error.
    public func keyCount() throws -> UInt32 {
        guard let count = try read("#KEY").doubleValue, count >= 0 else {
            throw SMCError.unsupportedType(try keyInfo("#KEY").typeString)
        }
        return UInt32(count)
    }

    /// The key at `index` in the SMC's own ordering.
    ///
    /// This is the only way to learn what a machine actually exposes. Every
    /// alternative — a table of keys per model identifier — is a guess that goes
    /// stale on the next Mac, and guesses about *which* key is *which* sensor are
    /// exactly what this project refuses to make.
    public func key(at index: UInt32) throws -> SMCKey {
        var input = SMCKeyData()
        input.data8 = SMCCommand.readKeyByIndex
        input.data32 = index
        return SMCKey(raw: try call(&input).key)
    }

    /// Every key on this hardware, in SMC order.
    ///
    /// Enumeration costs ~12 ms and the key set is fixed for the life of the
    /// machine, so callers are expected to do this once and cache it. An index
    /// that fails is skipped rather than aborting the sweep: one unreadable slot
    /// should not cost us the other 3602.
    public func allKeys() throws -> [SMCKey] {
        let count = try keyCount()
        var keys: [SMCKey] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let key = try? key(at: index) else { continue }
            keys.append(key)
        }
        return keys
    }

    // MARK: - Read

    public func read(_ key: SMCKey) throws -> SMCValue {
        let info = try keyInfo(key)

        var input = SMCKeyData()
        input.key = key.raw
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCCommand.readBytes

        let output = try call(&input)
        var bytes = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<min(32, raw.count) { bytes[i] = raw[i] }
        }
        return SMCValue(key: key, info: info, bytes: bytes)
    }

    public func readDouble(_ key: SMCKey) throws -> Double {
        guard let v = try read(key).doubleValue else {
            throw SMCError.unsupportedType(try keyInfo(key).typeString)
        }
        return v
    }

    public func readUInt8(_ key: SMCKey) throws -> UInt8 {
        let value = try read(key)
        guard let first = value.bytes.first else {
            throw SMCError.unsupportedType(value.info.typeString)
        }
        return first
    }

    // MARK: - Write (requires root)

    public func write(_ key: SMCKey, bytes payload: [UInt8]) throws {
        let info = try keyInfo(key)
        guard info.isWritable else { throw SMCError.notWritable(key) }

        var input = SMCKeyData()
        input.key = key.raw
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCCommand.writeBytes

        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for i in 0..<min(payload.count, raw.count) { raw[i] = payload[i] }
        }

        _ = try call(&input)
    }

    public func writeUInt8(_ key: SMCKey, _ value: UInt8) throws {
        try write(key, bytes: [value])
    }

    /// Encode a Double using the key's reported type, then write it.
    public func writeDouble(_ key: SMCKey, _ value: Double) throws {
        let info = try keyInfo(key)
        guard let type = info.type else { throw SMCError.unsupportedType(info.typeString) }

        switch type {
        case .flt:
            let bits = Float(value).bitPattern
            try write(key, bytes: [UInt8(bits & 0xff),
                                   UInt8((bits >> 8) & 0xff),
                                   UInt8((bits >> 16) & 0xff),
                                   UInt8((bits >> 24) & 0xff)])
        case .fpe2:
            let raw = UInt16(max(0, min(16383, value * 4)))
            try write(key, bytes: [UInt8(raw >> 8), UInt8(raw & 0xff)])
        case .ui8, .flag:
            try write(key, bytes: [UInt8(max(0, min(255, value)))])
        case .ui16:
            let raw = UInt16(max(0, min(65535, value)))
            try write(key, bytes: [UInt8(raw >> 8), UInt8(raw & 0xff)])
        default:
            throw SMCError.unsupportedType(info.typeString)
        }
    }
}
#endif
