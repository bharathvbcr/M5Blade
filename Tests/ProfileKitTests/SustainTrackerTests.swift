import XCTest
import FanKit
@testable import ProfileKit

/// The sustain clocks are what stop a profile flapping on every CPU spike, so
/// "continuously" has to mean continuously.
final class SustainTrackerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testDurationGrowsWhileContinuouslyActive() {
        var tracker = SustainTracker()
        tracker.update(activeKeys: ["a"], now: start)
        XCTAssertEqual(tracker.duration("a", now: start), 0, accuracy: 0.001)

        tracker.update(activeKeys: ["a"], now: start.addingTimeInterval(30))
        XCTAssertEqual(tracker.duration("a", now: start.addingTimeInterval(30)),
                       30, accuracy: 0.001)
    }

    /// The whole point: dropping out for one sample resets the clock rather than
    /// resuming where it left off.
    func testGapResetsTheClock() {
        var tracker = SustainTracker()
        tracker.update(activeKeys: ["a"], now: start)
        tracker.update(activeKeys: ["a"], now: start.addingTimeInterval(50))
        XCTAssertEqual(tracker.duration("a", now: start.addingTimeInterval(50)), 50, accuracy: 0.001)

        tracker.update(activeKeys: [], now: start.addingTimeInterval(55))
        XCTAssertEqual(tracker.duration("a", now: start.addingTimeInterval(55)), 0)

        tracker.update(activeKeys: ["a"], now: start.addingTimeInterval(60))
        XCTAssertEqual(tracker.duration("a", now: start.addingTimeInterval(70)),
                       10, accuracy: 0.001, "clock resumed instead of restarting")
    }

    func testKeysAreTrackedIndependently() {
        var tracker = SustainTracker()
        tracker.update(activeKeys: ["a"], now: start)
        tracker.update(activeKeys: ["a", "b"], now: start.addingTimeInterval(20))
        let now = start.addingTimeInterval(40)
        tracker.update(activeKeys: ["a", "b"], now: now)
        XCTAssertEqual(tracker.duration("a", now: now), 40, accuracy: 0.001)
        XCTAssertEqual(tracker.duration("b", now: now), 20, accuracy: 0.001)
    }

    func testUnknownKeyIsZeroNotNil() {
        let tracker = SustainTracker()
        XCTAssertEqual(tracker.duration("never-seen", now: start), 0)
    }

    /// Inactive keys must not accumulate forever in a process that runs for weeks.
    func testInactiveKeysAreDropped() {
        var tracker = SustainTracker()
        tracker.update(activeKeys: ["a", "b", "c"], now: start)
        XCTAssertEqual(tracker.trackedKeys.count, 3)
        tracker.update(activeKeys: ["b"], now: start.addingTimeInterval(5))
        XCTAssertEqual(tracker.trackedKeys, ["b"])
    }

    // MARK: - The conditions these clocks feed

    /// End to end: a process rule matches only once both the sustain window and
    /// the instantaneous CPU threshold are met.
    func testProcessRuleNeedsBothSustainAndInstantaneousCPU() {
        let rule = Rule(name: "compile",
                        conditions: [.processActive(match: .executableName("swift-frontend"),
                                                    sustainedCPU: 100, forSeconds: 15)],
                        targetProfileID: Profile.performanceID)

        // Busy right now, but only just started.
        let tooEarly = SystemState(maxTempC: 50, processes: [
            ProcessSnapshot(pid: 1, executableName: "swift-frontend",
                            cpuPercent: 300, activeFor: 5)
        ])
        XCTAssertFalse(rule.matches(tooEarly))

        // Long-running but idle.
        let tooCold = SystemState(maxTempC: 50, processes: [
            ProcessSnapshot(pid: 1, executableName: "swift-frontend",
                            cpuPercent: 20, activeFor: 600)
        ])
        XCTAssertFalse(rule.matches(tooCold))

        let justRight = SystemState(maxTempC: 50, processes: [
            ProcessSnapshot(pid: 1, executableName: "swift-frontend",
                            cpuPercent: 300, activeFor: 20)
        ])
        XCTAssertTrue(rule.matches(justRight))
    }

    func testThermalRuleMatchesAtOrAboveTheLevel() {
        let rule = Rule(name: "hot", conditions: [.thermalAtLeast(.serious)],
                        targetProfileID: Profile.maxCoolingID)
        XCTAssertFalse(rule.matches(SystemState(thermalPressure: .fair)))
        XCTAssertTrue(rule.matches(SystemState(thermalPressure: .serious)))
        XCTAssertTrue(rule.matches(SystemState(thermalPressure: .critical)))
    }

    func testIncompleteConditionsAreFlagged() {
        XCTAssertTrue(Condition.processActive(match: .executableName(""),
                                              sustainedCPU: 50, forSeconds: 10).isIncomplete)
        XCTAssertFalse(Condition.processActive(match: .executableName("clang"),
                                               sustainedCPU: 50, forSeconds: 10).isIncomplete)
        XCTAssertTrue(Rule(name: "empty", conditions: [],
                           targetProfileID: Profile.balancedID).isIncomplete)
    }
}
