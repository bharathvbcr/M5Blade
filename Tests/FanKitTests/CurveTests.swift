import XCTest
@testable import FanKit

final class CurveTests: XCTestCase {

    func testMonotonicityIsEnforced() {
        // A curve that dips as temperature rises is always a mistake.
        let curve = FanCurve(points: [
            CurvePoint(tempC: 50, percent: 40),
            CurvePoint(tempC: 60, percent: 20),
            CurvePoint(tempC: 70, percent: 60),
        ])
        let percents = curve.points.map(\.percent)
        XCTAssertEqual(percents, percents.sorted())
    }

    func testPointsAreSortedByTemperature() {
        let curve = FanCurve(points: [
            CurvePoint(tempC: 80, percent: 70),
            CurvePoint(tempC: 40, percent: 10),
            CurvePoint(tempC: 60, percent: 40),
        ])
        XCTAssertEqual(curve.points.map(\.tempC), [40, 60, 80])
    }

    func testInterpolationIsLinearBetweenPoints() {
        let curve = FanCurve(points: [
            CurvePoint(tempC: 50, percent: 0),
            CurvePoint(tempC: 100, percent: 100),
        ])
        XCTAssertEqual(curve.percent(at: 75), 50, accuracy: 0.001)
    }

    func testFlatExtrapolationOutsideRange() {
        let curve = FanCurve.balanced
        XCTAssertEqual(curve.percent(at: -40), curve.points.first!.percent)
        XCTAssertEqual(curve.percent(at: 500), curve.points.last!.percent)
    }

    func testFanPercentRoundTrip() {
        let fan = FanDescriptor(index: 0, minRPM: 1200, maxRPM: 8400, modeKeyName: "F0md")
        for percent in stride(from: 0.0, through: 100.0, by: 5) {
            let rpm = fan.rpm(forPercent: percent)
            XCTAssertEqual(fan.percent(forRPM: rpm), percent, accuracy: 0.001)
        }
    }

    func testMissingRangeFallsBackConservatively() {
        let fan = FanDescriptor(index: 0, minRPM: nil, maxRPM: nil, modeKeyName: "F0md")
        XCTAssertFalse(fan.hasReportedRange)
        XCTAssertGreaterThan(fan.effectiveMin, 0)
        XCTAssertGreaterThan(fan.effectiveMax, fan.effectiveMin)
    }
}

final class SafetyFloorTests: XCTestCase {

    func testFloorRisesWithTemperature() {
        let floor = SafetyFloor()
        var previous = -1.0
        for temp in stride(from: 40.0, through: 100.0, by: 5) {
            let value = floor.floorPercent(tempC: temp, pressure: .nominal)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testThermalPressureRaisesFloorIndependentlyOfTemperature() {
        let floor = SafetyFloor()
        // Even at a cool reported temperature, Apple saying "serious" must lift
        // the floor — thermalState is the most trustworthy signal we have.
        let cool = floor.floorPercent(tempC: 30, pressure: .nominal)
        let serious = floor.floorPercent(tempC: 30, pressure: .serious)
        XCTAssertEqual(cool, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(serious, 60)
    }

    func testCriticalPressureTriggersEmergency() {
        let floor = SafetyFloor()
        XCTAssertTrue(floor.requiresEmergency(tempC: 40, pressure: .critical))
        XCTAssertTrue(floor.requiresEmergency(tempC: 105, pressure: .nominal))
        XCTAssertFalse(floor.requiresEmergency(tempC: 70, pressure: .fair))
    }

    func testHardFloorAppliesAboveThreshold() {
        let floor = SafetyFloor()
        XCTAssertGreaterThanOrEqual(
            floor.floorPercent(tempC: 61, pressure: .nominal),
            floor.hardFloorPercent
        )
    }
}
