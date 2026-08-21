import XCTest
import SensorKit
import HistoryKit
@testable import FanControlApp

/// `HistorySensors` exists for one reason: the code that writes a series and the
/// code that reads it back must spell its key the same way. They would agree
/// today and diverge on the day someone edited one of them — and the symptom
/// would be an empty plot, not a build error.
final class HistorySensorsTests: XCTestCase {

    private func reading(_ name: String, _ celsius: Double = 60,
                         ordinal: Int = 0) -> TemperatureSensors.Reading {
        TemperatureSensors.Reading(name: name, celsius: celsius, ordinal: ordinal)
    }

    func testTheKeyAViewLooksUpIsTheKeyTheRecorderWrites() {
        for name in ["Chip zone 1", "PMU tdie1", "gas gauge battery", "NAND CH0", "☃"] {
            for ordinal in 0..<3 {
                let sensor = reading(name, ordinal: ordinal)
                XCTAssertEqual(HistorySensors.temperature(sensor, isAmbiguous: false).key,
                               HistorySensors.temperatureKey(sensor),
                               "writer and reader disagree about \(name)#\(ordinal)")
            }
        }
    }

    /// Several sensors share a name. If identity collapsed to the name, they
    /// would overwrite each other in the database and collide in `ForEach`.
    func testSensorsSharingANameKeepDistinctKeys() {
        let keys = (0..<6).map { HistorySensors.temperatureKey(reading("PMU tdie1", ordinal: $0)) }
        XCTAssertEqual(Set(keys).count, 6)
    }

    func testTemperatureGroupComesFromTheSharedClassifier() {
        XCTAssertEqual(HistorySensors.temperature(reading("eACC 1"), isAmbiguous: false).group,
                       SensorCategory.cpu.rawValue)
        XCTAssertEqual(HistorySensors.temperature(reading("gas gauge battery"), isAmbiguous: false).group,
                       SensorCategory.battery.rawValue)
        XCTAssertEqual(HistorySensors.temperature(reading("PMU tdie1"), isAmbiguous: false).group,
                       SensorCategory.soc.rawValue)
        XCTAssertEqual(HistorySensors.temperature(reading("something else"), isAmbiguous: false).group,
                       SensorCategory.other.rawValue)
    }

    /// The stored name has to be the one the popover prints, whatever the naming
    /// layer decides that is — an export people cross-check against the UI is
    /// worth nothing if the two disagree.
    func testTheStoredNameIsTheDisplayedName() {
        for name in ["PMU tdie1", "gas gauge battery", "NAND CH0", "eACC 1"] {
            for ambiguous in [true, false] {
                let sensor = reading(name, ordinal: 1)
                XCTAssertEqual(HistorySensors.temperature(sensor, isAmbiguous: ambiguous).name,
                               sensor.displayName(isAmbiguous: ambiguous),
                               "stored and displayed names differ for \(name)")
            }
        }
    }

    /// Whatever the display name becomes, the *key* is derived from the raw
    /// hardware identity — so relabelling a sensor never orphans its history.
    func testRelabellingASensorDoesNotChangeItsKey() {
        let sensor = reading("PMU tdie1", ordinal: 2)
        XCTAssertEqual(HistorySensors.temperature(sensor, isAmbiguous: true).key,
                       HistorySensors.temperature(sensor, isAmbiguous: false).key)
        XCTAssertTrue(HistorySensors.temperatureKey(sensor).contains(sensor.id))
    }

    func testFanSeriesAreDistinctAndNumberedFromOneForAReader() {
        let rpm = HistorySensors.fanRPM(0)
        let duty = HistorySensors.fanDuty(0)
        XCTAssertNotEqual(rpm.key, duty.key, "rpm and duty are different series")
        XCTAssertEqual(rpm.name, "Fan 1")
        XCTAssertEqual(duty.name, "Fan 1")
        XCTAssertEqual(HistorySensors.fanRPM(1).name, "Fan 2")

        XCTAssertEqual(rpm.kind, .rpm)
        XCTAssertEqual(duty.kind, .percent)
        XCTAssertEqual(rpm.group, HistorySensors.fanRPM)
        XCTAssertEqual(duty.group, HistorySensors.fan)
    }

    func testEveryKeyIsUniqueAcrossTheWholeCatalogue() {
        var keys = Set<String>()
        for index in 0..<8 {
            keys.insert(HistorySensors.fanRPM(index).key)
            keys.insert(HistorySensors.fanDuty(index).key)
        }
        keys.insert(HistorySensors.cpuLoad.key)
        for index in 0..<20 {
            keys.insert(HistorySensors.temperatureKey(reading("zone", ordinal: index)))
        }
        XCTAssertEqual(keys.count, 8 * 2 + 1 + 20)
    }

    /// rpm shares no axis with temperature or percent, so it is recorded for
    /// export and kept off the chart's toggles.
    func testOnlyFanRPMIsHiddenFromTheChart() {
        XCTAssertEqual(HistorySensors.ungroupedInCharts, [HistorySensors.fanRPM])
        XCTAssertFalse(HistorySensors.ungroupedInCharts.contains(HistorySensors.fan))
        XCTAssertFalse(HistorySensors.ungroupedInCharts.contains(HistorySensors.load))
    }

    func testCPULoadIsAPercentInItsOwnGroup() {
        XCTAssertEqual(HistorySensors.cpuLoad.kind, .percent)
        XCTAssertEqual(HistorySensors.cpuLoad.group, HistorySensors.load)
    }
}
