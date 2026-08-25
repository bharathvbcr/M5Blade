import XCTest
import FanKit
import ProfileKit
@testable import M5BladeApp

/// The first request to take the fans from macOS is deferred behind an explicit
/// acknowledgement. The app can damage hardware; the README says so, and now
/// so does the moment before it matters.
///
/// The suites that exercise what happens *after* consent start from an
/// acknowledged fixture (`InMemoryDefaults.acknowledgingControlRisk`). These
/// tests are about the gate itself.
@MainActor
final class ControlConsentTests: XCTestCase {

    private var directory: URL!
    private var daemon: SimulatedDaemon!
    private var model: AppModel!
    private var defaults: InMemoryDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlConsentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        daemon = SimulatedDaemon()
        defaults = InMemoryDefaults()
        model = AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("config.json")),
                         historyURL: directory.appendingPathComponent("history.sqlite"),
                         defaults: defaults,
                         daemon: daemon)
        model.applyForTesting(fans: Fixture.fans(2),
                              readings: Fixture.readings(Fixture.fans(2)),
                              temperatures: Fixture.temperatures(4))
    }

    override func tearDownWithError() throws {
        model = nil
        daemon = nil
        defaults = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func acknowledge() {
        model.confirmControlConsent()
    }

    func testFirstEnableControlIsDeferredAndArmsNothing() async {
        await model.enableControl()
        XCTAssertEqual(model.status, .watching)
        XCTAssertNil(model.pendingControlConsent == nil ? nil : model.controlProblem,
                     "the deferral is not a failure and must not read as one")
        XCTAssertEqual(daemon.armed, [])
        XCTAssertFalse(defaults.bool(forKey: AppModel.controlRiskAcknowledgedKey),
                       "a deferred request is not consent")
        XCTAssertNotNil(model.pendingControlConsent)
    }

    func testConfirmationProceedsExactlyOnceAndPersists() async {
        await model.enableControl()
        XCTAssertNotNil(model.pendingControlConsent)

        acknowledge()
        await model.settleForTesting()

        XCTAssertTrue(defaults.bool(forKey: AppModel.controlRiskAcknowledgedKey))
        XCTAssertEqual(model.status, .controlling)
        XCTAssertEqual(daemon.armed, [0, 1])
        XCTAssertNil(model.pendingControlConsent)

        // A second enable goes straight through — asked once per machine.
        await model.setAutoMode(true)
        await model.settleForTesting()
        await model.enableControl()
        await model.settleForTesting()
        XCTAssertEqual(model.status, .controlling)
        XCTAssertNil(model.pendingControlConsent)
    }

    func testCancellingClearsThePromptWithoutTouchingTheFans() async {
        await model.enableControl()
        XCTAssertNotNil(model.pendingControlConsent)

        model.cancelControlConsent()

        XCTAssertNil(model.pendingControlConsent)
        XCTAssertEqual(model.status, .watching)
        XCTAssertEqual(daemon.armed, [])
        XCTAssertFalse(defaults.bool(forKey: AppModel.controlRiskAcknowledgedKey))

        // And nothing was half-done: a later request defers again.
        await model.enableControl()
        XCTAssertNotNil(model.pendingControlConsent)
    }

    func testSelectingADrivingProfileDefersWithoutPinningIt() throws {
        let profile = try XCTUnwrap(model.profiles.first { $0.id != Profile.stockID && !$0.releasesToSystem })

        model.selectProfile(profile.id)

        XCTAssertNotNil(model.pendingControlConsent)
        XCTAssertEqual(daemon.armed, [])
        XCTAssertEqual(model.status, .watching)
    }

    func testSelectingStockNeedsNoConsent() async {
        let stock = Profile.stockID
        model.selectProfile(stock)
        await model.settleForTesting()

        // Stock hands the fans back — the safe direction, never gated.
        XCTAssertNil(model.pendingControlConsent)
        XCTAssertFalse(daemon.armed.contains(0), "stock releases rather than arms")
    }

    func testTurningAutoOffFromSettingsDefers() async {
        await model.setAutoMode(false)
        XCTAssertNotNil(model.pendingControlConsent)
        XCTAssertEqual(daemon.armed, [])
        XCTAssertEqual(model.autoMode, true, "auto mode stays on until the user agrees")
    }
}
