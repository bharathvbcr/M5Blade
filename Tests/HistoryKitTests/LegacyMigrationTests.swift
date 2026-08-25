import XCTest
@testable import HistoryKit

/// The pre-rename database migration. It used to be three independent `try?`
/// byte copies of the main file, `-wal` and `-shm`: a live database keeps its
/// newest commits in the WAL, so a torn or failed copy silently lost recent
/// history — or produced a malformed target that then latched "history broken"
/// forever, because the migration gate never re-runs over an existing file.
final class LegacyMigrationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sensor() -> SensorDescriptor {
        SensorDescriptor(key: "temp:migration", name: "CPU", kind: .temperature, group: "CPU")
    }

    /// A copy taken through the backup API must carry the rows that were still
    /// sitting in the source's WAL when the migration ran.
    func testMigrationCarriesRowsStillInWriteAheadLog() throws {
        let legacyURL = directory.appendingPathComponent("legacy.sqlite")
        let source = try HistoryStore(url: legacyURL)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try source.insert([
            (date: date, samples: [RecordedSample(sensor: sensor(), value: 61.5)]),
            (date: date.addingTimeInterval(1),
             samples: [RecordedSample(sensor: sensor(), value: 62.5)]),
        ])
        // Deliberately no flush/close: the rows above may live only in the WAL.

        let targetURL = directory.appendingPathComponent("migrated.sqlite")
        XCTAssertTrue(HistoryRecorder.migrateLegacyDatabase(from: legacyURL, to: targetURL))

        let reopened = try HistoryStore(url: targetURL)
        let series = try reopened.series(keys: ["temp:migration"],
                                         from: date.addingTimeInterval(-1),
                                         to: date.addingTimeInterval(2), now: date)
        XCTAssertEqual(series.first?.points.count, 2,
                       "rows living in the WAL at migration time must survive")
    }

    /// A failed migration must not leave a half-written target for the gate to
    /// treat as "already migrated": the partial output is removed so the next
    /// launch retries instead of opening a corrupt file forever.
    func testAFailedMigrationLeavesNoPartialTargetBehind() throws {
        let legacyURL = directory.appendingPathComponent("not-a-database.sqlite")
        try Data("this is not sqlite".utf8).write(to: legacyURL)

        let targetURL = directory.appendingPathComponent("target.sqlite")
        XCTAssertFalse(HistoryRecorder.migrateLegacyDatabase(from: legacyURL, to: targetURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path),
                       "a partial target would be mistaken for a completed migration")
    }
}
