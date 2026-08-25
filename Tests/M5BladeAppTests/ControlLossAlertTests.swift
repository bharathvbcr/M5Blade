import XCTest
import FanKit
import ProfileKit
import HistoryKit
@testable import M5BladeApp

/// Control lost mid-drive must reach the user even with every window closed.
///
/// The status-item glyph changing was the only signal when the helper dropped
/// while the fans were armed — and a glyph is invisible behind a closed
/// popover. These tests pin the two halves: the pure decision (which states
/// alert, how they are worded, how they are limited) and the one transition
/// hook that fires them (`setStatus`, the single writer of control state).
final class ControlLossAlertTests: XCTestCase {

    // MARK: - Decision engine

    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    func testAHelperLossAlertsImmediatelyWithTheRecoveryStated() throws {
        var engine = AlertDecisionEngine()
        let alert = try XCTUnwrap(engine.observeControlLoss(.helperLost,
                                              reason: "connection to the helper dropped",
                                              at: start))
        XCTAssertEqual(alert.title, "Fan control stopped")
        XCTAssertTrue(alert.body.hasPrefix("Connection to the helper dropped"),
                      "the reason is the user's first question, so it leads: \(alert.body)")
        XCTAssertTrue(alert.body.contains("macOS is driving the fans"),
                      "what happened to the fans is the second question: \(alert.body)")
    }

    func testEmergencyCoolingSaysWhatTheFansAreDoing() {
        var engine = AlertDecisionEngine()
        let alert = engine.observeControlLoss(.emergencyCooling,
                                              reason: "critical temperature",
                                              at: start)
        XCTAssertEqual(alert?.title, "Emergency cooling")
        XCTAssertTrue(alert?.body.contains("fans released to maximum") == true)
    }

    /// A helper that flaps — dropped, re-armed, dropped again inside minutes —
    /// must not stack notifications. One per limiter window; the popover banner
    /// carries the live state meanwhile.
    func testControlLossAlertsAreRateLimited() {
        var engine = AlertDecisionEngine()
        XCTAssertNotNil(engine.observeControlLoss(.helperLost, reason: "dropped", at: start))
        XCTAssertNil(engine.observeControlLoss(.helperLost, reason: "dropped again",
                                               at: start.addingTimeInterval(60)))
        XCTAssertNil(engine.observeControlLoss(.emergencyCooling, reason: "hot",
                                               at: start.addingTimeInterval(engine.policy.minimumInterval - 1)))
        XCTAssertNotNil(engine.observeControlLoss(.helperLost, reason: "dropped once more",
                                                  at: start.addingTimeInterval(engine.policy.minimumInterval)))
    }

    func testControlLossAndThrottleLimitersAreIndependent() {
        var engine = AlertDecisionEngine()
        _ = engine.observe(.opened(ThrottleEpisode(start: start)), at: start)
        XCTAssertNotNil(engine.observe(
            .updated(ThrottleEpisode(start: start)),
            at: start.addingTimeInterval(engine.policy.sustainedSeconds)))

        // A throttle alert moments earlier does not silence a control loss:
        // they answer different questions, and the control one may not wait a
        // quarter hour to be asked.
        XCTAssertNotNil(engine.observeControlLoss(.helperLost, reason: "dropped",
                                                  at: start.addingTimeInterval(5)))
    }

    // MARK: - The transition hook

    @MainActor
    func testLosingAnArmedHelperNotifiesExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlLossAlertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = FakeCenter()
        let daemon = SimulatedDaemon()
        let model = AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("config.json")),
                             historyURL: directory.appendingPathComponent("history.sqlite"),
                             defaults: InMemoryDefaults.acknowledgingControlRisk(),
                             daemon: daemon,
                             alerter: ThrottleAlerter(center: center,
                                                      defaults: InMemoryDefaults.acknowledgingControlRisk()))
        model.applyForTesting(fans: Fixture.fans(2),
                              readings: Fixture.readings(Fixture.fans(2)),
                              temperatures: Fixture.temperatures(4))

        await model.enableControl()
        await model.settleForTesting()
        XCTAssertEqual(model.status, .controlling, "fixture must be driving before it can lose anything")
        XCTAssertTrue(center.delivered.isEmpty)

        // The helper's connection dies. `onDisconnect` carries the model's own
        // recovery logic; invoking it is exactly what XPC would do. The handler
        // and the delivery both hop onto the main actor, so drain the queue
        // until either the alert lands or the bound is spent — a fixed number
        // of yields would be a once-a-week failure on a loaded machine.
        let generation = daemon.currentGeneration
        daemon.onDisconnect?(generation)
        var delivered: [ThrottleAlert] = []
        for _ in 0..<1_000 {
            await model.settleForTesting()
            delivered = center.delivered
            if !delivered.isEmpty { break }
            await Task.yield()
        }

        XCTAssertEqual(model.status, .daemonUnavailable)
        XCTAssertEqual(delivered.count, 1, "one loss, one notification: \(delivered)")
        XCTAssertEqual(delivered.first?.title, "Fan control stopped")

        // A deliberate hand-back never alerts: Stock is the safe direction.
        center.clearForTesting()
        model.selectProfile(Profile.stockID)
        await model.settleForTesting()
        XCTAssertTrue(center.delivered.isEmpty, "choosing macOS control is not a fault")
    }
}

// The delivery fake shared with ThrottleAlerterTests lives there; this file
// keeps its own so the two suites can run in isolation.
private final class FakeCenter: UserNotificationDelivering, @unchecked Sendable {
    var authorized = true
    private(set) var delivered: [ThrottleAlert] = []

    fileprivate func requestAuthorization() async -> Bool { authorized }
    fileprivate func deliver(_ alert: ThrottleAlert) async -> Bool {
        delivered.append(alert)
        return true
    }
    fileprivate func clearForTesting() { delivered.removeAll() }
}
