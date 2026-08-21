import Foundation

/// Mutual exclusion and supersession for fan-control operations.
///
/// Everything in `AppModel` runs on the main actor, which prevents data races
/// and nothing else. `await` is a yield point, so the sampling tick and a user's
/// profile switch — both main-actor, both full of `await`s on a helper across
/// XPC — interleaved freely at every one of them. The observed consequence, from
/// this machine's own helper log:
///
///     18:55:22.166  rejected setTarget: fan 0 is not under manual control
///     18:55:34.982  watchdog timeout — released 0,1
///
/// The user pressed Stock. `releaseToStock` handed the fans back while a tick
/// was suspended inside `applyControl`; the tick resumed, wrote a target to a fan
/// that was no longer armed, took the rejection as evidence that the daemon's
/// watchdog had dropped it, and *re-armed manual mode* — undoing the release the
/// user had just asked for. The app then showed "Watching", stopped sending
/// heartbeats, and the fans sat under manual control with nothing driving them
/// until the daemon's watchdog took them back 12.8 seconds later. The second
/// click worked because by then no tick was in flight.
///
/// Two mechanisms, because the two failures are different:
///
///   * **Exclusion.** One fan-control operation at a time. A release can no
///     longer land between a tick's `heartbeat` and its `setTarget`.
///   * **Supersession.** Exclusion alone would make Stock wait for a tick that is
///     mid-round-trip, so a user action bumps `epoch` *synchronously* before it
///     queues. The holder sees that at its next `await` and abandons, which keeps
///     the panic path prompt and stops superseded work from writing anything.
///
/// The tick uses `tryExclusive` rather than queueing: a sampler that piles up
/// behind a 15-second arm would run a burst of stale ticks afterwards, each
/// differencing CPU counters over a window that never happened.
@MainActor
final class ControlGate {

    /// Held by exactly one operation at a time. Ownership is handed directly to
    /// the next waiter on release, so this never flickers false while a queue is
    /// non-empty and a tick cannot slip in between two queued transitions.
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Incremented by every user-initiated transition. Work tagged with an older
    /// value has been superseded and must not write to the hardware.
    private(set) var epoch = 0

    /// Ticks that found the gate held and skipped. Exposed because "the guard
    /// engaged" and "nothing happened to test" are otherwise indistinguishable,
    /// and a reentrancy guard that never fires is not evidence of correctness.
    private(set) var skippedTicks = 0

    /// Marks all in-flight and queued work as superseded, and returns the epoch
    /// the caller now owns.
    ///
    /// Synchronous on purpose: it must take effect before the caller suspends on
    /// `exclusive`, or the holder would not see it until after doing the very
    /// writes this is meant to prevent.
    @discardableResult
    func supersede() -> Int {
        epoch += 1
        return epoch
    }

    /// Whether work tagged `epoch` is still the newest intent.
    func isCurrent(_ epoch: Int) -> Bool { epoch == self.epoch }

    /// Runs `body` once every previously admitted operation has finished. FIFO,
    /// so two clicks apply in the order they were made rather than whichever the
    /// scheduler happens to wake first.
    func exclusive<T>(_ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }

    /// Runs `body` only if the gate is free; returns nil without running it
    /// otherwise. Never queues.
    func tryExclusive<T>(_ body: () async -> T) async -> T? {
        guard !isHeld else {
            skippedTicks += 1
            return nil
        }
        isHeld = true
        defer { release() }
        return await body()
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        // Resumed by `release`, which hands ownership over without clearing
        // `isHeld` — otherwise the gate would be momentarily free between the
        // resume and this continuation running.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}
