import XCTest
@testable import DaemonProtocol

/// `clampRPM` documents itself as total: "every input maps to a target inside
/// `[0, maxRPM * overspeedAllowance]`". It is the daemon's last line — the one
/// thing standing between a compromised or buggy app and the hardware — so that
/// claim has to be true for inputs nobody intended, not just for the ones the
/// control loop happens to produce today.
///
/// It was not. `max`/`min` against NaN return the *other* operand, so a NaN
/// range flowed straight through and the result was silently NaN or the
/// unclamped request. NaN then reaches `SMCConnection.writeDouble`, whose
/// encoders clamp the same way — `min(16383, NaN)` is 16383 — so a value meaning
/// "no idea" was written to the fan as *maximum*.
final class ClampTotalityTests: XCTestCase {

    private let allowance = DaemonConstants.overspeedAllowance

    // MARK: - Named degenerate cases

    func testNaNRangeCannotProduceANaNTarget() {
        for temperature: TemperatureEvidence in [.measured(40), .measured(90), .unknown] {
            let value = DaemonConstants.clampRPM(3000, minRPM: .nan, maxRPM: .nan,
                                                 temperature: temperature)
            XCTAssertTrue(value.isFinite, "a NaN range produced \(value)")
            XCTAssertGreaterThanOrEqual(value, 0)
        }
    }

    func testInfiniteMaximumCannotProduceAnUnboundedTarget() {
        let value = DaemonConstants.clampRPM(1_000_000, minRPM: 1200, maxRPM: .infinity,
                                             temperature: .measured(90))
        XCTAssertTrue(value.isFinite)
    }

    func testInvertedRangeStillYieldsSomethingInsideIt() {
        let value = DaemonConstants.clampRPM(3000, minRPM: 5000, maxRPM: 1000,
                                             temperature: .measured(30))
        XCTAssertTrue(value.isFinite)
        XCTAssertGreaterThanOrEqual(value, 0)
    }

    /// A non-finite *request* resolves upward. The daemon rejects these before
    /// they get here, but if one ever arrives, "no idea how fast" must not
    /// silently become "stopped" — the only safe direction to be wrong in is
    /// more airflow.
    func testNonFiniteRequestResolvesTowardsMoreAirflowNotLess() {
        for bad in [Double.nan, .infinity, -.infinity] {
            let value = DaemonConstants.clampRPM(bad, minRPM: 1200, maxRPM: 5000,
                                                 temperature: .measured(30))
            XCTAssertTrue(value.isFinite, "\(bad) produced \(value)")
            XCTAssertGreaterThanOrEqual(value, 5000 - 0.001,
                                        "an unknown request must not read as a stopped fan")
        }
    }

    /// A non-finite measured temperature is unknown, and unknown means the floor
    /// applies — the same rule `TemperatureEvidence` and `SafetyFloor` already
    /// follow. A NaN comparing false against the threshold would have switched
    /// the floor off instead.
    func testNonFiniteMeasuredTemperatureStillAppliesTheFloor() {
        let value = DaemonConstants.clampRPM(0, minRPM: 1200, maxRPM: 5200,
                                             temperature: .measured(.nan))
        let expected = 1200 + (DaemonConstants.hardFloorPercent / 100) * 4000
        XCTAssertEqual(value, expected, accuracy: 0.001,
                       "an unreadable temperature is unknown, not cool")
    }

    // MARK: - Exhaustive

    /// The totality claim, asserted over the cross product of every adversarial
    /// value this function can receive. 3 × 8 × 8 × 3 cases, all of which must
    /// land inside a finite, non-negative envelope.
    func testTotalityOverEveryCombinationOfAdversarialInputs() {
        let nasty: [Double] = [.nan, .infinity, -.infinity, -1, 0, 1, 1e12, 5349]
        let requests: [Double] = [.nan, -.infinity, 1e300]
        let temperatures: [TemperatureEvidence] = [.measured(20), .measured(.nan), .unknown]

        for request in requests + nasty {
            for low in nasty {
                for high in nasty {
                    for temperature in temperatures {
                        let value = DaemonConstants.clampRPM(request, minRPM: low, maxRPM: high,
                                                             temperature: temperature)
                        XCTAssertTrue(value.isFinite,
                                      "request \(request), range \(low)…\(high), \(temperature) -> \(value)")
                        XCTAssertGreaterThanOrEqual(value, 0)
                        // The upper bound is the *sanitised* maximum: a garbage
                        // `maxRPM` cannot be the bound, so the guarantee is that
                        // the result never exceeds the largest sane reading of it.
                        let sanitisedLow = low.isFinite && low >= 0 ? low : 0
                        let sanitisedHigh = high.isFinite && high > sanitisedLow ? high : sanitisedLow
                        XCTAssertLessThanOrEqual(value, sanitisedHigh * allowance + 0.001,
                                                 "request \(request), range \(low)…\(high) escaped the envelope")
                    }
                }
            }
        }
    }

    /// On a sane range the clamp must not have become sloppy: the floor still
    /// applies above the threshold, and never below it.
    func testSaneRangesAreUnaffectedByTheHardening() {
        let low = 1350.0, high = 5349.0
        let span = high - low
        let floor = low + (DaemonConstants.hardFloorPercent / 100) * span

        XCTAssertEqual(DaemonConstants.clampRPM(0, minRPM: low, maxRPM: high,
                                                temperature: .measured(30)),
                       0, accuracy: 0.001, "a cool machine keeps the requested rpm")
        XCTAssertEqual(DaemonConstants.clampRPM(0, minRPM: low, maxRPM: high,
                                                temperature: .measured(DaemonConstants.hardFloorTempC)),
                       floor, accuracy: 0.001)
        XCTAssertEqual(DaemonConstants.clampRPM(0, minRPM: low, maxRPM: high, temperature: .unknown),
                       floor, accuracy: 0.001)
        XCTAssertEqual(DaemonConstants.clampRPM(1e9, minRPM: low, maxRPM: high,
                                                temperature: .measured(90)),
                       high * allowance, accuracy: 0.001)
    }
}
