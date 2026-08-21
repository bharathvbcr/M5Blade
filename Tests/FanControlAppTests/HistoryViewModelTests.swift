import XCTest
import HistoryKit
import ProfileKit
@testable import FanControlApp

/// The History window's presentation logic: the scales it computes, the groups
/// it offers, and what happens when it is asked to focus on a record that
/// shouldn't exist.
@MainActor
final class HistoryViewModelTests: XCTestCase {

    private var directory: URL!
    private var model: AppModel!
    private var viewModel: HistoryViewModel!

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryViewModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Disposable stores: a test suite has no business writing into the
        // developer's own configuration, history, or preferences. Through the
        // fixture rather than assembled here, so there is one definition of
        // "disposable" and a store cannot be forgotten from one of them.
        model = Fixture.model(directory: directory)
        viewModel = HistoryViewModel(model: model)
    }

    override func tearDownWithError() throws {
        viewModel = nil
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func series(_ id: String, kind: SensorKind, values: [Double]) -> Series {
        Series(id: id, name: id, kind: kind,
               points: values.enumerated().map { offset, value in
                   SeriesPoint(date: base.addingTimeInterval(Double(offset)), value: value)
               })
    }

    // MARK: - Vertical scale

    func testTemperatureTopFloorsAtOneHundred() {
        XCTAssertEqual(viewModel.temperatureTop, 100, "an empty chart still needs a scale")

        viewModel.applyForTesting(series: [series("CPU", kind: .temperature, values: [20, 30])])
        XCTAssertEqual(viewModel.temperatureTop, 100)
    }

    func testTemperatureTopLeavesHeadroomAboveThePeak() {
        viewModel.applyForTesting(series: [series("CPU", kind: .temperature, values: [61, 104.2])])
        XCTAssertEqual(viewModel.temperatureTop, 120)
        XCTAssertGreaterThan(viewModel.temperatureTop, 104.2, "the line must not touch the frame")
    }

    /// Percent series are mapped onto the temperature scale, so letting them
    /// *set* it would make a busy fan stretch the temperature axis.
    func testPercentSeriesDoNotDriveTheTemperatureScale() {
        viewModel.applyForTesting(series: [series("Fan", kind: .percent, values: [100]),
                                           series("CPU", kind: .temperature, values: [55])])
        XCTAssertEqual(viewModel.temperatureTop, 100)
    }

    func testPercentValuesMapOntoTheSharedScaleAndBackAgain() {
        viewModel.applyForTesting(series: [series("CPU", kind: .temperature, values: [95])])
        let top = viewModel.temperatureTop
        XCTAssertEqual(top, 110)

        for percent in stride(from: 0.0, through: 100, by: 12.5) {
            let plotted = viewModel.plotted(SeriesPoint(date: base, value: percent), kind: .percent)
            XCTAssertEqual(plotted, percent / 100 * top, accuracy: 0.0001)
            // The right-hand axis must label that same position with the number
            // the caller started from.
            XCTAssertEqual(viewModel.percentLabel(forAxisValue: plotted),
                           String(format: "%.0f%%", percent))
        }
    }

    func testTemperatureValuesArePlottedUnchanged() {
        viewModel.applyForTesting(series: [series("CPU", kind: .temperature, values: [72])])
        XCTAssertEqual(viewModel.plotted(SeriesPoint(date: base, value: 72), kind: .temperature), 72)
    }

    // MARK: - Offered groups

    func testOfferedGroupsFollowSensorOrderAndHideWhatCannotBeCharted() {
        viewModel.applyForTesting(availableGroups: ["Load", "Fan rpm", "Storage", "GPU",
                                                    "Fan", "CPU", "SoC"])
        XCTAssertEqual(viewModel.offeredGroups, ["CPU", "GPU", "SoC", "Storage", "Fan", "Load"])
        XCTAssertFalse(viewModel.offeredGroups.contains("Fan rpm"),
                       "rpm shares no axis with temperature or percent")
    }

    func testOfferedGroupsOnlyIncludeWhatWasActuallyRecorded() {
        viewModel.applyForTesting(availableGroups: ["SoC", "Fan"])
        XCTAssertEqual(viewModel.offeredGroups, ["SoC", "Fan"])
    }

    func testUnknownGroupsAreIgnoredRatherThanShownRaw() {
        viewModel.applyForTesting(availableGroups: ["SoC", "Nonsense", "Fan"])
        XCTAssertEqual(viewModel.offeredGroups, ["SoC", "Fan"])
    }

    // MARK: - Focus

    func testFocusOnAClosedEpisodeBracketsItWithAir() {
        let episode = ThrottleEpisode(id: 1, start: base, end: base.addingTimeInterval(240))
        viewModel.focus(on: episode)

        let focus = try? XCTUnwrap(viewModel.focus)
        XCTAssertEqual(focus?.lowerBound, base.addingTimeInterval(-60))
        XCTAssertEqual(focus?.upperBound, base.addingTimeInterval(300))
    }

    func testFocusOnAShortEpisodeStillGetsAUsableWindow() {
        viewModel.focus(on: ThrottleEpisode(id: 1, start: base, end: base))
        let focus = try? XCTUnwrap(viewModel.focus)
        XCTAssertEqual(focus?.upperBound.timeIntervalSince(focus!.lowerBound), 120,
                       "a zero-length episode must not produce a zero-width chart")
    }

    /// `ClosedRange` traps on inverted bounds. An episode that ends before it
    /// starts should not exist — but older builds wrote rows without that
    /// guarantee, and a chart is not where you want to discover one.
    func testFocusOnAnInvertedEpisodeDoesNotTrap() {
        let episode = ThrottleEpisode(id: 1, start: base,
                                      end: base.addingTimeInterval(-3_600))
        viewModel.focus(on: episode)

        let focus = try? XCTUnwrap(viewModel.focus)
        XCTAssertNotNil(focus)
        XCTAssertLessThanOrEqual(focus!.lowerBound, focus!.upperBound)
    }

    func testFocusOnARunningEpisodeUsesTheCurrentTimeAsItsEnd() {
        let episode = ThrottleEpisode(id: 1, start: Date().addingTimeInterval(-120), end: nil)
        viewModel.focus(on: episode)
        let focus = try? XCTUnwrap(viewModel.focus)
        XCTAssertNotNil(focus)
        XCTAssertGreaterThan(focus!.upperBound, episode.start)
    }

    func testClearingFocusReturnsToTheSelectedRange() {
        viewModel.focus(on: ThrottleEpisode(id: 1, start: base, end: base.addingTimeInterval(60)))
        XCTAssertNotNil(viewModel.focus)
        viewModel.clearFocus()
        XCTAssertNil(viewModel.focus)
    }

    func testChangingTheRangeDropsAnyFocus() {
        viewModel.focus(on: ThrottleEpisode(id: 1, start: base, end: base.addingTimeInterval(60)))
        viewModel.range = .day
        XCTAssertNil(viewModel.focus, "a scrubbed window must not survive picking a new range")
    }

    // MARK: - Export naming

    func testSuggestedFileNameIsSortableAndStampedWithTheWindowEnd() {
        viewModel.applyForTesting(visible: base...base.addingTimeInterval(3_600))
        let name = viewModel.suggestedFileName
        XCTAssertTrue(name.hasPrefix("FanControl-history-"), name)
        XCTAssertFalse(name.contains("/"), "a file name with a separator in it is not a file name")
        XCTAssertFalse(name.contains(":"))
    }

    // MARK: - Loading

    /// Two loads can be in flight at once — the five-second refresh and one
    /// triggered by a click. Finishing out of order must not repaint the chart
    /// with the older answer.
    func testAStaleLoadDoesNotOverwriteANewerOne() async {
        viewModel.selectedGroups = ["SoC"]
        async let first: Void = viewModel.reload()
        viewModel.range = .day
        async let second: Void = viewModel.reload()
        _ = await (first, second)

        // Whatever finished last, the state on screen describes the range that
        // is actually selected.
        let span = viewModel.visible.upperBound.timeIntervalSince(viewModel.visible.lowerBound)
        XCTAssertEqual(span, HistoryRange.day.duration, accuracy: 5)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testReloadOnAnEmptyDatabaseReportsNoProblem() async {
        await viewModel.reload()
        XCTAssertNil(viewModel.problem)
        XCTAssertTrue(viewModel.series.isEmpty)
        XCTAssertTrue(viewModel.episodes.isEmpty)
        XCTAssertEqual(viewModel.status?.isRecording, true)
    }
}
