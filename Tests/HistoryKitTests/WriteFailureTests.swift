import XCTest
import FanKit
@testable import HistoryKit

/// What the recorder does when the database refuses to be written to.
///
/// A full volume, a read-only mount, a database locked by something else: the
/// interesting part is not that the write fails, it is what is left behind
/// afterwards. An event row is written the moment it opens and rewritten on
/// every tick, so the write that carries the *end* is the one that turns "still
/// elevated" into a finished record — and it was the one being dropped.
///
/// Every case here fails against the recorder as it was: the failure showed up
/// not as an error but as a plausible, wrong record.
final class WriteFailureTests: XCTestCase {

    private var directory: URL!
    private var url: URL!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let sensor = SensorDescriptor(key: "temp:soc", name: "SoC",
                                          kind: .temperature, group: "SoC")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteFailureTests-\(UUID().uuidString)")
        url = directory.appendingPathComponent("history.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One tick at `offset` seconds past `base`, at `temp`.
    private func tick(_ recorder: HistoryRecorder, _ offset: Int, temp: Double,
                      cpu: Double = 95) async {
        let date = base.addingTimeInterval(Double(offset))
        await recorder.record(
            samples: [RecordedSample(sensor: sensor, value: temp)],
            at: date,
            throttle: .init(date: date, cpuPercent: cpu, pressure: .nominal, maxTempC: temp),
            spike: .init(date: date, maxTempC: temp, cpuPercent: cpu, hottestGroup: "SoC"))
    }

    /// A trace that opens a spike at tick 5 and closes it at tick 39.
    ///
    /// The close is `clearSeconds` after the last sample above the settle point,
    /// which is tick 9 — the detector's own arithmetic, not a guess: a 55 → 95
    /// rise settles at 75, and 60 °C is below it.
    private func spikeTrace(_ recorder: HistoryRecorder, through last: Int) async {
        for step in 0...last {
            await tick(recorder, step, temp: step < 5 ? 55 : (step < 10 ? 95 : 60))
        }
    }

    // MARK: - A close that could not be written

    /// The record that lasts is the one written when the spike ends. Losing it
    /// left a row on disk saying the machine was still hot — hours later, on
    /// every chart that reached back that far.
    func testASpikeCloseThatCouldNotBeWrittenIsRetriedRatherThanLost() async throws {
        let recorder = HistoryRecorder(url: url)
        await spikeTrace(recorder, through: 30)

        // The disk goes away just before the tick that ends the spike.
        try await recorder.setWritesFailForTesting(true)
        for step in 31...45 { await tick(recorder, step, temp: 60) }

        // While it is failing, the recorder says so, and owes the database a row.
        let failing = await recorder.status()
        XCTAssertNotNil(failing.problem, "a write that failed was not reported")
        let owed = await recorder.unwrittenEventCountForTesting()
        XCTAssertGreaterThan(owed, 0, "the close was dropped rather than kept")

        // The disk comes back.
        try await recorder.setWritesFailForTesting(false)
        await recorder.flush(now: base.addingTimeInterval(60))

        let insights = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                   to: base.addingTimeInterval(3_600))
        XCTAssertEqual(insights.spikes.count, 1)
        let spike = try XCTUnwrap(insights.spikes.first)
        XCTAssertEqual(spike.end, base.addingTimeInterval(9),
                       "the spike is still open on disk, or ended somewhere it did not")

        // And only then does it report healthy again.
        let recovered = await recorder.status()
        XCTAssertNil(recovered.problem, "still reporting a failure it has recovered from")
        let stillOwed = await recorder.unwrittenEventCountForTesting()
        XCTAssertEqual(stillOwed, 0)
    }

    /// The failure used to be erased by the next thing that *did* work: a
    /// successful sample write cleared the one field the status came from, so a
    /// stranded row was reported by a recorder claiming to be healthy.
    func testASucceedingSampleWriteDoesNotEraseAnOutstandingEventFailure() async throws {
        let recorder = HistoryRecorder(url: url)
        await spikeTrace(recorder, through: 30)

        try await recorder.setWritesFailForTesting(true)
        for step in 31...45 { await tick(recorder, step, temp: 60) }
        let outstanding = await recorder.unwrittenEventCountForTesting()
        XCTAssertGreaterThan(outstanding, 0, "precondition")

        // Reads flush the buffer on their way through. That write now succeeds —
        // and must not be taken as evidence about the row still owed.
        try await recorder.setWritesFailForTesting(false)
        _ = try await recorder.window(groups: ["SoC"], from: base,
                                      to: base.addingTimeInterval(3_600),
                                      now: base.addingTimeInterval(3_600))

        // Either the row was written or the failure is still reported. What must
        // never happen is neither: a healthy status over an unfinished record.
        let spikes = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                 to: base.addingTimeInterval(3_600)).spikes
        let status = await recorder.status()
        XCTAssertTrue(spikes.first?.end != nil || status.problem != nil,
                      "a recorder reporting no problem over a spike still marked in progress")
    }

    /// The id of the row being rewritten is recorder state, not detector state.
    /// Left set after a failed write, it belonged to a record that was over — and
    /// the *next* spike's updates were written over the previous spike's row.
    func testAFailedOpenNeverWritesTheNextSpikeOverThePreviousOnesRow() async throws {
        let recorder = HistoryRecorder(url: url)
        await spikeTrace(recorder, through: 30)
        await recorder.flush(now: base.addingTimeInterval(30))

        // Writes fail across the first spike's close *and* the second's open, so
        // the recorder reaches the second spike's updates still holding an id.
        try await recorder.setWritesFailForTesting(true)
        for step in 31...45 { await tick(recorder, step, temp: 60) }
        for step in 46...50 { await tick(recorder, step, temp: 108) }   // opens a second spike

        // And comes back in time for that spike's updates.
        try await recorder.setWritesFailForTesting(false)
        for step in 51...55 { await tick(recorder, step, temp: 108) }
        // A flush lands the first spike's close. The second spike is still
        // running, and its next ticks must go on rewriting its own row: a retry
        // that reset the recorder's id would make every tick after it insert a
        // fresh row for the same spike.
        await recorder.flush(now: base.addingTimeInterval(56))
        for step in 57...62 { await tick(recorder, step, temp: 108) }
        await recorder.flush(now: base.addingTimeInterval(63))

        let spikes = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                 to: base.addingTimeInterval(3_600)).spikes
        XCTAssertEqual(spikes.count, 2, "two spikes happened; \(spikes.count) rows describe them")

        // The first one still says what it said: 55 °C rising to 95, ended at 9.
        let first = try XCTUnwrap(spikes.last)
        XCTAssertEqual(first.start, base)
        XCTAssertEqual(first.peakTempC, 95)
        XCTAssertEqual(first.end, base.addingTimeInterval(9))
        // The second is its own record, not the first one wearing new numbers.
        let second = try XCTUnwrap(spikes.first)
        XCTAssertEqual(second.peakTempC, 108)
        XCTAssertNotEqual(second.id, first.id)
    }

    /// Clearing history is a delete. A row still owed to the database is a row
    /// the user just asked to be rid of, and retrying it would put it back.
    func testClearingHistoryDropsWhatWasStillOwedToTheDatabase() async throws {
        let recorder = HistoryRecorder(url: url)
        await spikeTrace(recorder, through: 30)

        try await recorder.setWritesFailForTesting(true)
        for step in 31...45 { await tick(recorder, step, temp: 60) }
        let outstanding = await recorder.unwrittenEventCountForTesting()
        XCTAssertGreaterThan(outstanding, 0, "precondition")

        try await recorder.setWritesFailForTesting(false)
        try await recorder.clear()
        await recorder.flush(now: base.addingTimeInterval(60))

        let spikes = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                 to: base.addingTimeInterval(3_600)).spikes
        XCTAssertTrue(spikes.isEmpty, "a retry wrote back a record the user had cleared")
    }

    /// Rollup and pruning only run when the recorder believes it is healthy, so
    /// a failure it will never retry — a profile change, a session — must not
    /// leave it believing otherwise forever. Reporting a write that failed once
    /// and has succeeded ever since would quietly stop retention for good.
    func testAOneShotWriteFailureStopsBeingReportedOnceNothingIsOwed() async throws {
        let recorder = HistoryRecorder(url: url)
        await tick(recorder, 0, temp: 55, cpu: 10)

        try await recorder.setWritesFailForTesting(true)
        await recorder.record(
            samples: [], at: base.addingTimeInterval(1),
            throttle: .init(date: base.addingTimeInterval(1), cpuPercent: 10,
                            pressure: .nominal, maxTempC: 55),
            profile: .init(id: "silent", name: "Silent", reason: "Manual"))
        let reported = await recorder.status()
        XCTAssertNotNil(reported.problem, "a profile change that could not be written said nothing")

        try await recorder.setWritesFailForTesting(false)
        for step in 2...20 { await tick(recorder, step, temp: 55, cpu: 10) }
        await recorder.flush(now: base.addingTimeInterval(21))

        let owed = await recorder.unwrittenEventCountForTesting()
        XCTAssertEqual(owed, 0, "precondition: nothing is still owed")
        let recovered = await recorder.status()
        XCTAssertNil(recovered.problem,
                     "still reporting a one-shot failure it has long since recovered from")
    }

    // MARK: - A clock that steps backwards

    /// `lastFlush` is a watermark, and a watermark left in the future stops the
    /// thing it guards from ever running. An NTP correction or a bad wake used to
    /// park it there: the buffer went on filling, silently, until it overflowed
    /// and started dropping the oldest ticks. The rollup watermark winds itself
    /// back for exactly this reason.
    func testAClockSteppedBackwardsStillFlushesTheBuffer() async throws {
        let recorder = HistoryRecorder(url: url)
        for step in 0..<30 { await tick(recorder, step, temp: 55, cpu: 10) }
        await recorder.flush(now: base.addingTimeInterval(30))

        // An hour backwards, then a minute of ticks at the corrected time.
        for step in -3_600 ..< -3_540 { await tick(recorder, step, temp: 55, cpu: 10) }

        let pending = await recorder.status().pendingBatches
        XCTAssertLessThan(pending, 20,
                          "\(pending) ticks stuck in the buffer: the flush watermark is in the future")

        let window = try await recorder.window(groups: ["SoC"],
                                               from: base.addingTimeInterval(-3_700),
                                               to: base.addingTimeInterval(60),
                                               targetPoints: 10_000,
                                               now: base.addingTimeInterval(60))
        XCTAssertEqual(window.groups.first?.points.count, 90,
                       "samples recorded after the correction never reached the database")
    }
}
