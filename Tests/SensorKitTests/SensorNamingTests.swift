import XCTest
@testable import SensorKit

/// The raw-to-plain-English translation. Names come from `smcfan sensors` on
/// this machine plus the Apple Silicon names other Macs are known to report.
final class SensorNamingTests: XCTestCase {

    // MARK: - This machine

    /// The 5 distinct name shapes behind this Mac's 52 sensors.
    func testRenamesRealSensorNamesFromThisMachine() {
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU tdie1"), "Chip zone 1")
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU tdie14"), "Chip zone 14")
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU tcal"), "Chip calibration reference")
        XCTAssertEqual(SensorNaming.friendlyName(for: "NAND CH0 temp"), "SSD flash channel 0")
        XCTAssertEqual(SensorNaming.friendlyName(for: "gas gauge battery"), "Battery sensor")
    }

    /// `tdie1` and `tdie10` must not collapse together — the number is read
    /// whole, not a digit at a time.
    func testMultiDigitZonesStayDistinct() {
        XCTAssertNotEqual(SensorNaming.friendlyName(for: "PMU tdie1"),
                          SensorNaming.friendlyName(for: "PMU tdie10"))
        let zones = (1...14).map { SensorNaming.friendlyName(for: "PMU tdie\($0)") }
        XCTAssertEqual(Set(zones).count, 14, "two die zones share a label")
    }

    // MARK: - Other Macs

    func testRenamesCommonNamesFromOtherMacs() {
        XCTAssertEqual(SensorNaming.friendlyName(for: "eCPU core 3"), "Efficiency core 3")
        XCTAssertEqual(SensorNaming.friendlyName(for: "pCPU core 1"), "Performance core 1")
        XCTAssertEqual(SensorNaming.friendlyName(for: "pACC MTR Temp Sensor"),
                       "Performance core cluster")
        XCTAssertEqual(SensorNaming.friendlyName(for: "GPU1 Temp"), "Graphics zone 1")
        XCTAssertEqual(SensorNaming.friendlyName(for: "ANE Temp"), "Neural Engine")
        XCTAssertEqual(SensorNaming.friendlyName(for: "LPDDR Temp"), "Memory")
        XCTAssertEqual(SensorNaming.friendlyName(for: "Ambient light"), "Ambient air")
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMIC Temp"), "Power regulator")
    }

    // MARK: - Rule ordering

    /// A die sensor reported through the power controller is still a die
    /// sensor. If the `pmu` rule won, all 45 of this Mac's PMU-reported
    /// sensors would read "Power controller".
    func testSpecificRulesBeatGeneralOnes() {
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU tdie6"), "Chip zone 6")
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU"), "Power controller")
        XCTAssertEqual(SensorNaming.friendlyName(for: "gas gauge"), "Battery gauge")
        XCTAssertEqual(SensorNaming.friendlyName(for: "eCPU core 3"), "Efficiency core 3")
    }

    // MARK: - Names with no rule

    /// Better an honest hardware name than a confident wrong translation.
    func testUnknownNamesKeepTheirOwnTextMinusFiller() {
        XCTAssertEqual(SensorNaming.friendlyName(for: "TZ0P"), "TZ0P")
        XCTAssertEqual(SensorNaming.friendlyName(for: "TZ0P Temp Sensor"), "TZ0P")
    }

    /// A blank label in the UI reads as a bug, and the HID hub falls back to
    /// the bare word "sensor" when it has no product name at all.
    func testNamesAreNeverBlank() {
        XCTAssertEqual(SensorNaming.friendlyName(for: ""), "Unnamed sensor")
        XCTAssertEqual(SensorNaming.friendlyName(for: "sensor"), "Unnamed sensor")
        for name in ["PMU tdie1", "TZ0P", "", "  ", "42"] {
            XCTAssertFalse(SensorNaming.friendlyName(for: name).isEmpty, "blank label for '\(name)'")
        }
    }

    // MARK: - Naming is display only

    /// Renaming must not touch identity: two different raw sensors that happen
    /// to share a friendly label would otherwise merge in the history store.
    func testRenamingDoesNotChangeSensorIdentity() {
        let reading = TemperatureSensors.Reading(name: "PMU tdie1", celsius: 62, ordinal: 2)
        XCTAssertEqual(reading.name, "PMU tdie1")
        XCTAssertEqual(reading.id, "PMU tdie1#2")
        XCTAssertEqual(reading.friendlyName, "Chip zone 1")
    }

    /// Grouping keys off the raw name too, so a label change can't move a
    /// sensor into a different section.
    func testRenamingDoesNotChangeClassification() {
        XCTAssertEqual(SensorCategory.classify("PMU tdie1"), .soc)
        XCTAssertEqual(SensorCategory.classify("NAND CH0 temp"), .storage)
    }

    // MARK: - Group headings

    func testGroupTitlesAreDistinctAndPlain() {
        let titles = SensorCategory.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two groups share a heading")
        XCTAssertEqual(SensorCategory.soc.title, "Main chip")
        XCTAssertEqual(SensorCategory.cpu.title, "Processor")
    }

    /// `rawValue` stays a stable `Codable` code even though the heading changed.
    func testRawValuesAreUnchangedByTheRelabelling() {
        XCTAssertEqual(SensorCategory.soc.rawValue, "SoC")
        XCTAssertEqual(SensorCategory(rawValue: "SoC"), .soc)
    }
}
