import XCTest
import FanKit
@testable import HistoryKit

/// Storing spikes: the round trip, the v1 → v2 migration, and the crash-recovery
/// invariant that keeps a dangling record from shading every later window.
final class SpikeStoreTests: XCTestCase {

    private var directory: URL!
    private var url: URL!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let temperatureSensor = SensorDescriptor(key: "temp:cpu", name: "CPU",
                                              kind: .temperature, group: "CPU")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpikeStoreTests-\(UUID().uuidString)")
        url = directory.appendingPathComponent("history.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(at date: Date, _ value: Double) -> (date: Date, samples: [RecordedSample]) {
        (date: date, samples: [RecordedSample(sensor: temperatureSensor, value: value)])
    }

    private var fullSpike: Spike {
        Spike(start: base,
              peak: base.addingTimeInterval(70),
              end: base.addingTimeInterval(240),
              fromTempC: 58.5,
              peakTempC: 94.25,
              cpuAtStartPercent: 7.5,
              peakCPUPercent: 96,
              hottestGroup: "GPU",
              peakFanRPM: 4_812,
              peakFanDutyPercent: 99.5,
              profileName: "Max cooling",
              profileChanged: true,
              onBattery: true,
              recordedProcessNames: true,
              processes: [.init(name: "swift-frontend", percent: 71.25),
                          .init(name: "Xcode", percent: 12.5)])
    }

    func testEveryFieldSurvivesTheRoundTrip() throws {
        let store = try HistoryStore(url: url)
        try store.save(fullSpike)

        let loaded = try XCTUnwrap(store.spikes(from: base.addingTimeInterval(-60),
                                                to: base.addingTimeInterval(3_600)).first)
        var expected = fullSpike
        expected.id = loaded.id
        XCTAssertEqual(loaded, expected)
        XCTAssertNotEqual(loaded.id, 0)
    }

    func testAnOpenSpikeIsUpdatedInPlaceRatherThanDuplicated() throws {
        let store = try HistoryStore(url: url)
        var spike = Spike(start: base, peak: base.addingTimeInterval(30),
                          fromTempC: 60, peakTempC: 82)
        spike.id = try store.save(spike)

        spike.peakTempC = 95
        spike.end = base.addingTimeInterval(200)
        try store.save(spike)

        let all = try store.spikes(from: base.addingTimeInterval(-60), to: base.addingTimeInterval(3_600))
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.peakTempC, 95)
        XCTAssertEqual(all.first?.end, base.addingTimeInterval(200))
    }

    /// The same rule episodes follow: written on open so a force quit still
    /// leaves a record, closed afterwards at the last sample actually observed —
    /// never at the next launch, which would invent hours of spike.
    func testADanglingSpikeIsClosedAtTheLastObservedSample() throws {
        do {
            let store = try HistoryStore(url: url)
            try store.insert([sample(at: base, 70), sample(at: base.addingTimeInterval(120), 90)])
            try store.save(Spike(start: base.addingTimeInterval(10),
                                 peak: base.addingTimeInterval(60),
                                 fromTempC: 62, peakTempC: 93))
        }

        let reopened = try HistoryStore(url: url)
        let closed = try reopened.finalizeDanglingRecords(now: base.addingTimeInterval(86_400))
        XCTAssertEqual(closed.spikes, 1)

        let spike = try XCTUnwrap(reopened.spikes(from: base.addingTimeInterval(-60),
                                                  to: base.addingTimeInterval(3_600)).first)
        XCTAssertEqual(spike.end, base.addingTimeInterval(120))
    }

    /// Every rate the app computes assumes start ≤ peak ≤ end. A crash after the
    /// peak but before any further sample must not invert that.
    func testAClosedDanglingSpikeNeverEndsBeforeItsPeak() throws {
        do {
            let store = try HistoryStore(url: url)
            try store.insert([sample(at: base, 70)])
            try store.save(Spike(start: base, peak: base.addingTimeInterval(600),
                                 fromTempC: 60, peakTempC: 92))
        }

        let reopened = try HistoryStore(url: url)
        try reopened.finalizeDanglingRecords(now: base.addingTimeInterval(86_400))
        let spike = try XCTUnwrap(reopened.spikes(from: base.addingTimeInterval(-60),
                                                  to: base.addingTimeInterval(7_200)).first)
        XCTAssertEqual(spike.end, spike.peak)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(spike.end), spike.peak)
    }

    /// An open spike belongs to every later window, exactly like an open
    /// episode — which is why it has to be closed at all.
    func testAnOpenSpikeAppearsInAnyWindowItReaches() throws {
        let store = try HistoryStore(url: url)
        try store.save(Spike(start: base, peak: base, fromTempC: 60, peakTempC: 90))
        let muchLater = base.addingTimeInterval(30 * 24 * 3_600)
        XCTAssertEqual(try store.spikes(from: muchLater,
                                        to: muchLater.addingTimeInterval(3_600)).count, 1)
    }

    /// "Clear history" that left spikes behind would still name every app the
    /// user has run.
    func testClearRemovesSpikesToo() throws {
        let store = try HistoryStore(url: url)
        try store.save(fullSpike)
        try store.clear()
        XCTAssertTrue(try store.spikes(from: base.addingTimeInterval(-60),
                                       to: base.addingTimeInterval(3_600)).isEmpty)
    }

    /// A database written by the previous version has no `spikes` table and a
    /// user_version of 1. Reopening it must add the table rather than failing
    /// every write from then on.
    func testAVersionOneDatabaseGainsTheSpikesTable() throws {
        do {
            let store = try HistoryStore(url: url)
            try store.insert([sample(at: base, 70)])
        }
        // Wind the file back to what v1 actually looked like.
        do {
            let database = try Database(path: url.path)
            try database.execute("DROP TABLE spikes")
            try database.setUserVersion(1)
        }

        let reopened = try HistoryStore(url: url)
        try reopened.save(fullSpike)
        XCTAssertEqual(try reopened.spikes(from: base.addingTimeInterval(-60),
                                           to: base.addingTimeInterval(3_600)).count, 1)
        XCTAssertEqual(try reopened.rowCountForTesting("samples"), 1,
                       "the migration must not cost the existing record")
    }

    // MARK: - Export

    func testJSONExportCarriesSpikesWithTheirExplanation() throws {
        let store = try HistoryStore(url: url)
        try store.insert([sample(at: base, 70)])
        try store.save(fullSpike)

        let data = try HistoryExport.data(format: .json, store: store,
                                          from: base.addingTimeInterval(-60),
                                          to: base.addingTimeInterval(3_600),
                                          now: base.addingTimeInterval(3_600))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let spikes = try XCTUnwrap(payload["spikes"] as? [[String: Any]])

        XCTAssertEqual(spikes.count, 1)
        XCTAssertEqual(spikes[0]["cause"] as? String, "application")
        XCTAssertEqual(spikes[0]["peakTempC"] as? Double, 94.25)
        XCTAssertEqual(spikes[0]["hottestGroup"] as? String, "GPU")
        XCTAssertEqual(spikes[0]["processNamesRecorded"] as? Bool, true)
        // The evidence travels with the verdict, so the reader can check it.
        XCTAssertEqual(spikes[0]["cpuAtStartPercent"] as? Double, 7.5)
        XCTAssertEqual(payload["includesProcessNames"] as? Bool, true,
                       "a spike's application names count as names")
    }

    // MARK: - Through the recorder

    /// End to end: the inputs the app actually produces, through the actor, into
    /// the database, back out as an insight. Each layer works in isolation
    /// above; this is the one that fails if they are wired together wrongly.
    func testTheRecorderPersistsASpikeWithItsAttribution() async throws {
        let recorder = HistoryRecorder(url: url, recordsProcessNames: true)

        func tick(_ offset: TimeInterval, temp: Double, cpu: Double,
                  processes: [ThrottleDetector.ProcessLoad] = []) async {
            let date = base.addingTimeInterval(offset)
            await recorder.record(
                samples: [RecordedSample(sensor: temperatureSensor, value: temp)],
                at: date,
                throttle: ThrottleDetector.Input(date: date, cpuPercent: cpu,
                                                 pressure: .nominal, maxTempC: temp),
                spike: SpikeDetector.Input(date: date, maxTempC: temp, cpuPercent: cpu,
                                           hottestGroup: "CPU", fanRPM: 4_000,
                                           fanDutyPercent: 90, profileName: "Balanced",
                                           processes: processes))
        }

        for offset in stride(from: 0.0, through: 10.0, by: 5) { await tick(offset, temp: 58, cpu: 6) }
        await tick(15, temp: 90, cpu: 95)
        for offset in stride(from: 20.0, through: 90.0, by: 5) {
            await tick(offset, temp: 92, cpu: 95,
                       processes: [.init(name: "swift-frontend", cpuPercent: 380)])
        }
        for offset in stride(from: 95.0, through: 200.0, by: 5) { await tick(offset, temp: 61, cpu: 6) }

        let insights = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                    to: base.addingTimeInterval(3_600))
        XCTAssertEqual(insights.spikes.count, 1)
        let spike = try XCTUnwrap(insights.spikes.first)
        XCTAssertEqual(spike.fromTempC, 58)
        XCTAssertEqual(spike.peakTempC, 92)
        XCTAssertNotNil(spike.end, "it settled, so it must be closed")
        XCTAssertEqual(spike.processes.first?.name, "swift-frontend")
        XCTAssertTrue(spike.recordedProcessNames)
        XCTAssertEqual(SpikeExplanation.explain(spike).cause, .application)
        XCTAssertTrue(insights.episodes.isEmpty,
                      "a rise that settled is not a throttle episode")

        // And the save panel must warn, even though no episode carries names.
        let includes = await recorder.exportIncludesProcessNames(
            from: base.addingTimeInterval(-60), to: base.addingTimeInterval(3_600))
        XCTAssertTrue(includes)
    }

    /// Attribution off is the default (DESIGN §5.4). A spike still gets
    /// recorded — it just cannot name anything, and says so.
    func testWithAttributionOffASpikeIsStillRecordedButNamesNothing() async throws {
        let recorder = HistoryRecorder(url: url)

        func tick(_ offset: TimeInterval, temp: Double, cpu: Double) async {
            let date = base.addingTimeInterval(offset)
            await recorder.record(
                samples: [RecordedSample(sensor: temperatureSensor, value: temp)],
                at: date,
                throttle: ThrottleDetector.Input(date: date, cpuPercent: cpu,
                                                 pressure: .nominal, maxTempC: temp),
                spike: SpikeDetector.Input(date: date, maxTempC: temp, cpuPercent: cpu,
                                           hottestGroup: "CPU",
                                           processes: [.init(name: "secret", cpuPercent: 300)]))
        }

        for offset in stride(from: 0.0, through: 10.0, by: 5) { await tick(offset, temp: 58, cpu: 6) }
        for offset in stride(from: 15.0, through: 60.0, by: 5) { await tick(offset, temp: 90, cpu: 95) }

        let insights = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                    to: base.addingTimeInterval(3_600))
        let spike = try XCTUnwrap(insights.spikes.first)
        XCTAssertTrue(spike.processes.isEmpty)
        XCTAssertFalse(spike.recordedProcessNames,
                       "an empty list must be readable as “not recorded”")
        XCTAssertNotNil(SpikeExplanation.explain(spike).suggestion)
    }
}
