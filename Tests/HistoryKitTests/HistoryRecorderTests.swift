import XCTest
import FanKit
@testable import HistoryKit

final class HistoryRecorderTests: XCTestCase {

    private var directory: URL!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let cpu = SensorDescriptor(key: "temp:cpu", name: "CPU", kind: .temperature, group: "CPU")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryRecorderTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recorder(recordsProcessNames: Bool = false) -> HistoryRecorder {
        HistoryRecorder(url: directory.appendingPathComponent("history.sqlite"),
                        recordsProcessNames: recordsProcessNames)
    }

    private func throttleInput(_ second: Int,
                               processes: [ThrottleDetector.ProcessLoad]) -> ThrottleDetector.Input {
        ThrottleDetector.Input(date: base.addingTimeInterval(Double(second)),
                               cpuPercent: 95,
                               pressure: .serious,
                               maxTempC: 98,
                               fanRPM: [0: 4000],
                               fanNearCeiling: true,
                               profileName: "Performance",
                               processes: processes)
    }

    private func drive(_ recorder: HistoryRecorder, seconds: ClosedRange<Int>,
                       processes: [ThrottleDetector.ProcessLoad]) async {
        for second in seconds {
            let date = base.addingTimeInterval(Double(second))
            await recorder.record(samples: [RecordedSample(sensor: cpu, value: 98)],
                                  at: date,
                                  throttle: throttleInput(second, processes: processes))
        }
    }

    /// The privacy guarantee is enforced where the write happens, not by asking
    /// callers to filter first (DESIGN §5.4).
    func testProcessNamesAreDroppedWhenAttributionIsOff() async throws {
        let recorder = recorder(recordsProcessNames: false)
        await drive(recorder, seconds: 0...40,
                    processes: [.init(name: "swift-frontend", cpuPercent: 90)])
        await recorder.flush(now: base.addingTimeInterval(40))

        let window = try await recorder.window(groups: ["CPU"], from: base,
                                               to: base.addingTimeInterval(60))
        let episode = try XCTUnwrap(window.episodes.first)
        XCTAssertEqual(episode.processes, [])
        let warns = await recorder.exportIncludesProcessNames(from: base,
                                                              to: base.addingTimeInterval(60))
        XCTAssertFalse(warns)
    }

    func testProcessNamesAreStoredWhenAttributionIsOn() async throws {
        let recorder = recorder(recordsProcessNames: true)
        await drive(recorder, seconds: 0...40,
                    processes: [.init(name: "swift-frontend", cpuPercent: 90)])

        let window = try await recorder.window(groups: ["CPU"], from: base,
                                               to: base.addingTimeInterval(60))
        let episode = try XCTUnwrap(window.episodes.first)
        XCTAssertEqual(episode.processes.first?.name, "swift-frontend")
    }

    /// An episode is written when it opens, so a crash mid-episode still leaves
    /// a record rather than nothing at all.
    func testOpenEpisodeIsPersistedBeforeItEnds() async throws {
        let recorder = recorder()
        await drive(recorder, seconds: 0...30, processes: [])

        let window = try await recorder.window(groups: ["CPU"], from: base,
                                               to: base.addingTimeInterval(60))
        let episode = try XCTUnwrap(window.episodes.first)
        XCTAssertNil(episode.end)
        XCTAssertEqual(episode.peakTempC, 98)
    }

    func testBufferedSamplesAreVisibleToTheNextQuery() async throws {
        let recorder = recorder()
        // Fewer seconds than the flush interval: the samples are still in the
        // buffer, and a query must not show a gap because of it.
        await drive(recorder, seconds: 0...3, processes: [])

        let window = try await recorder.window(groups: ["CPU"], from: base,
                                               to: base.addingTimeInterval(10),
                                               now: base.addingTimeInterval(10))
        XCTAssertEqual(window.groups.first?.points.count, 4)
        XCTAssertEqual(window.availableGroups, ["CPU"])
    }

    func testProfileChangesAreRecordedOncePerTransition() async throws {
        let recorder = recorder()
        for second in 0..<5 {
            await recorder.record(samples: [], at: base.addingTimeInterval(Double(second)),
                                  throttle: throttleInput(second, processes: []),
                                  profile: .init(id: "balanced", name: "Balanced", reason: "Default"))
        }
        await recorder.record(samples: [], at: base.addingTimeInterval(10),
                              throttle: throttleInput(10, processes: []),
                              profile: .init(id: "performance", name: "Performance", reason: "Manual"))

        let window = try await recorder.window(groups: [], from: base,
                                               to: base.addingTimeInterval(60))
        XCTAssertEqual(window.profileChanges.map(\.profileName), ["Balanced", "Performance"])
    }

    func testSessionOpensAndClosesOnce() async throws {
        let recorder = recorder()
        let started = await recorder.startSession(name: "Cinebench", profileName: "Performance",
                                                  at: base)
        XCTAssertNotNil(started)
        // A second start while one is open returns the open one rather than
        // silently beginning a second, overlapping session.
        let again = await recorder.startSession(name: "Other", profileName: "Balanced",
                                                at: base.addingTimeInterval(5))
        XCTAssertEqual(again?.id, started?.id)

        let ended = await recorder.endSession(at: base.addingTimeInterval(60))
        XCTAssertEqual(ended?.end, base.addingTimeInterval(60))
        let none = await recorder.endSession(at: base.addingTimeInterval(90))
        XCTAssertNil(none)

        let window = try await recorder.window(groups: [], from: base.addingTimeInterval(-10),
                                               to: base.addingTimeInterval(120))
        XCTAssertEqual(window.sessions.count, 1)
    }

    func testStatusReportsSizeAndRecordingState() async throws {
        let recorder = recorder()
        await drive(recorder, seconds: 0...3, processes: [])
        await recorder.flush(now: base.addingTimeInterval(3))

        let status = await recorder.status()
        XCTAssertTrue(status.isRecording)
        XCTAssertNil(status.problem)
        XCTAssertGreaterThan(status.byteSize, 0)
        XCTAssertEqual(status.oldestSample, base)
    }

    /// A database that cannot be opened turns history off and says why, rather
    /// than throwing on every tick or pretending to record.
    func testUnopenableDatabaseDegradesToAReportedProblem() async throws {
        // A path whose parent is a regular file: the directory create fails.
        let blocker = directory.appendingPathComponent("blocker")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker)

        let recorder = HistoryRecorder(url: blocker.appendingPathComponent("nested/history.sqlite"))
        await drive(recorder, seconds: 0...2, processes: [])

        let status = await recorder.status()
        XCTAssertFalse(status.isRecording)
        XCTAssertNotNil(status.problem)
        await XCTAssertThrowsErrorAsync(try await recorder.window(groups: ["CPU"], from: base,
                                                                  to: base.addingTimeInterval(60)))
    }

    func testClearEmptiesEverythingAndKeepsRecording() async throws {
        let recorder = recorder(recordsProcessNames: true)
        await drive(recorder, seconds: 0...40, processes: [.init(name: "Xcode", cpuPercent: 90)])
        try await recorder.clear()

        var window = try await recorder.window(groups: ["CPU"], from: base,
                                               to: base.addingTimeInterval(60),
                                               now: base.addingTimeInterval(60))
        XCTAssertTrue(window.episodes.isEmpty)
        XCTAssertTrue(window.groups.isEmpty)

        await drive(recorder, seconds: 100...103, processes: [])
        window = try await recorder.window(groups: ["CPU"], from: base.addingTimeInterval(90),
                                           to: base.addingTimeInterval(120),
                                           now: base.addingTimeInterval(120))
        XCTAssertEqual(window.groups.first?.points.count, 4)
    }
}

/// XCTest's `XCTAssertThrowsError` predates `async`; this is the same assertion
/// for an awaited expression.
private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
