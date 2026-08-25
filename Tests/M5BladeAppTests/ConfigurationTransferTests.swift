import XCTest
import FanKit
import ProfileKit
@testable import M5BladeApp

/// Export/import round-trip: what one model writes, another model must be able
/// to become — and a hostile file must be refused with something a human can
/// act on.
@MainActor
final class ConfigurationTransferTests: XCTestCase {

    private var directory: URL!
    private var source: AppModel!
    private var target: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigTransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = InMemoryDefaults.acknowledgingControlRisk()
        source = AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("a.json")),
                          historyURL: directory.appendingPathComponent("a.sqlite"),
                          defaults: InMemoryDefaults.acknowledgingControlRisk())
        target = AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("b.json")),
                          historyURL: directory.appendingPathComponent("b.sqlite"),
                          defaults: defaults)
        _ = defaults
    }

    override func tearDownWithError() throws {
        source = nil
        target = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testExportImportRoundTripCarriesProfilesAndRules() throws {
        // Make the source distinguishable from the factory set.
        var custom = Profile.builtIns(fanCount: 2)[0]
        custom.id = UUID()
        custom.isBuiltIn = false
        custom.name = "My Curve"
        source.profiles.append(custom)
        let rule = Rule(name: "When building", conditions: [.sustainedLoad(cpuPercent: 80, forSeconds: 30)],
                        targetProfileID: custom.id)
        source.rules.append(rule)
        source.persist()

        let data = try XCTUnwrap(source.configurationExportData(),
                                 "a healthy configuration must encode")

        let problem = target.importConfiguration(data)
        XCTAssertNil(problem)
        XCTAssertTrue(target.profiles.contains { $0.name == "My Curve" })
        XCTAssertEqual(target.rules.first?.name, "When building")
        XCTAssertEqual(target.defaultProfileID, source.defaultProfileID)
    }

    func testAnImportedRuleTargetingAMissingProfileIsRemovedAndReported() throws {
        // Hand-build a document whose rule points at a profile id the file
        // itself never defines — exactly what a hand-edited export looks like.
        var configuration = Configuration.factoryDefault(fanCount: 2)
        let ghost = UUID()
        configuration.rules = [Rule(name: "Orphaned",
                                    conditions: [.sustainedLoad(cpuPercent: 50, forSeconds: 10)],
                                    targetProfileID: ghost)]
        let data = try ConfigStore.encode(configuration)

        let report = try XCTUnwrap(target.importConfiguration(data))
        XCTAssertTrue(report.contains("Orphaned"), "the correction is named, not swallowed")
        XCTAssertTrue(target.rules.isEmpty)
    }

    func testGarbageDataIsRefusedWithoutDisturbingState() throws {
        let before = target.currentConfiguration
        let profileCount = target.profiles.count

        let problem = try XCTUnwrap(target.importConfiguration(Data("not json at all".utf8)))
        XCTAssertTrue(problem.contains("Could not read"))
        XCTAssertEqual(target.currentConfiguration, before)
        XCTAssertEqual(target.profiles.count, profileCount)
    }

    func testTheSummaryDescribesTheFileBeforeItIsApplied() throws {
        var configuration = Configuration.factoryDefault(fanCount: 2)
        var extra = configuration.profiles[0]
        extra.id = UUID(); extra.isBuiltIn = false; extra.name = "Extra"
        configuration.profiles.append(extra)
        let data = try ConfigStore.encode(configuration)

        let summary = try XCTUnwrap(target.importSummary(data))
        XCTAssertTrue(summary.isValid)
        XCTAssertEqual(summary.profiles, configuration.profiles.count)

        // Reading the summary applies nothing.
        XCTAssertFalse(target.profiles.contains { $0.name == "Extra" })
    }
}
