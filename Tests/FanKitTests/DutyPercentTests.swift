import XCTest
@testable import FanKit

/// A fan has two different "percent"s and conflating them is what made the
/// dashboard report 0% for a fan audibly spinning at its 1350 rpm minimum.
final class DutyPercentTests: XCTestCase {

    /// Real values probed from this machine's fan 0.
    private let fan = FanDescriptor(index: 0, minRPM: 1350, maxRPM: 5349, modeKeyName: "F0md")

    func testDutyIsAFractionOfMaximum() {
        XCTAssertEqual(fan.dutyPercent(forRPM: 5349), 100, accuracy: 0.001)
        XCTAssertEqual(fan.dutyPercent(forRPM: 2674.5), 50, accuracy: 0.01)
        XCTAssertEqual(fan.dutyPercent(forRPM: 0), 0, accuracy: 0.001)
    }

    /// The regression: idling at the minimum is ~25% duty, not 0%.
    func testIdlingAtMinimumReportsRealisticDuty() {
        let duty = fan.dutyPercent(forRPM: 1357)
        XCTAssertEqual(duty, 25.4, accuracy: 0.2)
        XCTAssertGreaterThan(duty, 20, "a spinning fan must not read as near zero")
    }

    /// The control percent keeps its own meaning — curves are authored in it and
    /// it must stay the exact inverse of `rpm(forPercent:)`.
    func testControlPercentStillRoundTripsWithRPM() {
        for percent in stride(from: 0.0, through: 100.0, by: 5) {
            let rpm = fan.rpm(forPercent: percent)
            XCTAssertEqual(fan.percent(forRPM: rpm), percent, accuracy: 0.001)
        }
    }

    func testTheTwoScalesDifferExactlyWhereExpected() {
        // At the minimum they disagree the most: control 0%, duty ~25%.
        XCTAssertEqual(fan.percent(forRPM: fan.effectiveMin), 0, accuracy: 0.001)
        XCTAssertEqual(fan.dutyPercent(forRPM: fan.effectiveMin), 25.24, accuracy: 0.1)
        // At the maximum they agree.
        XCTAssertEqual(fan.percent(forRPM: fan.effectiveMax), 100, accuracy: 0.001)
        XCTAssertEqual(fan.dutyPercent(forRPM: fan.effectiveMax), 100, accuracy: 0.001)
    }

    func testDutyIsClampedAndSafeOnDegenerateRanges() {
        XCTAssertEqual(fan.dutyPercent(forRPM: 99_999), 100, accuracy: 0.001)
        XCTAssertEqual(fan.dutyPercent(forRPM: -500), 0, accuracy: 0.001)

        let noRange = FanDescriptor(index: 0, minRPM: nil, maxRPM: nil, modeKeyName: "F0md")
        XCTAssertEqual(noRange.dutyPercent(forRPM: 4000), 100, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(noRange.dutyPercent(forRPM: 0), 0)
    }
}
