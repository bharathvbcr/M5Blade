import XCTest
@testable import HistoryKit

final class HistoryStoreTests: XCTestCase {

    private var directory: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryKitTests-\(UUID().uuidString)")
        store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private let cpu = SensorDescriptor(key: "temp:cpu", name: "CPU", kind: .temperature, group: "CPU")
    private let gpu = SensorDescriptor(key: "temp:gpu", name: "GPU", kind: .temperature, group: "GPU")

    private func insert(_ sensor: SensorDescriptor, values: [Double], startingAt start: Date) throws {
        try store.insert(values.enumerated().map { offset, value in
            (date: start.addingTimeInterval(Double(offset)),
             samples: [RecordedSample(sensor: sensor, value: value)])
        })
    }

    // MARK: - Raw tier

    func testRawSeriesReturnsEverySampleWhenNotDownsampled() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-10)
        try insert(cpu, values: [50, 51, 52, 53, 54], startingAt: start)

        let series = try store.series(keys: [cpu.key], from: start, to: now,
                                      targetPoints: 600, now: now)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].points.count, 5)
        XCTAssertEqual(series[0].points.map(\.average), [50, 51, 52, 53, 54])
        XCTAssertEqual(series[0].kind, .temperature)
    }

    func testUnknownKeyIsAbsentRatherThanEmpty() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try insert(cpu, values: [50], startingAt: now.addingTimeInterval(-5))

        let series = try store.series(keys: [cpu.key, "temp:nope"],
                                      from: now.addingTimeInterval(-60), to: now, now: now)
        XCTAssertEqual(series.map(\.id), [cpu.key])
    }

    /// The chart asks for a point budget; the store must honour it by widening
    /// buckets, not by truncating the window.
    func testTargetPointsWidensBucketsInsteadOfDroppingData() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-600)
        try insert(cpu, values: (0..<600).map { Double($0 % 100) }, startingAt: start)

        let series = try store.series(keys: [cpu.key], from: start, to: now,
                                      targetPoints: 10, now: now)
        let points = try XCTUnwrap(series.first).points
        // Buckets are aligned to absolute epoch multiples, not to the start of
        // the query, so the same instant lands in the same bucket no matter what
        // window it is asked for. That costs at most one extra partial bucket at
        // each edge.
        XCTAssertEqual(points.count, 11)
        let bucket = TimeInterval(600 / 10)
        XCTAssertEqual(points[0].date.timeIntervalSince1970
                        .truncatingRemainder(dividingBy: bucket), 0)
        XCTAssertLessThanOrEqual(points[0].date, start)
        XCTAssertGreaterThan(points[points.count - 1].date, start.addingTimeInterval(540))
        // A widened bucket keeps the extremes it swallowed. The leading bucket is
        // partial — it only holds the 40 samples that fall inside the window.
        XCTAssertEqual(points[0].minimum, 0)
        XCTAssertEqual(points[0].maximum, 39)
        XCTAssertEqual(points[1].minimum, 40)
        XCTAssertEqual(points[1].maximum, 99)
    }

    func testExclusiveUpperBoundDoesNotDoubleCountBoundarySample() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try insert(cpu, values: [10, 20, 30], startingAt: now.addingTimeInterval(-3))

        let series = try store.series(keys: [cpu.key], from: now.addingTimeInterval(-3),
                                      to: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(try XCTUnwrap(series.first).points.map(\.average), [10, 20])
    }

    // MARK: - Group aggregation

    func testGroupSeriesTracksTheHottestSensorInTheGroup() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-3)
        let hotter = SensorDescriptor(key: "temp:cpu2", name: "CPU 2", kind: .temperature, group: "CPU")
        try store.insert([
            (date: start, samples: [RecordedSample(sensor: cpu, value: 50),
                                    RecordedSample(sensor: hotter, value: 70),
                                    RecordedSample(sensor: gpu, value: 90)]),
        ])

        let series = try store.groupSeries(groups: ["CPU"], from: start, to: now, now: now)
        XCTAssertEqual(series.count, 1, "the GPU sensor must not leak into the CPU group")
        XCTAssertEqual(try XCTUnwrap(series.first).points.map(\.maximum), [70])
    }

    /// Collapsing sensors and time in one pass made `max` swallow everything —
    /// a group's average and minimum both came back as the bucket maximum. The
    /// band has to describe the hottest sensor's trace, not the whole bucket.
    func testGroupSeriesBandDescribesTheHottestSensorOverTimeNotTheBucketMaximum() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-4)
        let second = SensorDescriptor(key: "temp:cpu2", name: "CPU 2",
                                      kind: .temperature, group: "CPU")
        // Sensor A is always the hotter of the two, and climbs 50 → 53.
        try store.insert((0..<4).map { tick in
            (date: start.addingTimeInterval(Double(tick)),
             samples: [RecordedSample(sensor: cpu, value: Double(50 + tick)),
                       RecordedSample(sensor: second, value: 10)])
        })

        let point = try XCTUnwrap(
            store.groupSeries(groups: ["CPU"], from: start, to: now,
                              targetPoints: 1, now: now).first?.points.first)
        XCTAssertEqual(point.minimum, 50, "the hottest sensor's low point")
        XCTAssertEqual(point.maximum, 53, "the hottest sensor's high point")
        XCTAssertEqual(point.average, 51.5, accuracy: 0.0001, "mean over time, not the peak")
        XCTAssertLessThanOrEqual(point.minimum, point.average)
        XCTAssertLessThanOrEqual(point.average, point.maximum)
    }

    // MARK: - Rollup and retention

    func testMinuteRollupSurvivesRawPruning() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Three hours old: past the two-hour raw retention.
        let start = Date(timeIntervalSince1970: 1_700_000_000 - 3 * 3_600)
        try insert(cpu, values: (0..<120).map { Double(40 + $0 % 60) }, startingAt: start)

        // Before maintenance the samples are only in the raw tier, which no
        // longer answers a query this old.
        XCTAssertTrue(try store.series(keys: [cpu.key], from: start, to: now, now: now).isEmpty)

        try store.maintain(now: now)

        let series = try store.series(keys: [cpu.key], from: start, to: now, now: now)
        let points = try XCTUnwrap(series.first).points
        // 120 seconds of samples starting 20s into a minute spans three minute
        // buckets, and the query includes the one it opens inside rather than
        // dropping that leading fragment.
        XCTAssertEqual(points.count, 3)
        XCTAssertLessThanOrEqual(points[0].date, start)
        XCTAssertEqual(points[0].minimum, 40)
        XCTAssertEqual(points[0].maximum, 79, "the leading bucket holds only the 40s inside it")
        XCTAssertEqual(points[1].maximum, 99)
        XCTAssertEqual(store.resolutionSeconds(from: start, now: now), 60)
    }

    func testHourTierIsReachedWhenMinuteDataAgesOut() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Twenty days old: past both the raw and the minute retention.
        let start = now.addingTimeInterval(-20 * 24 * 3_600)
        try insert(cpu, values: (0..<180).map { _ in 80 }, startingAt: start)

        try store.maintain(now: now)

        let series = try store.series(keys: [cpu.key], from: now.addingTimeInterval(-30 * 24 * 3_600),
                                      to: now, now: now)
        let points = try XCTUnwrap(series.first).points
        XCTAssertFalse(points.isEmpty, "three minutes of samples must survive as an hour bucket")
        XCTAssertEqual(points.map(\.average), points.map { _ in 80 })
        XCTAssertEqual(store.resolutionSeconds(from: start, now: now), 3_600)
    }

    /// Rollup is watermarked and uses INSERT OR REPLACE — running it twice, or
    /// after a crash mid-run, must not double-count.
    func testMaintenanceIsIdempotent() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-3 * 3_600)
        try insert(cpu, values: (0..<60).map { Double($0) }, startingAt: start)

        try store.maintain(now: now)
        let first = try store.series(keys: [cpu.key], from: start, to: now, now: now)
        try store.maintain(now: now)
        try store.maintain(now: now)
        let third = try store.series(keys: [cpu.key], from: start, to: now, now: now)

        XCTAssertEqual(first.first?.points, third.first?.points)
    }

    /// The bucket containing `now` is still filling; averaging it would write a
    /// value the next sample contradicts.
    func testPartialBucketIsNotRolledUp() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_040)   // 40s into a minute
        let start = Date(timeIntervalSince1970: 1_700_000_000) // same minute
        try insert(cpu, values: [10, 20, 30], startingAt: start)

        try store.maintain(now: now)

        // Nothing rolled up, but the raw tier still answers — this window is
        // well inside raw retention.
        let series = try store.series(keys: [cpu.key], from: start, to: now, now: now)
        XCTAssertEqual(try XCTUnwrap(series.first).points.count, 3)
    }

    // MARK: - Episodes, sessions, profile changes

    func testEpisodeRoundTripsIncludingFanMapAndProcesses() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let episode = ThrottleEpisode(start: start,
                                      end: start.addingTimeInterval(258),
                                      peakTempC: 97.5,
                                      peakPressure: 2,
                                      meanCPUPercent: 88,
                                      profileName: "Performance",
                                      onBattery: true,
                                      externalDisplayCount: 2,
                                      fanRPMAtPeak: [0: 4200, 1: 4100],
                                      processes: [.init(name: "swift-frontend", percent: 71)])
        let id = try store.save(episode)
        XCTAssertNotEqual(id, 0)

        let loaded = try store.episodes(from: start.addingTimeInterval(-60),
                                        to: start.addingTimeInterval(600))
        XCTAssertEqual(loaded.count, 1)
        var expected = episode
        expected.id = id
        XCTAssertEqual(loaded[0], expected)
        XCTAssertEqual(loaded[0].duration, 258)
    }

    func testOpenEpisodeIsReturnedForWindowsThatStartAfterIt() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try store.save(ThrottleEpisode(start: start))

        // An episode with no end is still running, so it belongs to every later
        // window until it closes.
        let loaded = try store.episodes(from: start.addingTimeInterval(3_600),
                                        to: start.addingTimeInterval(7_200))
        XCTAssertEqual(loaded.map(\.id), [id])
        XCTAssertNil(loaded[0].duration)
    }

    func testUpdatingAnEpisodeDoesNotCreateASecondRow() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var episode = ThrottleEpisode(start: start)
        episode.id = try store.save(episode)
        episode.end = start.addingTimeInterval(60)
        episode.peakTempC = 99
        try store.save(episode)

        let loaded = try store.episodes(from: start.addingTimeInterval(-1),
                                        to: start.addingTimeInterval(600))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].peakTempC, 99)
    }

    /// Without the row immediately before the window, the first profile band on
    /// the chart would have nothing to label it.
    func testProfileChangesIncludeTheChangeThatPrecedesTheWindow() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try store.record(ProfileChange(date: base, profileID: "a", profileName: "Balanced", reason: "Default"))
        try store.record(ProfileChange(date: base.addingTimeInterval(600),
                                       profileID: "b", profileName: "Performance", reason: "Manual"))

        let changes = try store.profileChanges(from: base.addingTimeInterval(300),
                                               to: base.addingTimeInterval(900))
        XCTAssertEqual(changes.map(\.profileName), ["Balanced", "Performance"])
        XCTAssertEqual(try store.lastProfileChange()?.profileID, "b")
    }

    func testSessionRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = RecordingSession(name: "Cinebench", start: start, profileName: "Performance")
        session.id = try store.save(session)
        session.end = start.addingTimeInterval(300)
        try store.save(session)

        let loaded = try store.sessions(from: start.addingTimeInterval(-60),
                                        to: start.addingTimeInterval(600))
        XCTAssertEqual(loaded, [session])
    }

    // MARK: - Housekeeping

    func testClearRemovesSensorCatalogueAsWellAsSamples() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try insert(cpu, values: [50, 60], startingAt: now.addingTimeInterval(-2))
        try store.save(ThrottleEpisode(start: now, processes: [.init(name: "Xcode", percent: 100)]))
        XCTAssertFalse(try store.knownSensors().isEmpty)

        try store.clear()

        XCTAssertTrue(try store.knownSensors().isEmpty)
        XCTAssertTrue(try store.knownGroups().isEmpty)
        XCTAssertTrue(try store.episodes(from: now.addingTimeInterval(-60),
                                         to: now.addingTimeInterval(60)).isEmpty)
        XCTAssertNil(try store.oldestSample())

        // And the store is still usable afterwards.
        try insert(cpu, values: [42], startingAt: now.addingTimeInterval(-1))
        XCTAssertEqual(try store.knownSensors().count, 1)
    }

    func testOldestSampleSpansAllTiers() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-3 * 3_600)
        try insert(cpu, values: [70, 71], startingAt: old)
        try store.maintain(now: now)
        try insert(cpu, values: [50], startingAt: now.addingTimeInterval(-5))

        let oldest = try XCTUnwrap(store.oldestSample())
        // The raw rows were pruned. Rollup is continuous rather than deferred
        // until a tier expires — otherwise minute rows would age out at 14 days
        // before anything had folded them into hours — so the oldest surviving
        // trace of those samples is the hour bucket.
        XCTAssertEqual(oldest.timeIntervalSince1970,
                       (old.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
    }

    func testReopeningAnExistingDatabaseKeepsItsData() throws {
        let url = directory.appendingPathComponent("history.sqlite")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try insert(cpu, values: [55], startingAt: now.addingTimeInterval(-1))
        store = nil

        let reopened = try HistoryStore(url: url)
        XCTAssertEqual(try reopened.knownSensors().map(\.key), [cpu.key])
        store = reopened
    }
}
