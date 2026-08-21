import XCTest
import FanKit
import DaemonProtocol
@testable import DaemonCore

/// Lifecycle gaps in the privileged half: the moments *around* steady-state
/// control, where the daemon's bookkeeping and the hardware's actual state can
/// come apart.
///
/// Everything in `DaemonCoreTests` covers a daemon that is already running with
/// a client already talking to it. These cover arming, handing back, and coming
/// up after a crash — and in each of those the failure mode is the same and the
/// worst one this system has: a fan pinned under manual control that nothing is
/// tracking, therefore nothing will ever release.
final class DaemonLifecycleGapTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCore(fanCount: Int = 2) async -> (DaemonCore, SimulatedFanBackend) {
        var config = SimulatedFanBackend.Config()
        config.fanCount = fanCount
        let backend = SimulatedFanBackend(config: config)
        let core = DaemonCore(backend: backend)
        _ = await core.start(now: t0)
        return (core, backend)
    }

    private func faults(_ mutate: (inout SimulatedFanBackend.Faults) -> Void) -> SimulatedFanBackend.Faults {
        var f = SimulatedFanBackend.Faults()
        mutate(&f)
        return f
    }

    // MARK: - Handing a single fan back

    /// The mirror of `testFailedManualModeIsNotRecordedAsManual`, and the case
    /// that was missing. "Never record manual control we did not obtain" is right
    /// for arming and exactly backwards for releasing: if the write to `.auto`
    /// fails, the fan is *still under manual control*, and forgetting it is how a
    /// spinning fan becomes nobody's responsibility.
    func testAFanWeFailedToHandBackIsStillRecordedAsManual() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await backend.setFaults(faults { $0.rejectModeWrites = true })

        let result = await core.setManualMode(fan: 0, enabled: false, now: t0)
        XCTAssertTrue(result.isFailure, "the hardware rejected the write")

        let manual = await core.manualFanIndices()
        XCTAssertEqual(manual, [0],
                       "a fan we could not hand back is still ours to release")
    }

    /// The consequence, which is the part that actually matters: having forgotten
    /// the fan, the watchdog has nothing to act on and the fan stays pinned
    /// forever. This is the test that fails loudest against the old bookkeeping.
    func testTheWatchdogStillReleasesAFanWhoseHandbackFailed() async {
        let (core, backend) = await makeCore(fanCount: 1)
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 80, at: t0)

        await backend.setFaults(faults { $0.rejectModeWrites = true })
        _ = await core.setManualMode(fan: 0, enabled: false, now: t0)
        await backend.setFaults(SimulatedFanBackend.Faults())   // hardware recovers

        let action = await core.watchdogTick(now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout + 1))
        guard case .released = action else {
            return XCTFail("the watchdog forgot about a fan that is still spinning under manual control: \(action)")
        }
        let mode = await backend.mode(of: 0)
        XCTAssertEqual(mode?.isUserControlled, false)
    }

    // MARK: - Arming

    /// Arming and the first heartbeat cannot be simultaneous: the app arms every
    /// fan, then starts its 1 Hz loop, so the first heartbeat is up to a second
    /// later. The daemon's watchdog runs at 1 Hz too — so it would see manual
    /// fans and no heartbeat at all, conclude the client was dead, and release
    /// the fans out from under a client that had just finished arming them.
    func testWatchdogDoesNotTripBetweenArmingAndTheFirstHeartbeat() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)

        for offset in stride(from: 0.5, through: DaemonConstants.watchdogTimeout, by: 0.5) {
            let action = await core.watchdogTick(now: t0.addingTimeInterval(offset))
            XCTAssertEqual(action, .idle,
                           "released at +\(offset)s — a client that just armed had no chance to beat")
        }
    }

    /// The grace period is bounded, not open-ended. A client that arms and then
    /// never says another word must still lose the fans.
    func testArmingGraceExpiresIfTheClientNeverBeats() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)

        let action = await core.watchdogTick(now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout + 1))
        guard case .released = action else {
            return XCTFail("a client that armed and vanished kept the fans: \(action)")
        }
        let mode = await backend.mode(of: 0)
        XCTAssertEqual(mode?.isUserControlled, false)
    }

    /// `releaseAll` reads the mode back because on M3/M4 a mode write can be
    /// accepted and then overridden by `thermalmonitord`. That is the same
    /// hardware and the same key on the way *in*, so arming needs the same
    /// readback — otherwise the daemon records manual control it never obtained
    /// and every subsequent target is written into the void while the app is told
    /// it is in control.
    func testManualModeThatIsAcceptedButDoesNotTakeIsReportedAsFailure() async {
        let (core, backend) = await makeCore()
        await backend.setFaults(faults { $0.modeWritesSilentlyIgnored = true })

        let result = await core.setManualMode(fan: 0, enabled: true, now: t0)
        XCTAssertTrue(result.isFailure,
                      "a mode write that reports success and leaves the fan on system control is not success")

        let manual = await core.manualFanIndices()
        XCTAssertTrue(manual.isEmpty)

        let target = await core.setTarget(fan: 0, rpm: 3000, now: t0)
        XCTAssertEqual(target, .failure(.notUnderManualControl(0)),
                       "targets must not be written to a fan macOS is still driving")
    }

    /// Hardware that cannot report its mode at all must not be treated as
    /// hardware that reported the wrong mode. `releaseAll` already draws this
    /// distinction (`unverified` is not `failed`); arming has to draw it the same
    /// way or the app becomes unusable on any machine without mode readback.
    func testManualModeIsAcceptedWhenTheModeCannotBeReadBack() async {
        let (core, backend) = await makeCore()
        await backend.setFaults(faults { $0.readsFail = true })

        let result = await core.setManualMode(fan: 0, enabled: true, now: t0)
        XCTAssertTrue(result.isSuccess,
                      "an unreadable mode is unknown, not proof the write failed")
        let manual = await core.manualFanIndices()
        XCTAssertEqual(manual, [0])
    }

    // MARK: - When the hardware cannot be checked at all

    /// The combination the randomised soak found, which neither fault produces
    /// alone: a mode write that silently does nothing, on hardware whose mode
    /// cannot be read back. The daemon has no way to know the arm failed, so it
    /// believes the write — that is the best available evidence — but it must
    /// *record that it is guessing*, because the consequence of guessing wrong
    /// is every subsequent target written into the void and reported as success.
    func testAnUncheckableArmIsBelievedButFlaggedAsUnverified() async {
        let (core, backend) = await makeCore(fanCount: 1)
        await backend.setFaults(faults {
            $0.modeWritesSilentlyIgnored = true
            $0.readsFail = true
        })

        let armed = await core.setManualMode(fan: 0, enabled: true, now: t0)
        XCTAssertTrue(armed.isSuccess, "with no way to check, the write is the best evidence there is")
        let unconfirmed = await core.unconfirmedFanIndices()
        XCTAssertEqual(unconfirmed, [0], "believing a write is not the same as having checked it")
    }

    /// …and the guess must not outlive the fault. Once the hardware can answer,
    /// the very next watchdog tick has to correct the record — otherwise a brief
    /// unreadable window leaves the daemon permanently wrong about which fans it
    /// owns, and nothing in the system would ever notice.
    func testAWrongGuessIsCorrectedAsSoonAsTheHardwareCanAnswer() async {
        let (core, backend) = await makeCore(fanCount: 1)
        await backend.setFaults(faults {
            $0.modeWritesSilentlyIgnored = true
            $0.readsFail = true
        })
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        let believed = await core.manualFanIndices()
        XCTAssertEqual(believed, [0])

        // The fan was never actually taken; macOS is still driving it.
        await backend.setFaults(SimulatedFanBackend.Faults())
        _ = await core.watchdogTick(now: t0.addingTimeInterval(1))

        let corrected = await core.manualFanIndices()
        let stillUnconfirmed = await core.unconfirmedFanIndices()
        XCTAssertTrue(corrected.isEmpty, "the daemon kept claiming a fan macOS is driving")
        XCTAssertTrue(stillUnconfirmed.isEmpty)

        let target = await core.setTarget(fan: 0, rpm: 3000, now: t0.addingTimeInterval(2))
        XCTAssertEqual(target, .failure(.notUnderManualControl(0)),
                       "targets must stop being accepted once the claim is known to be false")
    }

    /// The mirror image: an uncheckable *release* that did not take. The fan is
    /// still spinning, and the daemon has to reclaim it rather than forget it.
    func testAnUncheckableReleaseThatDidNotTakeIsReclaimed() async {
        let (core, backend) = await makeCore(fanCount: 1)
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 80, at: t0)

        await backend.setFaults(faults {
            $0.modeWritesSilentlyIgnored = true
            $0.readsFail = true
        })
        _ = await core.releaseAll()
        let afterRelease = await core.manualFanIndices()
        let unconfirmed = await core.unconfirmedFanIndices()
        XCTAssertTrue(afterRelease.isEmpty)
        XCTAssertEqual(unconfirmed, [0], "we wrote auto and could not look")

        // The hardware recovers and reveals the fan is still under manual control.
        await backend.setFaults(SimulatedFanBackend.Faults())
        let action = await core.watchdogTick(
            now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout + 1))
        guard case .released = action else {
            return XCTFail("a fan left spinning by an unverifiable release was never reclaimed: \(action)")
        }
        let mode = await backend.mode(of: 0)
        XCTAssertEqual(mode?.isUserControlled, false)
    }

    // MARK: - Coming up after a crash

    /// launchd's `KeepAlive` restarts the helper after a crash. The replacement
    /// starts with an empty `manualFans`, so every fan the dead instance had
    /// pinned is invisible to it: `watchdogTick` sees nothing under manual
    /// control and reports `.idle` forever, while the hardware sits at whatever
    /// rpm it was last given. Nothing else in the system can recover from this —
    /// the app's own release path goes through this same daemon.
    func testFansLeftManualByACrashedInstanceAreAdoptedAndReleased() async {
        var config = SimulatedFanBackend.Config()
        config.fanCount = 2
        let backend = SimulatedFanBackend(config: config)

        // A previous instance armed both fans and died without releasing them.
        try? await backend.setMode(.manual, fan: 0)
        try? await backend.setMode(.manual, fan: 1)
        try? await backend.setTarget(rpm: 4200, fan: 0)

        let core = DaemonCore(backend: backend)
        _ = await core.start(now: t0)

        let adopted = await core.manualFanIndices()
        XCTAssertEqual(adopted, [0, 1],
                       "a fresh daemon must notice fans the hardware says are still under manual control")

        // No client ever connects, so the watchdog is what cleans up.
        let action = await core.watchdogTick(now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout + 1))
        guard case .released = action else {
            return XCTFail("orphaned fans were never returned to macOS: \(action)")
        }
        for fan in 0..<2 {
            let mode = await backend.mode(of: fan)
            XCTAssertEqual(mode?.isUserControlled, false)
        }
    }

    /// Adoption gives the same grace as arming, so a helper restarted *while the
    /// app is running* does not yank the fans away before the app's next tick.
    func testAdoptedFansGetTheSameGraceAsFreshlyArmedOnes() async {
        var config = SimulatedFanBackend.Config()
        config.fanCount = 1
        let backend = SimulatedFanBackend(config: config)
        try? await backend.setMode(.manual, fan: 0)

        let core = DaemonCore(backend: backend)
        _ = await core.start(now: t0)

        let early = await core.watchdogTick(now: t0.addingTimeInterval(1))
        XCTAssertEqual(early, .idle)

        // The app notices its writes failing and re-arms; that is a heartbeat.
        await core.heartbeat(maxTempC: 75, at: t0.addingTimeInterval(2))
        let held = await core.watchdogTick(now: t0.addingTimeInterval(3))
        XCTAssertEqual(held, .idle, "a live client lost its fans to a helper restart")
    }

    /// A daemon whose SMC probe failed must not silently claim there is nothing
    /// to release. `start` reports the failure and `releaseAll` re-probes.
    func testStartWithNoDiscoverableFansAdoptsNothing() async {
        let (core, _) = await makeCore(fanCount: 0)
        let adopted = await core.manualFanIndices()
        XCTAssertTrue(adopted.isEmpty)
        let action = await core.watchdogTick(now: t0.addingTimeInterval(10_000))
        XCTAssertEqual(action, .idle)
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
