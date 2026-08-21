import XCTest
import FanKit
import ProfileKit
import SensorKit
import SimSupport
@testable import FanControlApp

/// Long randomised soaks over the app's control-state machine, with the helper
/// failing and recovering underneath it.
///
/// `ControlTransitionTests` pins one interleaving each. These exist for the
/// failure this layer actually has to prevent, which is not any single transition
/// going wrong: it is the app's *claim* and the hardware's *state* drifting apart
/// over a long run of ordinary events, until the app says macOS is driving fans
/// that are in fact pinned under manual control with nothing feeding them.
///
/// Same shape as `DaemonSoakTests`, one layer up: the assertions are relational,
/// and they are checked after every operation rather than at the end.
@MainActor
final class ControlSoakTests: XCTestCase {

    private var directory: URL!
    private var daemon: SimulatedDaemon!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlSoakTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        daemon = SimulatedDaemon()
        model = AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("config.json")),
                         historyURL: directory.appendingPathComponent("history.sqlite"),
                         defaults: InMemoryDefaults(),
                         daemon: daemon)
        let fans = Fixture.fans(2)
        model.applyForTesting(fans: fans,
                              readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(4))
    }

    override func tearDownWithError() throws {
        model = nil
        daemon = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The contract

    /// Fixed by default, because a stress failure that cannot be reproduced is a
    /// rumour — and overridable, because one seed is one path through a very large
    /// space. Sweeping it is how the seeds now compiled in were chosen:
    ///
    ///     for s in $(seq 1 40); do FANCONTROL_SOAK_SEED=$s swift test --filter ControlSoakTests; done
    static func seed(_ fallback: UInt64) -> UInt64 {
        ProcessInfo.processInfo.environment["FANCONTROL_SOAK_SEED"].flatMap(UInt64.init) ?? fallback
    }

    private var claimsControl: Bool {
        model.status == .controlling || model.status == .emergency
    }

    /// With healthy hardware the app's claim and the fans' state are the same
    /// statement, with nothing to report.
    private func assertExactAgreement(_ context: @autoclosure () -> String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(claimsControl, !daemon.armed.isEmpty,
                       "claim and hardware disagree — \(context())", file: file, line: line)
    }

    /// With hardware that is failing, the claim and the fans *may* disagree —
    /// a release the helper refused genuinely leaves fans armed. What may never
    /// happen is disagreeing **silently**.
    ///
    /// This is the property with teeth. "Fans are armed and the app is calmly
    /// reporting Watching" is the state the original bug produced: no heartbeats,
    /// no controller, and nothing left to recover the hardware but the daemon's
    /// watchdog twelve seconds later. If the app cannot get the fans where the
    /// user asked, it must at least still be saying so.
    private func assertDisagreementIsReported(_ context: @autoclosure () -> String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        guard claimsControl != !daemon.armed.isEmpty else { return }
        XCTAssertNotNil(model.controlProblem,
                        "claim and hardware disagree and the app reports nothing wrong — \(context())",
                        file: file, line: line)
    }

    private func trace() -> String {
        "status=\(model.status.label) armed=\(daemon.armed.sorted()) "
            + "problem=\(model.controlProblem ?? "nil") log=\(daemon.log.suffix(10).map(\.description))"
    }

    /// Every user action the UI can produce, plus the tick.
    private func perform(_ choice: Int, rng: inout SplitMix64) async {
        switch choice {
        case 0: await model.releaseToStock()
        case 1: await model.enableControl()
        case 2: await model.setAutoMode(true)
        case 3: await model.setAutoMode(false)
        case 4: if let id = model.profiles.randomElement(using: &rng)?.id { model.selectProfile(id) }
        case 5:
            // Both halves, as `main.swift` does it. `noteWillSleep` only records
            // the intent and stops the app claiming control; the hardware release
            // is the detached call that follows. Simulating the first without the
            // second manufactures armed-fans-while-watching in the harness — a
            // state the running app never reaches, and one this soak spent a run
            // reporting as an app defect before the fixture was made faithful.
            model.noteWillSleep()
            if await model.shutdownFansAndFlush() == false { model.noteReleaseUnconfirmed() }
        case 6: await model.resumeAfterWake()
        default: await model.tickForTesting()
        }
        await model.settleForTesting()
    }

    /// Runs the app's own recovery path to completion, so an assertion measures a
    /// settled state rather than the instant before the app has been given any
    /// chance to notice. Something taking the fans away behind the app's back is
    /// invisible to it until its next tick — that is a fact about the hardware,
    /// not a defect.
    private func converge() async {
        await model.tickForTesting()
        await model.settleForTesting()
    }

    // MARK: - Soaks

    /// A healthy helper, and nothing but user actions racing the sampler.
    func testHealthyHelperSoak() async {
        var rng = SplitMix64(seed: Self.seed(0xA11_600D))
        await model.enableControl()

        for iteration in 0..<200 {
            let tick = Task { await self.model.tickForTesting() }
            await perform(Int.random(in: 0..<8, using: &rng), rng: &rng)
            await tick.value
            await converge()
            assertExactAgreement("iteration \(iteration): \(self.trace())")
            XCTAssertFalse(daemon.hadRefusedWrite,
                           "iteration \(iteration): a target reached an unarmed fan — \(self.trace())")
        }
    }

    /// The same, with the helper refusing and going unreachable at random.
    ///
    /// Refused writes are expected here — a helper that declines an arm leaves the
    /// fans on macOS, and the tick that follows will find them unarmed. What must
    /// not happen is the app claiming control it does not have, or falling silent
    /// about fans it could not release.
    func testFaultySoak() async {
        var rng = SplitMix64(seed: Self.seed(0xBAD_11FE))
        await model.enableControl()

        for iteration in 0..<200 {
            // Faults appear and clear underneath the app, as they do in life.
            if Int.random(in: 0..<100, using: &rng) < 30 {
                var faults = SimulatedDaemon.Faults()
                faults.refuseArm = Int.random(in: 0..<100, using: &rng) < 30
                faults.refuseRelease = Int.random(in: 0..<100, using: &rng) < 20
                faults.refuseTarget = Int.random(in: 0..<100, using: &rng) < 25
                faults.unreachable = Int.random(in: 0..<100, using: &rng) < 15
                daemon.faults = faults
            } else {
                daemon.faults = .healthy
            }
            // Something other than this app takes the fans back: the daemon's
            // watchdog, or a second root fan controller (ISSUES.md I-9).
            if Int.random(in: 0..<100, using: &rng) < 8 { daemon.simulateWatchdogRelease() }

            let tick = Task { await self.model.tickForTesting() }
            await perform(Int.random(in: 0..<8, using: &rng), rng: &rng)
            await tick.value
            await converge()
            assertDisagreementIsReported("iteration \(iteration): faults=\(daemon.faults) \(self.trace())")
        }

        // Whatever happened, healthy hardware plus a panic press must end with the
        // fans on macOS and the app saying so. This is the property the whole
        // system exists to guarantee.
        daemon.faults = .healthy
        await model.releaseToStock()
        await model.settleForTesting()
        XCTAssertTrue(daemon.armed.isEmpty, "the panic path did not recover the fans — \(trace())")
        XCTAssertEqual(model.status, .watching)
        XCTAssertNil(model.controlProblem)
    }

    // MARK: - The legitimate re-arm must survive the fix

    /// The daemon's watchdog dropping manual control is a real event with a real
    /// answer: re-arm. Serialising transitions must not have disabled that — a fix
    /// that made the app stop recovering from a genuine watchdog release would
    /// trade a loud bug for a quiet one.
    func testAWatchdogReleaseIsStillRecoveredByReArming() async {
        await model.enableControl()
        XCTAssertEqual(daemon.armed, [0, 1])

        // Something outside the app takes the fans back.
        daemon.simulateWatchdogRelease()
        XCTAssertTrue(daemon.armed.isEmpty)

        // The next tick writes into fans that are no longer armed, is refused, and
        // must respond by taking them back rather than by giving up.
        await model.tickForTesting()

        XCTAssertTrue(daemon.hadRefusedWrite, "the tick did not even attempt a write")
        XCTAssertEqual(daemon.armed, [0, 1],
                       "a genuine watchdog release was not recovered — \(trace())")
    }

    /// …but only while the user still wants control. A watchdog release followed
    /// by the user pressing Stock must not be "recovered" into re-arming.
    func testAWatchdogReleaseIsNotRecoveredAfterTheUserAsksForStock() async {
        await model.enableControl()

        let arrived = expectation(description: "the tick is mid-write")
        let release = Latch()
        let first = OneShot()
        daemon.beforeSetTarget = { @Sendable _ in
            guard first.claim() else { return }
            arrived.fulfill()
            await release.wait()
        }

        daemon.simulateWatchdogRelease()
        let tick = Task { await self.model.tickForTesting() }
        await fulfillment(of: [arrived], timeout: 5)

        let stock = Task { await self.model.releaseToStock() }
        release.open()
        await tick.value
        await stock.value
        await model.settleForTesting()

        XCTAssertTrue(daemon.armed.isEmpty,
                      "the recovery path re-armed fans the user had just handed back — \(trace())")
        XCTAssertEqual(model.status, .watching)
    }

    // MARK: - Reporting honestly

    /// A release the helper refused must not be reported as a handover.
    func testAnUnconfirmedReleaseIsNotReportedAsWatchingQuietly() async {
        await model.enableControl()
        daemon.faults.refuseRelease = true

        await model.releaseToStock()
        await model.settleForTesting()

        XCTAssertFalse(daemon.armed.isEmpty, "the simulated refusal did not hold the fans")
        XCTAssertNotNil(model.controlProblem,
                        "the fans are still armed and the app reported nothing — \(trace())")
        assertDisagreementIsReported(trace())
    }

    /// Sleeping with a release the helper refused must not be silent.
    ///
    /// Found by `testFaultySoak`, not by reading the code. `noteWillSleep` sets the
    /// app to "Watching" and `shutdownFansAndFlush` then does the release — but it
    /// runs off the main actor and so could not report its own failure, and its
    /// return value was discarded. The machine went to sleep with the fans still
    /// pinned under manual control while the app displayed a calm "Watching".
    func testAnUnconfirmedReleaseBeforeSleepIsSurfaced() async {
        await model.enableControl()
        daemon.faults.refuseRelease = true

        model.noteWillSleep()
        let released = await model.shutdownFansAndFlush()
        XCTAssertFalse(released, "the simulated refusal did not reach the caller")
        if !released { model.noteReleaseUnconfirmed() }

        XCTAssertFalse(daemon.armed.isEmpty, "premise: the fans really are still armed")
        XCTAssertNotNil(model.controlProblem,
                        "slept with the fans still armed and said nothing — \(trace())")
        assertDisagreementIsReported(trace())
    }

    /// An unreachable helper is not a helper that says no, and the app must not
    /// claim the fans were handed back by something it could not talk to.
    func testAnUnreachableHelperIsNotReportedAsAHandover() async {
        await model.enableControl()
        daemon.faults.unreachable = true

        await model.releaseToStock()
        await model.settleForTesting()

        XCTAssertEqual(model.status, .daemonUnavailable,
                       "an unreachable helper was reported as macOS taking over — \(trace())")
        XCTAssertNotNil(model.controlProblem)
    }
}
