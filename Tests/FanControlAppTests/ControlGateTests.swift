import XCTest
import SimSupport
@testable import FanControlApp

/// The gate on its own, apart from the model it protects.
///
/// It is a hand-written async mutex, which is a thing to be suspicious of: the
/// failure modes are a lost wakeup (a waiter that is never resumed, and a control
/// operation that never completes) and a moment of false vacancy between a
/// release and the next waiter actually running, through which a tick could slip
/// — precisely what the gate exists to prevent. Both are tested directly here
/// rather than inferred from the model-level suites passing.
@MainActor
final class ControlGateTests: XCTestCase {

    // MARK: - Exclusion

    func testOnlyOneOperationRunsAtATime() async {
        let gate = ControlGate()
        let concurrent = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { @MainActor in
                    await gate.exclusive {
                        concurrent.increment()
                        await Task.yield()
                        try? await Task.sleep(nanoseconds: 200_000)
                        concurrent.decrement()
                    }
                }
            }
        }
        XCTAssertEqual(concurrent.peak, 1, "the gate admitted two operations at once")
    }

    /// Every waiter must run. A lost wakeup here is a control operation that
    /// never completes and a UI that waits on it forever.
    func testEveryWaiterIsResumed() async {
        let gate = ControlGate()
        let completed = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { @MainActor in
                    await gate.exclusive { _ = completed.increment() }
                }
            }
        }
        XCTAssertEqual(completed.value, 200)
    }

    /// Queued operations run in the order they were admitted, so two clicks apply
    /// in the order they were made rather than whichever the scheduler wakes first.
    func testQueuedOperationsRunInOrder() async {
        let gate = ControlGate()
        let order = Recorder()

        // The first holds the gate while the rest queue behind it in a known order.
        let release = Latch()
        let holding = Task { @MainActor in
            await gate.exclusive { order.append(0); await release.wait() }
        }
        // Admitted one at a time, each awaited only far enough to be queued.
        var queued: [Task<Void, Never>] = []
        for index in 1...8 {
            queued.append(Task { @MainActor in await gate.exclusive { order.append(index) } })
            // Let the task reach `acquire` and enqueue before the next is created.
            for _ in 0..<4 { await Task.yield() }
        }
        release.open()
        await holding.value
        for task in queued { await task.value }

        XCTAssertEqual(order.values, Array(0...8), "the queue is not FIFO")
    }

    /// The gate must never look free while a queue is waiting, or a tick would
    /// slip between two queued transitions.
    func testATickCannotSlipBetweenTwoQueuedOperations() async {
        let gate = ControlGate()
        let order = Recorder()
        let release = Latch()

        let holding = Task { @MainActor in
            await gate.exclusive { order.append(1); await release.wait() }
        }
        let queuedSecond = Task { @MainActor in
            await gate.exclusive { order.append(2) }
        }
        for _ in 0..<8 { await Task.yield() }

        // Runs repeatedly across the whole handover, including the instant the
        // first operation finishes and the second has not yet resumed.
        let tickAttempts = Task { @MainActor in
            for _ in 0..<200 {
                _ = await gate.tryExclusive { order.append(99) }
                await Task.yield()
            }
        }
        release.open()
        await holding.value
        await queuedSecond.value
        await tickAttempts.value

        let transitions = order.values.filter { $0 != 99 }
        XCTAssertEqual(transitions, [1, 2])
        XCTAssertFalse(order.values.contains(99) && order.values.firstIndex(of: 99)! < order.values.firstIndex(of: 2)!,
                       "a tick ran between two queued transitions: \(order.values)")
    }

    // MARK: - tryExclusive

    func testTryExclusiveSkipsWhileHeldAndRunsWhenFree() async {
        let gate = ControlGate()
        let release = Latch()
        let ran = Counter()

        let holding = Task { @MainActor in
            await gate.exclusive { await release.wait() }
        }
        for _ in 0..<4 { await Task.yield() }

        let skipped = await gate.tryExclusive { ran.increment() }
        XCTAssertNil(skipped, "tryExclusive ran while the gate was held")
        XCTAssertEqual(gate.skippedTicks, 1)

        release.open()
        await holding.value

        let admitted = await gate.tryExclusive { ran.increment() }
        XCTAssertNotNil(admitted, "tryExclusive refused a free gate")
        XCTAssertEqual(ran.value, 1)
    }

    /// A skipped attempt must leave the gate exactly as it found it. An early
    /// return that forgot to unwind would wedge every later operation.
    func testASkippedAttemptDoesNotWedgeTheGate() async {
        let gate = ControlGate()
        let release = Latch()
        let holding = Task { @MainActor in await gate.exclusive { await release.wait() } }
        for _ in 0..<4 { await Task.yield() }
        for _ in 0..<50 { _ = await gate.tryExclusive { } }
        release.open()
        await holding.value

        let ran = Counter()
        await gate.exclusive { _ = ran.increment() }
        XCTAssertEqual(ran.value, 1, "the gate was left held after skipped attempts")
    }

    // MARK: - Supersession

    func testSupersedeInvalidatesOlderEpochsOnly() {
        let gate = ControlGate()
        let first = gate.supersede()
        XCTAssertTrue(gate.isCurrent(first))

        let second = gate.supersede()
        XCTAssertFalse(gate.isCurrent(first), "an older intent is still considered current")
        XCTAssertTrue(gate.isCurrent(second))
        XCTAssertGreaterThan(second, first)
    }

    /// Supersession has to be visible without suspending, or the holder learns of
    /// it only after doing the writes it was meant to skip.
    func testSupersedeIsVisibleWithoutAwaiting() async {
        let gate = ControlGate()
        let epoch = gate.supersede()
        let observed = Recorder()

        let release = Latch()
        let holding = Task { @MainActor in
            await gate.exclusive {
                await release.wait()
                observed.append(gate.isCurrent(epoch) ? 1 : 0)
            }
        }
        for _ in 0..<4 { await Task.yield() }
        gate.supersede()          // synchronous, from outside the gate
        release.open()
        await holding.value

        XCTAssertEqual(observed.values, [0], "the holder did not see it had been superseded")
    }

    // MARK: - Soak

    /// Mixed traffic, the shape the app produces: a stream of ticks against
    /// occasional transitions, all racing. Asserts the two properties that matter
    /// together — never two at once, and never a lost waiter.
    func testMixedTrafficSoak() async {
        let gate = ControlGate()
        let concurrent = Counter()
        let transitions = Counter()
        var rng = SplitMix64(seed: 0xC0FFEE)

        var plan: [Bool] = []
        for _ in 0..<600 { plan.append(Int.random(in: 0..<4, using: &rng) == 0) }

        await withTaskGroup(of: Void.self) { group in
            for isTransition in plan {
                group.addTask { @MainActor in
                    let body: @MainActor () async -> Void = {
                        concurrent.increment()
                        await Task.yield()
                        concurrent.decrement()
                    }
                    if isTransition {
                        gate.supersede()
                        await gate.exclusive { await body(); _ = transitions.increment() }
                    } else {
                        _ = await gate.tryExclusive { await body() }
                    }
                }
            }
        }

        XCTAssertEqual(concurrent.peak, 1, "the gate admitted two operations at once")
        XCTAssertEqual(transitions.value, plan.filter { $0 }.count,
                       "a queued transition was lost")
        XCTAssertEqual(concurrent.value, 0)
    }
}

/// Ordered log of what ran, for the FIFO and interleaving assertions.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Int) { lock.lock(); storage.append(value); lock.unlock() }
}
