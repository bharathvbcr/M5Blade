import XCTest
import HistoryKit
@testable import M5BladeApp

/// The summaries above the spike list. Their whole job is to turn a list into a
/// finding, and the failure mode is claiming a pattern from a single event.
@MainActor
final class InsightsViewModelTests: XCTestCase {

    private var directory: URL!
    private var model: AppModel!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsViewModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = Fixture.model(directory: directory)
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func viewModel(_ spikes: [Spike], recordsNames: Bool = true) -> InsightsViewModel {
        let viewModel = InsightsViewModel(model: model)
        viewModel.applyForTesting(spikes: spikes, recordsProcessNames: recordsNames,
                                  visible: base.addingTimeInterval(-86_400)...base)
        return viewModel
    }

    func testTheHeadlineCountsAndNamesTheWindow() {
        XCTAssertEqual(viewModel([]).headline, "No sudden spikes in the last 24 hours")
        XCTAssertEqual(viewModel([Fixture.spike(id: 1, at: base)]).headline,
                       "1 sudden spike in the last 24 hours")
        XCTAssertEqual(viewModel([Fixture.spike(id: 1, at: base),
                                  Fixture.spike(id: 2, at: base)]).headline,
                       "2 sudden spikes in the last 24 hours")
    }

    /// One event is not a pattern, and saying it is would send someone hunting
    /// for a recurring cause that has happened once.
    func testASingleSpikeIsNotReportedAsAPattern() {
        let single = viewModel([Fixture.spike(id: 1, at: base, app: "Xcode")])
        XCTAssertNil(single.dominantCause)
        XCTAssertNil(single.repeatOffender)
    }

    func testARepeatedApplicationIsNamed() throws {
        let spikes = (1...3).map {
            Fixture.spike(id: Int64($0), at: base.addingTimeInterval(Double($0) * -600),
                          app: "swift-frontend")
        }
        let offender = try XCTUnwrap(viewModel(spikes).repeatOffender)
        XCTAssertEqual(offender.name, "swift-frontend")
        XCTAssertEqual(offender.count, 3)
    }

    /// An application that appears in every spike but never dominates one is not
    /// the reason for any of them.
    func testAnApplicationThatNeverDominatedIsNotBlamed() {
        let spikes = (1...3).map { index -> Spike in
            var spike = Fixture.spike(id: Int64(index), at: base, cpuFrom: 8, cpuTo: 12)
            spike.processes = [.init(name: "Finder", percent: 95)]
            return spike
        }
        XCTAssertNil(viewModel(spikes).repeatOffender,
                     "load never rose, so nothing here was CPU work")
    }

    func testTheDominantCauseNeedsAtLeastTwoAgreeingSpikes() throws {
        // Load flat throughout, so the cause is decided by which part got hot.
        func quiet(_ id: Int64, _ group: String) -> Spike {
            Fixture.spike(id: id, at: base, group: group, cpuFrom: 8, cpuTo: 12)
        }
        let mixed = [quiet(1, "GPU"), quiet(2, "Storage")]
        XCTAssertNil(viewModel(mixed).dominantCause, "one each is not a majority of anything")

        let agreeing = [quiet(1, "GPU"), quiet(2, "GPU"), quiet(3, "Storage")]
        let cause = try XCTUnwrap(viewModel(agreeing).dominantCause)
        XCTAssertEqual(cause.cause, .graphics)
        XCTAssertEqual(cause.count, 2)
    }

    /// The call to action is only honest when turning attribution on would
    /// actually have changed the answer.
    func testTheAttributionPromptOnlyAppearsWhenItWouldHaveHelped() {
        var unattributed = Fixture.spike(id: 1, at: base)
        unattributed.recordedProcessNames = false

        XCTAssertTrue(viewModel([unattributed], recordsNames: false).wouldBenefitFromAttribution)
        XCTAssertFalse(viewModel([unattributed], recordsNames: true).wouldBenefitFromAttribution,
                       "already on — there is nothing to switch")
        XCTAssertFalse(viewModel([], recordsNames: false).wouldBenefitFromAttribution,
                       "nothing recorded, so nothing was missed")
    }

    func testASpikeStillInProgressIsSurfacedSeparately() throws {
        var open = Fixture.spike(id: 2, at: base)
        open.end = nil
        let viewModel = viewModel([Fixture.spike(id: 1, at: base), open])
        XCTAssertEqual(try XCTUnwrap(viewModel.openFinding).spike.id, 2)
    }

    /// "24h" reads fine on a segmented control and badly in a sentence, so the
    /// two labels are deliberately different words for the same range.
    func testEveryRangeHasSpokenWording() {
        for range in HistoryRange.allCases {
            XCTAssertFalse(range.spokenLabel.isEmpty)
            XCTAssertNotEqual(range.spokenLabel, range.label,
                              "\(range.label) would read as an abbreviation in a sentence")
        }
    }

    /// Reads through the real recorder rather than an injected list: the tick
    /// sequence, the actor hop, the query, and the explanation on the way back.
    func testLoadingReadsSpikesBackThroughTheRecorder() async {
        // Set on the recorder rather than through `AppModel`, which also writes
        // the user's real defaults — a test has no business doing that.
        await model.historyRecorder.setRecordsProcessNames(true)
        await Fixture.recordSpike(into: model.historyRecorder,
                                  endingAt: Date(), app: "swift-frontend")

        let viewModel = InsightsViewModel(model: model)
        await viewModel.reload()

        XCTAssertNil(viewModel.problem)
        XCTAssertEqual(viewModel.findings.count, 1)
        XCTAssertEqual(viewModel.findings.first?.spike.processes.first?.name, "swift-frontend")
        XCTAssertEqual(viewModel.findings.first?.explanation.cause, .application)
        XCTAssertFalse(viewModel.wouldBenefitFromAttribution, "it is already on")
    }

    /// Attribution is off by default, so the recorder must discard the names it
    /// was handed rather than trusting the caller to have filtered them.
    func testNamesAreNotStoredWhileAttributionIsOff() async {
        await model.historyRecorder.setRecordsProcessNames(false)
        await Fixture.recordSpike(into: model.historyRecorder,
                                  endingAt: Date(), app: "private-app")

        let viewModel = InsightsViewModel(model: model)
        await viewModel.reload()
        XCTAssertEqual(viewModel.findings.count, 1)
        XCTAssertTrue(viewModel.findings.first?.spike.processes.isEmpty ?? false)
        XCTAssertTrue(viewModel.wouldBenefitFromAttribution)
    }
}
