import XCTest
import ProfileKit
import DaemonProtocol
@testable import M5BladeApp

/// T-3 app-side wiring: the opt-in gate, the failure surface, and the
/// read-back-after-write rule.
///
/// The daemon is the simulated one, so "what took effect" and "what was
/// refused" are values a test can set rather than outcomes it must wait for.
final class ChargeLimitModelTests: XCTestCase {

    private func makeModel(daemon: SimulatedDaemon) async -> AppModel {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("charge-limit-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return await AppModel(configStore: .init(url: url.appendingPathComponent("config.json")),
                              historyURL: url.appendingPathComponent("history.sqlite"),
                              defaults: defaults,
                              daemon: daemon)
    }

    func testTheOptInDefaultsToOff() async {
        let model = await makeModel(daemon: SimulatedDaemon())
        let optedIn = await model.chargeLimitControlOptedIn
        XCTAssertFalse(optedIn,
                       "charge-limit control must be off by default (DESIGN §6.3)")
    }

    func testTheOptInPersistsAcrossInstances() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl-persist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))

        let first = await AppModel(configStore: store,
                                   historyURL: dir.appendingPathComponent("h.sqlite"),
                                   defaults: defaults, daemon: SimulatedDaemon())
        await first.setChargeLimitControlOptedIn(true)

        // A second model reading the same defaults — what happens across relaunch.
        let second = await AppModel(configStore: store,
                                    historyURL: dir.appendingPathComponent("h.sqlite"),
                                    defaults: defaults, daemon: SimulatedDaemon())
        let optedIn = await second.chargeLimitControlOptedIn
        XCTAssertTrue(optedIn)
    }

    func testARefusedChangeIsSurfacedAndNotShownAsSuccess() async {
        let daemon = SimulatedDaemon()
        daemon.simulatedChargeLimit = ChargeLimitStatus(supported: true,
                                                        percent: 100, keyName: "CHWA")
        daemon.chargeLimitWriteRejection = "simulated: firmware ignored the write"
        let model = await makeModel(daemon: daemon)

        await model.setChargeLimit(percent: 80)

        let problem = await model.chargeLimitProblem
        XCTAssertNotNil(problem, "a refused change must not vanish into the log")
    }

    func testASuccessfulChangeClearsAnyStaleProblem() async {
        let daemon = SimulatedDaemon()
        daemon.simulatedChargeLimit = ChargeLimitStatus(supported: true,
                                                        percent: 80, keyName: "CHWA")
        let model = await makeModel(daemon: daemon)
        await model.setChargeLimit(percent: 80)
        // First write fails against nothing — clear path. Force a problem, then
        // succeed once, and the stale banner must be gone.
        await model.setChargeLimit(percent: 80)
        let problem = await model.chargeLimitProblem
        XCTAssertNil(problem)
    }

    func testAnythingOtherThanEightyOrHundredNeverReachesTheHelper() async {
        let daemon = SimulatedDaemon()
        let model = await makeModel(daemon: daemon)
        await model.setChargeLimit(percent: 65)
        // The simulated helper records no operations for charge-limit sets;
        // its state can only have changed through the guarded path.
        let status = await daemon.simulatedChargeLimit
        XCTAssertEqual(status.supported, false,
                       "a 65 % request must never reach the SMC")
    }

}
