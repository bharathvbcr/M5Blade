import XCTest
import SMCKit
import SimSupport
@testable import FanKit

/// What happens when the hardware lies.
///
/// `minRPM`/`maxRPM` come straight from `F0Mn`/`F0Mx` via `try?`, so a read that
/// half-succeeds yields a `Double` that is NaN, negative, or inverted rather
/// than the `nil` the optional type suggests. Everything downstream — the curve,
/// the slew limiter, the safety floor, the SMC encoders — assumes a sane range,
/// and none of them check.
final class HardwareRangeTests: XCTestCase {

    private func fan(_ min: Double?, _ max: Double?) -> FanDescriptor {
        FanDescriptor(index: 0, minRPM: min, maxRPM: max, modeKeyName: "F0md")
    }

    // MARK: - The range itself

    func testNaNRangeFallsBackToTheConservativeDefault() {
        let f = fan(.nan, .nan)
        XCTAssertEqual(f.effectiveMin, 1200)
        XCTAssertEqual(f.effectiveMax, 4000)
        XCTAssertFalse(f.hasReportedRange, "NaN is not a reported range")
    }

    func testInfiniteMaximumFallsBackRatherThanScalingEveryPercentage() {
        let f = fan(1350, .infinity)
        XCTAssertTrue(f.effectiveMax.isFinite)
        XCTAssertFalse(f.hasReportedRange)
    }

    func testNegativeMinimumIsRejected() {
        XCTAssertEqual(fan(-500, 5349).effectiveMin, 1200)
    }

    /// The quiet one. An inverted range keeps every value finite, so nothing
    /// throws — but `rpm(forPercent:)` and `percent(forRPM:)` stop being
    /// inverses, and "faster" and "slower" swap places for the slew limiter and
    /// the safety floor independently.
    func testInvertedRangeIsNormalisedRatherThanRunningBackwards() {
        let f = fan(5000, 1000)
        XCTAssertGreaterThanOrEqual(f.effectiveMax, f.effectiveMin)
        XCTAssertFalse(f.hasReportedRange)
        XCTAssertGreaterThanOrEqual(f.rpm(forPercent: 100), f.rpm(forPercent: 0),
                                    "100% must never be slower than 0%")
    }

    /// The property that every other layer relies on: percentages are monotone
    /// and bounded, whatever the hardware claimed.
    func testPercentageMappingIsTotalAndMonotoneOverHostileRanges() {
        var rng = SplitMix64(seed: 0x0FA0_1234)
        let nasty: [Double?] = [nil, .nan, .infinity, -.infinity, -1, 0, 1e12]

        for _ in 0..<2_000 {
            let low = Bool.random(using: &rng) ? nasty.randomElement(using: &rng)!
                                              : Double.random(in: -5_000...20_000, using: &rng)
            let high = Bool.random(using: &rng) ? nasty.randomElement(using: &rng)!
                                               : Double.random(in: -5_000...20_000, using: &rng)
            let f = fan(low, high)

            XCTAssertTrue(f.effectiveMin.isFinite, "min \(String(describing: low))")
            XCTAssertTrue(f.effectiveMax.isFinite, "max \(String(describing: high))")
            XCTAssertGreaterThanOrEqual(f.effectiveMax, f.effectiveMin)

            var previous = -Double.infinity
            for percent in stride(from: -50.0, through: 150.0, by: 5) {
                let rpm = f.rpm(forPercent: percent)
                XCTAssertTrue(rpm.isFinite)
                XCTAssertGreaterThanOrEqual(rpm, 0)
                XCTAssertGreaterThanOrEqual(rpm, previous - 0.001, "rpm went backwards as percent rose")
                previous = rpm

                let back = f.percent(forRPM: rpm)
                XCTAssertTrue(back.isFinite)
                XCTAssertGreaterThanOrEqual(back, -0.001)
                XCTAssertLessThanOrEqual(back, 100.001)

                let duty = f.dutyPercent(forRPM: rpm)
                XCTAssertTrue(duty.isFinite)
                XCTAssertGreaterThanOrEqual(duty, -0.001)
                XCTAssertLessThanOrEqual(duty, 100.001)
            }
        }
    }

    /// A hostile range must not be able to produce a non-finite target through
    /// the control loop either — that is the value that reaches the SMC.
    func testControlLoopStaysFiniteOnAHostileRange() {
        var rng = SplitMix64(seed: 0xBADF_A115)
        let trace = Trace.hostile(steps: 400, rng: &rng)

        for (low, high) in [(Double.nan, Double.nan), (5000, 1000), (-1, .infinity), (0, 0)] {
            let descriptor = fan(low, high)
            var loop = ControlLoop(fan: descriptor, curve: .balanced)
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            for sample in trace {
                now.addTimeInterval(max(0, sample.dt))
                let d = loop.step(curveTempC: sample.tempC, floorTempC: sample.tempC,
                                  pressure: sample.pressure, now: now, dt: sample.dt)
                XCTAssertTrue(d.targetRPM.isFinite, "range \(low)…\(high) produced a non-finite rpm")
                XCTAssertTrue(d.targetPercent.isFinite)
                XCTAssertGreaterThanOrEqual(d.targetRPM, 0)
            }
        }
    }

    // MARK: - Fan key addressing

    /// A FourCC is exactly four bytes. Fan 10 composes "F10Ac", and the
    /// truncating initializer turns that into "F10A" — a *different key*, which
    /// the SMC will read and, for a target, write. Silently driving the wrong
    /// key is worse than refusing.
    func testFanKeysBeyondTheFourCCLimitAreRefusedRatherThanTruncated() {
        for index in 0...9 {
            let key = SMCKey.fan(index, "Ac")
            XCTAssertEqual(key?.description, "F\(index)Ac")
        }
        for index in [10, 11, 42, 100, Int.max] {
            XCTAssertNil(SMCKey.fan(index, "Ac"), "fan \(index) has no four-character spelling")
            XCTAssertNil(SMCKey.fan(index, "md"))
        }
        XCTAssertNil(SMCKey.fan(-1, "Ac"))
    }

    /// Every suffix the codebase actually uses fits, for every addressable fan.
    func testEverySuffixInUseComposesToExactlyFourCharacters() {
        for suffix in ["Ac", "Tg", "Mn", "Mx", "md", "Md"] {
            for index in 0...9 {
                let key = SMCKey.fan(index, suffix)
                XCTAssertNotNil(key, "F\(index)\(suffix) should be addressable")
                XCTAssertEqual(key?.description.count, 4)
            }
        }
    }
}
