import XCTest
@testable import DaemonProtocol

/// The daemon re-clamps every request on the assumption that the app is
/// compromised (AUDIT A-2), so this policy is load-bearing on its own.
final class ClampTests: XCTestCase {

    private let minRPM = 1350.0
    private let maxRPM = 5349.0

    private func clamp(_ rpm: Double, tempC: Double) -> Double {
        DaemonConstants.clampRPM(rpm, minRPM: minRPM, maxRPM: maxRPM,
                                 temperature: .measured(tempC))
    }

    private func clampUnknownTemperature(_ rpm: Double) -> Double {
        DaemonConstants.clampRPM(rpm, minRPM: minRPM, maxRPM: maxRPM, temperature: .unknown)
    }

    private var hardFloorRPM: Double {
        minRPM + (DaemonConstants.hardFloorPercent / 100) * (maxRPM - minRPM)
    }

    func testHardFloorAppliesAtOrAboveThreshold() {
        XCTAssertEqual(clamp(0, tempC: DaemonConstants.hardFloorTempC),
                       hardFloorRPM, accuracy: 0.001)
        XCTAssertEqual(clamp(0, tempC: 95), hardFloorRPM, accuracy: 0.001)
    }

    /// A zero request is honoured below the threshold — that is how the fans get
    /// to idle at all on Apple Silicon.
    func testZeroIsAllowedBelowThreshold() {
        XCTAssertEqual(clamp(0, tempC: 59.9), 0, accuracy: 0.001)
    }

    func testAppRequestBelowTheFloorIsRaised() {
        let sneaky = clamp(1, tempC: 80)
        XCTAssertEqual(sneaky, hardFloorRPM, accuracy: 0.001,
                       "daemon accepted a target below its own hard floor")
    }

    func testNegativeRequestIsFlooredNotPassedThrough() {
        XCTAssertGreaterThanOrEqual(clamp(-5000, tempC: 30), 0)
        XCTAssertEqual(clamp(-5000, tempC: 80), hardFloorRPM, accuracy: 0.001)
    }

    func testOverspeedIsCapped() {
        XCTAssertEqual(clamp(999_999, tempC: 80),
                       maxRPM * DaemonConstants.overspeedAllowance, accuracy: 0.001)
    }

    /// Total function: no input escapes the envelope.
    func testResultIsAlwaysWithinEnvelope() {
        let cap = maxRPM * DaemonConstants.overspeedAllowance
        for rpm in stride(from: -10_000.0, through: 20_000.0, by: 250) {
            for temp in stride(from: 0.0, through: 110.0, by: 5) {
                let result = clamp(rpm, tempC: temp)
                XCTAssertGreaterThanOrEqual(result, 0)
                XCTAssertLessThanOrEqual(result, cap)
                if temp >= DaemonConstants.hardFloorTempC {
                    XCTAssertGreaterThanOrEqual(result, hardFloorRPM - 0.001,
                                                "floor breached at \(temp)°C")
                }
            }
        }
    }

    /// A degenerate range must not produce a negative floor.
    func testInvertedRangeDoesNotProduceNegativeFloor() {
        let result = DaemonConstants.clampRPM(0, minRPM: 5000, maxRPM: 1000,
                                              temperature: .measured(80))
        XCTAssertGreaterThanOrEqual(result, 0)
    }

    // MARK: - Unknown temperature

    /// The regression that motivated `TemperatureEvidence`. The daemon used to
    /// hold `lastReportedTemp = 0` until a heartbeat arrived, so a client that
    /// never sent one — or stopped sending them — got *no floor at all*, in
    /// exactly the situation where the floor is the only protection left.
    func testUnknownTemperatureAppliesTheFloor() {
        XCTAssertEqual(clampUnknownTemperature(0), hardFloorRPM, accuracy: 0.001)
        XCTAssertEqual(clampUnknownTemperature(-1), hardFloorRPM, accuracy: 0.001)
    }

    func testUnknownTemperatureStillCapsOverspeed() {
        XCTAssertEqual(clampUnknownTemperature(999_999),
                       maxRPM * DaemonConstants.overspeedAllowance, accuracy: 0.001)
    }

    func testEvidenceTreatsAStaleOrAbsentHeartbeatAsUnknown() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(TemperatureEvidence.from(lastHeartbeat: nil, now: t0), .unknown)
        XCTAssertEqual(TemperatureEvidence.from(lastHeartbeat: (70, t0), now: t0), .measured(70))
        XCTAssertEqual(TemperatureEvidence.from(lastHeartbeat: (70, t0),
                                                now: t0.addingTimeInterval(DaemonConstants.watchdogTimeout + 0.1)),
                       .unknown)
        XCTAssertEqual(TemperatureEvidence.from(lastHeartbeat: (.nan, t0), now: t0), .unknown)
        // Clock moved backwards: the reading is "from the future" and is not evidence.
        XCTAssertEqual(TemperatureEvidence.from(lastHeartbeat: (70, t0.addingTimeInterval(60)), now: t0),
                       .unknown)
    }
}
