import XCTest
@testable import SensorKit

final class SensorGroupingTests: XCTestCase {

    // MARK: - Identity

    /// This Mac reports three sensors named "PMU tdie1" and six named
    /// "gas gauge battery". Using the name as the identity gave SwiftUI duplicate
    /// `ForEach` ids, so identity must include the ordinal.
    func testRepeatedNamesGetDistinctIdentities() {
        let readings = [
            TemperatureSensors.Reading(name: "PMU tdie1", celsius: 41, ordinal: 0),
            TemperatureSensors.Reading(name: "PMU tdie1", celsius: 42, ordinal: 1),
            TemperatureSensors.Reading(name: "PMU tdie1", celsius: 43, ordinal: 2),
        ]
        XCTAssertEqual(Set(readings.map(\.id)).count, 3, "sensor ids collided")
    }

    /// Asserts the relationship rather than a specific mapping — the raw-to-
    /// friendly translation is `SensorNaming`'s contract to test, not this one's.
    func testDisplayNameOnlyDisambiguatesWhenNeeded() {
        let reading = TemperatureSensors.Reading(name: "NAND CH0 temp", celsius: 32, ordinal: 0)
        XCTAssertEqual(reading.displayName(isAmbiguous: false), reading.friendlyName)
        XCTAssertEqual(reading.displayName(isAmbiguous: true), "\(reading.friendlyName) 1")
    }

    /// The ordinal shown is 1-based, so the second sensor reads "… 2".
    func testDisambiguatedNamesAreOneBased() {
        let second = TemperatureSensors.Reading(name: "PMU tdie1", celsius: 41, ordinal: 1)
        XCTAssertEqual(second.displayName(isAmbiguous: true), "\(second.friendlyName) 2")
    }

    /// Identity must stay the raw name — a friendly-name collision between two
    /// different raw sensors would silently merge them in the history store.
    func testIdentityUsesRawNameNotFriendlyName() {
        let reading = TemperatureSensors.Reading(name: "NAND CH0 temp", celsius: 32, ordinal: 0)
        XCTAssertEqual(reading.id, "NAND CH0 temp#0")
    }

    /// Both the popover and the Sensors tab ask for this set, so it decides
    /// which readings carry an index — and they must agree.
    func testAmbiguousNamesFindsOnlyTheSharedNames() {
        let readings = [
            TemperatureSensors.Reading(name: "PMU tcal", celsius: 51, ordinal: 0),
            TemperatureSensors.Reading(name: "PMU tcal", celsius: 52, ordinal: 1),
            TemperatureSensors.Reading(name: "NAND CH0 temp", celsius: 35, ordinal: 0),
        ]
        XCTAssertEqual(TemperatureSensors.ambiguousNames(in: readings), ["PMU tcal"])
    }

    func testAmbiguousNamesIsEmptyForDistinctSensors() {
        let readings = [
            TemperatureSensors.Reading(name: "PMU tdie1", celsius: 60, ordinal: 0),
            TemperatureSensors.Reading(name: "PMU tdie2", celsius: 61, ordinal: 0),
        ]
        XCTAssertTrue(TemperatureSensors.ambiguousNames(in: readings).isEmpty)
    }

    // MARK: - Classification

    func testClassifiesRealSensorNamesFromThisMachine() {
        XCTAssertEqual(SensorCategory.classify("PMU tdie1"), .soc)
        XCTAssertEqual(SensorCategory.classify("PMU tcal"), .soc)
        XCTAssertEqual(SensorCategory.classify("NAND CH0 temp"), .storage)
        XCTAssertEqual(SensorCategory.classify("gas gauge battery"), .battery)
    }

    func testClassifiesCommonNamesFromOtherMacs() {
        XCTAssertEqual(SensorCategory.classify("eCPU core 3"), .cpu)
        XCTAssertEqual(SensorCategory.classify("pACC MTR Temp Sensor"), .cpu)
        XCTAssertEqual(SensorCategory.classify("GPU1 Temp"), .gpu)
        XCTAssertEqual(SensorCategory.classify("ANE Temp"), .gpu)
        XCTAssertEqual(SensorCategory.classify("LPDDR Temp"), .memory)
        XCTAssertEqual(SensorCategory.classify("Ambient light"), .ambient)
    }

    /// Better an honest "Other" than a confident wrong group.
    func testUnknownNamesFallThroughToOther() {
        XCTAssertEqual(SensorCategory.classify("TZ0P"), .other)
        XCTAssertEqual(SensorCategory.classify(""), .other)
    }

    func testEveryCategoryHasADistinctSortPosition() {
        let orders = SensorCategory.allCases.map(\.sortOrder)
        XCTAssertEqual(Set(orders).count, SensorCategory.allCases.count)
    }
}
