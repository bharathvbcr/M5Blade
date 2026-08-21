import XCTest
@testable import HistoryKit

/// The retention scheme rests on one invariant: **nothing is deleted that has
/// not been folded into the next tier.** Every test here is a way that could
/// stop being true — a clock that steps backwards, a rollup that stalls, a
/// sample that arrives after the rollup has already passed its timestamp.
final class RetentionInvariantTests: XCTestCase {

    private var directory: URL!
    private var store: HistoryStore!

    /// Deliberately *not* on a minute boundary (1_700_000_000 is 20s past one),
    /// so these tests exercise unaligned windows rather than the easy case.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let cpu = SensorDescriptor(key: "temp:cpu", name: "CPU", kind: .temperature, group: "CPU")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetentionTests-\(UUID().uuidString)")
        store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func insert(_ values: [Double], startingAt start: Date) throws {
        try store.insert(values.enumerated().map { offset, value in
            (date: start.addingTimeInterval(Double(offset)),
             samples: [RecordedSample(sensor: cpu, value: value)])
        })
    }

    /// Everything that was recorded is still reachable at *some* resolution.
    private func totalReachable(around date: Date, now: Date) throws -> [SeriesPoint] {
        try store.series(keys: [cpu.key],
                         from: date.addingTimeInterval(-3_600),
                         to: date.addingTimeInterval(3_600),
                         targetPoints: 100_000, now: now)
            .first?.points ?? []
    }

    // MARK: - Clock steps backwards

    /// An NTP correction or a bad wake can move the clock backwards. The old
    /// code left the watermark stranded in the future: rollup skipped every run
    /// until real time caught up, while pruning carried on deleting.
    func testClockSteppingBackwardsDoesNotStrandTheRollup() throws {
        let future = base.addingTimeInterval(4 * 3_600)
        try insert([70, 71], startingAt: future)
        try store.maintain(now: future.addingTimeInterval(120))

        // Clock jumps back four hours. Samples keep arriving at the corrected time.
        try insert([80, 81], startingAt: base)
        try store.maintain(now: base.addingTimeInterval(120))

        let points = try totalReachable(around: base, now: base.addingTimeInterval(4 * 3_600))
        XCTAssertFalse(points.isEmpty, "the post-correction samples must survive the rollup")
        XCTAssertEqual(points.map(\.maximum).max(), 81)
    }

    func testWatermarkIsWoundBackRatherThanLeftInTheFuture() throws {
        let future = base.addingTimeInterval(10 * 3_600)
        try insert([70], startingAt: future)
        try store.maintain(now: future.addingTimeInterval(120))

        // One maintenance run at the corrected time clamps the watermark; the
        // next one does real work again.
        try store.maintain(now: base)
        try insert([90, 91], startingAt: base)
        try store.maintain(now: base.addingTimeInterval(120))

        let minute = try store.series(keys: [cpu.key], from: base, to: base.addingTimeInterval(60),
                                      targetPoints: 1, now: base.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(minute.first?.points.first?.maximum, 91,
                       "the minute bucket containing an unaligned window start must be included")
    }

    // MARK: - Rollup stalls

    /// Retention alone would delete raw seconds two hours old whether or not
    /// they had been aggregated. Pruning is gated on the watermark instead, so a
    /// rollup that never runs makes the table grow — a visible, recoverable
    /// failure — rather than quietly destroying data.
    func testPruneNeverOutrunsTheRollup() throws {
        let old = base.addingTimeInterval(-5 * 3_600)
        try insert([60, 61, 62], startingAt: old)

        // `prune` alone, with no rollup: nothing may be removed, because nothing
        // has been folded into the minute tier yet.
        try store.pruneForTesting(now: base)

        let raw = try store.series(keys: [cpu.key], from: old, to: old.addingTimeInterval(60),
                                   targetPoints: 100, now: old)
        XCTAssertEqual(raw.first?.points.count, 3,
                       "un-aggregated raw samples must survive their retention window")

        // Once maintenance runs properly, the data moves down a tier and the raw
        // rows are then free to go.
        try store.maintain(now: base)
        let aggregated = try totalReachable(around: old, now: base)
        XCTAssertFalse(aggregated.isEmpty)
        XCTAssertEqual(aggregated.map(\.maximum).max(), 62)
    }

    // MARK: - Late inserts

    /// A batch buffered while writes were failing is inserted minutes after its
    /// own timestamp. By then the rollup has passed that minute and would never
    /// revisit it — but `prune` would still be entitled to delete it.
    func testSampleInsertedBehindTheWatermarkIsStillRolledUp() throws {
        // Normal operation carries the watermark forward.
        try insert([50, 51], startingAt: base.addingTimeInterval(600))
        try store.maintain(now: base.addingTimeInterval(900))

        // A stalled flush finally lands, ten minutes behind.
        try insert([99], startingAt: base.addingTimeInterval(60))
        try store.maintain(now: base.addingTimeInterval(900))

        // Age it past raw retention and prune. The late sample must have made it
        // into the minute tier first.
        try store.maintain(now: base.addingTimeInterval(4 * 3_600))

        let points = try store.series(keys: [cpu.key],
                                      from: base, to: base.addingTimeInterval(1_200),
                                      targetPoints: 100_000,
                                      now: base.addingTimeInterval(4 * 3_600))
            .first?.points ?? []
        XCTAssertTrue(points.contains { $0.maximum == 99 },
                      "a sample that landed behind the watermark was pruned unaggregated")
    }

    func testWatermarkRewindDoesNotDuplicateAlreadyRolledBuckets() throws {
        try insert(Array(repeating: 70, count: 120), startingAt: base)
        try store.maintain(now: base.addingTimeInterval(600))
        let before = try store.series(keys: [cpu.key], from: base, to: base.addingTimeInterval(600),
                                      targetPoints: 100_000, now: base.addingTimeInterval(600))

        // A late sample inside an already-rolled minute rewinds the watermark and
        // re-aggregates. `INSERT OR REPLACE` must make that a no-op, not a double count.
        try insert([70], startingAt: base.addingTimeInterval(30))
        try store.maintain(now: base.addingTimeInterval(600))
        let after = try store.series(keys: [cpu.key], from: base, to: base.addingTimeInterval(600),
                                     targetPoints: 100_000, now: base.addingTimeInterval(600))

        XCTAssertEqual(before.first?.points.count, after.first?.points.count)
        XCTAssertEqual(before.first?.points, after.first?.points)
    }

    /// The same guarantee one tier down. A sample old enough to land behind the
    /// hour watermark must still reach the hour tier before the minute tier's
    /// retention can remove it.
    func testSampleInsertedBehindTheHourWatermarkStillReachesTheHourTier() throws {
        // Run normally for a while so both watermarks are well advanced.
        try insert([50, 51], startingAt: base)
        try store.maintain(now: base.addingTimeInterval(4 * 3_600))

        // A write from twenty days ago finally lands — older than the minute
        // tier's retention, so only the hour tier can hold it.
        let ancient = base.addingTimeInterval(-20 * 24 * 3_600)
        try insert([42], startingAt: ancient)
        try store.maintain(now: base.addingTimeInterval(4 * 3_600))

        let now = base.addingTimeInterval(4 * 3_600)
        let points = try store.series(keys: [cpu.key],
                                      from: ancient.addingTimeInterval(-3_600),
                                      to: ancient.addingTimeInterval(3_600),
                                      targetPoints: 100_000, now: now).first?.points ?? []
        XCTAssertTrue(points.contains { $0.maximum == 42 },
                      "a sample behind the hour watermark never reached the hour tier")
        XCTAssertEqual(store.resolutionSeconds(from: ancient, now: now), 3_600)
    }

    // MARK: - Full cascade under repeated maintenance

    /// Thirty days of samples, maintained hourly, asserting both halves of the
    /// bargain: old data stays reachable, and the tables stay bounded.
    func testThirtyDaysOfMaintenanceKeepsDataReachableAndTablesBounded() throws {
        let start = base.addingTimeInterval(-30 * 24 * 3_600)
        // One sample a minute for thirty days would be 43k rows; sampling one per
        // hour keeps the test fast while still crossing every tier boundary.
        for hour in 0..<(30 * 24) {
            let at = start.addingTimeInterval(Double(hour) * 3_600)
            try insert([Double(50 + hour % 40)], startingAt: at)
            try store.maintain(now: at.addingTimeInterval(3_600))
        }

        let now = base
        // The oldest sample is still reachable, at hour resolution.
        let oldest = try XCTUnwrap(store.oldestSample())
        XCTAssertLessThanOrEqual(oldest.timeIntervalSince1970,
                                 start.timeIntervalSince1970 + 3_600)
        XCTAssertEqual(store.resolutionSeconds(from: start, now: now), 3_600)

        let month = try store.series(keys: [cpu.key], from: start, to: now,
                                     targetPoints: 100_000, now: now).first?.points ?? []
        XCTAssertGreaterThan(month.count, 700, "a month of hourly buckets should survive")

        // Raw holds only what is still inside its two-hour retention.
        XCTAssertLessThanOrEqual(try store.rowCountForTesting("samples"), 3)
        XCTAssertLessThan(try store.rowCountForTesting("samples_minute"), 30 * 24 + 10)
    }
}
