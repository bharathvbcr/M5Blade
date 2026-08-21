import XCTest
import FanKit
import ProfileKit
import SensorKit
import SimSupport
@testable import FanControlApp

/// The reported bug, and the contract that replaces it.
///
/// > "switching between profiles and stock triggers fan failure errors, but a
/// > second click resolves it"
///
/// Reproduced from this machine's own helper log:
///
///     18:55:22.166  rejected setTarget: fan 0 is not under manual control
///     18:55:34.982  watchdog timeout — released 0,1
///
/// A sampling tick and a user's click are both main-actor work full of `await`s,
/// so they interleaved at every one of them. Pressing Stock released the fans
/// underneath a tick that was mid-`applyControl`; the tick's next target was
/// refused, it read the refusal as the daemon's watchdog having dropped it, and
/// re-armed. The banner was the visible half. The invisible half is the second
/// log line — twelve seconds later both fans were *still* under manual control,
/// with the app showing "Watching" and sending no heartbeats to keep them safe.
@MainActor
final class ControlTransitionTests: XCTestCase {

    private var directory: URL!
    private var daemon: SimulatedDaemon!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlTransitionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        daemon = SimulatedDaemon()
        model = AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("config.json")),
                         historyURL: directory.appendingPathComponent("history.sqlite"),
                         defaults: InMemoryDefaults(),
                         daemon: daemon)
    }

    override func tearDownWithError() throws {
        model = nil
        daemon = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// A model driving two fans, exactly as `enableControl` leaves it.
    private func startControlling() async {
        let fans = Fixture.fans(2)
        model.applyForTesting(fans: fans,
                              readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(4))
        XCTAssertNotNil(model.maxTempC,
                        "without a temperature the loop releases on staleness and the premise is gone")
        await model.enableControl()
        XCTAssertEqual(model.status, .controlling, "the fixture must actually be in control")
        XCTAssertEqual(daemon.armed, [0, 1])
    }

    /// Holds the next `setTarget` until the test lets it go, and reports when it
    /// has arrived. This is where the real tick sits during an XPC round trip.
    private func suspendFirstWrite() -> (arrived: XCTestExpectation, release: Latch) {
        let arrived = expectation(description: "a tick is suspended mid-write")
        let release = Latch()
        let first = OneShot()
        daemon.beforeSetTarget = { @Sendable _ in
            guard first.claim() else { return }
            arrived.fulfill()
            await release.wait()
        }
        return (arrived, release)
    }

    // MARK: - The reported failure

    /// Stock, pressed while a tick is suspended mid-write.
    ///
    /// Against the pre-fix code this fails on `reArmedAfterRelease`: the tick
    /// resumed after the release, had its target refused, and armed both fans
    /// again.
    func testStockPressedDuringATickLeavesTheFansOnMacOS() async {
        await startControlling()
        let (arrived, release) = suspendFirstWrite()

        let tick = Task { await self.model.tickForTesting() }
        await fulfillment(of: [arrived], timeout: 5)

        // The click, while that tick is still in flight.
        let stock = Task { await self.model.releaseToStock() }
        release.open()

        await tick.value
        await stock.value

        XCTAssertFalse(daemon.reArmedAfterRelease,
                       "a fan was armed after the release: \(daemon.log)")
        XCTAssertTrue(daemon.armed.isEmpty,
                      "the fans are still under manual control after Stock: \(daemon.log)")
        XCTAssertEqual(model.status, .watching)
        XCTAssertNil(model.controlProblem,
                     "the user's own click was reported back to them as a fault")
    }

    /// The same, entered the way the menu does it — by pinning the Stock profile
    /// rather than by pressing the panic button.
    func testSelectingStockDuringATickLeavesTheFansOnMacOS() async {
        await startControlling()
        let (arrived, release) = suspendFirstWrite()

        let tick = Task { await self.model.tickForTesting() }
        await fulfillment(of: [arrived], timeout: 5)

        model.selectProfile(Profile.stockID)
        release.open()

        await tick.value
        await model.settleForTesting()

        XCTAssertFalse(daemon.reArmedAfterRelease, "a fan was armed after the release: \(daemon.log)")
        XCTAssertTrue(daemon.armed.isEmpty, "fans left armed after selecting Stock: \(daemon.log)")
        XCTAssertEqual(model.status, .watching)
    }

    /// The other half of "switching between profiles and stock": Stock, then
    /// straight back to driving, with a tick in flight throughout. The last
    /// request must be the one the hardware ends up in.
    func testSwitchingBackToAProfileEndsArmedAndControlling() async {
        await startControlling()
        let (arrived, release) = suspendFirstWrite()

        let tick = Task { await self.model.tickForTesting() }
        await fulfillment(of: [arrived], timeout: 5)

        let stock = Task { await self.model.releaseToStock() }
        let resume = Task { await self.model.enableControl() }
        release.open()

        await tick.value
        await stock.value
        await resume.value

        XCTAssertEqual(daemon.armed, [0, 1],
                       "control was requested last and must be what the hardware ends in: \(daemon.log)")
        XCTAssertEqual(model.status, .controlling)
        XCTAssertFalse(daemon.hadRefusedWrite,
                       "a target was written to an unarmed fan: \(daemon.log)")
    }

    /// No sequence of clicks may leave the app's claim and the hardware apart.
    ///
    /// The relational invariant, in the style of `DaemonSoakTests`: once things
    /// settle, "the app says it is controlling" and "the fans are armed" have to
    /// be the same statement. The failure this catches is the silent one — armed
    /// fans with the app in `.watching`, heartbeats stopped, and nothing left to
    /// notice but the daemon's watchdog twelve seconds later.
    func testRandomisedClickingNeverStrandsTheFans() async {
        await startControlling()
        var rng = SplitMix64(seed: ControlSoakTests.seed(0x5EED_FA17))

        for iteration in 0..<150 {
            // The click must land while a tick is *inside* `applyControl`, not
            // merely while one is running. Launching both and hoping they collide
            // is the version of this test that passes against the broken code. So
            // each iteration pins the tick open at its first write and clicks into
            // that window.
            //
            // `ready` is also opened when the tick finishes, because a tick that
            // is watching — or whose profile hands control back — never reaches a
            // write, and waiting for a window that cannot open would hang.
            let ready = Latch()
            let release = Latch()
            let first = OneShot()
            daemon.beforeSetTarget = { @Sendable _ in
                guard first.claim() else { return }
                ready.open()
                await release.wait()
            }

            let tick = Task { await self.model.tickForTesting(); ready.open() }
            await ready.wait()

            let choice = Int.random(in: 0..<5, using: &rng)
            let pick = model.profiles.randomElement(using: &rng)?.id
            let action = Task { @MainActor in
                switch choice {
                case 0: await self.model.releaseToStock()
                case 1: await self.model.enableControl()
                case 2: await self.model.setAutoMode(true)
                case 3: await self.model.setAutoMode(false)
                default: if let pick { self.model.selectProfile(pick) }
                }
            }
            release.open()

            await tick.value
            await action.value
            await model.settleForTesting()

            let claimsControl = model.status == .controlling || model.status == .emergency
            XCTAssertEqual(claimsControl, !daemon.armed.isEmpty,
                           """
                           iteration \(iteration): app says “\(model.status.label)” while armed \
                           fans are \(daemon.armed.sorted()) — last operations: \
                           \(daemon.log.suffix(10).map(\.description))
                           """)
            XCTAssertFalse(daemon.hadRefusedWrite,
                           "iteration \(iteration): a target reached an unarmed fan — \(daemon.log.suffix(10).map(\.description))")
        }
    }

    // MARK: - The gate itself

    /// A tick that fires while another is still mid-write must not run.
    ///
    /// Deterministic rather than probabilistic: the first tick is *held* inside
    /// `setTarget`, so a second tick that is admitted has demonstrably overlapped
    /// rather than merely been given the opportunity to. Counting writes is the
    /// assertion — `skippedTicks` is the gate's own bookkeeping and proves nothing
    /// on its own.
    func testATickCannotStartWhileAnotherIsMidWrite() async {
        await startControlling()

        let concurrent = Counter()
        let attempts = Counter()
        let arrived = expectation(description: "the first tick is suspended mid-write")
        let release = Latch()
        let first = OneShot()
        daemon.beforeSetTarget = { @Sendable _ in
            concurrent.increment()
            attempts.increment()
            defer { concurrent.decrement() }
            guard first.claim() else { return }
            arrived.fulfill()
            await release.wait()
        }

        let held = Task { await self.model.tickForTesting() }
        await fulfillment(of: [arrived], timeout: 5)

        // Fires while the first tick is provably still inside `applyControl`.
        await model.tickForTesting()
        // One: the held tick's own. A second means the gate admitted a tick that
        // overlapped a write, which is the state that corrupts the CPU delta
        // window and lets two decisions chase each other onto one fan.
        let attemptsDuringHold = attempts.value

        release.open()
        await held.value

        XCTAssertEqual(attemptsDuringHold, 1,
                       "a second tick reached a fan write while the first was still mid-write: \(daemon.log)")
        XCTAssertEqual(concurrent.peak, 1, "two ticks were inside applyControl at once")
    }

    /// Arming is the slow operation; a tick must not slip in beside it and drive
    /// a fan set that is still being taken over.
    func testATickCannotRunWhileControlIsBeingTaken() async {
        let fans = Fixture.fans(2)
        model.applyForTesting(fans: fans,
                              readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(4))

        let arming = expectation(description: "arming has started")
        let first = OneShot()
        daemon.beforeSetManual = { @Sendable _, _ in
            if first.claim() { arming.fulfill() }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let enable = Task { await self.model.enableControl() }
        await fulfillment(of: [arming], timeout: 5)
        await model.tickForTesting()
        await enable.value

        XCTAssertGreaterThan(model.controlGate.skippedTicks, 0)
        XCTAssertEqual(daemon.armed, [0, 1])
        XCTAssertEqual(model.status, .controlling)
    }

    /// Superseding must not leave arming half-done. A click that arrives between
    /// two fans has to end with both armed or neither — one fan under this app
    /// and one under macOS is two controllers in one thermal envelope.
    func testAClickDuringArmingNeverLeavesOneFanBehind() async {
        let fans = Fixture.fans(2)
        model.applyForTesting(fans: fans,
                              readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(4))

        let armingFirstFan = expectation(description: "the first fan is being armed")
        let release = Latch()
        let first = OneShot()
        daemon.beforeSetManual = { @Sendable _, enabled in
            guard enabled, first.claim() else { return }
            armingFirstFan.fulfill()
            await release.wait()
        }

        let enable = Task { await self.model.enableControl() }
        await fulfillment(of: [armingFirstFan], timeout: 5)
        let stock = Task { await self.model.releaseToStock() }
        release.open()

        await enable.value
        await stock.value

        XCTAssertTrue(daemon.armed.isEmpty,
                      "Stock arrived last; no fan may remain armed — \(daemon.log.map(\.description))")
        XCTAssertEqual(model.status, .watching)
    }
}

// MARK: - Helpers

/// One-shot claim, for hooks that must fire on the first call only. Lock-guarded
/// because the hook runs on whichever executor the caller is on, and two of them
/// genuinely can arrive at once.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var highWater = 0

    var value: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// The most concurrent this ever got. Asserted in preference to the
    /// instantaneous value: a sampled count of 1 only means the sample missed the
    /// overlap, which is not the same as there having been none.
    var peak: Int { lock.lock(); defer { lock.unlock() }; return highWater }

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        highWater = max(highWater, count)
        return count
    }

    @discardableResult
    func decrement() -> Int { lock.lock(); defer { lock.unlock() }; count -= 1; return count }
}

/// A one-way latch that can be awaited from inside a hook.
///
/// `XCTestExpectation` covers the other direction — a hook signalling the test
/// body — but cannot be awaited itself, and the hooks here have to hold a tick
/// suspended until the test has done its half of the interleaving.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        isOpen = true
        let resume = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in resume { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
