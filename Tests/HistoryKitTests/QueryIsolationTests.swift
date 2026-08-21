import XCTest
import FanKit
@testable import HistoryKit

/// Reading must not have side effects on retention. The History window queries
/// arbitrary past windows — scrubbing to an episode from this morning must not
/// run rollup and pruning against a clock from this morning.
final class QueryIsolationTests: XCTestCase {

    private var directory: URL!
    private var url: URL!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let cpu = SensorDescriptor(key: "temp:cpu", name: "CPU", kind: .temperature, group: "CPU")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueryIsolationTests-\(UUID().uuidString)")
        url = directory.appendingPathComponent("history.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func throttle(_ date: Date) -> ThrottleDetector.Input {
        ThrottleDetector.Input(date: date, cpuPercent: 10, pressure: .nominal, maxTempC: 50)
    }

    func testQueryingAnOldWindowDoesNotWindTheRollupBackwards() async throws {
        let recorder = HistoryRecorder(url: url)

        // Three hours of ticks, flushed and maintained as normal.
        for minute in stride(from: 0, to: 180, by: 1) {
            let at = base.addingTimeInterval(Double(minute) * 60)
            await recorder.record(samples: [RecordedSample(sensor: cpu, value: Double(50 + minute % 30))],
                                  at: at, throttle: throttle(at))
        }
        let now = base.addingTimeInterval(180 * 60)
        await recorder.flush(now: now)

        // Scrub back to the very beginning, repeatedly, the way clicking through
        // episodes does.
        for _ in 0..<5 {
            _ = try await recorder.window(groups: ["CPU"], from: base,
                                          to: base.addingTimeInterval(600), now: now)
        }

        // The record is unchanged: still reachable, still at the same resolution.
        let window = try await recorder.window(groups: ["CPU"], from: base, to: now,
                                               targetPoints: 100_000, now: now)
        let points = try XCTUnwrap(window.groups.first).points
        XCTAssertEqual(points.count, 180)
        XCTAssertEqual(points.map(\.maximum).max(), 79)
    }

    /// The buffer still has to land, though — a read that skipped it would show
    /// a chart that stops ten seconds short of the present.
    func testQueryStillSeesUnflushedTicks() async throws {
        let recorder = HistoryRecorder(url: url)
        for second in 0..<4 {
            let at = base.addingTimeInterval(Double(second))
            await recorder.record(samples: [RecordedSample(sensor: cpu, value: 70)],
                                  at: at, throttle: throttle(at))
        }

        let window = try await recorder.window(groups: ["CPU"], from: base,
                                               to: base.addingTimeInterval(10),
                                               now: base.addingTimeInterval(10))
        XCTAssertEqual(window.groups.first?.points.count, 4)
        let pending = await recorder.status().pendingBatches
        XCTAssertEqual(pending, 0)
    }

    func testExportAlsoSeesUnflushedTicksWithoutRunningRetention() async throws {
        let recorder = HistoryRecorder(url: url)
        for second in 0..<4 {
            let at = base.addingTimeInterval(Double(second))
            await recorder.record(samples: [RecordedSample(sensor: cpu, value: 70)],
                                  at: at, throttle: throttle(at))
        }

        let data = try await recorder.export(.csv, from: base, to: base.addingTimeInterval(10),
                                             now: base.addingTimeInterval(10))
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 5, "header plus four ticks")
    }
}
