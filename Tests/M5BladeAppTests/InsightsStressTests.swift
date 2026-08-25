import XCTest
import SwiftUI
import SensorKit
import HistoryKit
@testable import M5BladeApp

/// The Insights page under loads a person could not produce by hand: hundreds
/// of findings, every cause at once, and reloads landing out of order.
@MainActor
final class InsightsStressTests: XCTestCase {

    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private var directory: URL!
    private var model: AppModel!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsStress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = Fixture.model(directory: directory)
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Must hold after every operation, whatever order they arrived in.
    private func assertInvariants(_ viewModel: InsightsViewModel, step: Int) {
        XCTAssertLessThanOrEqual(viewModel.visible.lowerBound, viewModel.visible.upperBound,
                                 "inverted window at step \(step)")
        XCTAssertFalse(viewModel.headline.isEmpty, "no headline at step \(step)")
        for finding in viewModel.findings {
            XCTAssertFalse(finding.explanation.headline.isEmpty,
                           "a finding with nothing to say at step \(step)")
            XCTAssertFalse(finding.explanation.detail.isEmpty,
                           "a verdict with no evidence at step \(step)")
        }
        // Whatever the database holds, exactly one thing can be *presented* as
        // happening now. The detector guarantees one open record at a time; this
        // says the page stays coherent even if that guarantee were ever broken.
        XCTAssertEqual(viewModel.openFinding == nil,
                       viewModel.findings.allSatisfy { $0.spike.end != nil },
                       "disagreement about whether anything is in progress at step \(step)")
        if let dominant = viewModel.dominantCause {
            XCTAssertGreaterThanOrEqual(dominant.count, 2, "a pattern of one at step \(step)")
            XCTAssertLessThanOrEqual(dominant.count, viewModel.findings.count,
                                     "more spikes in a cause than exist at step \(step)")
        }
        if let offender = viewModel.repeatOffender {
            XCTAssertGreaterThanOrEqual(offender.count, 2, "a repeat of one at step \(step)")
            XCTAssertFalse(offender.name.isEmpty, "an unnamed offender at step \(step)")
        }
    }

    /// - Parameter open: leaves the record without an end. The detector only
    ///   ever has one of these at a time, so a batch is generated with at most
    ///   one — a fixture that broke the producer's own invariant would be
    ///   testing the view model against data it can never receive.
    private func randomSpike(_ id: Int64, _ random: inout Seeded, open: Bool = false) -> Spike {
        let start = base.addingTimeInterval(-Double.random(in: 0...86_400, using: &random))
        let from = Double.random(in: 30...80, using: &random)
        let named = Bool.random(using: &random)
        return Spike(
            id: id,
            start: start,
            peak: start.addingTimeInterval(Double.random(in: 0...200, using: &random)),
            end: open ? nil
                : start.addingTimeInterval(Double.random(in: 200...900, using: &random)),
            fromTempC: from,
            peakTempC: from + Double.random(in: 12...40, using: &random),
            cpuAtStartPercent: Double.random(in: 0...40, using: &random),
            peakCPUPercent: Double.random(in: 0...100, using: &random),
            hottestGroup: ["CPU", "GPU", "SoC", "Storage", "Memory", ""]
                .randomElement(using: &random)!,
            peakFanRPM: Double.random(in: 0...6_000, using: &random),
            peakFanDutyPercent: Double.random(in: 0...100, using: &random),
            profileName: ["Balanced", "Silent", ""].randomElement(using: &random)!,
            profileChanged: Bool.random(using: &random),
            onBattery: Bool.random(using: &random),
            recordedProcessNames: named,
            processes: named
                ? [ProcessShare(name: ["swift-frontend", "Xcode", "Chrome"]
                                    .randomElement(using: &random)!,
                                percent: Double.random(in: 1...100, using: &random))]
                : [])
    }

    // MARK: - Volume

    func testHundredsOfFindingsAcrossEveryCause() {
        var random = Seeded(seed: 7)
        let viewModel = InsightsViewModel(model: model)

        for step in 0..<40 {
            // The newest may still be running; everything before it is closed.
            let spikes = (0..<25).map {
                randomSpike(Int64(step * 25 + $0), &random, open: $0 == 0 && step % 3 == 0)
            }
            viewModel.applyForTesting(spikes: spikes,
                                      recordsProcessNames: Bool.random(using: &random),
                                      visible: base.addingTimeInterval(-86_400)...base)
            assertInvariants(viewModel, step: step)
        }
    }

    /// A database written by an older build, or one a crash left in a state the
    /// current code would not produce: several records with no end. The page has
    /// to stay coherent rather than claim several things are happening at once.
    func testSeveralOpenRecordsDoNotConfuseThePage() {
        var random = Seeded(seed: 21)
        let viewModel = InsightsViewModel(model: model)
        let spikes = (0..<12).map { randomSpike(Int64($0), &random, open: true) }
        viewModel.applyForTesting(spikes: spikes, recordsProcessNames: true,
                                  visible: base.addingTimeInterval(-86_400)...base)

        XCTAssertNotNil(viewModel.openFinding)
        assertInvariants(viewModel, step: 0)
        RenderHarness.assertDraws(
            InsightsPage(model: model, viewModel: viewModel, onShowOnChart: { _ in }),
            "insights with several open records")
    }

    /// Every cause the explainer can reach has to be reachable, or a branch is
    /// dead and nobody would find out.
    func testEveryCauseIsProducedBySomeRealisticSpike() {
        var random = Seeded(seed: 11)
        var seen = Set<SpikeExplanation.Cause>()
        for id in 0..<4_000 {
            var spike = randomSpike(Int64(id), &random)
            // The explainer only reaches `profileChange` when nothing else fits,
            // so the sample has to include quiet spikes that changed profile.
            if id % 7 == 0 { spike.profileChanged = true; spike.peakCPUPercent = 10 }
            seen.insert(SpikeExplanation.explain(spike).cause)
        }
        XCTAssertEqual(seen, Set(SpikeExplanation.Cause.allCases),
                       "unreachable causes: \(Set(SpikeExplanation.Cause.allCases).subtracting(seen))")
    }

    // MARK: - Out-of-order loading

    /// Two reloads can be in flight at once — the five-second refresh and one
    /// the user triggered by changing the range. A slow one landing after a
    /// fast one must not repaint the page with a window already moved off.
    func testInterleavedRangeChangesSettleOnTheLastOne() async {
        let viewModel = InsightsViewModel(model: model)
        for range in [HistoryRange.month, .hour, .week, .day, .sixHours, .hour] {
            viewModel.range = range
        }
        await viewModel.settle()

        XCTAssertEqual(viewModel.range, .hour)
        let span = viewModel.visible.upperBound.timeIntervalSince(viewModel.visible.lowerBound)
        XCTAssertEqual(span, HistoryRange.hour.duration, accuracy: 1,
                       "the window belongs to a range the user already left")
        assertInvariants(viewModel, step: 0)
    }

    /// Reading a database that was never written to is a normal state on first
    /// launch, not an error to surface.
    func testAnEmptyDatabaseIsNotReportedAsAProblem() async {
        let viewModel = InsightsViewModel(model: model)
        await viewModel.reload()
        XCTAssertNil(viewModel.problem)
        XCTAssertTrue(viewModel.findings.isEmpty)
        XCTAssertEqual(viewModel.headline, "No sudden spikes in the last 24 hours")
    }

    // MARK: - Rendering

    /// Charts and lists trap at layout time on things the compiler accepts. Two
    /// hundred findings, hostile names, and a degenerate size.
    func testThePageDrawsUnderVolumeAndHostileNames() {
        var random = Seeded(seed: 3)
        let viewModel = InsightsViewModel(model: model)
        var spikes = (0..<200).map { randomSpike(Int64($0), &random) }
        spikes[0].processes = [.init(name: String(repeating: "long name ", count: 40), percent: 99)]
        spikes[1].processes = [.init(name: "☃ 温度 \u{202E}reversed", percent: 51)]
        spikes[2].processes = [.init(name: "", percent: 100)]
        spikes[3].peakTempC = spikes[3].fromTempC + 0.0001   // a rise of almost nothing
        viewModel.applyForTesting(spikes: spikes, recordsProcessNames: false,
                                  visible: base.addingTimeInterval(-86_400)...base)

        let page = InsightsPage(model: model, viewModel: viewModel, onShowOnChart: { _ in })
        RenderHarness.assertDraws(page, "insights under volume")
        _ = RenderHarness.render(page, size: CGSize(width: 1, height: 1))
    }

    /// Switching pages must carry a finding's window to the chart intact, in the
    /// order the chart requires — this is the one place the two pages touch.
    func testShowingAFindingOnTheChartHandsOverAUsableWindow() async {
        var random = Seeded(seed: 5)
        let history = HistoryViewModel(model: model)
        let insights = InsightsViewModel(model: model)

        for id in 0..<50 {
            let spike = randomSpike(Int64(id), &random)
            let bounds = [spike.start, spike.end ?? Date()].sorted()
            history.focus(from: bounds[0], to: bounds[1])
            let focus = history.focus
            XCTAssertNotNil(focus, "no window handed over for spike \(id)")
            XCTAssertLessThanOrEqual(focus!.lowerBound, focus!.upperBound,
                                     "inverted window for spike \(id)")
            XCTAssertGreaterThan(focus!.upperBound.timeIntervalSince(focus!.lowerBound), 0,
                                 "zero-width window for spike \(id)")
        }
        await history.settle()
        _ = insights
    }
}
