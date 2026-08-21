import XCTest
@testable import FanKit

final class ControlLoopTests: XCTestCase {

    private func makeFan() -> FanDescriptor {
        FanDescriptor(index: 0, minRPM: 1200, maxRPM: 8400, modeKeyName: "F0md")
    }

    /// The single most important invariant in the project.
    func testTargetNeverDropsBelowTheSafetyFloor() {
        let fan = makeFan()
        // A deliberately dangerous curve: zero percent everywhere.
        let reckless = FanCurve(points: [
            CurvePoint(tempC: 0, percent: 0),
            CurvePoint(tempC: 120, percent: 0),
        ])
        var loop = ControlLoop(fan: fan, curve: reckless)
        let floor = SafetyFloor()
        var now = Date()

        for temp in stride(from: 30.0, through: 105.0, by: 1) {
            let decision = loop.step(temp: temp, pressure: .nominal, now: now, dt: 1)
            now.addTimeInterval(1)
            let expectedFloor = floor.floorPercent(tempC: temp, pressure: .nominal)
            XCTAssertGreaterThanOrEqual(decision.targetPercent, expectedFloor - 4.0,
                                        "floor violated at \(temp)°C")
        }
    }

    func testCeilingIsRespectedUntilEmergency() {
        var loop = ControlLoop(fan: makeFan(), curve: .performance,
                               settings: ControlSettings(ceilingPercent: 95))
        var now = Date()
        for _ in 0..<200 {
            let d = loop.step(temp: 88, pressure: .nominal, now: now, dt: 1)
            now.addTimeInterval(1)
            XCTAssertLessThanOrEqual(d.targetPercent, 95.5)
        }
    }

    func testEmergencyReleasesTheCeilingImmediately() {
        var loop = ControlLoop(fan: makeFan(), curve: .silent,
                               settings: ControlSettings(ceilingPercent: 60))
        let decision = loop.step(temp: 101, pressure: .critical, now: Date(), dt: 1)
        XCTAssertTrue(decision.isEmergency)
        XCTAssertGreaterThan(decision.targetPercent, 95)
    }

    func testStaleSensorDataReleasesToSystem() {
        var loop = ControlLoop(fan: makeFan(), curve: .balanced)
        var now = Date()
        _ = loop.step(temp: 70, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(30)
        let decision = loop.step(temp: nil, pressure: .nominal, now: now, dt: 30)
        XCTAssertTrue(decision.releaseToSystem)
    }

    func testBriefSensorGapHoldsRatherThanReleasing() {
        var loop = ControlLoop(fan: makeFan(), curve: .balanced)
        var now = Date()
        _ = loop.step(temp: 75, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(2)
        let decision = loop.step(temp: nil, pressure: .nominal, now: now, dt: 2)
        XCTAssertFalse(decision.releaseToSystem)
    }

    /// Slew limiting applies to curve-driven movement. The step stays below 50 °C
    /// so the safety floor is zero throughout and cannot be the binding constraint
    /// — see `testSafetyFloorOverridesSlewLimit` for what happens when it is.
    func testSlewLimitingCapsRateOfChange() {
        var loop = ControlLoop(fan: makeFan(), curve: .maxCooling,
                               settings: ControlSettings(ceilingPercent: 100,
                                                         slewUpRPMPerSec: 200))
        var now = Date()
        let first = loop.step(temp: 30, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(1)
        let second = loop.step(temp: 45, pressure: .nominal, now: now, dt: 1)
        XCTAssertEqual(second.floorPercent, 0, "floor must not participate in this test")
        XCTAssertGreaterThan(second.targetRPM, first.targetRPM, "slew cap was never exercised")
        XCTAssertLessThanOrEqual(second.targetRPM - first.targetRPM, 201)
    }

    /// The rate limit is a comfort feature; the safety floor is not. When a step
    /// in temperature puts the floor above what the slew cap would allow, the
    /// floor wins and the fan jumps (AUDIT A-1: target never below floor).
    func testSafetyFloorOverridesSlewLimit() {
        let fan = makeFan()
        var loop = ControlLoop(fan: fan, curve: .maxCooling,
                               settings: ControlSettings(ceilingPercent: 100,
                                                         slewUpRPMPerSec: 200))
        var now = Date()
        let first = loop.step(temp: 30, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(1)
        let second = loop.step(temp: 90, pressure: .nominal, now: now, dt: 1)

        let floorAt90 = SafetyFloor().floorPercent(tempC: 90, pressure: .nominal)
        XCTAssertGreaterThan(second.targetRPM - first.targetRPM, 201,
                             "floor should have overridden the rate cap")
        XCTAssertGreaterThanOrEqual(second.targetRPM, fan.rpm(forPercent: floorAt90) - 0.001)
    }

    func testHysteresisSuppressesSmallOscillation() {
        var loop = ControlLoop(fan: makeFan(), curve: .balanced,
                               settings: ControlSettings(hysteresisC: 3, smoothingAlpha: 1.0))
        var now = Date()
        let baseline = loop.step(temp: 70, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(1)
        let jitter = loop.step(temp: 71, pressure: .nominal, now: now, dt: 1)
        XCTAssertEqual(baseline.targetPercent, jitter.targetPercent, accuracy: 0.5)
    }

    /// Closed-loop check against the thermal simulator: with a real curve under
    /// sustained load, temperature must stabilise rather than run away.
    func testSimulatedSystemStabilisesUnderSustainedLoad() async throws {
        let backend = SimulatedFanBackend()
        let fans = try await backend.discoverFans()
        var loop = ControlLoop(fan: fans[0], curve: .balanced)
        await backend.setLoad(1.0)
        try await backend.setMode(.manual, fan: 0)
        for i in 0..<600 {
            await backend.advance(1)
            let temp = await backend.currentTemp
            let d = loop.step(temp: temp, pressure: .nominal,
                              now: Date().addingTimeInterval(Double(i)), dt: 1)
            try await backend.setTarget(rpm: d.targetRPM, fan: 0)
        }
        let final = await backend.currentTemp
        XCTAssertLessThan(final, 100, "temperature ran away under control")
        XCTAssertGreaterThan(final, 24)
    }

    // MARK: - Curve temperature vs safety temperature

    /// AUDIT A-3: a fan mapped to a cool sensor still has to answer to a hot
    /// machine. The curve reads its own sensors; the floor reads the maximum.
    func testFloorFollowsTheMachineMaximumEvenWhenTheCurveSensorIsCool() {
        var loop = ControlLoop(fan: makeFan(), curve: .silent,
                               settings: ControlSettings(ceilingPercent: 100))
        let decision = loop.step(curveTempC: 35, floorTempC: 95,
                                 pressure: .nominal, now: Date(), dt: 1)
        let expected = SafetyFloor().floorPercent(tempC: 95, pressure: .nominal)
        XCTAssertEqual(decision.floorPercent, expected, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(decision.targetPercent, expected - 0.001,
                                    "a cool mapped sensor must not suppress the floor")
    }

    func testEmergencyUsesTheMachineMaximumNotTheCurveSensor() {
        var loop = ControlLoop(fan: makeFan(), curve: .silent,
                               settings: ControlSettings(ceilingPercent: 60))
        let decision = loop.step(curveTempC: 40, floorTempC: 101,
                                 pressure: .nominal, now: Date(), dt: 1)
        XCTAssertTrue(decision.isEmergency)
    }

    /// The curve is smoothed; the floor is not. On a ramp the floor must track
    /// the real temperature rather than the EMA of it.
    func testFloorDoesNotLagBehindTheEMA() {
        var loop = ControlLoop(fan: makeFan(), curve: .silent,
                               settings: ControlSettings(ceilingPercent: 100, smoothingAlpha: 0.05))
        var now = Date()
        var last = ControlDecision(targetRPM: 0, targetPercent: 0, floorPercent: 0,
                                   isEmergency: false, releaseToSystem: false, reason: "")
        for temp in stride(from: 40.0, through: 90.0, by: 1) {
            last = loop.step(temp: temp, pressure: .nominal, now: now, dt: 1)
            now.addTimeInterval(1)
            let expected = SafetyFloor().floorPercent(tempC: temp, pressure: .nominal)
            XCTAssertEqual(last.floorPercent, expected, accuracy: 0.001,
                           "floor lagged the measurement at \(temp)°C")
        }
        XCTAssertGreaterThan(last.floorPercent, 0)
    }

    /// A curve whose mapped sensors vanish gets `nil`, and must fall back to the
    /// machine maximum rather than reading as 0 °C and stopping the fan.
    func testMissingCurveTemperatureFallsBackToTheMachineMaximum() {
        var loop = ControlLoop(fan: makeFan(), curve: .performance,
                               settings: ControlSettings(ceilingPercent: 100))
        let mapped = loop.step(curveTempC: 80, floorTempC: 80, pressure: .nominal, now: Date(), dt: 0)
        var fallbackLoop = ControlLoop(fan: makeFan(), curve: .performance,
                                       settings: ControlSettings(ceilingPercent: 100))
        let fallback = fallbackLoop.step(curveTempC: nil, floorTempC: 80,
                                         pressure: .nominal, now: Date(), dt: 0)
        XCTAssertEqual(mapped.targetRPM, fallback.targetRPM, accuracy: 0.001)
    }

    // MARK: - Hostile inputs

    func testNaNTemperatureIsTreatedAsMissingNotAsZero() {
        var loop = ControlLoop(fan: makeFan(), curve: .balanced)
        var now = Date()
        _ = loop.step(temp: 70, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(1)
        let decision = loop.step(temp: .nan, pressure: .nominal, now: now, dt: 1)
        XCTAssertFalse(decision.releaseToSystem, "one NaN sample is a gap, not a stale sensor")
        XCTAssertGreaterThan(decision.targetRPM, 0, "NaN must not be read as a cold machine")
    }

    func testNaNCurveTemperatureFallsBackToTheFloorSample() {
        var loop = ControlLoop(fan: makeFan(), curve: .performance,
                               settings: ControlSettings(ceilingPercent: 100))
        let decision = loop.step(curveTempC: .nan, floorTempC: 80,
                                 pressure: .nominal, now: Date(), dt: 0)
        XCTAssertTrue(decision.targetRPM.isFinite)
        XCTAssertGreaterThanOrEqual(decision.targetPercent,
                                    SafetyFloor().floorPercent(tempC: 80, pressure: .nominal) - 0.001)
    }

    /// A negative slew rate used to invert the limiter: `previous + (-400)`
    /// dragged the target *down* on the way up, so a hand-edited config could
    /// make the fan respond backwards.
    func testNegativeSlewRatesCannotInvertTheLimiter() {
        var loop = ControlLoop(fan: makeFan(), curve: .maxCooling,
                               settings: ControlSettings(ceilingPercent: 100,
                                                         slewUpRPMPerSec: -400,
                                                         slewDownRPMPerSec: -400))
        var now = Date()
        let first = loop.step(temp: 30, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(1)
        let second = loop.step(temp: 60, pressure: .nominal, now: now, dt: 1)
        XCTAssertGreaterThanOrEqual(second.targetRPM, first.targetRPM - 0.001,
                                    "a negative rate must clamp to zero, not reverse the fan")
    }

    /// Waking from a four-hour sleep must not let the slew limiter carry an rpm
    /// from before the sleep, nor smooth across the gap.
    func testLongGapResetsSmoothingAndSlewState() {
        var loop = ControlLoop(fan: makeFan(), curve: .maxCooling,
                               settings: ControlSettings(ceilingPercent: 100, slewUpRPMPerSec: 50))
        var now = Date()
        _ = loop.step(temp: 30, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(4 * 3600)
        let afterWake = loop.step(temp: 95, pressure: .nominal, now: now, dt: 4 * 3600)
        let expected = SafetyFloor().floorPercent(tempC: 95, pressure: .nominal)
        XCTAssertGreaterThanOrEqual(afterWake.targetPercent, expected - 0.001)
        XCTAssertTrue(afterWake.targetRPM.isFinite)
    }

    func testClockRunningBackwardsDoesNotProduceANegativeTarget() {
        var loop = ControlLoop(fan: makeFan(), curve: .balanced)
        var now = Date()
        _ = loop.step(temp: 80, pressure: .nominal, now: now, dt: 1)
        now.addTimeInterval(-600)
        let decision = loop.step(temp: 80, pressure: .nominal, now: now, dt: -600)
        XCTAssertGreaterThanOrEqual(decision.targetRPM, 0)
        XCTAssertTrue(decision.targetRPM.isFinite)
    }
}

extension ControlLoop {
    /// An unmapped curve: one temperature drives both the curve and the floor,
    /// which is what every built-in profile does.
    mutating func step(temp: Double?, pressure: ThermalPressure,
                       now: Date, dt: TimeInterval) -> ControlDecision {
        step(curveTempC: temp, floorTempC: temp, pressure: pressure, now: now, dt: dt)
    }
}
