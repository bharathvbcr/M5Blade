import AppKit
import SwiftUI

/// Carries one Bool back from the detached release to the thread waiting on it.
/// `nil` means the wait timed out and the answer never arrived, which is not the
/// same as "it failed" but is treated the same way: unconfirmed.
private final class ReleaseOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?

    var value: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        statusController = StatusItemController(model: model)

        Task { await model.start() }

        // Hand the fans back before sleep rather than relying on the firmware
        // reset and repairing on wake. This has to *complete* before we return —
        // firing a Task and returning let the machine sleep with the fans still
        // under manual control — and for the same reason as `willTerminate` the
        // work must not need the main actor we are standing on.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let model = MainActor.assumeIsolated { () -> AppModel in
                self.model.noteWillSleep()
                return self.model
            }
            let semaphore = DispatchSemaphore(value: 0)
            let released = ReleaseOutcomeBox()
            Task.detached {
                released.value = await model.shutdownFansAndFlush()
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 5) == .timedOut {
                NSLog("[M5Blade] sleep: fans were not confirmed released within 5s")
            }
            // Still on the main thread, and the detached work has either finished
            // or timed out — so this is the one place that can both know the answer
            // and say so. Unlike quit, the app is still running afterwards, and an
            // unconfirmed handover is something the user should find waiting for
            // them rather than only in the unified log.
            if released.value != true {
                MainActor.assumeIsolated { self.model.noteReleaseUnconfirmed() }
            }
        }

        // Manual control is lost across sleep on Apple Silicon — re-probe on
        // wake, and retake control if that is what the user had.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { _ = Task { await self.model.resumeAfterWake() } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // AppKit will not finish quitting until this returns, so the work has to
        // be waited on — but it must not be work that needs the main actor,
        // because this *is* the main actor. The previous version awaited a
        // `Task { @MainActor in … }` from behind a semaphore on the main thread:
        // a guaranteed deadlock that expired its 2s timeout on every quit and
        // left the fans under manual control until the daemon's watchdog
        // noticed. `releaseAndFlushForTermination` is `nonisolated` for exactly
        // this reason, and `Task.detached` keeps it off the main actor.
        let semaphore = DispatchSemaphore(value: 0)
        let model = self.model!
        // Stops the sampler and supersedes anything in flight *before* the
        // release below, so nothing can re-arm the fans behind it.
        MainActor.assumeIsolated { model.noteWillTerminate() }
        Task.detached {
            _ = await model.shutdownFansAndFlush()
            semaphore.signal()
        }
        // Generous enough to cover the helper's own request timeout, so a slow
        // helper produces a slow quit rather than an unreleased fan.
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            NSLog("[M5Blade] quit: shutdown did not complete within 5s")
        }
    }
}

// Top-level code is nonisolated, but it does run on the main thread — assert that
// and hand the rest of startup to the main actor. `delegate` is a global so it
// outlives the closure: NSApplication.delegate is a weak reference.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
