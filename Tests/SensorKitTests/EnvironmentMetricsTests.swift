import XCTest
@testable import SensorKit

/// `EnvironmentMetrics` is the one new component that reads a system API rather
/// than pure state, so it gets a sanity check: whatever this machine reports, the
/// values must be inside their documented ranges. A rule engine fed a nonsense
/// battery percentage would misfire silently.
final class EnvironmentMetricsTests: XCTestCase {

    func testPowerSourceReturnsSaneValues() {
        let (onAC, percent) = EnvironmentMetrics.powerSource()

        if let percent {
            XCTAssertTrue(percent.isFinite, "battery percent must be a real number")
            XCTAssertGreaterThanOrEqual(percent, 0)
            XCTAssertLessThanOrEqual(percent, 100)
        }
        // A machine with no battery must report AC rather than inventing one.
        if percent == nil {
            XCTAssertTrue(onAC, "no battery present should mean AC power")
        }
    }

    /// Repeated reads must not leak or drift — this runs on every control tick.
    func testPowerSourceIsStableAcrossReads() {
        let first = EnvironmentMetrics.powerSource()
        let second = EnvironmentMetrics.powerSource()
        XCTAssertEqual(first.onAC, second.onAC)
        if let a = first.percent, let b = second.percent {
            XCTAssertEqual(a, b, accuracy: 5, "battery reading jumped between adjacent reads")
        }
    }
}
