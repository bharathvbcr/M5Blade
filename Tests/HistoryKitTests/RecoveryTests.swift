import XCTest
import FanKit
@testable import HistoryKit

/// What the app looks like after it was killed rather than closed — a force
/// quit, a panic, a battery pull. Episodes and sessions are written when they
/// *open* precisely so a crash leaves a record; the cost is that something has
/// to close them afterwards.
final class RecoveryTests: XCTestCase {

    private var directory: URL!
    private var url: URL!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let cpu = SensorDescriptor(key: "temp:cpu", name: "CPU", kind: .temperature, group: "CPU")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTests-\(UUID().uuidString)")
        url = directory.appendingPathComponent("history.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(at date: Date, _ value: Double) -> (date: Date, samples: [RecordedSample]) {
        (date: date, samples: [RecordedSample(sensor: cpu, value: value)])
    }

    // MARK: - Dangling episodes

    func testDanglingEpisodeIsClosedAtTheLastObservedSample() throws {
        do {
            let store = try HistoryStore(url: url)
            try store.insert([sample(at: base, 70), sample(at: base.addingTimeInterval(30), 80)])
            try store.save(ThrottleEpisode(start: base.addingTimeInterval(10), peakTempC: 95))
        }

        let reopened = try HistoryStore(url: url)
        let closed = try reopened.finalizeDanglingRecords(now: base.addingTimeInterval(86_400))
        XCTAssertEqual(closed.episodes, 1)

        let episode = try XCTUnwrap(reopened.episodes(from: base.addingTimeInterval(-60),
                                                      to: base.addingTimeInterval(3_600)).first)
        XCTAssertEqual(episode.end, base.addingTimeInterval(30),
                       "closed when observation stopped, not at the next launch")
        XCTAssertEqual(episode.duration, 20)
    }

    /// The reason this matters: an open episode belongs to *every* later window,
    /// so one dangling row would shade every chart the user ever opens.
    func testDanglingEpisodeStopsAppearingInUnrelatedWindows() throws {
        do {
            let store = try HistoryStore(url: url)
            try store.insert([sample(at: base, 70)])
            try store.save(ThrottleEpisode(start: base))
            let muchLater = base.addingTimeInterval(30 * 24 * 3_600)
            XCTAssertEqual(try store.episodes(from: muchLater,
                                              to: muchLater.addingTimeInterval(3_600)).count, 1,
                           "precondition: an open episode leaks into every later window")
        }

        let reopened = try HistoryStore(url: url)
        try reopened.finalizeDanglingRecords(now: base.addingTimeInterval(86_400))

        let muchLater = base.addingTimeInterval(30 * 24 * 3_600)
        XCTAssertTrue(try reopened.episodes(from: muchLater,
                                            to: muchLater.addingTimeInterval(3_600)).isEmpty)
    }

    /// No samples at all — a crash seconds after launch. A zero-length episode is
    /// honest; a negative-length one is a bug someone has to debug later.
    func testDanglingEpisodeWithNoSamplesGetsZeroLengthNotNegative() throws {
        do {
            let store = try HistoryStore(url: url)
            try store.save(ThrottleEpisode(start: base.addingTimeInterval(3_600)))
        }
        let reopened = try HistoryStore(url: url)
        try reopened.finalizeDanglingRecords(now: base)

        let episode = try XCTUnwrap(reopened.episodes(from: base,
                                                      to: base.addingTimeInterval(7_200)).first)
        XCTAssertEqual(episode.duration, 0)
        XCTAssertEqual(episode.end, episode.start)
    }

    func testDanglingSessionIsClosedToo() throws {
        do {
            let store = try HistoryStore(url: url)
            try store.insert([sample(at: base.addingTimeInterval(120), 70)])
            try store.save(RecordingSession(name: "Cinebench", start: base))
        }
        let reopened = try HistoryStore(url: url)
        let closed = try reopened.finalizeDanglingRecords(now: base.addingTimeInterval(86_400))
        XCTAssertEqual(closed.sessions, 1)

        let session = try XCTUnwrap(reopened.sessions(from: base.addingTimeInterval(-60),
                                                      to: base.addingTimeInterval(3_600)).first)
        XCTAssertEqual(session.end, base.addingTimeInterval(120))
    }

    func testFinalizingIsANoOpWhenNothingIsDangling() throws {
        let store = try HistoryStore(url: url)
        try store.save(ThrottleEpisode(start: base, end: base.addingTimeInterval(60)))
        let closed = try store.finalizeDanglingRecords(now: base.addingTimeInterval(3_600))
        XCTAssertEqual(closed.episodes, 0)
        XCTAssertEqual(closed.sessions, 0)

        let episode = try XCTUnwrap(store.episodes(from: base.addingTimeInterval(-1),
                                                   to: base.addingTimeInterval(3_600)).first)
        XCTAssertEqual(episode.end, base.addingTimeInterval(60), "an already-closed record is untouched")
    }

    /// The recorder must do this on its own, at open — nobody else is going to.
    func testRecorderFinalizesOnFirstUse() async throws {
        do {
            let store = try HistoryStore(url: url)
            try store.insert([sample(at: base, 70)])
            try store.save(ThrottleEpisode(start: base))
        }

        let recorder = HistoryRecorder(url: url)
        let window = try await recorder.window(groups: [], from: base.addingTimeInterval(-60),
                                               to: base.addingTimeInterval(3_600),
                                               now: base.addingTimeInterval(3_600))
        XCTAssertEqual(window.episodes.count, 1)
        XCTAssertNotNil(window.episodes[0].end, "a record left open by a crash must not read as running")
    }

    // MARK: - Reopening

    /// Closing without a clean shutdown leaves data in the WAL. Reopening has to
    /// recover it, or every unclean exit silently loses the last few minutes.
    func testDataSurvivesAnUncleanCloseViaTheWAL() throws {
        do {
            let store = try HistoryStore(url: url)
            try store.insert((0..<100).map { sample(at: base.addingTimeInterval(Double($0)),
                                                    Double(50 + $0 % 20)) })
            // No explicit checkpoint or close: the WAL is where this lives.
        }

        let reopened = try HistoryStore(url: url)
        let points = try reopened.series(keys: [cpu.key], from: base,
                                         to: base.addingTimeInterval(100),
                                         targetPoints: 1_000, now: base.addingTimeInterval(100))
            .first?.points ?? []
        XCTAssertEqual(points.count, 100)
    }

    func testSchemaMigrationIsIdempotentAcrossReopens() throws {
        for _ in 0..<5 {
            let store = try HistoryStore(url: url)
            try store.insert([sample(at: base, 70)])
            XCTAssertEqual(try store.knownSensors().count, 1)
        }
    }

    // MARK: - Write buffer

    private func throttleInput(_ date: Date) -> ThrottleDetector.Input {
        ThrottleDetector.Input(date: date, cpuPercent: 10, pressure: .nominal, maxTempC: 50)
    }

    func testBufferIsEmptyAfterASuccessfulFlush() async throws {
        let recorder = HistoryRecorder(url: url)
        for second in 0..<5 {
            let at = base.addingTimeInterval(Double(second))
            await recorder.record(samples: [RecordedSample(sensor: cpu, value: 70)],
                                  at: at, throttle: throttleInput(at))
        }
        await recorder.flush(now: base.addingTimeInterval(5))

        let status = await recorder.status()
        XCTAssertEqual(status.pendingBatches, 0)
        XCTAssertEqual(status.droppedBatches, 0)
    }

    /// A buffer that grows without limit is a memory leak with a good excuse.
    /// Dropping is allowed; dropping *silently* is not.
    func testOverflowingBufferDropsOldestAndSaysSo() async throws {
        let recorder = HistoryRecorder(url: url)
        // The first record flushes (lastFlush starts at distantPast), after which
        // ticks that share an instant never reach the flush interval — so they
        // accumulate, which is exactly the condition being tested.
        let overflow = 200
        for _ in 0..<(HistoryRecorder.maxBufferedBatches + overflow) {
            await recorder.record(samples: [RecordedSample(sensor: cpu, value: 70)],
                                  at: base, throttle: throttleInput(base))
        }

        let status = await recorder.status()
        XCTAssertEqual(status.pendingBatches, HistoryRecorder.maxBufferedBatches)
        XCTAssertEqual(status.droppedBatches, overflow - 1,
                       "one batch went out with the initial flush")
    }

    func testClearResetsTheDropCount() async throws {
        let recorder = HistoryRecorder(url: url)
        for _ in 0..<(HistoryRecorder.maxBufferedBatches + 10) {
            await recorder.record(samples: [RecordedSample(sensor: cpu, value: 70)],
                                  at: base, throttle: throttleInput(base))
        }
        try await recorder.clear()

        let status = await recorder.status()
        XCTAssertEqual(status.droppedBatches, 0)
        XCTAssertEqual(status.pendingBatches, 0)
    }
}
