import XCTest
import FanKit
import HistoryKit
@testable import M5BladeApp

/// T-4 / DESIGN §3.5: notifications fire for *sustained* throttling and for
/// `.critical` pressure, and never more often than the design allows.
///
/// The decision engine is pure, so every rate-limit and coalescing rule is
/// pinned against exact dates rather than sleeps. The delivery path is driven
/// through a fake center, so "what would have been posted" is a value a test
/// can hold — no authorization dialog, no bundle, no flake.
final class ThrottleAlerterTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func episode(start: Date, end: Date? = nil) -> ThrottleEpisode {
        ThrottleEpisode(start: start, end: end)
    }

    // MARK: - Duration threshold

    func testAFreshlyOpenedEpisodeDoesNotAlert() {
        var engine = AlertDecisionEngine()
        XCTAssertNil(engine.observe(.opened(episode(start: start)), at: start))
        XCTAssertNil(engine.observe(.updated(episode(start: start)), at: start.addingTimeInterval(30)))
    }

    func testAnEpisodePastTheSustainedThresholdAlerts() {
        var engine = AlertDecisionEngine()
        _ = engine.observe(.opened(episode(start: start)), at: start)
        // 119 s: one second under the threshold. Off-by-one bugs in an alert
        // threshold are invisible until someone compares them to the wording.
        XCTAssertNil(engine.observe(.updated(episode(start: start)),
                                    at: start.addingTimeInterval(engine.policy.sustainedSeconds - 1)))
        let alert = engine.observe(.updated(episode(start: start)),
                                   at: start.addingTimeInterval(engine.policy.sustainedSeconds))
        XCTAssertNotNil(alert)
    }

    func testOneEpisodeAlertsAtMostOnce() {
        var engine = AlertDecisionEngine()
        _ = engine.observe(.opened(episode(start: start)), at: start)
        let first = engine.observe(
            .updated(episode(start: start)),
            at: start.addingTimeInterval(engine.policy.sustainedSeconds))
        XCTAssertNotNil(first)
        // An hour later and still running — still the same episode.
        XCTAssertNil(engine.observe(
            .updated(episode(start: start)),
            at: start.addingTimeInterval(engine.policy.sustainedSeconds + 3_600)))
    }

    func testAClosedEpisodeMayAlertAgainWhenItReopens() {
        var engine = AlertDecisionEngine()
        _ = engine.observe(.opened(episode(start: start)), at: start)
        _ = engine.observe(.updated(episode(start: start)),
                           at: start.addingTimeInterval(engine.policy.sustainedSeconds))
        // Closing resets per-episode state…
        _ = engine.observe(.closed(episode(start: start, end: start.addingTimeInterval(600))),
                           at: start.addingTimeInterval(700))
        // …but the 15-minute limiter still governs the next alert. The first
        // alert was stamped at `sustainedSeconds`, so the limiter lifts at
        // sustainedSeconds + minimumInterval — not at minimumInterval alone.
        XCTAssertNil(engine.observe(.opened(episode(start: start.addingTimeInterval(800))),
                                    at: start.addingTimeInterval(800)))
        XCTAssertNil(engine.observe(
            .updated(episode(start: start.addingTimeInterval(800))),
            at: start.addingTimeInterval(engine.policy.sustainedSeconds + engine.policy.minimumInterval - 1)))
        let alert = engine.observe(
            .updated(episode(start: start.addingTimeInterval(800))),
            at: start.addingTimeInterval(engine.policy.sustainedSeconds + engine.policy.minimumInterval))
        XCTAssertNotNil(alert)
    }

    // MARK: - Rate limiting

    func testTwoEpisodesInsideTheRateLimitProduceOneAlert() {
        var engine = AlertDecisionEngine()
        _ = engine.observe(.opened(episode(start: start)), at: start)
        let first = engine.observe(
            .updated(episode(start: start)),
            at: start.addingTimeInterval(engine.policy.sustainedSeconds))
        XCTAssertNotNil(first)

        _ = engine.observe(.closed(episode(start: start, end: start.addingTimeInterval(200))),
                           at: start.addingTimeInterval(300))
        let reopen = start.addingTimeInterval(400)
        _ = engine.observe(.opened(episode(start: reopen)), at: reopen)
        // Past its own duration threshold, but inside the global limiter.
        XCTAssertNil(engine.observe(
            .updated(episode(start: reopen)),
            at: reopen.addingTimeInterval(engine.policy.sustainedSeconds)))
        // Still inside the window measured from the first alert.
        XCTAssertNil(engine.observe(
            .updated(episode(start: reopen)),
            at: start.addingTimeInterval(engine.policy.minimumInterval + 1)))
        // The limiter is measured from the last alert, so the earliest the
        // second one can fire is sustainedSeconds + minimumInterval.
        let third = engine.observe(
            .updated(episode(start: reopen)),
            at: start.addingTimeInterval(engine.policy.sustainedSeconds
                                           + engine.policy.minimumInterval))
        XCTAssertNotNil(third)
    }

    // MARK: - Coalescing

    func testRepeatedEpisodesAreCountedInTheWording() throws {
        var engine = AlertDecisionEngine()

        func runShortEpisode(openedAt: Date) {
            _ = engine.observe(.opened(episode(start: openedAt)), at: openedAt)
            _ = engine.observe(.closed(episode(start: openedAt,
                                               end: openedAt.addingTimeInterval(60))),
                               at: openedAt.addingTimeInterval(120))
        }
        // Two finished episodes inside the hour; the limiter suppresses their
        // alerts (each fires under two minutes of open time or inside the
        // window), but both count toward the coalescing of the third.
        runShortEpisode(openedAt: start)
        runShortEpisode(openedAt: start.addingTimeInterval(600))

        let thirdStart = start.addingTimeInterval(1_200)
        _ = engine.observe(.opened(episode(start: thirdStart)), at: thirdStart)
        let alert = try XCTUnwrap(engine.observe(
            .updated(episode(start: thirdStart)),
            at: thirdStart.addingTimeInterval(engine.policy.sustainedSeconds)))
        XCTAssertTrue(alert.body.contains("3rd episode in the last hour"),
                      "unexpected wording: \(alert.body)")
    }

    func testASingleEpisodeNeverClaimsToBePartOfASequence() throws {
        var engine = AlertDecisionEngine()
        _ = engine.observe(.opened(episode(start: start)), at: start)
        let alert = try XCTUnwrap(engine.observe(
            .updated(episode(start: start)),
            at: start.addingTimeInterval(engine.policy.sustainedSeconds)))
        XCTAssertFalse(alert.body.lowercased().contains("episode in the last hour"))
    }

    func testOldEpisodesFallOutOfTheHourWindow() {
        var engine = AlertDecisionEngine()
        func runShortEpisode(openedAt: Date) {
            _ = engine.observe(.opened(episode(start: openedAt)), at: openedAt)
            _ = engine.observe(.closed(episode(start: openedAt,
                                               end: openedAt.addingTimeInterval(60))),
                               at: openedAt.addingTimeInterval(120))
        }
        runShortEpisode(openedAt: start)
        runShortEpisode(openedAt: start.addingTimeInterval(600))

        // Three hours later nothing from that burst remains to count.
        let late = start.addingTimeInterval(3 * 3_600)
        _ = engine.observe(.opened(episode(start: late)), at: late)
        let alert = engine.observe(.updated(episode(start: late)),
                                   at: late.addingTimeInterval(engine.policy.sustainedSeconds))
        guard let alert else { return XCTFail("expected an alert") }
        XCTAssertFalse(alert.body.contains("episode in the last hour"),
                       "episodes from three hours ago were counted: \(alert.body)")
    }

    // MARK: - Critical thermal pressure

    func testCriticalPressureAlertsImmediatelyWithoutALoadGate() {
        var engine = AlertDecisionEngine()
        let alert = engine.observe(pressure: .critical, at: start)
        XCTAssertNotNil(alert)
    }

    func testCriticalPressureAlertsOnlyOnEscalation() {
        var engine = AlertDecisionEngine()
        _ = engine.observe(pressure: .critical, at: start)
        // Still critical a minute later — already alerted, not news.
        XCTAssertNil(engine.observe(pressure: .critical, at: start.addingTimeInterval(60)))
        // Recovery is deliberately silent.
        XCTAssertNil(engine.observe(pressure: .nominal, at: start.addingTimeInterval(120)))
        XCTAssertNil(engine.observe(pressure: .serious, at: start.addingTimeInterval(180)))
    }

    func testEscalatingBackToCriticalRespectsTheRateLimiter() {
        var engine = AlertDecisionEngine()
        _ = engine.observe(pressure: .critical, at: start)
        _ = engine.observe(pressure: .serious, at: start.addingTimeInterval(60))
        // Back to critical five minutes later: inside the 15-minute window.
        XCTAssertNil(engine.observe(pressure: .critical,
                                    at: start.addingTimeInterval(engine.policy.minimumInterval - 300)))
        let alert = engine.observe(pressure: .critical,
                                   at: start.addingTimeInterval(engine.policy.minimumInterval + 1))
        XCTAssertNotNil(alert)
    }

    func testPressureChangesDoNotResetTheEpisodeLimiter() {
        var engine = AlertDecisionEngine()
        _ = engine.observe(.opened(episode(start: start)), at: start)
        let alert = engine.observe(.updated(episode(start: start)),
                                   at: start.addingTimeInterval(engine.policy.sustainedSeconds))
        XCTAssertNotNil(alert)
        // A pressure escalation right after an episode alert must not double up.
        XCTAssertNil(engine.observe(pressure: .critical,
                                    at: start.addingTimeInterval(engine.policy.sustainedSeconds + 10)))
    }

    // MARK: - Wording

    func testOrdinalsFollowEnglishIrregulars() {
        XCTAssertEqual(AlertDecisionEngine.ordinal(1), "1st")
        XCTAssertEqual(AlertDecisionEngine.ordinal(2), "2nd")
        XCTAssertEqual(AlertDecisionEngine.ordinal(3), "3rd")
        XCTAssertEqual(AlertDecisionEngine.ordinal(4), "4th")
        XCTAssertEqual(AlertDecisionEngine.ordinal(11), "11th")
        XCTAssertEqual(AlertDecisionEngine.ordinal(12), "12th")
        XCTAssertEqual(AlertDecisionEngine.ordinal(13), "13th")
        XCTAssertEqual(AlertDecisionEngine.ordinal(21), "21st")
        XCTAssertEqual(AlertDecisionEngine.ordinal(22), "22nd")
    }

    // MARK: - Delivery path

    private final class FakeCenter: UserNotificationDelivering, @unchecked Sendable {
        var authorized = true
        private(set) var authorizationRequests = 0
        private(set) var delivered: [ThrottleAlert] = []

        func requestAuthorization() async -> Bool {
            authorizationRequests += 1
            return authorized
        }
        func deliver(_ alert: ThrottleAlert) async -> Bool {
            delivered.append(alert)
            return true
        }
    }

    private func makeInput(cpu: Double, pressure: ThermalPressure, date: Date) -> ThrottleDetector.Input {
        ThrottleDetector.Input(date: date, cpuPercent: cpu, pressure: pressure,
                               maxTempC: nil, fanNearCeiling: true,
                               profileName: "Balanced")
    }

    func testAnEndToEndSustainedEpisodeReachesTheCenterExactlyOnce() async {
        let center = FakeCenter()
        let alerter = await ThrottleAlerter(center: center)
        var detector = ThrottleDetector()

        // Drive the real detector with hot, loaded input so the event stream
        // is the production one rather than hand-assembled cases.
        var date = start
        var event = ThrottleDetector.Event.none
        for step in 0..<180 {
            date = start.addingTimeInterval(TimeInterval(step))
            event = detector.update(makeInput(cpu: 85, pressure: .serious, date: date))
            if case .none = event { continue }
            await alerter.observe(event, at: date)
        }
        let delivered = await center.delivered
        // The detector opens after ~20 s (gate) + declares on serious; the
        // alert lands once the episode crosses 120 s. Exactly one notification.
        guard case .updated = event else { return XCTFail("detector never declared: \(event)") }
        XCTAssertEqual(delivered.count, 1, "expected exactly one alert, got \(delivered)")
        XCTAssertEqual(delivered.first?.title, "Sustained thermal throttling")
    }

    /// A denial suppresses delivery without re-asking inside the cooldown —
    /// no dialog loop — but it is no longer latched for the process lifetime.
    /// The old behavior stranded every user who denied once and later granted
    /// permission in System Settings: alerts stayed dead until relaunch, while
    /// this tab's own banner told them that granting would turn them on.
    ///
    /// Event spacing respects the engine's own 15-minute alert limiter, so the
    /// dates below drive the *delivery* path rather than being swallowed by
    /// the decision engine first.
    func testADeniedAuthorizationIsRetriedAtACooldownNotEveryAlert() async {
        let cadence = max(ThrottleAlerter.authorizationRetryInterval,
                          AlertDecisionEngine().policy.minimumInterval)
        let center = FakeCenter()
        center.authorized = false
        let alerter = await ThrottleAlerter(center: center)

        await alerter.observe(pressure: .critical, at: start)
        let requests = await center.authorizationRequests
        XCTAssertEqual(requests, 1)
        let delivered = await center.delivered
        XCTAssertTrue(delivered.isEmpty)

        // Past both the cooldown and the engine's limiter: exactly one retry.
        // The nominal reading first resets the engine's rising-edge gate —
        // a machine parked at critical is told once and not again.
        await alerter.observe(pressure: .nominal, at: start.addingTimeInterval(cadence))
        await alerter.observe(pressure: .critical, at: start.addingTimeInterval(cadence + 1))
        let retries = await center.authorizationRequests
        XCTAssertEqual(retries, 2)
        let stillDenied = await alerter.authorizationDenied
        XCTAssertTrue(stillDenied)
    }

    /// Granting permission in System Settings takes effect mid-session.
    func testAGrantedPermissionRecoversWithoutRelaunch() async {
        let cadence = max(ThrottleAlerter.authorizationRetryInterval,
                          AlertDecisionEngine().policy.minimumInterval)
        let center = FakeCenter()
        center.authorized = false
        let alerter = await ThrottleAlerter(center: center)
        await alerter.observe(pressure: .critical, at: start)
        var denied = await alerter.authorizationDenied
        XCTAssertTrue(denied)

        // The user flips the switch in System Settings, then a fresh episode
        // begins (nominal first — the pressure path alerts on rising edges).
        center.authorized = true
        await alerter.observe(pressure: .nominal, at: start.addingTimeInterval(cadence))
        let later = start.addingTimeInterval(cadence + 1)
        await alerter.observe(pressure: .critical, at: later)
        let delivered = await center.delivered
        XCTAssertGreaterThanOrEqual(delivered.count, 1,
                                    "a recovered authorization must deliver again")
        denied = await alerter.authorizationDenied
        XCTAssertFalse(denied)
    }

    func testTheToggleOffMeansNothingIsRequestedOrDelivered() async {
        let center = FakeCenter()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let alerter = await ThrottleAlerter(center: center, defaults: defaults)
        await alerter.setEnabledForTesting(false)

        await alerter.observe(pressure: .critical, at: start)
        let requests = await center.authorizationRequests
        XCTAssertEqual(requests, 0, "a disabled feature must not ask for permission")
        let delivered = await center.delivered
        XCTAssertTrue(delivered.isEmpty)
    }

    func testTheToggleDefaultsToOn() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let alerter = await ThrottleAlerter(defaults: defaults)
        let enabled = await alerter.isEnabled
        XCTAssertTrue(enabled)
    }
}
