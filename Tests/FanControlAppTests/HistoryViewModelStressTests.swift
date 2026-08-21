import XCTest
import SensorKit
import ProfileKit
import HistoryKit
@testable import FanControlApp

/// The History window is a small state machine — a range, a set of groups, an
/// optional scrubbed window, and loads landing out of order. These drive it
/// harder than a person could and check the invariants after every step.
@MainActor
final class HistoryViewModelStressTests: XCTestCase {

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

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = Fixture.model(directory: directory)
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Holds after every operation, whatever order they came in.
    private func assertInvariants(_ viewModel: HistoryViewModel, step: Int) {
        XCTAssertLessThanOrEqual(viewModel.visible.lowerBound, viewModel.visible.upperBound,
                                 "inverted window at step \(step)")
        XCTAssertGreaterThan(viewModel.temperatureTop, 0, "unusable scale at step \(step)")
        XCTAssertTrue(viewModel.temperatureTop.isFinite, "non-finite scale at step \(step)")
        if let focus = viewModel.focus {
            XCTAssertLessThanOrEqual(focus.lowerBound, focus.upperBound,
                                     "inverted focus at step \(step)")
        }
        for series in viewModel.series {
            for point in series.points {
                let plotted = viewModel.plotted(point, kind: series.kind)
                XCTAssertTrue(plotted.isFinite, "non-finite plot value at step \(step)")
            }
        }
        // Every offered group is one the chart can actually draw.
        for group in viewModel.offeredGroups {
            XCTAssertFalse(HistorySensors.ungroupedInCharts.contains(group),
                           "offered an unchartable group at step \(step)")
        }
    }

    /// A person clicking around at random for a few hundred steps.
    func testRandomInteractionNeverBreaksAnInvariant() async {
        let viewModel = HistoryViewModel(model: model)
        var random = Seeded(seed: 0xF00D)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for step in 0..<400 {
            switch Int.random(in: 0..<7, using: &random) {
            case 0:
                viewModel.range = HistoryRange.allCases.randomElement(using: &random)!
            case 1:
                let pool = ["CPU", "GPU", "SoC", "Fan", "Load", "Battery", "Fan rpm", "Nonsense"]
                viewModel.selectedGroups = Set(pool.shuffled(using: &random)
                    .prefix(Int.random(in: 0...pool.count, using: &random)))
            case 2:
                // Episodes with every shape of bounds, including impossible ones.
                let start = base.addingTimeInterval(Double.random(in: -100_000...100_000,
                                                                 using: &random))
                let length = Double.random(in: -5_000...5_000, using: &random)
                viewModel.focus(on: ThrottleEpisode(id: Int64(step), start: start,
                                                    end: Bool.random(using: &random)
                                                        ? start.addingTimeInterval(length) : nil))
            case 3:
                viewModel.clearFocus()
            case 4:
                viewModel.applyForTesting(availableGroups: ["SoC", "Fan", "Load", "Fan rpm"]
                    .shuffled(using: &random))
            case 5:
                let count = Int.random(in: 0...40, using: &random)
                viewModel.applyForTesting(series: [
                    Fixture.series("SoC", kind: .temperature, count: count, from: base) { _ in
                        Double.random(in: -50...200, using: &random)
                    },
                    Fixture.series("Fan", kind: .percent, count: count, from: base) { _ in
                        Double.random(in: 0...100, using: &random)
                    },
                ])
            default:
                await viewModel.reload()
            }
            assertInvariants(viewModel, step: step)
        }
    }

    /// Eight loads racing. Whatever order they land in, the state left behind
    /// must describe one coherent window, and `isLoading` must not stick on.
    func testConcurrentReloadsSettleOnOneCoherentState() async {
        let viewModel = HistoryViewModel(model: model)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { @MainActor in
                    viewModel.range = HistoryRange.allCases[index % HistoryRange.allCases.count]
                    await viewModel.reload()
                }
            }
        }
        // Setting `range` schedules a load of its own; the assertions below are
        // about where the dust settles, not about a moment mid-race.
        await viewModel.settle()
        assertInvariants(viewModel, step: -1)
        XCTAssertFalse(viewModel.isLoading, "a lost race left the spinner on")
        let span = viewModel.visible.upperBound.timeIntervalSince(viewModel.visible.lowerBound)
        XCTAssertEqual(span, viewModel.range.duration, accuracy: 5,
                       "the window on screen does not match the range that is selected")
    }

    /// Opening and closing the window repeatedly. Each one starts a refresh loop
    /// that must stop when its view goes away, or they accumulate and hammer the
    /// database forever.
    func testRefreshLoopsStopWhenTheirWindowGoesAway() async {
        for _ in 0..<20 {
            let viewModel = HistoryViewModel(model: model)
            let task = Task { await viewModel.refreshLoop() }
            // Let it get through at least one load, then close the window.
            await Task.yield()
            task.cancel()
            _ = await task.value
            XCTAssertTrue(task.isCancelled)
        }
        // The recorder is still usable afterwards — nothing was left holding it.
        let status = await model.historyRecorder.status()
        XCTAssertTrue(status.isRecording)
        XCTAssertNil(status.problem)
    }

    /// The end-to-end path the chart depends on: the descriptors the app records
    /// under are the ones the window's group query finds. A mismatch anywhere in
    /// that chain shows up as an empty chart and nothing else.
    func testRecordedSensorsReachTheChartUnderTheirOwnGroups() async throws {
        let now = Date()
        let readings = Fixture.temperatures(4)
        let fans = Fixture.fans(2)

        for offset in 0..<30 {
            let at = now.addingTimeInterval(Double(offset) - 30)
            var samples = readings.map {
                RecordedSample(sensor: HistorySensors.temperature($0, isAmbiguous: false),
                               value: $0.celsius)
            }
            samples += fans.flatMap { fan in
                [RecordedSample(sensor: HistorySensors.fanRPM(fan.index), value: 2_100),
                 RecordedSample(sensor: HistorySensors.fanDuty(fan.index), value: 44)]
            }
            samples.append(RecordedSample(sensor: HistorySensors.cpuLoad, value: 30))

            await model.historyRecorder.record(
                samples: samples, at: at,
                throttle: .init(date: at, cpuPercent: 30, pressure: .nominal, maxTempC: 61),
                profile: .init(id: "balanced", name: "Balanced", reason: "Default"))
        }
        await model.historyRecorder.flush(now: now)

        let viewModel = HistoryViewModel(model: model)
        // Whatever group these sensors classify into — the naming layer decides,
        // not this test.
        let temperatureGroup = HistorySensors.temperature(readings[0], isAmbiguous: false).group
        viewModel.selectedGroups = [temperatureGroup, HistorySensors.fan, HistorySensors.load]
        await viewModel.reload()
        await viewModel.settle()

        XCTAssertNil(viewModel.problem)
        let drawn = Set(viewModel.series.map(\.id))
        XCTAssertTrue(drawn.contains(temperatureGroup), "temperatures never reached the chart")
        XCTAssertTrue(drawn.contains(HistorySensors.fan), "fan duty never reached the chart")
        XCTAssertTrue(drawn.contains(HistorySensors.load), "CPU load never reached the chart")
        XCTAssertFalse(drawn.contains(HistorySensors.fanRPM),
                       "rpm has no axis and must not be plotted")

        // And the axes stay sane against real values.
        assertInvariants(viewModel, step: -2)
        XCTAssertTrue(viewModel.availableGroups.contains(HistorySensors.fanRPM),
                      "rpm is still recorded, just not charted")

        // The profile band the chart draws underneath came through too.
        XCTAssertEqual(viewModel.profileChanges.map(\.profileName), ["Balanced"])
    }

    /// Thirty days at hour resolution is the widest thing the window can be
    /// asked to draw. It must stay responsive rather than handing Charts a
    /// hundred thousand marks.
    func testAMonthOfDataIsDownsampledBeforeItReachesTheChart() async throws {
        let now = Date()
        let start = now.addingTimeInterval(-30 * 24 * 3_600)
        let sensor = HistorySensors.temperature(Fixture.temperatures(1)[0], isAmbiguous: false)

        // One sample every ten minutes for thirty days: 4,320 rows.
        var batches: [(date: Date, samples: [RecordedSample])] = []
        for step in 0..<4_320 {
            batches.append((date: start.addingTimeInterval(Double(step) * 600),
                            samples: [RecordedSample(sensor: sensor, value: 60)]))
        }
        let store = try HistoryStore(url: directory.appendingPathComponent("bulk.sqlite"))
        try store.insert(batches)
        try store.maintain(now: now)

        let series = try store.groupSeries(groups: [sensor.group], from: start, to: now,
                                           targetPoints: 600, now: now)
        let points = try XCTUnwrap(series.first).points
        XCTAssertLessThanOrEqual(points.count, 602,
                                 "the chart was handed \(points.count) marks for one line")
        XCTAssertGreaterThan(points.count, 100, "downsampled past usefulness")
    }
}
