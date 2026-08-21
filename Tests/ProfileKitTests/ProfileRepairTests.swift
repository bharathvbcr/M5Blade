import XCTest
import FanKit
@testable import ProfileKit

/// Everything a hand-edited or older-build `config.json` can get wrong, and what
/// the app does about it. The rule throughout: correct it, and say so.
final class ProfileRepairTests: XCTestCase {

    // MARK: - Deterministic curve lookup

    /// `fanCurves.values.first` is dictionary order, which is unspecified and
    /// differs between runs of the same binary. A fan with no curve of its own
    /// was therefore getting a randomly chosen one — a nondeterministic input to
    /// a control loop.
    func testCurveLookupForAnUnmappedFanIsDeterministic() {
        let cold = FanCurve(points: [CurvePoint(tempC: 0, percent: 10)])
        let hot = FanCurve(points: [CurvePoint(tempC: 0, percent: 90)])
        let profile = Profile(name: "Two fans", fanCurves: [0: cold, 1: hot])

        for _ in 0..<200 {
            XCTAssertEqual(profile.curve(forFan: 7).percent(at: 50), 10,
                           "fallback must be the lowest fan index, every time")
        }
    }

    func testCurveLookupPrefersAnExactMatch() {
        let cold = FanCurve(points: [CurvePoint(tempC: 0, percent: 10)])
        let hot = FanCurve(points: [CurvePoint(tempC: 0, percent: 90)])
        let profile = Profile(name: "Two fans", fanCurves: [0: cold, 1: hot])
        XCTAssertEqual(profile.curve(forFan: 1).percent(at: 50), 90)
    }

    func testCurveLookupWithNoCurvesAtAllFallsBackToBalanced() {
        let profile = Profile(name: "Empty")
        XCTAssertEqual(profile.curve(forFan: 0).points, FanCurve.balanced.points)
    }

    // MARK: - Repair

    func testEmptyCurveIsReplacedRatherThanCommandingZeroPercent() {
        var config = Configuration(profiles: [
            Profile(name: "Broken", fanCurves: [0: FanCurve(points: [])]),
        ])
        let report = config.reconcile(fanCount: 1)

        let repaired = config.profiles.first { $0.name == "Broken" }
        XCTAssertEqual(repaired?.curve(forFan: 0).points, FanCurve.balanced.points)
        XCTAssertTrue(report.corrections.contains { $0.contains("no points") })
    }

    func testProfileWithNoCurvesGetsOne() {
        var config = Configuration(profiles: [Profile(name: "Bare")])
        let report = config.reconcile(fanCount: 2)
        let repaired = config.profiles.first { $0.name == "Bare" }
        XCTAssertFalse(repaired!.fanCurves.isEmpty)
        XCTAssertTrue(report.corrections.contains { $0.contains("no fan curves") })
    }

    func testStockKeepsItsEmptyCurveSet() {
        var config = Configuration.factoryDefault(fanCount: 2)
        config.reconcile(fanCount: 2)
        let stock = config.profiles.first { $0.id == Profile.stockID }
        XCTAssertTrue(stock!.fanCurves.isEmpty,
                      "Stock releases to macOS; giving it a curve would be meaningless")
    }

    func testOutOfRangeSettingsAreClamped() {
        var config = Configuration(profiles: [
            Profile(name: "Hostile",
                    fanCurves: [0: .balanced],
                    settings: ControlSettings(ceilingPercent: 5000,
                                              hysteresisC: -10,
                                              slewUpRPMPerSec: -400,
                                              slewDownRPMPerSec: 1e9,
                                              smoothingAlpha: 0)),
        ])
        let report = config.reconcile(fanCount: 1)
        let s = config.profiles.first { $0.name == "Hostile" }!.settings
        XCTAssertEqual(s.ceilingPercent, 100)
        XCTAssertEqual(s.hysteresisC, 0)
        XCTAssertEqual(s.slewUpRPMPerSec, 0)
        XCTAssertEqual(s.slewDownRPMPerSec, 10_000)
        XCTAssertEqual(s.smoothingAlpha, 0.01)
        XCTAssertTrue(report.corrections.contains { $0.contains("clamped") })
    }

    func testDuplicateProfileIDsAreRemoved() {
        let id = UUID()
        var config = Configuration(profiles: [
            Profile(id: id, name: "First", fanCurves: [0: .balanced]),
            Profile(id: id, name: "Second", fanCurves: [0: .performance]),
        ])
        let report = config.reconcile(fanCount: 1)
        XCTAssertEqual(config.profiles.filter { $0.id == id }.count, 1)
        XCTAssertTrue(report.corrections.contains { $0.contains("sharing the id") })
    }

    func testDuplicateRuleIDsAreRemoved() {
        let ruleID = UUID()
        var config = Configuration(
            profiles: Profile.builtIns(fanCount: 1),
            rules: [
                Rule(id: ruleID, name: "A", conditions: [.powerSource(.ac)],
                     targetProfileID: Profile.silentID),
                Rule(id: ruleID, name: "B", conditions: [.powerSource(.battery)],
                     targetProfileID: Profile.silentID),
            ])
        config.reconcile(fanCount: 1)
        XCTAssertEqual(config.rules.count, 1)
    }

    func testUnnamedProfileIsNamed() {
        var config = Configuration(profiles: [Profile(name: "   ", fanCurves: [0: .balanced])])
        config.reconcile(fanCount: 1)
        XCTAssertTrue(config.profiles.contains { $0.name == "Unnamed profile" })
    }

    func testNegativeFanIndexCurvesAreDropped() {
        var config = Configuration(profiles: [
            Profile(name: "Odd", fanCurves: [-1: .balanced, 0: .performance]),
        ])
        config.reconcile(fanCount: 1)
        let repaired = config.profiles.first { $0.name == "Odd" }!
        XCTAssertNil(repaired.fanCurves[-1])
        XCTAssertNotNil(repaired.fanCurves[0])
    }

    func testAnEmptyRuleIsReportedRatherThanSilentlyNeverFiring() {
        var config = Configuration(
            profiles: Profile.builtIns(fanCount: 1),
            rules: [Rule(name: "Does nothing", conditions: [], targetProfileID: Profile.silentID)])
        let report = config.reconcile(fanCount: 1)
        XCTAssertTrue(report.warnings.contains { $0.contains("can never match") })
        XCTAssertEqual(report.corrections, [],
                       "the user's rule is theirs — say something, change nothing")
        XCTAssertEqual(config.rules.count, 1)
    }

    func testAFactoryConfigNeedsNoCorrections() {
        var config = Configuration.factoryDefault(fanCount: 2)
        XCTAssertEqual(config.reconcile(fanCount: 2).corrections, [],
                       "the shipped defaults must not trip our own validator")
    }

    func testReconcileIsIdempotent() {
        var config = Configuration(profiles: [
            Profile(name: "", fanCurves: [0: FanCurve(points: [])],
                    settings: ControlSettings(ceilingPercent: -5)),
        ])
        config.reconcile(fanCount: 2)
        let after = config
        XCTAssertEqual(config.reconcile(fanCount: 2).corrections, [],
                       "a repaired config must not keep reporting the same repairs")
        XCTAssertEqual(config, after)
    }
}
