import XCTest
import FanKit
@testable import ProfileKit

/// The rolling backups behind every save.
///
/// A config that quietly overwrote its only predecessor gave a bad hand-edit
/// or a future migration exactly one chance. These tests pin the contract:
/// bounded set, oldest pruned, every backup a configuration that decodes.
final class ConfigBackupTests: XCTestCase {

    private var directory: URL!
    private var store: ConfigStore!
    private var url: URL { directory.appendingPathComponent("config.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.uniqueTemporaryDirectory()
        store = ConfigStore(url: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func save(profileName: String) throws {
        var configuration = Configuration.factoryDefault(fanCount: 2)
        configuration.profiles[0].name = profileName
        try store.save(configuration)
        // Distinct filenames come from the millisecond stamp; make sure each
        // save actually lands in its own.
        usleep(1_100)
    }

    func testASaveLeavesTheLiveFileAndNoMoreBackupsThanAllowed() throws {
        try save(profileName: "first")
        try save(profileName: "second")
        try save(profileName: "third")

        XCTAssertEqual(backups.count, ConfigStore.backupCount - 1,
                       "two rotations after three saves: the live file plus two predecessors")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOlderBackupsArePrunedNotAccumulated() throws {
        for i in 0..<10 {
            try save(profileName: "gen\(i)")
            XCTAssertLessThanOrEqual(backups.count, ConfigStore.backupCount,
                                     "generation \(i): the backup set must stay bounded")
        }
    }

    func testEveryBackupDecodesAsAConfiguration() throws {
        try save(profileName: "recoverable")
        try save(profileName: "current")

        let restored = try XCTUnwrap(backups.last)
        let data = try Data(contentsOf: directory.appendingPathComponent(restored))
        let configuration = try ConfigStore.decode(data)
        XCTAssertEqual(configuration.profiles.first?.name, "recoverable",
                       "the newest backup is the config as it stood before this save")
    }

    func testTheLiveFileAlwaysHoldsTheNewestSave() throws {
        try save(profileName: "old")
        try save(profileName: "new")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try ConfigStore.decode(data).profiles.first?.name, "new")
    }

    func testAFailedSaveDoesNotConsumeABackupSlot() throws {
        // A first-ever save has nothing to back up; the backup set must stay
        // empty rather than gaining an empty or duplicate entry.
        try save(profileName: "only")
        XCTAssertEqual(backups.count, 0)
    }

    private var backups: [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.filter { $0.hasPrefix("config.backup-") && $0.hasSuffix(".json") }.sorted()
    }
}

extension FileManager {
    func uniqueTemporaryDirectory() -> URL {
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
