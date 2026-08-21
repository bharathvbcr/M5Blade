import XCTest
import SwiftUI
import FanKit
import SensorKit
@testable import FanControlApp

/// The SMC source as the app exposes it: a setting that persists, and a readout
/// that must not change for anyone who leaves it alone.
@MainActor
final class SMCSensorToggleTests: XCTestCase {

    private var directory: URL!
    private var model: AppModel!
    /// The model's own defaults, private to this test. Reading the setting back
    /// out of `UserDefaults.standard` made this a test of a machine-wide store
    /// that any concurrent run could write.
    private var defaults: InMemoryDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMCSensorToggleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = InMemoryDefaults()
        model = Fixture.model(directory: directory, defaults: defaults)
    }

    override func tearDownWithError() throws {
        model = nil
        defaults = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// A reading set of the shape the merged source produces: HID names, the two
    /// families load testing established, the family it did not, and three keys
    /// measured to be constants or non-temperatures.
    private func mixedReadings() -> [TemperatureSensors.Reading] {
        [
            TemperatureSensors.Reading(name: "PMU tdie1", celsius: 73.5, smcKey: "TP1b"),
            TemperatureSensors.Reading(name: "PMU tcal", celsius: 51.8, smcKey: "TP0Z"),
            TemperatureSensors.Reading(name: "gas gauge battery", celsius: 33.9, smcKey: "TG0B"),
            TemperatureSensors.Reading(name: "Tp04", celsius: 88.2, smcKey: "Tp04"),
            TemperatureSensors.Reading(name: "Tg08", celsius: 79.1, smcKey: "Tg08"),
            TemperatureSensors.Reading(name: "Tm04", celsius: 91.4, smcKey: "Tm04"),
            TemperatureSensors.Reading(name: "TVMX", celsius: 61.0, smcKey: "TVMX"),
            TemperatureSensors.Reading(name: "TR0Z", celsius: 51.82, smcKey: "TR0Z"),
            TemperatureSensors.Reading(name: "Tz11", celsius: 0.0, smcKey: "Tz11"),
        ]
    }

    // MARK: - The setting

    func testDefaultsToOff() {
        XCTAssertFalse(model.includesSMCSensors,
                       "the SMC source must never switch itself on")
    }

    func testTogglePersists() async {
        await model.setIncludesSMCSensors(true)
        XCTAssertTrue(model.includesSMCSensors)
        XCTAssertTrue(defaults.bool(forKey: "sensors.includesSMC"))

        await model.setIncludesSMCSensors(false)
        XCTAssertFalse(model.includesSMCSensors)
        XCTAssertFalse(defaults.bool(forKey: "sensors.includesSMC"))
    }

    /// Persisted means a *new* model reads it back, which is the thing the
    /// setting is for. Asserting only that the key is in the store checks the
    /// write and not the read.
    func testASettingWrittenIsTheSettingTheNextLaunchReads() async {
        await model.setIncludesSMCSensors(true)
        XCTAssertTrue(Fixture.model(directory: directory, defaults: defaults).includesSMCSensors)

        await model.setIncludesSMCSensors(false)
        XCTAssertFalse(Fixture.model(directory: directory, defaults: defaults).includesSMCSensors)
    }

    /// And one model's setting is not another's. Two `AppModel`s pointed at
    /// different stores must not see each other's toggles — which is exactly what
    /// they did while every one of them wrote to `UserDefaults.standard`.
    func testTwoModelsWithSeparateStoresDoNotShareTheSetting() async throws {
        let other = directory.deletingLastPathComponent()
            .appendingPathComponent("SMCSensorToggleTests-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        await model.setIncludesSMCSensors(true)
        XCTAssertFalse(Fixture.model(directory: other).includesSMCSensors,
                       "a second model saw a setting that was not its own")
    }

    /// Turning the source off must not discard readings already taken. The
    /// toggle's own copy promises this.
    func testTurningItOffKeepsWhatWasAlreadyRead() async {
        model.applyForTesting(temperatures: mixedReadings())
        let before = model.temperatures.count
        await model.setIncludesSMCSensors(false)
        XCTAssertEqual(model.temperatures.count, before)
    }

    // MARK: - What the readouts use

    /// `Tm04` is the hottest reading at 91.4 °C and must still not set the
    /// number the fan curve reads — its subsystem is unestablished. `Tp04` at
    /// 88.2 °C is the hottest sensor anything is allowed to act on.
    func testUnattributedKeysCannotSetTheCurveInput() {
        model.applyForTesting(temperatures: mixedReadings())
        XCTAssertEqual(model.maxTempC ?? 0, 88.2, accuracy: 0.001)
        XCTAssertEqual(model.hottestGroup, SensorCategory.cpu.rawValue)
    }

    /// All nine are shown. Excluding a sensor from the curve is not a reason to
    /// hide it — the Sensors tab reports what the hardware reports.
    func testEveryReadingIsStillDisplayed() {
        model.applyForTesting(temperatures: mixedReadings())
        XCTAssertEqual(model.temperatures.count, 9)
        XCTAssertTrue(model.temperatures.contains { $0.name == "Tz11" })
        XCTAssertTrue(model.temperatures.contains { $0.name == "TR0Z" })
    }

    /// The set written to history is the set that can be attributed: the three
    /// named sensors minus the calibration reference, plus `Tp04` and `Tg08`.
    func testOnlyAttributedSensorsReachHistory() {
        let recorded = TemperatureSources.attributed(mixedReadings()).map(\.name)
        XCTAssertEqual(Set(recorded),
                       ["PMU tdie1", "gas gauge battery", "Tp04", "Tg08"])
    }

    /// The guarantee for everyone who never touches the toggle: with only HID
    /// readings present, every derived readout is what it was before the SMC
    /// source existed.
    func testHIDOnlyReadoutsAreUnchanged() {
        let hidOnly = mixedReadings().filter { SMCKeyNameIsAbsent($0.name) }
        model.applyForTesting(temperatures: hidOnly)
        XCTAssertEqual(model.maxTempC ?? 0, 73.5, accuracy: 0.001,
                       "the calibration reference must still be excluded")
        XCTAssertEqual(model.temperatures.count, 3)
    }

    /// Local rather than exported from SensorKit: the test wants "is this one of
    /// the hub's prose names", and asking that here keeps the production type's
    /// surface from growing to serve a test.
    private func SMCKeyNameIsAbsent(_ name: String) -> Bool {
        name.contains(" ")
    }

    // MARK: - Rendering

    func testGeneralTabDrawsWithTheSourceOn() async {
        await model.setIncludesSMCSensors(true)
        model.applyForTesting(temperatures: mixedReadings())
        RenderHarness.assertDraws(GeneralTab(model: model), "general tab, SMC on")
    }

    /// Before the first tick there are no readings, so the summary has no counts
    /// to show. It must say so rather than render "0 shown · 0 charted".
    func testGeneralTabDrawsBeforeAnySensorsArrive() {
        RenderHarness.assertDraws(GeneralTab(model: model), "general tab, no sensors")
    }

    func testSensorsPageDrawsWithRawKeys() {
        model.applyForTesting(temperatures: mixedReadings())
        RenderHarness.assertDraws(SensorsPage(model: model), "sensors page with SMC keys")
    }
}
