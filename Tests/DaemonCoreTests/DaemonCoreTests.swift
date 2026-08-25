import XCTest
import FanKit
import DaemonProtocol
@testable import DaemonCore

/// The privileged half's policy, exercised against `SimulatedFanBackend` with
/// injected hardware faults. None of this needs root or a real SMC — which is
/// the point of splitting `DaemonCore` out of the executable.
final class DaemonCoreTests: XCTestCase {

    private func makeCore(fanCount: Int = 2) async -> (DaemonCore, SimulatedFanBackend) {
        var config = SimulatedFanBackend.Config()
        config.fanCount = fanCount
        let backend = SimulatedFanBackend(config: config)
        let core = DaemonCore(backend: backend)
        _ = await core.start(now: t0)
        return (core, backend)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Request validation

    func testUnknownFanIsRefusedRatherThanClamped() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        let result = await core.setTarget(fan: 9, rpm: 3000, now: t0)
        XCTAssertEqual(result, .failure(.unknownFan(9)))
    }

    func testNonFiniteTargetIsRefused() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        // NaN != NaN, so match the case rather than comparing payloads.
        for bad in [Double.nan, .infinity, -.infinity] {
            let result = await core.setTarget(fan: 0, rpm: bad, now: t0)
            guard case .failure(.invalidRPM) = result else {
                return XCTFail("expected invalidRPM for \(bad), got \(result)")
            }
        }
    }

    func testTargetIsRefusedForAFanNotUnderManualControl() async {
        let (core, backend) = await makeCore()
        let result = await core.setTarget(fan: 0, rpm: 3000, now: t0)
        XCTAssertEqual(result, .failure(.notUnderManualControl(0)))
        let target = await backend.target(of: 0)
        XCTAssertEqual(target, 0, "a refused request must not reach the hardware")
    }

    func testFailedManualModeIsNotRecordedAsManual() async {
        let (core, backend) = await makeCore()
        await backend.setFaults({ var f = SimulatedFanBackend.Faults(); f.rejectModeWrites = true; return f }())

        let armed = await core.setManualMode(fan: 0, enabled: true, now: t0)
        XCTAssertTrue(armed.isFailure)
        let manual = await core.manualFanIndices()
        XCTAssertTrue(manual.isEmpty, "manual control we did not obtain must not be recorded")

        // And the follow-up target is refused rather than written into the void.
        let result = await core.setTarget(fan: 0, rpm: 3000, now: t0)
        XCTAssertEqual(result, .failure(.notUnderManualControl(0)))
    }

    // MARK: - The floor fails closed

    func testHardFloorAppliesWhenNoHeartbeatHasEverArrived() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)

        // 1200..8400 -> 25% floor is 1200 + 0.25 * 7200 = 3000
        let result = await core.setTarget(fan: 0, rpm: 0, now: t0)
        XCTAssertEqual(try result.get(), 3000, accuracy: 0.001,
                       "no heartbeat means unknown temperature, not a cold machine")
    }

    func testHardFloorAppliesOnceTheHeartbeatGoesStale() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 30, at: t0)

        let fresh = await core.setTarget(fan: 0, rpm: 1500, now: t0.addingTimeInterval(1))
        XCTAssertEqual(try fresh.get(), 1500, accuracy: 0.001, "a cool machine keeps a low target")

        let stale = await core.setTarget(
            fan: 0, rpm: 1500,
            now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout + 1))
        XCTAssertEqual(try stale.get(), 3000, accuracy: 0.001,
                       "a stale heartbeat must not keep asserting the last temperature")
    }

    func testNonFiniteHeartbeatCountsAsUnknown() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: .nan, at: t0)
        let result = await core.setTarget(fan: 0, rpm: 0, now: t0)
        XCTAssertEqual(try result.get(), 3000, accuracy: 0.001)
    }

    func testHeartbeatFromTheFutureCountsAsUnknown() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 20, at: t0.addingTimeInterval(600))
        let result = await core.setTarget(fan: 0, rpm: 0, now: t0)
        XCTAssertEqual(try result.get(), 3000, accuracy: 0.001,
                       "a clock jump must not disable the floor")
    }

    func testTargetIsClampedToTheOverspeedAllowance() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 90, at: t0)
        let result = await core.setTarget(fan: 0, rpm: 1_000_000, now: t0)
        XCTAssertEqual(try result.get(), 8400 * DaemonConstants.overspeedAllowance, accuracy: 0.001)
    }

    // MARK: - Release reports what it achieved

    func testReleaseReportsFailureWhenTheHardwareRejectsTheWrite() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        _ = await core.setManualMode(fan: 1, enabled: true, now: t0)
        await backend.setFaults({ var f = SimulatedFanBackend.Faults(); f.rejectModeWrites = true; return f }())

        let outcome = await core.releaseAll()
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(outcome.failed.count, 2)
        let manual = await core.manualFanIndices()
        XCTAssertEqual(manual, [0, 1], "fans we failed to release are still manual")
    }

    func testReleaseReportsFailureWhenTheWriteIsAcceptedButDoesNotTake() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await backend.setFaults({
            var f = SimulatedFanBackend.Faults(); f.modeWritesSilentlyIgnored = true; return f
        }())

        let outcome = await core.releaseAll()
        XCTAssertFalse(outcome.isComplete, "a write that reports success but leaves the fan in manual is a failure")
        XCTAssertNotNil(outcome.failed[0])
    }

    func testReleaseWithNoFansIsNotSuccess() async {
        let (core, _) = await makeCore(fanCount: 0)
        let outcome = await core.releaseAll()
        XCTAssertTrue(outcome.hadNoFans)
        XCTAssertFalse(outcome.isComplete,
                       "'nothing to release' must not be reported the same as 'released everything'")
    }

    func testUnverifiedReleaseIsNotCountedAsFailure() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        _ = await core.setManualMode(fan: 1, enabled: true, now: t0)
        await backend.setFaults({ var f = SimulatedFanBackend.Faults(); f.readsFail = true; return f }())

        let outcome = await core.releaseAll()
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(outcome.unverified.sorted(), [0, 1])
    }

    // MARK: - Watchdog

    func testWatchdogIsIdleWhileHeartbeatsArrive() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        for i in 0..<100 {
            let now = t0.addingTimeInterval(Double(i))
            await core.heartbeat(maxTempC: 70, at: now)
            let action = await core.watchdogTick(now: now)
            XCTAssertEqual(action, .idle)
        }
    }

    func testWatchdogReleasesAfterTheTimeout() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 70, at: t0)

        let before = await core.watchdogTick(now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout - 0.1))
        XCTAssertEqual(before, .idle)

        let after = await core.watchdogTick(now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout + 0.1))
        guard case .released = after else { return XCTFail("expected a release, got \(after)") }
        let mode = await backend.mode(of: 0)
        XCTAssertEqual(mode?.isUserControlled, false)
    }

    func testWatchdogDoesNotFireWhenNothingIsUnderManualControl() async {
        let (core, _) = await makeCore()
        let action = await core.watchdogTick(now: t0.addingTimeInterval(10_000))
        XCTAssertEqual(action, .idle, "there is nothing to release, so there is nothing to panic about")
    }

    /// A clock stepped backwards past the last proof of life used to read as
    /// "no time has passed": the age went negative, the old signed comparison
    /// failed open, and fans pinned under a dead client stayed pinned until
    /// wall time crawled forward past the stamp — hours for a large NTP
    /// correction. Staleness must be judged by magnitude.
    func testWatchdogTripsWhenTheClockStepsBackPastTheLastHeartbeat() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 70, at: t0)

        let action = await core.watchdogTick(now: t0.addingTimeInterval(-3_600))
        guard case .released = action else {
            return XCTFail("a clock stepped far backwards must not pin a dead client's fans, got \(action)")
        }
        let mode = await backend.mode(of: 0)
        XCTAssertEqual(mode?.isUserControlled, false)
    }

    /// A correction smaller than the grace window is not evidence of death:
    /// the negative age stays inside the timeout, the fan keeps its grace, and
    /// the normal aging path takes over once wall time passes the stamp — so
    /// worst case is one extra period, not forever.
    func testASmallClockStepBackKeepsTheGraceWindow() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 70, at: t0)

        // Wall falls 5 s behind the last beat, then resumes forward from there.
        let steppedBack = await core.watchdogTick(now: t0.addingTimeInterval(-5))
        XCTAssertEqual(steppedBack, .idle)
        let resumed = await core.watchdogTick(now: t0.addingTimeInterval(2))
        XCTAssertEqual(resumed, .idle)
        let agedOut = await core.watchdogTick(now: t0.addingTimeInterval(15))
        guard case .released = agedOut else {
            return XCTFail("grace must still expire once wall time passes the stamp, got \(agedOut)")
        }
    }

    /// A live client beating about once a second across a modest backwards
    /// correction must never lose its fans: each fresh stamp re-anchors the
    /// clock the timeout runs against.
    func testALiveClientSurvivesAClockStepBack() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        var now = t0
        for i in 0..<60 {
            now = t0.addingTimeInterval(Double(i))
            if i == 30 { now = now.addingTimeInterval(-20) } // one-off NTP correction
            await core.heartbeat(maxTempC: 70, at: now)
            let action = await core.watchdogTick(now: now)
            XCTAssertEqual(action, .idle, "beat \(i): a live client must not be tripped by a clock step")
        }
    }

    func testTrippedWatchdogRefusesFurtherTargetsUntilManualModeIsRetaken() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 70, at: t0)
        _ = await core.watchdogTick(now: t0.addingTimeInterval(100))

        let refused = await core.setTarget(fan: 0, rpm: 4000, now: t0.addingTimeInterval(101))
        XCTAssertEqual(refused, .failure(.notUnderManualControl(0)))

        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        let allowed = await core.setTarget(fan: 0, rpm: 4000, now: t0.addingTimeInterval(102))
        XCTAssertTrue(allowed.isSuccess, "re-arming manual control is the documented way back")
    }

    /// The release contract in three phases: a bounded fast retry budget, then
    /// silence against hardware that is refusing, then one attempt per slow
    /// interval — because giving up used to mean *forever*, and hardware that
    /// stops refusing minutes later never saw another attempt.
    func testWatchdogRetriesAFailedReleaseThenBacksOffToASlowCadence() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 70, at: t0)
        await backend.setFaults({ var f = SimulatedFanBackend.Faults(); f.rejectModeWrites = true; return f }())

        var attempts = 0
        var gaveUp = false
        // Phase 1+2: one attempt per second until the fast budget is spent,
        // then giving-up reports without further writes.
        for i in 1...10 {
            switch await core.watchdogTick(now: t0.addingTimeInterval(100 + Double(i))) {
            case .releaseIncomplete: attempts += 1
            case .givingUp:          gaveUp = true
            default:                 break
            }
        }
        XCTAssertEqual(attempts, DaemonConstants.maxReleaseRetries,
                       "the fast budget bounds how often dead hardware is written")
        XCTAssertTrue(gaveUp, "the give-up state must be visible, not silent")

        // Still inside the slow window: backed off, no writes.
        let mid = await core.watchdogTick(now: t0.addingTimeInterval(130))
        guard case .givingUp = mid else { return XCTFail("expected continued backoff, got \(mid)") }

        // Past the window, with the hardware healed: exactly one more attempt
        // happens, and it succeeds — recovery stays alive after giving up.
        await backend.setFaults(SimulatedFanBackend.Faults())
        let deadline = t0.addingTimeInterval(106 + Double(DaemonConstants.slowReleaseRetryInterval))
        let late = await core.watchdogTick(now: deadline.addingTimeInterval(1))
        guard case .released = late else { return XCTFail("expected slow-cadence recovery, got \(late)") }
        let manual = await core.manualFanIndices()
        XCTAssertTrue(manual.isEmpty)
    }

    func testWatchdogRecoversWhenTheHardwareStartsWorkingAgain() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 70, at: t0)
        await backend.setFaults({ var f = SimulatedFanBackend.Faults(); f.rejectModeWrites = true; return f }())

        _ = await core.watchdogTick(now: t0.addingTimeInterval(100))
        await backend.setFaults(SimulatedFanBackend.Faults())
        let action = await core.watchdogTick(now: t0.addingTimeInterval(101))
        guard case .released = action else { return XCTFail("expected recovery, got \(action)") }
        let manual = await core.manualFanIndices()
        XCTAssertTrue(manual.isEmpty)
    }

    // MARK: - Concurrency

    /// The state this exercises used to be plain properties on a class touched
    /// from XPC reply queues, detached tasks, and a signal-source queue at once.
    /// Under TSan this test is the regression guard for that.
    func testConcurrentRequestsDoNotCorruptState() async {
        let (core, _) = await makeCore(fanCount: 4)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<400 {
                let fan = i % 4
                group.addTask {
                    switch i % 5 {
                    case 0: _ = await core.setManualMode(fan: fan, enabled: true, now: self.t0)
                    case 1: _ = await core.setTarget(fan: fan, rpm: Double(2000 + i), now: self.t0)
                    case 2: await core.heartbeat(maxTempC: Double(60 + i % 30), at: self.t0)
                    case 3: _ = await core.readFans()
                    default: _ = await core.watchdogTick(now: self.t0)
                    }
                }
            }
        }
        // The invariant that matters: every fan the core still calls manual is a
        // fan it knows about, and nothing is left half-recorded.
        let manual = await core.manualFanIndices()
        let known = await core.knownFanCount()
        XCTAssertTrue(manual.allSatisfy { $0 >= 0 && $0 < known })
    }

    func testReleaseIsSafeToCallConcurrentlyWithTargets() async {
        let (core, backend) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        _ = await core.setManualMode(fan: 1, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 80, at: t0)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if i % 20 == 0 {
                        _ = await core.releaseAll()
                    } else {
                        _ = await core.setTarget(fan: i % 2, rpm: 5000, now: self.t0)
                    }
                }
            }
        }
        // Whatever the interleaving, the last release must leave no fan claiming
        // manual control that the backend disagrees about.
        _ = await core.releaseAll()
        for fan in 0..<2 {
            let mode = await backend.mode(of: fan)
            XCTAssertEqual(mode?.isUserControlled, false)
        }
        let manual = await core.manualFanIndices()
        XCTAssertTrue(manual.isEmpty)
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
