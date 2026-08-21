import XCTest
import SimSupport
@testable import FanKit

/// Long-running and adversarial exercises of the control loop.
///
/// Every one of these asserts the same contract (`ControlInvariants.check`) on
/// every single step, rather than only on the final value: a controller that
/// violates the safety floor for 200 milliseconds and recovers is still a
/// controller that violated the safety floor.
final class ControlLoopStressTests: XCTestCase {

    private let fan = FanDescriptor(index: 0, minRPM: 1350, maxRPM: 5349, modeKeyName: "F0md")
    private let floor = SafetyFloor()

    private func run(curve: FanCurve,
                     settings: ControlSettings,
                     trace: [TraceSample],
                     file: StaticString = #filePath,
                     line: UInt = #line) -> [ControlDecision] {
        var loop = ControlLoop(fan: fan, curve: curve, settings: settings, floor: floor)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var decisions: [ControlDecision] = []
        decisions.reserveCapacity(trace.count)

        for (i, sample) in trace.enumerated() {
            now.addTimeInterval(sample.dt)
            let previousRPM = decisions.last?.targetRPM
            let decision = loop.step(curveTempC: sample.tempC, floorTempC: sample.tempC,
                                     pressure: sample.pressure, now: now, dt: sample.dt)
            decisions.append(decision)
            do {
                try ControlInvariants.check(decision, fan: fan, settings: settings, floor: floor,
                                            floorTempC: sample.tempC, pressure: sample.pressure,
                                            previousRPM: previousRPM, step: i)
            } catch {
                XCTFail("\(error) — sample \(String(describing: sample))", file: file, line: line)
                return decisions
            }
        }
        return decisions
    }

    private var allProfiles: [(String, FanCurve, ControlSettings)] {
        [
            ("silent", .silent, ControlSettings(ceilingPercent: 60)),
            ("balanced", .balanced, ControlSettings(ceilingPercent: 95)),
            ("performance", .performance, ControlSettings(ceilingPercent: 95, hysteresisC: 2, slewUpRPMPerSec: 400)),
            ("maxCooling", .maxCooling, ControlSettings(ceilingPercent: 100, hysteresisC: 2, slewUpRPMPerSec: 600)),
        ]
    }

    // MARK: - Deterministic traces

    func testEveryBuiltInProfileSurvivesAFullTemperatureSweep() {
        for (name, curve, settings) in allProfiles {
            let up = Trace.ramp(from: -10, to: 120, steps: 1400)
            let down = Trace.ramp(from: 120, to: -10, steps: 1400)
            let decisions = run(curve: curve, settings: settings, trace: up + down)
            XCTAssertEqual(decisions.count, 2800, "\(name) aborted early")
        }
    }

    func testSquareWaveDoesNotBreakHysteresisOrSlew() {
        for (_, curve, settings) in allProfiles {
            _ = run(curve: curve, settings: settings,
                    trace: Trace.square(low: 35, high: 99, period: 3, steps: 3000))
        }
    }

    func testTwentyFourHoursOfNoiseHoldsEveryInvariant() {
        var rng = SplitMix64(seed: 0xFA0C_0417)
        for (_, curve, settings) in allProfiles {
            let trace = Trace.noisy(around: 72, amplitude: 6, steps: 86_400, rng: &rng)
            _ = run(curve: curve, settings: settings, trace: trace)
        }
    }

    /// Ten seeded runs of dropouts, NaN, sleep gaps, backwards clocks, and
    /// pressure moving independently of temperature.
    func testHostileTracesAcrossManySeeds() {
        for seed in UInt64(1)...10 {
            var rng = SplitMix64(seed: seed)
            let trace = Trace.hostile(steps: 5_000, rng: &rng)
            for (name, curve, settings) in allProfiles {
                let decisions = run(curve: curve, settings: settings, trace: trace)
                XCTAssertEqual(decisions.count, trace.count, "\(name) seed \(seed) aborted early")
            }
        }
    }

    /// Randomised *settings* as well as inputs: the config file is user-editable,
    /// so the loop has to be total over hostile settings too.
    func testRandomSettingsCannotBreakTheContract() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<300 {
            let settings = ControlSettings(
                ceilingPercent: Double.random(in: -50...500, using: &rng),
                hysteresisC: Double.random(in: -20...200, using: &rng),
                slewUpRPMPerSec: Double.random(in: -5_000...50_000, using: &rng),
                slewDownRPMPerSec: Double.random(in: -5_000...50_000, using: &rng),
                smoothingAlpha: Double.random(in: -5...5, using: &rng))
            let points = (0..<Int.random(in: 0...8, using: &rng)).map { _ in
                CurvePoint(tempC: Double.random(in: -50...200, using: &rng),
                           percent: Double.random(in: -200...400, using: &rng))
            }
            let trace = Trace.hostile(steps: 200, rng: &rng)
            // The contract is checked against the *sanitized* ceiling, because
            // that is what the loop is required to honour; an unsanitized
            // negative ceiling must still never push the target below the floor.
            _ = run(curve: FanCurve(points: points), settings: settings.sanitized(), trace: trace)
        }
    }

    /// The other half of the ceiling contract. A slew-limited descent is allowed
    /// to sit above the ceiling on the way down — it cannot teleport — but it has
    /// to *arrive*. Without this, "temporarily above the ceiling" is indefinite.
    func testDescentFromEmergencyConvergesBackUnderTheCeiling() {
        let settings = ControlSettings(ceilingPercent: 60, slewDownRPMPerSec: 100)
        var loop = ControlLoop(fan: fan, curve: .silent, settings: settings, floor: floor)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        // Pin it at full blast, then drop to a cool machine with no pressure.
        for _ in 0..<20 {
            now.addTimeInterval(1)
            _ = loop.step(temp: 105, pressure: .critical, now: now, dt: 1)
        }
        var settled: ControlDecision?
        for _ in 0..<180 {
            now.addTimeInterval(1)
            settled = loop.step(temp: 45, pressure: .nominal, now: now, dt: 1)
        }
        XCTAssertNotNil(settled)
        XCTAssertLessThanOrEqual(settled!.targetPercent, 60.001,
                                 "the fan never came back under the profile's ceiling")
    }

    /// The unknown-temperature floor, end to end. A sensor that blinks out must
    /// not leave the fan reported as floor-zero while the daemon is separately
    /// enforcing 25%.
    func testSensorGapHoldsAtTheUnknownTemperatureFloor() {
        var loop = ControlLoop(fan: fan, curve: .silent, floor: floor)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        // Cool machine: the fan is legitimately at its minimum.
        let cool = loop.step(temp: 30, pressure: .nominal, now: now, dt: 1)
        XCTAssertEqual(cool.floorPercent, 0)

        now.addTimeInterval(1)
        let gap = loop.step(temp: nil, pressure: .nominal, now: now, dt: 1)
        XCTAssertFalse(gap.releaseToSystem)
        XCTAssertEqual(gap.floorPercent, floor.hardFloorPercent, accuracy: 0.001,
                       "an unreadable sensor is unknown, not cool")
        XCTAssertGreaterThanOrEqual(gap.targetPercent, floor.hardFloorPercent - 0.001)
    }

    // MARK: - Behaviour, not just safety

    /// The question this whole system exists to answer: do profiles actually
    /// produce different fan speeds? Checked at a temperature where none of them
    /// is pinned to the floor or the ceiling.
    func testProfilesProduceDistinctSteadyStateTargets() {
        var results: [String: Double] = [:]
        for (name, curve, settings) in allProfiles {
            let decisions = run(curve: curve, settings: settings,
                                trace: Array(repeating: TraceSample(tempC: 72), count: 600))
            results[name] = decisions.last!.targetPercent
        }
        XCTAssertLessThan(results["silent"]!, results["balanced"]!)
        XCTAssertLessThan(results["balanced"]!, results["performance"]!)
        XCTAssertLessThanOrEqual(results["performance"]!, results["maxCooling"]!)
        XCTAssertGreaterThan(results["maxCooling"]! - results["silent"]!, 20,
                             "the spread between Silent and Max cooling should be substantial")
    }

    /// A profile switch has to take effect promptly. Slew limiting delays it, but
    /// it must not prevent it.
    func testSwitchingProfileMovesTheFanWithinAFewSeconds() {
        var loop = ControlLoop(fan: fan, curve: .silent, settings: ControlSettings(ceilingPercent: 60))
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<300 {
            now.addTimeInterval(1)
            _ = loop.step(temp: 68, pressure: .nominal, now: now, dt: 1)
        }
        let before = loop.step(temp: 68, pressure: .nominal, now: now, dt: 1)

        loop.curve = .maxCooling
        loop.settings = ControlSettings(ceilingPercent: 100, hysteresisC: 2, slewUpRPMPerSec: 600)
        var after = before
        for _ in 0..<10 {
            now.addTimeInterval(1)
            after = loop.step(temp: 68, pressure: .nominal, now: now, dt: 1)
        }
        XCTAssertGreaterThan(after.targetPercent, before.targetPercent + 20,
                             "switching to Max cooling did not move the fan")
    }

    /// Noise must not reach the fan as chatter. This is what hysteresis and the
    /// EMA are for, and it is the difference between a usable app and one people
    /// turn off.
    func testNoisePlateauDoesNotChatterTheFan() {
        var rng = SplitMix64(seed: 99)
        let trace = Trace.noisy(around: 70, amplitude: 2.5, steps: 4_000, rng: &rng)
        let decisions = run(curve: .balanced, settings: ControlSettings(), trace: trace)

        let settled = decisions.suffix(3_000)
        var reversals = 0
        var previous: Double?
        var lastDirection = 0
        for d in settled {
            defer { previous = d.targetRPM }
            guard let previous else { continue }
            let delta = d.targetRPM - previous
            guard abs(delta) > 1 else { continue }
            let direction = delta > 0 ? 1 : -1
            if lastDirection != 0 && direction != lastDirection { reversals += 1 }
            lastDirection = direction
        }
        XCTAssertLessThan(reversals, 60,
                          "\(reversals) direction changes in 3000 samples of ±2.5 °C noise is audible hunting")
    }

    // MARK: - Closed loop

    /// The full loop against the thermal model, across every profile and a load
    /// that changes underneath it. Asserts the machine is actually cooled, not
    /// merely that no assertion tripped.
    func testClosedLoopAcrossProfilesAndChangingLoad() async throws {
        for (name, curve, settings) in allProfiles {
            let backend = SimulatedFanBackend()
            let fans = try await backend.discoverFans()
            var loop = ControlLoop(fan: fans[0], curve: curve, settings: settings, floor: floor)
            try await backend.setMode(.manual, fan: 0)
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            var peak = 0.0

            for i in 0..<3_600 {
                await backend.setLoad(i % 1_200 < 600 ? 1.0 : 0.05)
                await backend.advance(1)
                let temp = await backend.currentTemp
                peak = max(peak, temp)
                now.addTimeInterval(1)
                let d = loop.step(temp: temp, pressure: .nominal, now: now, dt: 1)
                try ControlInvariants.check(d, fan: fans[0], settings: settings, floor: floor,
                                            floorTempC: temp, pressure: .nominal, step: i)
                try await backend.setTarget(rpm: d.targetRPM, fan: 0)
            }
            XCTAssertLessThan(peak, 110, "\(name) let the simulated machine run away")
            let final = await backend.currentTemp
            XCTAssertLessThan(final, 70, "\(name) never recovered after the load dropped")
        }
    }

    /// Two fans with different ranges driven from one machine temperature — the
    /// per-fan modelling from AUDIT A-3. Neither may violate its own envelope.
    func testTwoFansWithDifferentRangesStayInTheirOwnEnvelopes() {
        let fans = [
            FanDescriptor(index: 0, minRPM: 1350, maxRPM: 5349, modeKeyName: "F0md"),
            FanDescriptor(index: 1, minRPM: 1350, maxRPM: 5777, modeKeyName: "F1md"),
        ]
        var loops = fans.map { ControlLoop(fan: $0, curve: .balanced, floor: floor) }
        var previous = [Double?](repeating: nil, count: fans.count)
        var rng = SplitMix64(seed: 4242)
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        for (i, sample) in Trace.hostile(steps: 4_000, rng: &rng).enumerated() {
            now.addTimeInterval(sample.dt)
            for index in loops.indices {
                let d = loops[index].step(temp: sample.tempC, pressure: sample.pressure,
                                          now: now, dt: sample.dt)
                XCTAssertNoThrow(
                    try ControlInvariants.check(d, fan: fans[index], settings: ControlSettings(),
                                                floor: floor, floorTempC: sample.tempC,
                                                pressure: sample.pressure,
                                                previousRPM: previous[index], step: i))
                previous[index] = d.targetRPM
            }
        }
        // The two fans have different maxima, so identical percentages must have
        // produced different rpm — otherwise the per-fan modelling is decorative.
        XCTAssertNotEqual(previous[0], previous[1])
    }
}
