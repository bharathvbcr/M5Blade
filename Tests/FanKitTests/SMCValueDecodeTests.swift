import XCTest
@testable import SMCKit

/// Decoding of the SMC value types the sensor sweep depends on, against bytes
/// read off this Mac rather than bytes composed to match the implementation.
final class SMCValueDecodeTests: XCTestCase {

    private func value(_ key: String, type: String, _ bytes: [UInt8]) -> SMCValue {
        let fourCC = type.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return SMCValue(key: SMCKey(key),
                        info: SMCKeyInfo(dataSize: UInt32(bytes.count),
                                         dataType: fourCC,
                                         attributes: 0x80),
                        bytes: bytes)
    }

    /// `ioft` is 8 bytes, little-endian, scaled by 65536. Nine keys on this Mac
    /// use it and all nine are temperatures; before it was added they decoded to
    /// nil and vanished from the list without a word.
    func testDecodesIOFloat() {
        // TG0B, the battery gauge, read 33.80 °C.
        XCTAssertEqual(value("TG0B", type: "ioft",
                             [0xcc, 0xcc, 0x21, 0, 0, 0, 0, 0]).doubleValue ?? 0,
                       33.80, accuracy: 0.01)
        // TR0Z, the constant reference, read 51.82 °C.
        XCTAssertEqual(value("TR0Z", type: "ioft",
                             [0xec, 0xd1, 0x33, 0, 0, 0, 0, 0]).doubleValue ?? 0,
                       51.82, accuracy: 0.01)
    }

    /// A short buffer must decode to nil, not to a value built from whatever
    /// followed it in the struct.
    func testTruncatedIOFloatIsRefused() {
        XCTAssertNil(value("TG0B", type: "ioft", [0xcc, 0xcc, 0x21]).doubleValue)
    }

    /// The type the CPU and GPU families use. `Tp04` read 79.25 °C.
    func testDecodesLittleEndianFloat() {
        XCTAssertEqual(value("Tp04", type: "flt ",
                             [0x00, 0x80, 0x9e, 0x42]).doubleValue ?? 0,
                       79.25, accuracy: 0.01)
    }

    /// `TTPD` is a well-formed `flt ` key that reads −306783232 °C. Decoding is
    /// not the layer that rejects it — it decodes faithfully, and
    /// `PlausibleTemperature` is what drops the reading.
    func testDecodesFaithfullyEvenWhenTheValueIsAbsurd() {
        let decoded = value("TTPD", type: "flt ",
                            [0x20, 0x49, 0x92, 0xcd]).doubleValue
        XCTAssertEqual(decoded ?? 0, -306_783_232, accuracy: 1)
    }

    /// `si32` is not a temperature type and has no case. The 31 `TV*` keys on
    /// this Mac report it, and discovery drops them for exactly this reason.
    func testUnknownTypeDecodesToNil() {
        XCTAssertNil(value("TVGi", type: "si32", [0x29, 0, 0, 0]).doubleValue)
    }
}
