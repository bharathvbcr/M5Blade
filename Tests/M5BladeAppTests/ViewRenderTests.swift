import XCTest
import SwiftUI
import FanKit
import ProfileKit
import SensorKit
import HistoryKit
@testable import M5BladeApp

/// Every view, laid out for real, in the states that break layouts: nothing,
/// too much, too long, too hot, and every degraded mode the app can be in.
///
/// A crash here is a crash a user would have had. SwiftUI traps at layout time
/// on things the compiler is happy with — inverted ranges, NaN geometry — so
/// running the views is the only way to know.
@MainActor
final class ViewRenderTests: XCTestCase {

    private var directory: URL!
    private var model: AppModel!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewRenderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = Fixture.model(directory: directory)
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var popoverSize: CGSize { CGSize(width: 340, height: 520) }

    private func popover() -> some View {
        PopoverView(model: model, onOpenSettings: {}, onOpenDashboard: {})
    }

    // MARK: - Popover

    /// First launch on a fanless Mac, or before the first sample lands. The
    /// popover is the app's primary surface; it has to say something.
    func testPopoverWithNothingToShow() {
        RenderHarness.assertDraws(popover(), "empty popover", size: popoverSize)
    }

    func testPopoverWithLiveReadings() {
        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(),
                              cpuPercent: 34, status: .controlling)
        RenderHarness.assertDraws(popover(), "live popover", size: popoverSize)
    }

    func testPopoverInEveryDegradedState() {
        let states: [ControlStatus] = [.watching, .controlling, .emergency,
                                       .daemonUnavailable,
                                       .unverifiedOS("macOS 26.5 hasn't been verified")]
        for state in states {
            let fans = Fixture.fans()
            model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                                  temperatures: Fixture.temperatures(3), status: state)
            RenderHarness.assertDraws(popover(), "popover \(state.label)", size: popoverSize)
        }
    }

    /// A fan reading of zero, a sensor at freezing, and one hotter than any Mac
    /// gets: the bars and the sparkline scale must survive all three.
    func testPopoverWithExtremeValues() {
        let fans = Fixture.fans()
        model.applyForTesting(
            fans: fans,
            readings: [0: FanReading(index: 0, actualRPM: 0, targetRPM: 0, mode: .manual),
                       1: FanReading(index: 1, actualRPM: 99_999, targetRPM: nil, mode: nil)],
            temperatures: [.init(name: "Freezing", celsius: -40, ordinal: 0),
                           .init(name: "Impossible", celsius: 199, ordinal: 0),
                           .init(name: "Flat", celsius: 50, ordinal: 0)],
            cpuPercent: 100)
        RenderHarness.assertDraws(popover(), "extreme popover", size: popoverSize)
    }

    /// Sensor names come from a private API and are not ours to assume are
    /// short, unique, or even sensible.
    func testPopoverWithHostileSensorNames() {
        model.applyForTesting(
            fans: Fixture.fans(1),
            readings: Fixture.readings(Fixture.fans(1)),
            temperatures: [.init(name: String(repeating: "very long sensor name ", count: 12),
                                 celsius: 61, ordinal: 0),
                           .init(name: "duplicate", celsius: 62, ordinal: 0),
                           .init(name: "duplicate", celsius: 63, ordinal: 1),
                           .init(name: "☃ 温度 \u{202E}reversed", celsius: 64, ordinal: 0)])
        RenderHarness.assertDraws(popover(), "hostile names popover", size: popoverSize)
    }

    func testPopoverInLightAppearance() {
        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures())
        RenderHarness.assertDraws(popover(), "light popover",
                                  size: popoverSize, appearance: .aqua)
    }

    // MARK: - History page

    private func historyWindow(_ configure: (HistoryViewModel) -> Void) -> some View {
        let viewModel = HistoryViewModel(model: model)
        configure(viewModel)
        return HistoryPage(model: model, viewModel: viewModel)
    }

    func testHistoryWindowWithNoDataYet() {
        RenderHarness.assertDraws(historyWindow { _ in }, "empty history")
    }

    func testHistoryWindowWithNothingSelected() {
        RenderHarness.assertDraws(historyWindow { $0.selectedGroups = [] },
                                  "history with no groups selected")
    }

    func testHistoryWindowWithAFullChart() {
        RenderHarness.assertDraws(historyWindow { viewModel in
            viewModel.applyForTesting(
                series: [Fixture.series("SoC", kind: .temperature, count: 60, from: base) {
                             60 + Double($0 % 30)
                         },
                         Fixture.series("Fan", kind: .percent, count: 60, from: base) {
                             20 + Double($0 % 60)
                         }],
                episodes: [ThrottleEpisode(id: 1, start: base.addingTimeInterval(600),
                                           end: base.addingTimeInterval(900),
                                           peakTempC: 97, meanCPUPercent: 88,
                                           profileName: "Performance",
                                           processes: [.init(name: "swift-frontend", percent: 71)])],
                profileChanges: [.init(date: base, profileID: "a", profileName: "Balanced",
                                       reason: "Default"),
                                 .init(date: base.addingTimeInterval(1_800), profileID: "b",
                                       profileName: "Performance", reason: "Manual")],
                availableGroups: ["SoC", "Fan", "Load"],
                visible: base...base.addingTimeInterval(3_600))
        }, "full history chart")
    }

    /// Many short-lived profile changes: the band labels must not spill over
    /// each other, and a hundred bands must not wedge the layout.
    func testHistoryWindowWithRapidProfileChurn() {
        RenderHarness.assertDraws(historyWindow { viewModel in
            viewModel.applyForTesting(
                series: [Fixture.series("SoC", kind: .temperature, count: 60, from: base) { _ in 70 }],
                profileChanges: (0..<100).map { index in
                    .init(date: base.addingTimeInterval(Double(index) * 36),
                          profileID: "p\(index % 4)", profileName: "Profile \(index % 4)",
                          reason: "Auto")
                },
                availableGroups: ["SoC"],
                visible: base...base.addingTimeInterval(3_600))
        }, "history with churn")
    }

    /// An episode still running, one that started before the window, and one
    /// that ends after it — every way a mark can hang off the edge.
    func testHistoryWindowWithEpisodesOverhangingBothEdges() {
        RenderHarness.assertDraws(historyWindow { viewModel in
            viewModel.applyForTesting(
                series: [Fixture.series("SoC", kind: .temperature, count: 60, from: base) { _ in 80 }],
                episodes: [ThrottleEpisode(id: 1, start: base.addingTimeInterval(-7_200),
                                           end: base.addingTimeInterval(600)),
                           ThrottleEpisode(id: 2, start: base.addingTimeInterval(3_000), end: nil),
                           ThrottleEpisode(id: 3, start: base.addingTimeInterval(1_200),
                                           end: base.addingTimeInterval(1_200))],
                availableGroups: ["SoC"],
                visible: base...base.addingTimeInterval(3_600))
        }, "history with overhanging episodes")
    }

    func testHistoryWindowWithAProblemAndDroppedSamples() {
        RenderHarness.assertDraws(historyWindow { viewModel in
            viewModel.applyForTesting(
                availableGroups: ["SoC"],
                status: .init(isRecording: false,
                              problem: "History database error: disk I/O error",
                              byteSize: 12_345_678, oldestSample: nil,
                              pendingBatches: 3_600, droppedBatches: 412))
        }, "history reporting failure")
    }

    /// A month view, where the time axis has to say which day and the store
    /// hands back hour buckets.
    func testHistoryWindowOverAMonth() {
        let start = base.addingTimeInterval(-30 * 24 * 3_600)
        RenderHarness.assertDraws(historyWindow { viewModel in
            viewModel.range = .month
            viewModel.applyForTesting(
                series: [Fixture.series("SoC", kind: .temperature, count: 720, from: start) {
                    55 + Double($0 % 40)
                }],
                episodes: (0..<40).map { index in
                    ThrottleEpisode(id: Int64(index),
                                    start: start.addingTimeInterval(Double(index) * 60_000),
                                    end: start.addingTimeInterval(Double(index) * 60_000 + 600),
                                    peakTempC: 96)
                },
                availableGroups: ["SoC", "Fan"],
                visible: start...base)
        }, "month view")
    }

    func testHistoryWindowInLightAppearance() {
        RenderHarness.assertDraws(historyWindow { viewModel in
            viewModel.applyForTesting(
                series: [Fixture.series("SoC", kind: .temperature, count: 30, from: base) {
                    50 + Double($0)
                }],
                availableGroups: ["SoC"],
                visible: base...base.addingTimeInterval(1_800))
        }, "light history", appearance: .aqua)
    }

    // MARK: - Settings

    func testSettingsRendersEveryTab() {
        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(40),
                              cpuPercent: 40, configProblem: "Could not read the configuration")
        RenderHarness.assertDraws(SettingsView(model: model), "settings")
    }

    // MARK: - Insights

    private func insights(_ configure: (InsightsViewModel) -> Void) -> some View {
        let viewModel = InsightsViewModel(model: model)
        configure(viewModel)
        return InsightsPage(model: model, viewModel: viewModel, onShowOnChart: { _ in })
    }

    func testInsightsWithNothingRecordedYet() {
        RenderHarness.assertDraws(insights { _ in }, "empty insights")
    }

    /// One of every cause, plus one still running, plus the attribution prompt —
    /// the page at its busiest.
    func testInsightsWithEveryKindOfFinding() {
        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(), cpuPercent: 71,
                              status: .controlling)
        RenderHarness.assertDraws(insights { viewModel in
            var running = Fixture.spike(id: 5, at: base.addingTimeInterval(3_000),
                                        cpuFrom: 4, cpuTo: 88)
            running.end = nil
            var unattributed = Fixture.spike(id: 6, at: base.addingTimeInterval(3_400))
            unattributed.recordedProcessNames = false
            viewModel.applyForTesting(
                spikes: [Fixture.spike(id: 1, at: base, app: "swift-frontend"),
                         Fixture.spike(id: 2, at: base.addingTimeInterval(600),
                                       app: "swift-frontend"),
                         Fixture.spike(id: 3, at: base.addingTimeInterval(1_200),
                                       group: "GPU", cpuFrom: 8, cpuTo: 12),
                         Fixture.spike(id: 4, at: base.addingTimeInterval(2_400),
                                       group: "Storage", cpuFrom: 8, cpuTo: 12),
                         running, unattributed],
                episodes: [ThrottleEpisode(id: 1, start: base.addingTimeInterval(600),
                                           end: base.addingTimeInterval(900),
                                           peakTempC: 99, meanCPUPercent: 94,
                                           profileName: "Performance",
                                           processes: [.init(name: "swift-frontend", percent: 71)])],
                recordsProcessNames: false,
                visible: base...base.addingTimeInterval(86_400))
        }, "insights with findings")
    }

    /// Application names are the one field on this page that comes from outside
    /// the app, and a process name is not ours to assume is short or sensible.
    func testInsightsWithHostileApplicationNames() {
        RenderHarness.assertDraws(insights { viewModel in
            viewModel.applyForTesting(
                spikes: [Fixture.spike(id: 1, at: base,
                                       app: String(repeating: "long process name ", count: 14)),
                         Fixture.spike(id: 2, at: base, app: "☃ 温度 \u{202E}reversed")],
                visible: base...base.addingTimeInterval(3_600))
        }, "insights with hostile names")
    }

    func testInsightsReportingAFailure() {
        RenderHarness.assertDraws(insights { viewModel in
            viewModel.applyForTesting(problem: "History database error: disk I/O error")
        }, "insights reporting failure")
    }

    // MARK: - Dashboard

    /// Every page of the merged window, reached the way a user reaches them.
    func testDashboardRendersEveryPage() {
        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(20), cpuPercent: 55)
        for page in DashboardWindowView.Page.allCases {
            RenderHarness.assertDraws(
                DashboardWindowView(model: model,
                                    history: HistoryViewModel(model: model),
                                    insights: InsightsViewModel(model: model),
                                    page: page),
                "dashboard \(page.title)")
        }
    }

    func testDashboardInLightAppearance() {
        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(), cpuPercent: 62)
        let insights = InsightsViewModel(model: model)
        insights.applyForTesting(spikes: [Fixture.spike(id: 1, at: base, app: "swift-frontend")],
                                 visible: base...base.addingTimeInterval(86_400))
        RenderHarness.assertDraws(
            DashboardWindowView(model: model,
                                history: HistoryViewModel(model: model),
                                insights: insights),
            "light dashboard", appearance: .aqua)
    }

    func testSensorsPageWithAWholeMacWorthOfSensors() {
        model.applyForTesting(temperatures: (0..<60).map { index in
            TemperatureSensors.Reading(name: ["Chip zone", "gas gauge battery", "NAND CH0",
                                              "PMU tdie", "ambient"][index % 5],
                                       celsius: Double(30 + index % 70),
                                       ordinal: index / 5)
        })
        RenderHarness.assertDraws(SensorsPage(model: model), "sensors page")
    }

    func testSensorsPageWithNoSensorsAtAll() {
        RenderHarness.assertDraws(SensorsPage(model: model), "empty sensors page")
    }

    func testGeneralTabBeforeAnyHistoryFileExists() {
        RenderHarness.assertDraws(GeneralTab(model: model), "general tab")
    }

    func testCurveEditorWithBuiltInProfiles() {
        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures())
        RenderHarness.assertDraws(CurveEditorView(model: model), "curve editor")
    }

    func testProfilesAndAutomationTabs() {
        RenderHarness.assertDraws(ProfilesTab(model: model), "profiles tab")
        RenderHarness.assertDraws(AutomationTab(model: model), "automation tab")
    }

    /// A window dragged down to nothing. Every scale in the app divides by
    /// something; none of them may divide by this.
    func testViewsSurviveADegenerateSize() {
        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(3))
        _ = RenderHarness.render(popover(), size: CGSize(width: 1, height: 1))
        _ = RenderHarness.render(historyWindow { viewModel in
            viewModel.applyForTesting(
                series: [Fixture.series("SoC", kind: .temperature, count: 10, from: base) { _ in 70 }],
                visible: base...base.addingTimeInterval(600))
        }, size: CGSize(width: 1, height: 1))
        _ = RenderHarness.render(SensorsPage(model: model), size: CGSize(width: 1, height: 1))
        _ = RenderHarness.render(insights { viewModel in
            viewModel.applyForTesting(spikes: [Fixture.spike(id: 1, at: base, app: "swift-frontend")],
                                      visible: base...base.addingTimeInterval(3_600))
        }, size: CGSize(width: 1, height: 1))
        _ = RenderHarness.render(DashboardWindowView(model: model,
                                                     history: HistoryViewModel(model: model),
                                                     insights: InsightsViewModel(model: model)),
                                 size: CGSize(width: 1, height: 1))
    }
}
