import XCTest
import FanKit
@testable import ProfileKit

final class ConfigurationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FanControlTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ConfigStore {
        ConfigStore(url: directory.appendingPathComponent("config.json"))
    }

    // MARK: - Round trip

    /// Curves are hand-authored work. If they don't survive a save/load cycle the
    /// entire editor is pointless.
    func testRoundTripPreservesCurvesRulesAndDefault() throws {
        let store = makeStore()
        var config = Configuration.factoryDefault(fanCount: 2)

        let custom = FanCurve(points: [
            CurvePoint(tempC: 40, percent: 10),
            CurvePoint(tempC: 90, percent: 88),
        ])
        config.profiles[0].fanCurves[1] = custom
        config.profiles[0].settings.ceilingPercent = 73
        config.rules = [
            Rule(name: "xcode",
                 conditions: [.processActive(match: .executableName("swift-frontend"),
                                             sustainedCPU: 150, forSeconds: 20),
                              .thermalAtLeast(.fair)],
                 targetProfileID: Profile.performanceID,
                 minDwell: 45, debounce: 7)
        ]
        config.defaultProfileID = Profile.silentID

        try store.save(config)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.profiles[0].fanCurves[1], custom)
        XCTAssertEqual(loaded.rules.first?.conditions.count, 2)
        XCTAssertEqual(loaded.defaultProfileID, Profile.silentID)
    }

    /// `[Int: FanCurve]` is the one shape in the document with a non-obvious
    /// Codable representation, so it gets its own check.
    func testPerFanCurveKeysSurviveEncoding() throws {
        let store = makeStore()
        var config = Configuration.factoryDefault(fanCount: 4)
        for fan in 0..<4 {
            config.profiles[1].fanCurves[fan] = FanCurve(points: [
                CurvePoint(tempC: 50, percent: Double(fan * 10)),
                CurvePoint(tempC: 90, percent: Double(fan * 10) + 40),
            ])
        }
        try store.save(config)
        let loaded = try XCTUnwrap(store.load())
        for fan in 0..<4 {
            let curve = try XCTUnwrap(loaded.profiles[1].fanCurves[fan], "fan \(fan) curve lost")
            XCTAssertEqual(curve.percent(at: 50), Double(fan * 10), accuracy: 0.001)
        }
    }

    func testLoadReturnsNilWhenNothingSavedYet() throws {
        XCTAssertNil(try makeStore().load())
    }

    // MARK: - Reconcile

    func testReconcileReaddsMissingBuiltIn() {
        var config = Configuration(profiles: [], rules: [])
        config.reconcile(fanCount: 2)
        XCTAssertEqual(Set(config.profiles.map(\.id)),
                       Set(Profile.builtIns(fanCount: 2).map(\.id)))
    }

    /// A rule pointing at a deleted profile would resolve to a profile that
    /// doesn't exist — silently never applying.
    func testReconcileDropsRulesTargetingUnknownProfiles() {
        var config = Configuration.factoryDefault(fanCount: 1)
        config.rules = [
            Rule(name: "orphan", conditions: [.powerSource(.ac)], targetProfileID: UUID()),
            Rule(name: "valid", conditions: [.powerSource(.ac)],
                 targetProfileID: Profile.silentID),
        ]
        config.reconcile(fanCount: 1)
        XCTAssertEqual(config.rules.map(\.name), ["valid"])
    }

    func testReconcileResetsUnknownDefaultProfile() {
        var config = Configuration.factoryDefault(fanCount: 1)
        config.defaultProfileID = UUID()
        config.reconcile(fanCount: 1)
        XCTAssertEqual(config.defaultProfileID, Profile.balancedID)
    }

    /// A stored profile must not be able to claim built-in status and thereby
    /// make itself undeletable.
    func testReconcileCorrectsForgedBuiltInFlag() {
        var config = Configuration.factoryDefault(fanCount: 1)
        config.profiles.append(Profile(name: "forged", isBuiltIn: true))
        config.reconcile(fanCount: 1)
        XCTAssertEqual(config.profiles.first { $0.name == "forged" }?.isBuiltIn, false)
    }

    // MARK: - Corruption

    /// Hand-authored curves must not be destroyed by a decode failure.
    func testCorruptConfigFallsBackAndKeepsTheOriginalFile() throws {
        let store = makeStore()
        try Data("{ not json".utf8).write(to: store.url)

        let result = store.loadOrDefault(fanCount: 2)
        XCTAssertNotNil(result.problem, "a corrupt config must be reported, not swallowed")
        XCTAssertEqual(Set(result.configuration.profiles.map(\.id)),
                       Set(Profile.builtIns(fanCount: 2).map(\.id)))

        let kept = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("invalid") }
        XCTAssertEqual(kept.count, 1, "the unreadable file should be preserved, not deleted")
    }

    func testFirstRunProducesFactoryDefaultsWithoutAProblem() {
        let result = makeStore().loadOrDefault(fanCount: 2)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.configuration.profiles.count,
                       Profile.builtIns(fanCount: 2).count)
    }

    func testRuleDeletionRemovesRuleFromConfig() throws {
        var config = Configuration.factoryDefault(fanCount: 1)
        let rule1 = Rule(name: "rule1", conditions: [.powerSource(.ac)], targetProfileID: Profile.silentID)
        let rule2 = Rule(name: "rule2", conditions: [.powerSource(.battery)], targetProfileID: Profile.balancedID)
        config.rules = [rule1, rule2]

        config.rules.removeAll { $0.id == rule1.id }
        XCTAssertEqual(config.rules.count, 1)
        XCTAssertEqual(config.rules.first?.id, rule2.id)
    }
}
