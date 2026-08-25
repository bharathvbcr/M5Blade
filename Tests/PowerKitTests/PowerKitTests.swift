import XCTest
import SMCKit
import DaemonProtocol
@testable import PowerKit

/// T-3: battery health decomposition and charge-limit byte semantics.
///
/// Every fixture here is built from values measured on real firmware — the
/// Mac17,8 shapes in particular, which omit several keys older write-ups
/// treat as guaranteed. The decoder must survive those omissions without
/// inventing readings.
final class PowerKitTests: XCTestCase {

    // MARK: - BatteryHealth decoding

    /// The property shape measured on Mac17,8 / macOS 27: capacities nested in
    /// `BatteryData`, no top-level temperature or permanent-failure status.
    func testTheMeasuredMac17_8ShapeDecodes() throws {
        let health = BatteryHealth(registry: [
            "BatteryInstalled": true,
            "CurrentCapacity": 85,
            "MaxCapacity": 100,
            "CycleCount": 30,
            "AppleRawBatteryVoltage": 12461,
            "Amperage": 0,
            "IsCharging": false,
            "ExternalConnected": true,
            "BatteryData": [
                "DesignCapacity": 8579,
                "NominalChargeCapacity": 9012,
                "FullChargeCapacity": 8768,
                "RemainingCapacity": 7196,
                "MaxCapacity": 100,
            ] as [String: Any],
        ] as [String: Any])

        XCTAssertEqual(health.batteryInstalled, true)
        XCTAssertEqual(health.chargePercent, 85)
        XCTAssertEqual(health.appleMaxPercent, 100)
        XCTAssertEqual(health.cycleCount, 30)
        XCTAssertEqual(health.designCapacityMah, 8579)
        XCTAssertEqual(health.nominalCapacityMah, 9012)
        XCTAssertEqual(health.fullChargeCapacityMah, 8768)
        XCTAssertEqual(health.voltageMillivolts, 12461)
        XCTAssertEqual(health.isCharging, false)
        XCTAssertEqual(health.externalConnected, true)

        // The raw ratio is capped at 100: a gauge reporting more than design
        // capacity is a calibration quirk, not free battery.
        let raw = try XCTUnwrap(health.rawHealthPercent)
        XCTAssertEqual(raw, min(100, 9012.0 / 8579.0 * 100), accuracy: 0.01)
    }

    func testAnEmptyRegistryProducesNoInventedReadings() {
        let health = BatteryHealth(registry: [:])
        XCTAssertNil(health.chargePercent)
        XCTAssertNil(health.cycleCount)
        XCTAssertNil(health.rawHealthPercent)
        XCTAssertNil(health.batteryInstalled)
    }

    func testADesktopWithNoBatteryNodeReadsAsAbsent() {
        // BatteryReader returns nil when the node is missing; the pure half's
        // contract is that nothing here fabricates a percentage for it.
        XCTAssertNil(BatteryHealth(registry: ["Voltage": 12000]).chargePercent)
    }

    func testImplausiblePercentagesAreDroppedNotClamped() {
        // A negative capacity is a broken gauge, not a broken battery; keeping
        // it would render as a negative bar somewhere.
        let health = BatteryHealth(registry: ["CurrentCapacity": -5])
        XCTAssertNil(health.chargePercent)
    }

    // MARK: - CHWA semantics (Apple Silicon)

    func testCHWAByteDecoding() {
        XCTAssertEqual(ChargeLimit.state(fromAppleSiliconByte: 0x00), .fullCharge)
        XCTAssertEqual(ChargeLimit.state(fromAppleSiliconByte: 0x01), .limitedTo80)
        // Firmware adds meanings between generations; an unrecognised byte
        // must arrive labelled unknown, never mapped to something convenient.
        if case .unknown(let raw) = ChargeLimit.state(fromAppleSiliconByte: 0x02) {
            XCTAssertEqual(raw, 0x02)
        } else {
            XCTFail("0x02 must decode as unknown, not silently as a known state")
        }
    }

    // MARK: - BCLM semantics (Intel)

    func testBCLMByteDecoding() {
        XCTAssertEqual(ChargeLimit.state(fromIntelByte: 80), .limitedTo80)
        XCTAssertEqual(ChargeLimit.state(fromIntelByte: 100), .fullCharge)
        if case .unknown(let raw) = ChargeLimit.state(fromIntelByte: 60) {
            XCTAssertEqual(raw, 60)
        } else {
            XCTFail("a partial limit below 80 is not expressible here")
        }
    }

    // MARK: - Encoding

    func testEncodingRoundTripsThroughTheSameDecoder() {
        for percent in [80, 100] {
            let chwa = ChargeLimit.byte(forPercent: percent, appleSiliconKey: true)!
            XCTAssertEqual(ChargeLimit.state(fromAppleSiliconByte: chwa).percent, percent)
            let bclm = ChargeLimit.byte(forPercent: percent, appleSiliconKey: false)!
            XCTAssertEqual(ChargeLimit.state(fromIntelByte: bclm).percent, percent)
        }
    }

    func testOnlyEightyAndHundredAreEncodable() {
        XCTAssertNil(ChargeLimit.byte(forPercent: 50, appleSiliconKey: true))
        XCTAssertNil(ChargeLimit.byte(forPercent: 77, appleSiliconKey: false))
        XCTAssertNil(ChargeLimit.byte(forPercent: 90, appleSiliconKey: true))
    }

    // MARK: - Status JSON round trip

    func testStatusCodableRoundTrip() throws {
        let original = ChargeLimitStatus(supported: true, percent: 80, keyName: "CHWA")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChargeLimitStatus.self, from: data)
        XCTAssertEqual(decoded, original)

        let unsupported = try JSONEncoder().encode(ChargeLimitStatus.unsupported)
        let decodedUnsupported = try JSONDecoder().decode(ChargeLimitStatus.self,
                                                          from: unsupported)
        XCTAssertEqual(decodedUnsupported.supported, false)
        XCTAssertNil(decodedUnsupported.percent)
    }
}
