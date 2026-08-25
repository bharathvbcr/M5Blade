import XCTest
import FanKit
import ProfileKit
import SensorKit
import HistoryKit
@testable import M5BladeApp

/// The pure decision surfaces added with the UX enhancements: the status-item
/// readout format, the watching sampling rate, reading staleness, and the
/// diagnostics report. Everything here is testable without hardware because it
/// was built as pure functions over injected state.
@MainActor
final class StatusPreferenceTests: XCTestCase {

    private var directory: URL!
    private var defaults: InMemoryDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusPrefTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = InMemoryDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model() -> AppModel {
        AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("config.json")),
                 historyURL: directory.appendingPathComponent("history.sqlite"),
                 defaults: defaults)
    }

    // MARK: - Status display mode

    /// The three readouts, from one formatter. Icon-only draws no text at all,
    /// which is the point of the mode — anything non-nil would defeat it.
    func testDisplayModeTitles() {
        XCTAssertEqual(StatusDisplayMode.title(for: .full, tempC: 42.4, maxRPM: 3120),
                       " 42° 3120")
        XCTAssertEqual(StatusDisplayMode.title(for: .temperatureOnly, tempC: 42.4, maxRPM: 3120),
                       " 42°")
        XCTAssertNil(StatusDisplayMode.title(for: .iconOnly, tempC: 42.4, maxRPM: 3120))
    }

    /// Missing data renders as placeholders rather than crashing or hiding the
    /// item entirely.
    func testDisplayModeTitlesWithoutReadings() {
        XCTAssertEqual(StatusDisplayMode.title(for: .full, tempC: nil, maxRPM: nil),
                       " --° ----")
        XCTAssertEqual(StatusDisplayMode.title(for: .temperatureOnly, tempC: nil, maxRPM: nil),
                       " --°")
    }

    func testDisplayModePersistsAndSurvivesReinit() {
        let first = model()
        XCTAssertEqual(first.statusDisplayMode, .full, "default is the historical readout")
        first.setStatusDisplayMode(.iconOnly)

        let second = model()
        XCTAssertEqual(second.statusDisplayMode, .iconOnly)
    }

    /// A stored value from a version that had different cases must not crash
    /// startup — it falls back to the default instead.
    func testUnrecognisedStoredDisplayModeFallsBack() {
        defaults.set("holographic", forKey: "status.displayMode")
        XCTAssertEqual(model().statusDisplayMode, .full)
    }

    // MARK: - Watching sample rate

    func testWatchingRateIntervals() {
        XCTAssertEqual(WatchingSampleRate.standard.interval, 5.0)
        XCTAssertEqual(WatchingSampleRate.batterySaver.interval, 15.0)
    }

    func testWatchingRatePersistsAndSurvivesReinit() {
        let first = model()
        XCTAssertEqual(first.watchingSampleRate, .standard, "default matches historic behaviour")
        first.setWatchingSampleRate(.batterySaver)

        let second = model()
        XCTAssertEqual(second.watchingSampleRate, .batterySaver)
    }

    func testUnrecognisedStoredRateFallsBack() {
        defaults.set("turbo", forKey: "sampling.watchingRate")
        XCTAssertEqual(model().watchingSampleRate, .standard)
    }

    // MARK: - Reading staleness

    /// The rule mirrors `ControlLoop.stalenessLimit` on the temperature side:
    /// past ten seconds a reading is missing, not merely old.
    func testReadingStaleness() {
        let m = model()
        let fans = Fixture.fans(1)
        let now = Date(timeIntervalSince1970: 1_000_000)
        m.applyForTesting(
            fans: fans,
            readings: Fixture.readings(fans),
            readingsUpdatedAt: [0: now.addingTimeInterval(-9)])
        XCTAssertFalse(m.readingIsStale(0, now: now))

        m.applyForTesting(readingsUpdatedAt: [0: now.addingTimeInterval(-11)])
        XCTAssertTrue(m.readingIsStale(0, now: now))
    }

    /// A fan that has never produced a reading is stale by definition — there
    /// is nothing on screen to trust.
    func testNeverReadFanIsStale() {
        let fans = Fixture.fans(2)
        let m = model()
        m.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                          readingsUpdatedAt: [0: Date()])
        XCTAssertTrue(m.readingIsStale(1, now: Date()))
    }
}
