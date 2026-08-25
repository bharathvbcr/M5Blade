import XCTest
@testable import HistoryKit

final class HistoryExportTests: XCTestCase {

    private var directory: URL!
    private var store: HistoryStore!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let cpu = SensorDescriptor(key: "temp:cpu", name: "CPU", kind: .temperature, group: "CPU")
    private let fan = SensorDescriptor(key: "fan:0:rpm", name: "Fan 1", kind: .rpm, group: "Fan")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryExportTests-\(UUID().uuidString)")
        store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try store.insert([
            (date: now.addingTimeInterval(-2),
             samples: [RecordedSample(sensor: cpu, value: 61.25),
                       RecordedSample(sensor: fan, value: 2140)]),
            // The CPU sensor drops out for a tick: its cell must be empty, not 0.
            (date: now.addingTimeInterval(-1),
             samples: [RecordedSample(sensor: fan, value: 2200)]),
        ])
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func csv() throws -> [String] {
        let data = try HistoryExport.data(format: .csv, store: store,
                                          from: now.addingTimeInterval(-60), to: now, now: now)
        return String(decoding: data, as: UTF8.self)
            // The file carries a UTF-8 BOM so Excel renders the `°C` headers;
            // strip it here so line assertions stay about content.
            .drop(while: { $0 == "\u{FEFF}" })
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    func testCSVIsWideWithOneColumnPerSensorAndUnitsInTheHeader() throws {
        let lines = try csv()
        XCTAssertEqual(lines[0], "timestamp_unix,timestamp_iso,CPU (°C),Fan 1 (rpm)")
        XCTAssertEqual(lines[1], "1699999998,2023-11-14T22:13:18Z,61.25,2140.00")
    }

    func testMissingSampleIsAnEmptyCellRatherThanAZero() throws {
        let lines = try csv()
        XCTAssertEqual(lines[2], "1699999999,2023-11-14T22:13:19Z,,2200.00")
    }

    /// Sensor names come from a private API, so a comma or quote in one must not
    /// be able to shift every column to the right.
    func testCSVQuotesFieldsThatWouldOtherwiseBreakTheColumns() throws {
        let awkward = SensorDescriptor(key: "temp:odd", name: "PMU tdie, \"left\"",
                                       kind: .temperature, group: "SoC")
        try store.insert([(date: now.addingTimeInterval(-2),
                           samples: [RecordedSample(sensor: awkward, value: 40)])])

        let header = try XCTUnwrap(csv().first)
        XCTAssertTrue(header.contains("\"PMU tdie, \"\"left\"\" (°C)\""), header)
    }

    func testJSONCarriesTheMetadataCSVCannot() throws {
        try store.record(ProfileChange(date: now.addingTimeInterval(-30), profileID: "p1",
                                       profileName: "Performance", reason: "Manual"))
        try store.save(ThrottleEpisode(start: now.addingTimeInterval(-20),
                                       end: now.addingTimeInterval(-5),
                                       peakTempC: 98,
                                       peakPressure: 2,
                                       meanCPUPercent: 91,
                                       profileName: "Performance",
                                       fanRPMAtPeak: [0: 4400],
                                       processes: [.init(name: "swift-frontend", percent: 71)]))

        let data = try HistoryExport.data(format: .json, store: store,
                                          from: now.addingTimeInterval(-60), to: now, now: now)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["resolutionSeconds"] as? Int, 1)
        XCTAssertEqual(json["includesProcessNames"] as? Bool, true)
        XCTAssertEqual((json["sensors"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((json["samples"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((json["profileChanges"] as? [[String: Any]])?.first?["profile"] as? String,
                       "Performance")

        let episode = try XCTUnwrap((json["episodes"] as? [[String: Any]])?.first)
        XCTAssertEqual(episode["durationSeconds"] as? Double, 15)
        // Fans are numbered from 1 for a reader, matching every other surface.
        XCTAssertEqual((episode["fanRPMAtPeak"] as? [String: Double])?["1"], 4400)
        XCTAssertEqual((episode["processes"] as? [[String: Any]])?.first?["name"] as? String,
                       "swift-frontend")
    }

    /// The save panel warns before writing app names; that warning has to be
    /// driven by what is actually in the payload.
    func testProcessNameFlagIsFalseWhenNoEpisodeCarriesNames() throws {
        try store.save(ThrottleEpisode(start: now.addingTimeInterval(-20),
                                       end: now.addingTimeInterval(-5)))

        let data = try HistoryExport.data(format: .json, store: store,
                                          from: now.addingTimeInterval(-60), to: now, now: now)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["includesProcessNames"] as? Bool, false)
    }

    func testEmptyWindowStillProducesAParsableCSV() throws {
        let data = try HistoryExport.data(format: .csv, store: store,
                                          from: now.addingTimeInterval(-7_200),
                                          to: now.addingTimeInterval(-3_600), now: now)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       "\u{FEFF}timestamp_unix,timestamp_iso\n")
    }

    /// A sensor known to the catalogue but with no rows in the window keeps its
    /// column — an absent column and an empty one mean different things.
    func testACatalogueSensorWithoutRowsInTheWindowKeepsItsColumn() throws {
        try store.insert([
            (date: now.addingTimeInterval(-90),
             samples: [RecordedSample(sensor: SensorDescriptor(key: "temp:cold",
                                                                name: "=Cold", kind: .temperature,
                                                                group: "CPU"),
                                      value: 5.0)]),
        ])
        let data = try HistoryExport.data(format: .csv, store: store,
                                          from: now.addingTimeInterval(-60), to: now, now: now)
        let header = String(decoding: data, as: UTF8.self)
            .drop(while: { $0 == "\u{FEFF}" })
            .split(separator: "\n")[0]
        XCTAssertTrue(header.contains("CPU (°C)"), "present sensor keeps its column")
        // A name a spreadsheet would treat as a formula arrives inert.
        XCTAssertTrue(header.contains("'=Cold (°C)"),
                      "formula-leading names are neutralized: \(header)")
    }
}
