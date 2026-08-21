import XCTest
@testable import HistoryKit

/// Moved here with `LiveWindow` itself: it was `SensorKit.SensorHistory`, which
/// put one of the app's two history tiers in a module that knows nothing about
/// history — and keyed it differently from the other tier.
final class LiveWindowTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ key: String, _ value: Double) -> RecordedSample {
        RecordedSample(sensor: SensorDescriptor(key: key, name: key,
                                                kind: .temperature, group: "CPU"),
                       value: value)
    }

    func testAccumulatesPerSeries() {
        var window = LiveWindow()
        for i in 0..<5 {
            window.record([sample("a", Double(40 + i)), sample("b", 50)],
                          at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(window.points(for: "a").count, 5)
        XCTAssertEqual(window.points(for: "a").last?.average, 44)
        XCTAssertEqual(window.points(for: "b").count, 5)
    }

    /// A long-running app must not accumulate samples forever.
    func testDropsSamplesOlderThanTheWindow() {
        var window = LiveWindow(window: 10, capacity: 10_000)
        for i in 0..<60 {
            window.record([sample("a", 40)], at: start.addingTimeInterval(Double(i)))
        }
        let points = window.points(for: "a")
        XCTAssertLessThanOrEqual(points.count, 11, "window not enforced")
        let span = points.last!.date.timeIntervalSince(points.first!.date)
        XCTAssertLessThanOrEqual(span, 10.001)
    }

    func testHonoursCapacityEvenWithAWideWindow() {
        var window = LiveWindow(window: 86_400, capacity: 25)
        for i in 0..<200 {
            window.record([sample("a", 40)], at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(window.points(for: "a").count, 25)
    }

    /// A sensor that stops reporting should disappear rather than leave a frozen
    /// line on the chart.
    func testForgetsSeriesThatStopReporting() {
        var window = LiveWindow()
        window.record([sample("a", 40), sample("b", 50)], at: start)
        window.record([sample("a", 41)], at: start.addingTimeInterval(1))
        XCTAssertEqual(window.points(for: "b").count, 0)
        XCTAssertEqual(window.points(for: "a").count, 2)
    }

    func testSpanReportsActualCoverageNotTheWindow() {
        var window = LiveWindow(window: 900)
        window.record([sample("a", 40)], at: start)
        window.record([sample("a", 41)], at: start.addingTimeInterval(30))
        XCTAssertEqual(window.span(now: start.addingTimeInterval(30)), 30, accuracy: 0.001)
    }

    /// A non-finite reading must not poison a plot's scale. `HistoryStore` drops
    /// these too; both tiers see the same batch, so both have to agree.
    func testNonFiniteValuesAreIgnored() {
        var window = LiveWindow()
        window.record([sample("a", 40)], at: start)
        window.record([sample("a", .nan)], at: start.addingTimeInterval(1))
        XCTAssertEqual(window.points(for: "a").map(\.average), [40])
    }

    /// Both tiers are fed the same batch and keyed the same way, so a series
    /// drawn live and the same series read back from disk are the same series.
    func testLiveAndStoredTiersShareAKeySpace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWindowTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        var window = LiveWindow()
        let batch = [sample("temp:CPU#0", 61)]
        window.record(batch, at: start)
        try store.insert([(date: start, samples: batch)])

        let stored = try store.series(keys: ["temp:CPU#0"], from: start,
                                      to: start.addingTimeInterval(1), now: start)
        XCTAssertEqual(window.points(for: "temp:CPU#0").map(\.average),
                       stored.first?.points.map(\.average))
    }
}
