import XCTest
import FanKit
import DaemonProtocol
import SimSupport
@testable import DaemonCore

/// Long randomised soaks over the daemon's whole lifecycle, with hardware faults
/// appearing and clearing underneath it.
///
/// The other daemon suites each exercise one transition from a known state.
/// These exist for the failure this system actually has to prevent, which is not
/// any single transition going wrong: it is the daemon's bookkeeping and the
/// hardware drifting apart over a long sequence of ordinary events, until a fan
/// is spinning under manual control that nothing is tracking and therefore
/// nothing will ever release.
///
/// So the assertions are *relational* — daemon state versus backend state — and
/// they are checked after every single operation rather than at the end.
final class DaemonSoakTests: XCTestCase {

    // MARK: - Harness

    /// The consistency contract between the daemon's records and the hardware.
    private struct Consistency {
        /// Fans the hardware says are under user control.
        let backendManual: Set<Int>
        /// Fans the daemon believes it is driving.
        let recordedManual: Set<Int>
        /// Fans the daemon admits it cannot currently check.
        let unconfirmed: Set<Int>
        let knownFans: Int

        /// A fan under manual control that the daemon does not know about. This
        /// is the one that matters: nothing else in the system will release it.
        var orphans: Set<Int> { backendManual.subtracting(recordedManual) }
        /// A fan the daemon thinks it is driving that macOS is actually driving.
        /// Every target written to it is a write into the void, reported as
        /// success.
        var phantoms: Set<Int> { recordedManual.subtracting(backendManual) }
    }

    private func consistency(_ core: DaemonCore,
                             _ backend: SimulatedFanBackend,
                             fanCount: Int) async -> Consistency {
        var manual = Set<Int>()
        for index in 0..<fanCount where await backend.mode(of: index)?.isUserControlled == true {
            manual.insert(index)
        }
        return Consistency(backendManual: manual,
                           recordedManual: await core.manualFanIndices(),
                           unconfirmed: await core.unconfirmedFanIndices(),
                           knownFans: await core.knownFanCount())
    }

    private func randomFaults(_ rng: inout SplitMix64) -> SimulatedFanBackend.Faults {
        var f = SimulatedFanBackend.Faults()
        // Weighted so that healthy hardware is the common case and the exotic
        // combinations still show up often enough to matter.
        f.rejectTargetWrites = Int.random(in: 0..<100, using: &rng) < 12
        f.rejectModeWrites = Int.random(in: 0..<100, using: &rng) < 12
        f.modeWritesSilentlyIgnored = Int.random(in: 0..<100, using: &rng) < 10
        f.readsFail = Int.random(in: 0..<100, using: &rng) < 10
        return f
    }

    private func makeBackend(fanCount: Int) -> SimulatedFanBackend {
        var config = SimulatedFanBackend.Config()
        config.fanCount = fanCount
        config.minRPM = 1350
        config.maxRPM = 5349
        return SimulatedFanBackend(config: config)
    }

    /// Clears every fault and drives the daemon until it is quiescent, then
    /// asserts the hardware really is back on macOS control with nothing left
    /// recorded. This is the property the whole system exists to guarantee, and
    /// it must hold no matter what happened beforehand.
    private func assertRecoversToMacOSControl(_ core: DaemonCore,
                                              _ backend: SimulatedFanBackend,
                                              fanCount: Int,
                                              now: Date,
                                              context: String,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) async {
        await backend.setFaults(SimulatedFanBackend.Faults())

        // The watchdog is the mechanism of last resort, so recovery is asserted
        // through it rather than by calling releaseAll directly.
        var clock = now
        for _ in 0..<(DaemonConstants.maxReleaseRetries + 4) {
            clock = clock.addingTimeInterval(DaemonConstants.watchdogTimeout + 1)
            _ = await core.watchdogTick(now: clock)
        }

        let end = await consistency(core, backend, fanCount: fanCount)
        XCTAssertTrue(end.backendManual.isEmpty,
                      "\(context): fans \(end.backendManual.sorted()) left under manual control after recovery",
                      file: file, line: line)
        XCTAssertTrue(end.recordedManual.isEmpty,
                      "\(context): daemon still claims \(end.recordedManual.sorted()) after recovery",
                      file: file, line: line)
    }

    // MARK: - The soak

    /// How many seeds the lifecycle soak runs. Ten keeps the default suite fast
    /// enough to run on every change; the environment override exists so a
    /// deliberate deep run can be thousands without editing the test — and so
    /// that a failure found at seed 3,412 is reproducible by name.
    ///
    ///     FANCONTROL_SOAK_SEEDS=2000 swift test --filter DaemonSoakTests
    private var soakSeeds: UInt64 {
        guard let raw = ProcessInfo.processInfo.environment["FANCONTROL_SOAK_SEEDS"],
              let value = UInt64(raw), value > 0 else { return 10 }
        return value
    }

    /// Seeded runs of 600 randomised operations each, with faults appearing and
    /// clearing throughout, asserting the relational invariants after every
    /// operation and full recovery at the end of every run.
    func testLifecycleSoakNeverStrandsAFanUnderManualControl() async {
        let fanCount = 3

        for seed in UInt64(1)...soakSeeds {
            var rng = SplitMix64(seed: seed)
            let backend = makeBackend(fanCount: fanCount)
            let core = DaemonCore(backend: backend)
            var clock = Date(timeIntervalSince1970: 1_700_000_000)
            _ = await core.start(now: clock)

            var faults = SimulatedFanBackend.Faults()

            for step in 0..<600 {
                clock = clock.addingTimeInterval(Double.random(in: 0.2...3, using: &rng))
                let fan = Int.random(in: 0..<fanCount, using: &rng)

                switch Int.random(in: 0..<100, using: &rng) {
                case 0..<8:
                    faults = randomFaults(&rng)
                    await backend.setFaults(faults)
                case 8..<28:
                    _ = await core.setManualMode(fan: fan, enabled: true, now: clock)
                case 28..<36:
                    _ = await core.setManualMode(fan: fan, enabled: false, now: clock)
                case 36..<60:
                    _ = await core.setTarget(fan: fan,
                                             rpm: Double.random(in: -500...9000, using: &rng),
                                             now: clock)
                case 60..<75:
                    await core.heartbeat(maxTempC: Double.random(in: 20...105, using: &rng), at: clock)
                case 75..<90:
                    _ = await core.watchdogTick(now: clock)
                case 90..<96:
                    _ = await core.readFans()
                default:
                    _ = await core.releaseAll()
                }

                let state = await consistency(core, backend, fanCount: fanCount)
                let where_ = "seed \(seed) step \(step) faults \(faults)"

                XCTAssertTrue(state.recordedManual.allSatisfy { $0 >= 0 && $0 < state.knownFans },
                              "\(where_): recorded a fan index that does not exist")

                // The contract, stated exactly: the daemon's records may differ
                // from the hardware *only* for fans it has already admitted it
                // cannot currently check. A silent disagreement — one the daemon
                // believes is settled — is the bug, in either direction.
                XCTAssertTrue(state.orphans.isSubset(of: state.unconfirmed),
                              "\(where_): fan(s) \(state.orphans.subtracting(state.unconfirmed).sorted()) "
                              + "are under manual control, untracked, and not flagged as unverifiable")
                XCTAssertTrue(state.phantoms.isSubset(of: state.unconfirmed),
                              "\(where_): daemon silently claims fan(s) "
                              + "\(state.phantoms.subtracting(state.unconfirmed).sorted()) that macOS is driving")

                // Whatever the daemon accepted, the hardware must never be
                // holding a target outside its envelope.
                for index in 0..<fanCount {
                    guard let target = await backend.target(of: index) else { continue }
                    XCTAssertTrue(target.isFinite, "\(where_): fan \(index) holds \(target)")
                    XCTAssertGreaterThanOrEqual(target, 0, "\(where_): fan \(index)")
                    XCTAssertLessThanOrEqual(target, 5349 * DaemonConstants.overspeedAllowance + 0.001,
                                             "\(where_): fan \(index) overspeed escaped the clamp")
                }
            }

            await assertRecoversToMacOSControl(core, backend, fanCount: fanCount,
                                               now: clock, context: "seed \(seed)")
        }
    }

    /// Every fault combination, exhaustively: whatever state it leaves the
    /// hardware in, clearing the fault and letting the watchdog run must return
    /// every fan to macOS. Sixteen combinations, each armed, driven, and then
    /// abandoned by its client.
    func testEveryFaultCombinationRecoversOnceTheHardwareWorksAgain() async {
        let fanCount = 2
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        for mask in 0..<16 {
            var faults = SimulatedFanBackend.Faults()
            faults.rejectTargetWrites = mask & 1 != 0
            faults.rejectModeWrites = mask & 2 != 0
            faults.modeWritesSilentlyIgnored = mask & 4 != 0
            faults.readsFail = mask & 8 != 0

            let backend = makeBackend(fanCount: fanCount)
            let core = DaemonCore(backend: backend)
            _ = await core.start(now: t0)

            // Arm on healthy hardware so there is genuinely something to lose,
            // then break it underneath the running client.
            for fan in 0..<fanCount { _ = await core.setManualMode(fan: fan, enabled: true, now: t0) }
            await core.heartbeat(maxTempC: 85, at: t0)
            await backend.setFaults(faults)

            for i in 1...5 {
                let now = t0.addingTimeInterval(Double(i))
                _ = await core.setTarget(fan: i % fanCount, rpm: 4000, now: now)
                _ = await core.watchdogTick(now: now)
            }
            // The client vanishes.
            _ = await core.watchdogTick(now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout + 5))

            await assertRecoversToMacOSControl(core, backend, fanCount: fanCount,
                                               now: t0.addingTimeInterval(100),
                                               context: "faults mask \(mask) \(faults)")
        }
    }

    /// Repeated helper restarts over a machine whose fans are already spinning.
    ///
    /// `KeepAlive` restarts the helper after every crash, so this is a loop in
    /// production, not a one-off. Each replacement has to inherit the previous
    /// one's fans — if any generation fails to adopt them, the fans are stranded
    /// and every later generation inherits nothing.
    func testRepeatedHelperRestartsNeverLoseTrackOfSpinningFans() async {
        let fanCount = 2
        let backend = makeBackend(fanCount: fanCount)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)

        // Generation zero arms the fans and dies without releasing them.
        let first = DaemonCore(backend: backend)
        _ = await first.start(now: clock)
        for fan in 0..<fanCount { _ = await first.setManualMode(fan: fan, enabled: true, now: clock) }
        _ = await first.setTarget(fan: 0, rpm: 4800, now: clock)

        for generation in 1...6 {
            clock = clock.addingTimeInterval(30)
            let core = DaemonCore(backend: backend)
            _ = await core.start(now: clock)

            let state = await consistency(core, backend, fanCount: fanCount)
            XCTAssertTrue(state.orphans.isEmpty,
                          "generation \(generation) did not adopt fan(s) \(state.orphans.sorted())")

            if generation % 2 == 0 {
                // A client shows up and keeps the fans; the watchdog must leave
                // them alone.
                await core.heartbeat(maxTempC: 80, at: clock)
                let action = await core.watchdogTick(now: clock.addingTimeInterval(1))
                XCTAssertEqual(action, .idle, "generation \(generation) took the fans off a live client")
                let still = await consistency(core, backend, fanCount: fanCount)
                XCTAssertEqual(still.backendManual.count, fanCount)
            } else {
                // Nobody claims them within the grace window, so this generation
                // releases them — and then re-arms, so the next generation has
                // something to inherit.
                let action = await core.watchdogTick(
                    now: clock.addingTimeInterval(DaemonConstants.watchdogTimeout + 1))
                guard case .released = action else {
                    return XCTFail("generation \(generation) never released orphaned fans: \(action)")
                }
                clock = clock.addingTimeInterval(DaemonConstants.watchdogTimeout + 2)
                for fan in 0..<fanCount {
                    _ = await core.setManualMode(fan: fan, enabled: true, now: clock)
                }
            }
        }

        let final = DaemonCore(backend: backend)
        _ = await final.start(now: clock.addingTimeInterval(10))
        await assertRecoversToMacOSControl(final, backend, fanCount: fanCount,
                                           now: clock.addingTimeInterval(20),
                                           context: "after six restarts")
    }

    /// Concurrency, with faults. `DaemonCoreTests` covers concurrent requests on
    /// healthy hardware; this adds a fault stream, because the recovery paths
    /// mutate the same state the request paths do and they now do more of it.
    func testConcurrentRequestsUnderAFaultStreamStayConsistent() async {
        let fanCount = 4
        let backend = makeBackend(fanCount: fanCount)
        let core = DaemonCore(backend: backend)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await core.start(now: t0)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<600 {
                let fan = i % fanCount
                let now = t0.addingTimeInterval(Double(i) * 0.01)
                group.addTask {
                    switch i % 7 {
                    case 0: _ = await core.setManualMode(fan: fan, enabled: true, now: now)
                    case 1: _ = await core.setTarget(fan: fan, rpm: Double(2000 + i), now: now)
                    case 2: await core.heartbeat(maxTempC: Double(60 + i % 40), at: now)
                    case 3: _ = await core.readFans()
                    case 4: _ = await core.watchdogTick(now: now)
                    case 5: _ = await core.setManualMode(fan: fan, enabled: false, now: now)
                    default:
                        var f = SimulatedFanBackend.Faults()
                        f.rejectModeWrites = i % 3 == 0
                        f.readsFail = i % 5 == 0
                        await backend.setFaults(f)
                    }
                }
            }
        }

        let state = await consistency(core, backend, fanCount: fanCount)
        XCTAssertTrue(state.recordedManual.allSatisfy { $0 >= 0 && $0 < fanCount },
                      "concurrent access corrupted the manual set: \(state.recordedManual)")

        await assertRecoversToMacOSControl(core, backend, fanCount: fanCount,
                                           now: t0.addingTimeInterval(1_000),
                                           context: "after concurrent fault stream")
    }

    /// The daemon's envelope holds for every request the app could ever send,
    /// including ones no correct app would: negative, non-finite, and absurd
    /// targets, at every temperature evidence the heartbeat can produce.
    func testNoRequestSequenceCanPushTheHardwareOutsideItsEnvelope() async {
        let backend = makeBackend(fanCount: 1)
        let core = DaemonCore(backend: backend)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await core.start(now: clock)
        _ = await core.setManualMode(fan: 0, enabled: true, now: clock)

        var rng = SplitMix64(seed: 0x50AC_0001)
        let nasty: [Double] = [.nan, .infinity, -.infinity, -1e9, -1, 0, 1e9]

        for step in 0..<4_000 {
            clock = clock.addingTimeInterval(Double.random(in: 0...2, using: &rng))

            if Int.random(in: 0..<4, using: &rng) == 0 {
                let temp = Bool.random(using: &rng)
                    ? nasty.randomElement(using: &rng)!
                    : Double.random(in: -50...200, using: &rng)
                await core.heartbeat(maxTempC: temp, at: clock)
            }
            // Re-arm periodically: the watchdog is entitled to take the fans.
            if step % 100 == 0 {
                _ = await core.setManualMode(fan: 0, enabled: true, now: clock)
            }

            let request = Bool.random(using: &rng)
                ? nasty.randomElement(using: &rng)!
                : Double.random(in: -10_000...100_000, using: &rng)
            let result = await core.setTarget(fan: 0, rpm: request, now: clock)

            if case .success(let clamped) = result {
                XCTAssertTrue(clamped.isFinite, "step \(step): accepted \(request) -> \(clamped)")
                XCTAssertGreaterThanOrEqual(clamped, 0)
                XCTAssertLessThanOrEqual(clamped, 5349 * DaemonConstants.overspeedAllowance + 0.001)
            }
            if let held = await backend.target(of: 0) {
                XCTAssertTrue(held.isFinite, "step \(step): hardware holds \(held)")
                XCTAssertGreaterThanOrEqual(held, 0)
            }
        }
    }
}
