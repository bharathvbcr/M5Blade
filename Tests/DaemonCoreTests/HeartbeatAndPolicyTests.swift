import XCTest
import FanKit
import PowerKit
import DaemonProtocol
@testable import DaemonCore

/// The daemon's clamp is documented as independent of the app so "a bug or a
/// compromise on the app side cannot lower it". That holds only if the
/// *temperature input* gating the floor is itself gated: one finite garbage
/// reading used to switch the floor off entirely, because any value below
/// 60 °C read as "measured, ice cold".
final class HeartbeatAndPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeCore() async -> (DaemonCore, SimulatedFanBackend) {
        var config = SimulatedFanBackend.Config()
        config.fanCount = 1
        let backend = SimulatedFanBackend(config: config)
        let core = DaemonCore(backend: backend)
        _ = await core.start(now: t0)
        return (core, backend)
    }

    /// `TTPD` reads −306783232 °C on this Mac — finite, so it sailed past an
    /// `isFinite` gate as a measurement of absolute zero. Implausible input
    /// must be treated as "no idea", and no-idea floors at 25% (1200–8400 rpm
    /// → 3000).
    func testAnImplausibleHeartbeatTemperatureCannotDisableTheHardFloor() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: -306_783_232, at: t0)

        let result = await core.setTarget(fan: 0, rpm: 1_500, now: t0.addingTimeInterval(1))
        guard case .success(let applied) = result else {
            return XCTFail("expected a clamped write, got \(result)")
        }
        XCTAssertEqual(applied, 3_000, accuracy: 1,
                       "implausible temperature must leave the hard floor engaged")
    }

    /// The control for the test above: a genuinely cool machine still gets the
    /// low target it asked for — plausibility gates absurdity, not quietness.
    func testAPlausibleCoolHeartbeatStillPermitsLowTargets() async {
        let (core, _) = await makeCore()
        _ = await core.setManualMode(fan: 0, enabled: true, now: t0)
        await core.heartbeat(maxTempC: 40, at: t0)

        let result = await core.setTarget(fan: 0, rpm: 1_500, now: t0.addingTimeInterval(1))
        guard case .success(let applied) = result else {
            return XCTFail("expected the write to be accepted")
        }
        XCTAssertEqual(applied, 1_500, accuracy: 1,
                       "a measured cool machine may run its fans low")
    }
}

/// The policy layer's own contract, pinned without root or hardware.
final class ChargeLimitPolicyValidationTests: XCTestCase {

    func testAnUnreportedBatteryIsRefusedNotWrittenTo() {
        // Nil means the battery could not be seen at all — which is not
        // "present": writing firmware charge state on a machine whose battery
        // cannot even be read is a write nobody asked for.
        let result = ChargeLimitPolicy.validate(percent: 80,
                                                support: ChargeLimitSupport(hasAppleSiliconKey: true),
                                                batteryInstalled: nil)
        guard case .failure(.noBattery) = result else {
            return XCTFail("an unreported battery must be refused, got \(result)")
        }
    }

    func testAMeasuredAbsentBatteryIsRefused() {
        let result = ChargeLimitPolicy.validate(percent: 80,
                                                support: ChargeLimitSupport(hasAppleSiliconKey: true),
                                                batteryInstalled: false)
        guard case .failure(.noBattery) = result else {
            return XCTFail("an absent battery must be refused, got \(result)")
        }
    }

    func testAReportedBatteryWithAKeyProceeds() {
        let result = ChargeLimitPolicy.validate(percent: 80,
                                                support: ChargeLimitSupport(hasAppleSiliconKey: true),
                                                batteryInstalled: true)
        guard case .success(let write) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(write.keyName, "CHWA")
    }

    func testDisallowedPercentsAreRefusedBeforeAnythingElse() {
        let result = ChargeLimitPolicy.validate(percent: 90,
                                                support: ChargeLimitSupport(hasAppleSiliconKey: true),
                                                batteryInstalled: true)
        guard case .failure(.unsupportedPercent(90)) = result else {
            return XCTFail("90 is not a writable percent, got \(result)")
        }
    }
}
