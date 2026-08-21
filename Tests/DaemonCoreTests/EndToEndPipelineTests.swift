import XCTest
import FanKit
import DaemonProtocol
import SimSupport
@testable import DaemonCore

/// The whole chain the app runs every second, assembled without the app:
///
///     profile -> per-fan curve -> ControlLoop -> DaemonCore (clamp, floor,
///     manual-mode check) -> backend -> fan rpm
///
/// Each layer is tested on its own elsewhere. These tests exist because the
/// original defect was not in any layer — it was that the chain was never
/// joined up, so a profile change reached `activeProfileID` and stopped there.
final class EndToEndPipelineTests: XCTestCase {

    /// Stands in for `AppModel.applyControl`, running the same sequence in the
    /// same order: heartbeat, per-fan curve input, control step, setTarget.
    private struct Pipeline {
        let core: DaemonCore
        let backend: SimulatedFanBackend
        let fans: [FanDescriptor]
        var loops: [Int: ControlLoop]
        var now: Date

        mutating func tick(profile: (curves: [Int: FanCurve], settings: ControlSettings),
                           readings: [String: Double],
                           pressure: ThermalPressure = .nominal,
                           dt: TimeInterval = 1) async -> [Int: Double] {
            now.addTimeInterval(dt)
            let globalMax = readings.values.filter(\.isFinite).max()
            await core.heartbeat(maxTempC: globalMax ?? .nan, at: now)

            var applied: [Int: Double] = [:]
            for fan in fans {
                guard var loop = loops[fan.index] else { continue }
                let curve = profile.curves[fan.index] ?? profile.curves.keys.min().flatMap { profile.curves[$0] } ?? .balanced
                loop.curve = curve
                loop.settings = profile.settings
                let input = curve.input(readings: readings, globalMax: globalMax)
                let decision = loop.step(curveTempC: input.celsius, floorTempC: globalMax,
                                         pressure: pressure, now: now, dt: dt)
                loops[fan.index] = loop
                guard !decision.releaseToSystem else {
                    _ = await core.releaseAll()
                    continue
                }
                if case .success(let rpm) = await core.setTarget(fan: fan.index,
                                                                 rpm: decision.targetRPM, now: now) {
                    applied[fan.index] = rpm
                }
            }
            return applied
        }
    }

    /// Every clock in the pipeline starts here. The daemon now measures its
    /// watchdog from the moment fans were armed as well as from the last
    /// heartbeat, so a test that arms on the wall clock and beats on a synthetic
    /// one is testing a machine that cannot exist.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePipeline(fanCount: Int = 2) async throws -> Pipeline {
        var config = SimulatedFanBackend.Config()
        config.fanCount = fanCount
        config.minRPM = 1350
        config.maxRPM = 5349
        let backend = SimulatedFanBackend(config: config)
        let core = DaemonCore(backend: backend)
        _ = await core.start(now: start)
        let fans = try await backend.discoverFans()
        for fan in fans { _ = await core.setManualMode(fan: fan.index, enabled: true, now: start) }
        let loops = Dictionary(uniqueKeysWithValues: fans.map {
            ($0.index, ControlLoop(fan: $0, curve: .balanced))
        })
        return Pipeline(core: core, backend: backend, fans: fans, loops: loops, now: start)
    }

    private func profile(_ curve: FanCurve, ceiling: Double, fans: Int = 2)
        -> (curves: [Int: FanCurve], settings: ControlSettings) {
        (Dictionary(uniqueKeysWithValues: (0..<fans).map { ($0, curve) }),
         ControlSettings(ceilingPercent: ceiling, slewUpRPMPerSec: 5000, slewDownRPMPerSec: 5000))
    }

    // MARK: - Profiles reach the hardware

    /// The headline: each profile produces a materially different rpm at the
    /// hardware, not merely a different number in the model.
    func testEachProfileProducesADifferentRPMAtTheBackend() async throws {
        let readings = ["soc#0": 72.0]
        var results: [String: Double] = [:]

        for (name, curve, ceiling) in [("silent", FanCurve.silent, 60.0),
                                       ("balanced", .balanced, 95.0),
                                       ("performance", .performance, 95.0),
                                       ("maxCooling", .maxCooling, 100.0)] {
            var pipeline = try await makePipeline()
            let p = profile(curve, ceiling: ceiling)
            for _ in 0..<30 { _ = await pipeline.tick(profile: p, readings: readings) }
            let target = await pipeline.backend.target(of: 0)
            results[name] = try XCTUnwrap(target)
        }

        XCTAssertLessThan(results["silent"]!, results["balanced"]!)
        XCTAssertLessThan(results["balanced"]!, results["performance"]!)
        XCTAssertLessThanOrEqual(results["performance"]!, results["maxCooling"]!)
        XCTAssertGreaterThan(results["maxCooling"]! - results["silent"]!, 800,
                             "profiles should differ by more than a rounding error at the fan")
    }

    /// Switching profiles mid-run moves the hardware, and switching back moves
    /// it back. This is exactly what selecting a profile in the menu bar has to
    /// achieve, and exactly what it silently failed to do.
    func testSwitchingProfileMovesTheHardwareBothWays() async throws {
        var pipeline = try await makePipeline()
        let readings = ["soc#0": 75.0]
        let silent = profile(.silent, ceiling: 60)
        let maxCooling = profile(.maxCooling, ceiling: 100)

        for _ in 0..<30 { _ = await pipeline.tick(profile: silent, readings: readings) }
        let quietTarget = await pipeline.backend.target(of: 0)
        let quiet = try XCTUnwrap(quietTarget)

        for _ in 0..<30 { _ = await pipeline.tick(profile: maxCooling, readings: readings) }
        let loudTarget = await pipeline.backend.target(of: 0)
        let loud = try XCTUnwrap(loudTarget)

        for _ in 0..<30 { _ = await pipeline.tick(profile: silent, readings: readings) }
        let quietAgainTarget = await pipeline.backend.target(of: 0)
        let quietAgain = try XCTUnwrap(quietAgainTarget)

        XCTAssertGreaterThan(loud - quiet, 800, "switching to Max cooling did not reach the fan")
        XCTAssertEqual(quietAgain, quiet, accuracy: 1, "switching back did not reach the fan")
    }

    /// Per-fan sensor mapping, end to end: two fans, two mappings, one machine.
    func testTwoFansMappedToDifferentSensorsGetDifferentTargets() async throws {
        var pipeline = try await makePipeline()
        let curves: [Int: FanCurve] = [
            0: FanCurve(points: FanCurve.balanced.points, sensorIDs: ["soc#0"]),
            1: FanCurve(points: FanCurve.balanced.points, sensorIDs: ["ssd#0"]),
        ]
        let settings = ControlSettings(ceilingPercent: 100, slewUpRPMPerSec: 5000, slewDownRPMPerSec: 5000)
        // The SoC is hot and the SSD is cool; the floor follows the SoC.
        let readings = ["soc#0": 78.0, "ssd#0": 40.0]

        for _ in 0..<40 { _ = await pipeline.tick(profile: (curves, settings), readings: readings) }

        let hotTarget = await pipeline.backend.target(of: 0)
        let coolTarget = await pipeline.backend.target(of: 1)
        let hot = try XCTUnwrap(hotTarget)
        let cool = try XCTUnwrap(coolTarget)
        XCTAssertGreaterThan(hot, cool, "the SoC fan should be working harder than the SSD fan")

        // ...but the cool fan is still held at the machine-wide safety floor.
        let floorPercent = SafetyFloor().floorPercent(tempC: 78, pressure: .nominal)
        XCTAssertGreaterThanOrEqual(cool, pipeline.fans[1].rpm(forPercent: floorPercent) - 1,
                                    "the mapped-cool fan dropped below the machine's safety floor")
    }

    // MARK: - Failure paths reach the hardware too

    /// If the daemon's watchdog releases the fans, the next tick's writes must
    /// fail rather than silently succeed — that is what tells the app it is no
    /// longer in control.
    func testWritesFailAfterTheWatchdogReleases() async throws {
        var pipeline = try await makePipeline()
        let p = profile(.balanced, ceiling: 95)
        let readings = ["soc#0": 75.0]
        _ = await pipeline.tick(profile: p, readings: readings)

        // Stall the app: no heartbeat for longer than the watchdog timeout.
        pipeline.now.addTimeInterval(DaemonConstants.watchdogTimeout + 5)
        let action = await pipeline.core.watchdogTick(now: pipeline.now)
        guard case .released = action else { return XCTFail("expected a release, got \(action)") }

        let applied = await pipeline.tick(profile: p, readings: readings)
        XCTAssertTrue(applied.isEmpty, "the daemon accepted targets for fans it had released")
        for fan in pipeline.fans {
            let mode = await pipeline.backend.mode(of: fan.index)
            XCTAssertEqual(mode?.isUserControlled, false)
        }
    }

    /// Total sensor loss: the loop releases, and the daemon confirms the fans
    /// really did go back to macOS.
    func testTotalSensorLossEndsWithTheFansOnMacOSControl() async throws {
        var pipeline = try await makePipeline()
        let p = profile(.balanced, ceiling: 95)
        for _ in 0..<5 { _ = await pipeline.tick(profile: p, readings: ["soc#0": 70]) }

        for _ in 0..<20 { _ = await pipeline.tick(profile: p, readings: [:]) }

        for fan in pipeline.fans {
            let mode = await pipeline.backend.mode(of: fan.index)
            XCTAssertEqual(mode?.isUserControlled, false,
                           "fans were left under manual control with no sensor data")
        }
    }

    /// A long randomised run through the real chain, asserting the daemon's own
    /// envelope on every accepted write. The app is assumed hostile: the clamp
    /// is the last line, and it has to hold for every input the loop can emit.
    func testLongRandomisedRunNeverEscapesTheDaemonEnvelope() async throws {
        for seed in UInt64(1)...5 {
            var rng = SplitMix64(seed: seed)
            var pipeline = try await makePipeline()
            let trace = Trace.hostile(steps: 800, rng: &rng)
            let profiles = [profile(.silent, ceiling: 60), profile(.balanced, ceiling: 95),
                            profile(.performance, ceiling: 95), profile(.maxCooling, ceiling: 100)]

            for (i, sample) in trace.enumerated() {
                // Switch profile at random, the way a rule or the user would.
                let p = profiles[i % profiles.count]
                var readings: [String: Double] = [:]
                if let temp = sample.tempC { readings["soc#0"] = temp }

                let applied = await pipeline.tick(profile: p, readings: readings,
                                                  pressure: sample.pressure,
                                                  dt: max(0.1, sample.dt))
                for (fan, rpm) in applied {
                    let descriptor = pipeline.fans[fan]
                    XCTAssertTrue(rpm.isFinite, "seed \(seed) step \(i): non-finite rpm reached the fan")
                    XCTAssertGreaterThanOrEqual(rpm, 0)
                    XCTAssertLessThanOrEqual(rpm,
                                             descriptor.effectiveMax * DaemonConstants.overspeedAllowance + 0.001,
                                             "seed \(seed) step \(i): overspeed escaped the clamp")
                }
                // Re-arm if the watchdog dropped us, as the app now does.
                if i % 50 == 0 {
                    for fan in pipeline.fans {
                        _ = await pipeline.core.setManualMode(fan: fan.index, enabled: true, now: pipeline.now)
                    }
                }
            }

            let outcome = await pipeline.core.releaseAll()
            XCTAssertTrue(outcome.isComplete, "seed \(seed): could not return the fans to macOS")
        }
    }
}
