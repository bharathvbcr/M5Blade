import XCTest
@testable import FanKit

/// Per-fan sensor mapping (AUDIT A-3). These fields were persisted to
/// `config.json` for the entire life of the project and read by nothing, so a
/// curve that named sensors behaved exactly like one that did not.
final class CurveInputTests: XCTestCase {

    private let readings: [String: Double] = [
        "PMU tdie0#0": 88,
        "PMU tdie1#0": 62,
        "NAND CH0 temp#0": 41,
    ]

    func testUnmappedCurveUsesTheMachineMaximum() {
        let curve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)])
        let input = curve.input(readings: readings, globalMax: 88)
        XCTAssertEqual(input.celsius, 88)
        XCTAssertTrue(input.missingSensorIDs.isEmpty)
        XCTAssertFalse(input.usedGlobalFallback,
                       "naming no sensors is the documented default, not a fallback")
    }

    func testMappedCurveReadsOnlyItsOwnSensors() {
        let curve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)],
                             sensorIDs: ["NAND CH0 temp#0"])
        let input = curve.input(readings: readings, globalMax: 88)
        XCTAssertEqual(input.celsius, 41, "the SSD fan must not chase the SoC package")
    }

    func testMaxAndMeanReductionsDiffer() {
        let ids = ["PMU tdie0#0", "PMU tdie1#0"]
        let maxCurve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)],
                                sensorIDs: ids, reduction: .max)
        let meanCurve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)],
                                 sensorIDs: ids, reduction: .mean)
        XCTAssertEqual(maxCurve.input(readings: readings, globalMax: 88).celsius, 88)
        XCTAssertEqual(meanCurve.input(readings: readings, globalMax: 88).celsius, 75)
    }

    func testPartiallyMissingMappingUsesWhatReportedAndSaysWhatDidNot() {
        let curve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)],
                             sensorIDs: ["PMU tdie1#0", "ghost sensor#3"])
        let input = curve.input(readings: readings, globalMax: 88)
        XCTAssertEqual(input.celsius, 62)
        XCTAssertEqual(input.missingSensorIDs, ["ghost sensor#3"])
        XCTAssertFalse(input.usedGlobalFallback)
    }

    /// The failure that matters: every named sensor gone. Reading that as 0 °C
    /// would stop the fan on a hot machine, and it is the quietest possible way
    /// to do it.
    func testFullyMissingMappingFallsBackToTheMaximumAndReportsIt() {
        let curve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)],
                             sensorIDs: ["renamed by a macOS update#0"])
        let input = curve.input(readings: readings, globalMax: 88)
        XCTAssertEqual(input.celsius, 88)
        XCTAssertTrue(input.usedGlobalFallback)
        XCTAssertEqual(input.missingSensorIDs.count, 1)
    }

    func testNoSensorsAtAllYieldsNoTemperature() {
        let curve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)],
                             sensorIDs: ["anything#0"])
        XCTAssertNil(curve.input(readings: [:], globalMax: nil).celsius)
        XCTAssertNil(FanCurve.balanced.input(readings: [:], globalMax: nil).celsius)
    }

    func testNonFiniteReadingsAreIgnoredRatherThanReduced() {
        let curve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)],
                             sensorIDs: ["a", "b"], reduction: .mean)
        let input = curve.input(readings: ["a": .nan, "b": 50], globalMax: 50)
        XCTAssertEqual(input.celsius, 50, "a NaN must not poison the mean")
        XCTAssertEqual(input.missingSensorIDs, ["a"])
    }

    func testNonFiniteGlobalMaxIsNotUsedAsAFallback() {
        let curve = FanCurve(points: [CurvePoint(tempC: 40, percent: 0)], sensorIDs: ["gone"])
        let input = curve.input(readings: [:], globalMax: .nan)
        XCTAssertNil(input.celsius)
        XCTAssertFalse(input.usedGlobalFallback)
    }

    // MARK: - Curve hygiene

    func testCurveWithNoPointsIsReportedUnusable() {
        XCTAssertFalse(FanCurve(points: []).isUsable)
        XCTAssertTrue(FanCurve.balanced.isUsable)
    }

    func testNonFinitePointsAreDroppedAtConstruction() {
        let curve = FanCurve(points: [
            CurvePoint(tempC: .nan, percent: 50),
            CurvePoint(tempC: 60, percent: .infinity),
            CurvePoint(tempC: 70, percent: 40),
        ])
        XCTAssertEqual(curve.points.count, 1)
        XCTAssertEqual(curve.points.first?.tempC, 70)
    }

    func testPercentsAreClampedIntoRange() {
        let curve = FanCurve(points: [
            CurvePoint(tempC: 40, percent: -20),
            CurvePoint(tempC: 80, percent: 900),
        ])
        XCTAssertEqual(curve.percent(at: 30), 0)
        XCTAssertEqual(curve.percent(at: 90), 100)
    }

    func testEvaluatingAtNaNDoesNotProduceNaN() {
        XCTAssertEqual(FanCurve.balanced.percent(at: .nan), 0)
        XCTAssertTrue(FanCurve.balanced.percent(at: .infinity).isFinite)
    }
}
