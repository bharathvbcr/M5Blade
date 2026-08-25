import Foundation
import os
import FanKit
import HistoryKit

/// The notification decision the engine reached, already worded.
///
/// Built here rather than at the delivery boundary so a test can assert the
/// exact sentence a user would have been shown, without UserNotifications in
/// the picture.
struct ThrottleAlert: Equatable {
    let title: String
    let body: String
}

/// Decides when sustained throttling or thermal pressure has earned a user
/// notification (DESIGN §3.5, roadmap T-4).
///
/// Pure: every decision is a function of the event stream and the clock, so
/// the rate limiter, the duration threshold, and the coalescing are all
/// testable without touching `UNUserNotificationCenter`. The rules, from the
/// design:
///
/// * An episode must run past a duration threshold before it may alert — most
///   episodes are over within seconds of opening, and a chime for each one is
///   how an alerting feature trains users to ignore it.
/// * At most one notification per 15 minutes; repeats inside the window are
///   folded into the wording ("3rd episode in the last hour") rather than
///   delivered separately.
/// * `.critical` thermal pressure alerts immediately. It is Apple saying so
///   directly — the same fast path the throttle detector grants it — and is
///   still rate-limited, because a machine parked at critical produces a
///   pressure change roughly never but stays there indefinitely.
struct AlertDecisionEngine: Sendable {

    struct Policy: Sendable, Equatable {
        /// How long an episode must be open before it may alert.
        var sustainedSeconds: TimeInterval = 120
        /// Minimum spacing between any two notifications.
        var minimumInterval: TimeInterval = 15 * 60
        /// How far back "Nth episode in the last hour" counts.
        var coalescingWindow: TimeInterval = 3_600
    }

    var policy = Policy()

    private var episodeStart: Date?
    private var alertedForEpisode = false
    private var episodeStarts: [Date] = []
    private var lastAlertedAt: Date?
    private var lastPressure: ThermalPressure = .nominal
    private var lastLossAlertAt: Date?

    mutating func observe(_ event: ThrottleDetector.Event, at now: Date) -> ThrottleAlert? {
        switch event {
        case .none:
            return nil
        case .opened(let episode):
            episodeStarts.append(episode.start)
            pruneStarts(before: now)
            episodeStart = episode.start
            alertedForEpisode = false
            return nil
        case .updated:
            guard let start = episodeStart else { return nil }
            guard now.timeIntervalSince(start) >= policy.sustainedSeconds else { return nil }
            // One alert per episode: the limiter alone would re-alert every
            // 15 minutes for as long as it ran.
            guard !alertedForEpisode else { return nil }
            return alert(now: now)
        case .closed(let episode):
            episodeStart = nil
            alertedForEpisode = false
            // Nothing is appended here: the episode was counted when it
            // *opened*, which is also when any alert fired. Counting the close
            // as well would bill one episode twice.
            _ = episode
            return nil
        }
    }

    mutating func observe(pressure: ThermalPressure, at now: Date) -> ThrottleAlert? {
        guard pressure == .critical else {
            // Recovery and ordinary fluctuation are recorded silently.
            lastPressure = pressure
            return nil
        }
        // Already accounted for: a machine parked at critical stays here for
        // hours, and saying so again adds nothing.
        guard lastPressure != .critical else { return nil }
        guard let alert = alert(
            now: now,
            titleOverride: "Critical thermal pressure",
            bodyOverride: "macOS reports critical thermal pressure. Performance is being "
                + "reduced to protect the hardware.") else { return nil }
        // Set only once the alert actually went out. A rise that arrived inside
        // another alert's rate-limit window has not been reported yet — marking
        // it seen here would leave the user never told at all.
        lastPressure = .critical
        return alert
    }

    /// Why control stopped — the two states worth interrupting someone for,
    /// because both mean the app is no longer doing what it said it was.
    enum ControlLossKind {
        /// The helper dropped or stopped answering while the fans were armed.
        case helperLost
        /// The emergency path released the ceiling to 100%.
        case emergencyCooling
    }

    /// Control was lost mid-drive. Unlike throttling this needs no sustained
    /// gate — the event itself is the emergency — but it keeps its own rate
    /// limiter, because a helper flapping in and out must not stack banners.
    mutating func observeControlLoss(_ kind: ControlLossKind, reason: String,
                                     at now: Date) -> ThrottleAlert? {
        if let last = lastLossAlertAt, now.timeIntervalSince(last) < policy.minimumInterval {
            return nil
        }
        lastLossAlertAt = now
        switch kind {
        case .helperLost:
            return ThrottleAlert(
                title: "Fan control stopped",
                body: "\(reason.prefix(1).uppercased())\(reason.dropFirst()) — macOS is driving the fans.")
        case .emergencyCooling:
            return ThrottleAlert(
                title: "Emergency cooling",
                body: "\(reason.prefix(1).uppercased())\(reason.dropFirst()) — fans released to maximum until temperatures fall.")
        }
    }

    // MARK: - Mechanics

    /// Builds one alert unless the rate limiter refuses. The count includes the
    /// current episode, so a first-ever episode says nothing about hours.
    private mutating func alert(now: Date, titleOverride: String? = nil,
                                bodyOverride: String? = nil) -> ThrottleAlert? {
        if let last = lastAlertedAt, now.timeIntervalSince(last) < policy.minimumInterval {
            return nil
        }
        lastAlertedAt = now
        alertedForEpisode = true
        pruneStarts(before: now)

        let count = episodeStarts.count
        let suffix = count >= 2 ? " \(Self.ordinal(count)) episode in the last hour." : ""
        if let bodyOverride {
            return ThrottleAlert(title: titleOverride ?? "Fan Control", body: bodyOverride + suffix)
        }
        return ThrottleAlert(title: "Sustained thermal throttling",
                             body: "Your Mac has been throttling under load.\(suffix)")
    }

    private mutating func pruneStarts(before date: Date) {
        let cutoff = date.addingTimeInterval(-policy.coalescingWindow)
        episodeStarts.removeAll { $0 < cutoff }
    }

    /// 2nd, 3rd, … — the only ordinals this app needs are small, but 11th–13th
    /// are irregular in English and a machine under sustained compile load can
    /// genuinely get there within an hour.
    static func ordinal(_ n: Int) -> String {
        let irregular: Set = [11, 12, 13]
        let suffix: String
        switch n % 10 {
        case 1 where !irregular.contains(n): suffix = "st"
        case 2 where !irregular.contains(n): suffix = "nd"
        case 3 where !irregular.contains(n): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

/// The slice of `UNUserNotificationCenter` this feature needs.
///
/// A protocol rather than the concrete class: the decision to notify is the
/// testable part, and driving it against the real center would either pop
/// dialogs during tests or silently no-op without a bundle.
protocol UserNotificationDelivering: AnyObject, Sendable {
    /// Requests alert authorization. False when denied or unreachable.
    func requestAuthorization() async -> Bool
    /// Posts one alert. Returns whether it was handed to the system.
    func deliver(_ alert: ThrottleAlert) async -> Bool
}

/// Drives the engine and carries its decisions to `UNUserNotificationCenter`.
///
/// Authorization is requested lazily — on the first alert that wants to fire,
/// not at launch (DESIGN §3.5). It is the only permission prompt in the app,
/// and asking before there is anything to say is how permission prompts become
/// reflex-deny clicks. A denial suppresses delivery but is retried on a slow
/// cadence rather than latched forever: the user who grants permission in
/// System Settings must get their alerts back without relaunching, which the
/// old permanent latch silently refused to allow. Re-asking is not a dialog
/// loop — after the first prompt, `requestAuthorization` only reads settings —
/// and it is rate-limited besides.
@MainActor
final class ThrottleAlerter: ObservableObject {

    /// True when notifications currently cannot reach the user. Surfaced next
    /// to the toggle that offers them; clears itself once a retry succeeds.
    @Published private(set) var authorizationDenied = false

    /// How long after a denial (or any attempt) before another one may be
    /// made. Long enough that nobody could experience it as nagging.
    nonisolated static let authorizationRetryInterval: TimeInterval = 300
    private var lastAuthorizationAttempt: Date?

    private var engine = AlertDecisionEngine()
    private let center: any UserNotificationDelivering
    private let enabledDefaultsKey = "alerts.throttling.enabled"
    private let defaults: UserDefaults
    private static let log = Logger(subsystem: "com.m5blade.app", category: "alerts")

    init(center: any UserNotificationDelivering = LiveNotificationCenter(),
         defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    /// Whether the user wants these notifications at all. On by default — the
    /// design treats alerting as part of the throttle feature, not an add-on —
    /// but a single switch turns it off without touching history or detection.
    var isEnabled: Bool {
        get { defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledDefaultsKey) }
    }

    func observe(_ event: ThrottleDetector.Event, at now: Date = Date()) async {
        guard let alert = engine.observe(event, at: now) else { return }
        await deliverIfPermitted(alert, at: now)
    }

    func observe(pressure: ThermalPressure, at now: Date = Date()) async {
        guard let alert = engine.observe(pressure: pressure, at: now) else { return }
        await deliverIfPermitted(alert, at: now)
    }

    /// Control was lost while this app had been driving the fans. Rides the
    /// same delivery path and toggle as the throttle alerts — one switch means
    /// "tell me when something needs me", not two.
    func controlLost(_ kind: AlertDecisionEngine.ControlLossKind,
                     reason: String, at now: Date = Date()) async {
        guard let alert = engine.observeControlLoss(kind, reason: reason, at: now) else { return }
        await deliverIfPermitted(alert, at: now)
    }

    private func deliverIfPermitted(_ alert: ThrottleAlert, at now: Date = Date()) async {
        guard isEnabled else { return }
        if authorizationDenied {
            guard let last = lastAuthorizationAttempt,
                  now.timeIntervalSince(last) >= Self.authorizationRetryInterval else {
                Self.log.notice("notification suppressed (\(alert.title, privacy: .public)): authorization previously denied")
                return
            }
        }
        lastAuthorizationAttempt = now
        if await center.requestAuthorization() {
            if authorizationDenied {
                // The user granted permission in System Settings. Saying so once
                // in the log beats a UI banner nobody asked for.
                Self.log.notice("notification authorization recovered")
                authorizationDenied = false
            }
        } else {
            authorizationDenied = true
            Self.log.notice("notification not delivered (\(alert.title, privacy: .public)): authorization unavailable")
            return
        }
        _ = await center.deliver(alert)
    }

    /// Exposed for tests: drives the engine without delivering anywhere.
    func observeForTesting(_ event: ThrottleDetector.Event, at now: Date) -> Bool {
        engine.observe(event, at: now) != nil
    }

    func setEnabledForTesting(_ enabled: Bool) {
        isEnabled = enabled
    }
}

#if canImport(UserNotifications)
import UserNotifications

/// The real delivery path. Small on purpose — everything debatable lives in
/// the engine above.
final class LiveNotificationCenter: UserNotificationDelivering, @unchecked Sendable {
    private var requestedAuthorization = false

    func requestAuthorization() async -> Bool {
        // `UNUserNotificationCenter.current()` traps when the process has no
        // app bundle to attach to — exactly the situation in the bare xctest
        // runner, where a simulated helper loss now legitimately reaches this
        // path. Its directory carries a bundle *identifier* but no `.app`
        // wrapper, so that is what gates here: no app bundle means nothing to
        // notify *with*, and the honest answer is "cannot deliver".
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                if !granted { return false }
            } catch {
                return false
            }
        } else {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return false }
        }
        return true
    }

    func deliver(_ alert: ThrottleAlert) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            Self.log.error("deliver failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static let log = Logger(subsystem: "com.m5blade.app", category: "alerts")
}
#endif
