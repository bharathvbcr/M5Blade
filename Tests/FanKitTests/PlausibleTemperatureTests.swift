import XCTest
@testable import FanKit

/// The bound that separates "a reading" from "a number".
///
/// It exists because more than one module needs it and only one of them can see
/// the sensor layer that used to own the rule privately. A copy per consumer is
/// how one of them ends up admitting a value the other rejects.
final class PlausibleTemperatureTests: XCTestCase {

    func testRealReadingsAreAccepted() {
        for celsius in [-40.0, -0.0, 0, 18.5, 51.8, 88.8, 103, 110, 199.9] {
            XCTAssertTrue(PlausibleTemperature.admits(celsius), "\(celsius) rejected")
        }
    }

    func testNumbersThatCannotBeTemperaturesAreRejected() {
        for celsius in [1e9, -1e9, 1e300, -1e300, 200.1, -50.1, -273.16] {
            XCTAssertFalse(PlausibleTemperature.admits(celsius), "\(celsius) accepted")
        }
    }

    /// The readings that each caller independently needed this for, kept
    /// together because they are the reason it is one rule and not three.
    ///
    /// Every one of these was measured, not imagined: `TTPD` really reports
    /// −306783232 °C on this Mac, and `1e9` really became a spike's baseline
    /// when the detectors checked only `isFinite`.
    func testTheReadingsEachCallerNeededThisFor() {
        XCTAssertFalse(PlausibleTemperature.admits(-306_783_232),
                       "the SMC's TTPD key")
        XCTAssertFalse(PlausibleTemperature.admits(1e9),
                       "finite, and it became a spike baseline")
        XCTAssertTrue(PlausibleTemperature.admits(102.07), "a real SMC reading")
        XCTAssertTrue(PlausibleTemperature.admits(88.8), "a real HID die-zone reading")
        XCTAssertTrue(PlausibleTemperature.admits(51.8), "PMU tcal, a real constant")
    }

    /// The one that a naive range check gets wrong: every comparison against NaN
    /// is false, so "not too hot" and "not too cold" both pass it through.
    func testNaNAndInfinitiesAreRejected() {
        XCTAssertFalse(PlausibleTemperature.admits(.nan))
        XCTAssertFalse(PlausibleTemperature.admits(.signalingNaN))
        XCTAssertFalse(PlausibleTemperature.admits(.infinity))
        XCTAssertFalse(PlausibleTemperature.admits(-.infinity))
    }

    func testTheBoundsThemselvesAreInside() {
        XCTAssertTrue(PlausibleTemperature.admits(PlausibleTemperature.minimumC))
        XCTAssertTrue(PlausibleTemperature.admits(PlausibleTemperature.maximumC))
    }

    func testValidatedPassesThroughOrErasesToNil() {
        XCTAssertEqual(PlausibleTemperature.validated(88.8), 88.8)
        XCTAssertNil(PlausibleTemperature.validated(nil))
        XCTAssertNil(PlausibleTemperature.validated(.nan))
        XCTAssertNil(PlausibleTemperature.validated(1e9))
    }

    /// The range has to cover the machine this app runs on. A Mac in a cold room
    /// and a die about to halt are both readings, not glitches.
    func testTheRangeCoversEveryStateARealMacReachesIn() {
        XCTAssertLessThan(PlausibleTemperature.minimumC, -20, "a cold room is not a glitch")
        XCTAssertGreaterThan(PlausibleTemperature.maximumC, 115,
                             "silicon at its shutdown threshold is still reporting")
    }
}
