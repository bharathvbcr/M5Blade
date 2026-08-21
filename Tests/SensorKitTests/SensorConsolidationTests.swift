import XCTest
@testable import SensorKit

/// Collapsing the HID hub's duplicate enumerations.
///
/// Ground truth from this machine's IORegistry: 52 temperature services, 22
/// distinct `LocationID`s. Every `PMU tdie*`/`PMU tcal` name appears three
/// times under a single SMC key — one sensor listed three times. The six
/// `gas gauge battery` entries carry six *different* keys — six sensors that
/// happen to share a name. The two cases must not be treated alike.
final class SensorConsolidationTests: XCTestCase {

    private func reading(_ name: String, _ celsius: Double, key: String) -> TemperatureSensors.Reading {
        TemperatureSensors.Reading(name: name, celsius: celsius, smcKey: key)
    }

    // MARK: - FourCC decoding

    func testLocationIDDecodesToAnSMCKey() {
        XCTAssertEqual(TemperatureSensors.fourCC(1414541666), "TP1b")   // PMU tdie1
        XCTAssertEqual(TemperatureSensors.fourCC(1414541402), "TP0Z")   // PMU tcal
        XCTAssertEqual(TemperatureSensors.fourCC(1414410350), "TN0n")   // NAND CH0
        XCTAssertEqual(TemperatureSensors.fourCC(1413951554), "TG0B")   // battery
    }

    /// A non-ASCII LocationID is not a key we can trust as an identity, so it
    /// must degrade to "no key" and let the name-and-ordinal path take over —
    /// never to a garbled string that could collide with a real key.
    func testNonPrintableLocationIDYieldsNoKey() {
        XCTAssertEqual(TemperatureSensors.fourCC(0), "")
        XCTAssertEqual(TemperatureSensors.fourCC(0xFFFFFFFF), "")
    }

    // MARK: - Duplicates collapse

    func testSameKeyCollapsesToOneSensor() {
        let raw = [
            reading("PMU tdie1", 62.0, key: "TP1b"),
            reading("PMU tdie1", 62.4, key: "TP1b"),
            reading("PMU tdie1", 62.4, key: "TP1b"),
        ]
        let out = TemperatureSensors.consolidate(raw)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "TP1b")
    }

    /// Averaging, not first-wins: the copies are read at slightly different
    /// instants, and picking one would put that sampling jitter on the chart.
    func testCollapsedValueIsTheMeanOfTheCopies() {
        let out = TemperatureSensors.consolidate([
            reading("PMU tdie1", 60.0, key: "TP1b"),
            reading("PMU tdie1", 62.0, key: "TP1b"),
            reading("PMU tdie1", 64.0, key: "TP1b"),
        ])
        XCTAssertEqual(out[0].celsius, 62.0, accuracy: 0.0001)
    }

    // MARK: - Namesakes stay separate

    func testDifferentKeysUnderOneNameStaySeparate() {
        let keys = ["TG0B", "TG0C", "TG0H", "TG0V", "TG1B", "TG2B"]
        let out = TemperatureSensors.consolidate(keys.map { reading("gas gauge battery", 34, key: $0) })
        XCTAssertEqual(out.count, 6, "six distinct battery sensors were merged")
        XCTAssertEqual(Set(out.map(\.id)).count, 6)
        XCTAssertEqual(out.map(\.ordinal), [0, 1, 2, 3, 4, 5])
    }

    /// The whole machine at once: 52 in, 22 out.
    func testThisMachinesFullSensorSetCollapsesTo22() {
        // The real keys, read from this Mac's IORegistry.
        let zoneKeys = ["TP1b", "TP2b", "TP3b", "TP4b", "TP5b", "TP6b", "TP7b",
                        "TP8b", "TP9b", "TPab", "TPbl", "TPcl", "TPdl", "TPel"]
        var raw: [TemperatureSensors.Reading] = []
        for _ in 0..<3 {
            raw.append(reading("PMU tcal", 51.8, key: "TP0Z"))
            for (index, key) in zoneKeys.enumerated() {
                raw.append(reading("PMU tdie\(index + 1)", 50, key: key))
            }
        }
        raw.append(reading("NAND CH0 temp", 35, key: "TN0n"))
        for key in ["TG0B", "TG0C", "TG0H", "TG0V", "TG1B", "TG2B"] {
            raw.append(reading("gas gauge battery", 34, key: key))
        }
        XCTAssertEqual(raw.count, 52, "test fixture no longer matches the real machine")
        XCTAssertEqual(TemperatureSensors.consolidate(raw).count, 22)
    }

    // MARK: - Stability

    /// Ordinals must come from the hardware key, not from the order the
    /// services happened to come back in, or a sensor's label would shuffle
    /// between reads and its history would follow the wrong line.
    func testOrdinalsAreStableAgainstScanOrder() {
        let keys = ["TG2B", "TG0V", "TG0B", "TG1B", "TG0H", "TG0C"]
        let shuffled = TemperatureSensors.consolidate(keys.map { reading("gas gauge battery", 34, key: $0) })
        let sorted = TemperatureSensors.consolidate(keys.sorted().map { reading("gas gauge battery", 34, key: $0) })
        XCTAssertEqual(shuffled.map(\.id), sorted.map(\.id))
        XCTAssertEqual(shuffled.first?.id, "TG0B")
    }

    /// A plain string sort puts "tdie10" above "tdie2", which reads as a bug in
    /// a list of 14 zones.
    func testZonesAreOrderedNumericallyNotAlphabetically() {
        let zoneKeys = ["TP1b", "TP2b", "TP3b", "TP4b", "TP5b", "TP6b", "TP7b",
                        "TP8b", "TP9b", "TPab", "TPbl", "TPcl", "TPdl", "TPel"]
        let raw = zoneKeys.enumerated().map { reading("PMU tdie\($0.offset + 1)", 50, key: $0.element) }
        let names = TemperatureSensors.consolidate(raw.reversed()).map(\.name)
        XCTAssertEqual(names, (1...14).map { "PMU tdie\($0)" })
    }

    // MARK: - Fallback when the key is missing

    /// Without a key we cannot prove two entries are the same sensor, so they
    /// must stay separate — merging on a guess would silently hide a reading.
    func testUnkeyedSensorsAreNeverMerged() {
        let out = TemperatureSensors.consolidate([
            TemperatureSensors.Reading(name: "TZ0P", celsius: 40),
            TemperatureSensors.Reading(name: "TZ0P", celsius: 41),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.id)).count, 2, "unkeyed sensors collided")
    }

    // MARK: - Calibration references

    /// Measured: tcal read 51.8 °C at idle and 51.8 under sustained all-core
    /// load, while real die sensors moved 14–24 °C. It is a constant, and at
    /// idle it sits *above* every real sensor — so a fan curve fed the maximum
    /// would have tracked a number that never moves.
    func testCalibrationReferenceIsFlagged() {
        XCTAssertTrue(TemperatureSensors.Reading(name: "PMU tcal", celsius: 51.8).isReference)
        XCTAssertFalse(TemperatureSensors.Reading(name: "PMU tdie1", celsius: 62).isReference)
        XCTAssertFalse(TemperatureSensors.Reading(name: "NAND CH0 temp", celsius: 35).isReference)
    }
}
