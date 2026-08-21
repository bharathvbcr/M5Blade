import XCTest
import FanKit
@testable import HistoryKit

/// Volume, concurrency, and adversarial input.
///
/// Randomised cases use a seeded generator, so a failure here is a failure you
/// can run again and get the same way. Cost is asserted the same way: on how
/// much work SQLite does — `workUnitsForTesting`, its own bytecode step counter —
/// rather than on elapsed seconds. What these cases are for is catching an
/// accidental O(n²), and a stopwatch is a poor instrument for it in both
/// directions: on a loaded machine it fails over scheduling, and on an idle one a
/// threshold loose enough to be safe there is far too loose to notice a plan that
/// turned quadratic. Steps are a property of the statements and the data, so they
/// come out the same under any load.
final class StressTests: XCTestCase {

    /// Deterministic xorshift. `Math.random`-style nondeterminism in a test suite
    /// buys nothing and costs reproducibility.
    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private var directory: URL!
    private var url: URL!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StressTests-\(UUID().uuidString)")
        url = directory.appendingPathComponent("history.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sensors(_ count: Int) -> [SensorDescriptor] {
        (0..<count).map {
            SensorDescriptor(key: "temp:s\($0)", name: "Sensor \($0)",
                             kind: .temperature, group: "G\($0 % 5)")
        }
    }

    // MARK: - Volume

    /// A real machine reports ~50 sensors. Two hours at 1 Hz is the most the raw
    /// tier ever holds, so this is the worst case the store is designed for.
    func testTwoHoursOfFiftySensorsAtOneHertz() throws {
        let store = try HistoryStore(url: url)
        let catalogue = sensors(50)
        let ticks = 7_200

        /// SQLite's work over one call, so a cost can be compared with a cost.
        func work(_ body: () throws -> Void) rethrows -> Int {
            let before = store.workUnitsForTesting
            try body()
            return store.workUnitsForTesting - before
        }

        // Written in flush-sized groups, the way the recorder actually writes.
        func writeHour(_ hour: Int) throws {
            for chunk in stride(from: hour * 3_600, to: (hour + 1) * 3_600, by: 10) {
                let batches = (chunk..<min(chunk + 10, ticks)).map { tick in
                    (date: base.addingTimeInterval(Double(tick)),
                     samples: catalogue.map {
                         RecordedSample(sensor: $0, value: Double(40 + tick % 60))
                     })
                }
                try store.insert(batches)
            }
        }
        let firstHour = try work { try writeHour(0) }
        let secondHour = try work { try writeHour(1) }

        XCTAssertEqual(try store.rowCountForTesting("samples"), 50 * ticks)
        // The cost of an insert must not depend on how much is already stored.
        // A batch that grew with the table is what "360k inserts took minutes"
        // actually meant, and it is visible here as a ratio rather than a clock.
        XCTAssertLessThan(Double(secondHour), 1.5 * Double(firstHour),
                          "the second hour cost \(Double(secondHour) / Double(firstHour))× the first")

        // A chart-sized query: the same 600 points over twice the window should
        // cost about twice as much to gather, not four times. A plan that sorted
        // the window instead of bucketing it shows up here.
        var narrow: [Series] = []
        var wide: [Series] = []
        let narrowWork = try work {
            narrow = try store.groupSeries(groups: ["G0", "G1"], from: base,
                                           to: base.addingTimeInterval(Double(ticks / 2)),
                                           targetPoints: 600,
                                           now: base.addingTimeInterval(Double(ticks)))
        }
        let wideWork = try work {
            wide = try store.groupSeries(groups: ["G0", "G1"], from: base,
                                         to: base.addingTimeInterval(Double(ticks)),
                                         targetPoints: 600,
                                         now: base.addingTimeInterval(Double(ticks)))
        }
        XCTAssertLessThan(Double(wideWork), 2.5 * Double(narrowWork),
                          "a downsampled query scaled worse than linearly with its window")

        XCTAssertEqual(wide.count, 2)
        for entry in wide {
            XCTAssertLessThanOrEqual(entry.points.count, 602)
            XCTAssertEqual(entry.points.map(\.maximum).max(), 99)
            XCTAssertEqual(entry.points.map(\.minimum).min(), 40)
        }
        XCTAssertEqual(narrow.count, 2)

        // And maintenance is watermark-bounded, which is the claim the whole
        // retention scheme rests on: run twice over the same data, the second run
        // has nothing left to fold and must cost a fraction of the first. A
        // rollup that re-aggregated from the beginning would pass a "took under a
        // minute" check for years and then stop passing anything.
        let firstMaintain = try work { try store.maintain(now: base.addingTimeInterval(Double(ticks))) }
        let secondMaintain = try work { try store.maintain(now: base.addingTimeInterval(Double(ticks))) }
        XCTAssertLessThan(Double(secondMaintain), 0.1 * Double(firstMaintain),
                          "maintenance re-did work it had already done")
    }

    /// Long-run behaviour: the database must reach a steady size rather than
    /// growing forever. Ninety days, sampled sparsely enough to stay fast but
    /// still crossing both tier boundaries many times.
    func testNinetyDaysReachesASteadyStateSize() throws {
        let store = try HistoryStore(url: url)
        let catalogue = sensors(10)
        let start = base.addingTimeInterval(-90 * 24 * 3_600)

        for step in 0..<(90 * 24) {
            let at = start.addingTimeInterval(Double(step) * 3_600)
            try store.insert([(date: at, samples: catalogue.map {
                RecordedSample(sensor: $0, value: Double(50 + step % 40))
            })])
            try store.maintain(now: at.addingTimeInterval(3_600))
        }

        // Minute rows only survive 14 days; hour rows carry the rest.
        XCTAssertLessThanOrEqual(try store.rowCountForTesting("samples_minute"),
                                 14 * 24 * catalogue.count + catalogue.count * 2)
        XCTAssertLessThanOrEqual(try store.rowCountForTesting("samples_hour"),
                                 90 * 24 * catalogue.count + catalogue.count * 2)
        XCTAssertLessThan(store.byteSize(), 32 * 1_024 * 1_024,
                          "ninety days of ten sensors should be megabytes, not tens of them")

        // The far end is still reachable.
        XCTAssertNotNil(try store.oldestSample())
        let oldest = try XCTUnwrap(store.oldestSample())
        XCTAssertLessThan(oldest.timeIntervalSince(start), 2 * 3_600)
    }

    // MARK: - Concurrency

    /// Everything funnels through one actor, so this cannot corrupt state by
    /// construction — but it can deadlock if a read path ever awaits a write
    /// path. `window` calls `flush` on itself; that has to stay a plain call.
    func testConcurrentWritersAndReadersNeitherDeadlockNorLoseSamples() async throws {
        let recorder = HistoryRecorder(url: url)
        let sensor = SensorDescriptor(key: "temp:cpu", name: "CPU",
                                      kind: .temperature, group: "CPU")
        let ticks = 600

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for tick in 0..<ticks {
                    let at = self.base.addingTimeInterval(Double(tick))
                    await recorder.record(
                        samples: [RecordedSample(sensor: sensor, value: Double(50 + tick % 30))],
                        at: at,
                        throttle: ThrottleDetector.Input(date: at, cpuPercent: 90,
                                                         pressure: .serious, maxTempC: 96),
                        profile: .init(id: "p\(tick % 3)", name: "Profile \(tick % 3)",
                                       reason: "Auto"))
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<50 {
                        _ = try? await recorder.window(groups: ["CPU"], from: self.base,
                                                       to: self.base.addingTimeInterval(600),
                                                       now: self.base.addingTimeInterval(600))
                        _ = await recorder.status()
                    }
                }
            }
        }

        await recorder.flush(now: base.addingTimeInterval(Double(ticks)))
        let window = try await recorder.window(groups: ["CPU"], from: base,
                                               to: base.addingTimeInterval(Double(ticks)),
                                               targetPoints: 10_000,
                                               now: base.addingTimeInterval(Double(ticks)))
        XCTAssertEqual(window.groups.first?.points.count, ticks,
                       "every tick must be present exactly once")
        let pending = await recorder.status().pendingBatches
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Adversarial input

    /// Sensor names come from a private Apple API. They are not ours to assume
    /// are well behaved, and a name that breaks CSV quoting shifts every column
    /// after it — silently producing a plausible, wrong spreadsheet.
    func testHostileSensorNamesSurviveCSVRoundTrip() throws {
        let store = try HistoryStore(url: url)
        let awkward = [
            "PMU tdie, left",
            "sensor \"quoted\"",
            "line\nbreak",
            "carriage\rreturn",
            "unicode ☃ 温度",
            String(repeating: "very long name ", count: 40),
            "",
        ]
        let catalogue = awkward.enumerated().map { index, name in
            SensorDescriptor(key: "temp:x\(index)", name: name, kind: .temperature, group: "CPU")
        }
        try store.insert([(date: base, samples: catalogue.map {
            RecordedSample(sensor: $0, value: 60)
        })])

        let data = try HistoryExport.data(format: .csv, store: store,
                                          from: base.addingTimeInterval(-60),
                                          to: base.addingTimeInterval(60), now: base)
        let rows = Self.parseCSV(String(decoding: data, as: UTF8.self))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        let header = rows[0]
        XCTAssertEqual(header.count, 2 + catalogue.count)
        for row in rows.dropFirst() {
            XCTAssertEqual(row.count, header.count, "a name broke the column alignment")
        }
        // Every name is recoverable from the header, embedded newlines and all.
        for name in awkward where !name.isEmpty {
            XCTAssertTrue(header.contains { $0.contains(name) }, "lost \(name.prefix(20))")
        }
    }

    func testExtremeAndNonFiniteValues() throws {
        let store = try HistoryStore(url: url)
        let sensor = SensorDescriptor(key: "temp:x", name: "X", kind: .temperature, group: "CPU")
        let values: [Double] = [0, -273.15, 1e308, -1e308, .leastNonzeroMagnitude,
                                .nan, .infinity, -.infinity]
        try store.insert(values.enumerated().map { offset, value in
            (date: base.addingTimeInterval(Double(offset)),
             samples: [RecordedSample(sensor: sensor, value: value)])
        })

        let points = try store.series(keys: [sensor.key], from: base,
                                      to: base.addingTimeInterval(10),
                                      targetPoints: 100, now: base.addingTimeInterval(10))
            .first?.points ?? []
        XCTAssertEqual(points.count, 5, "the three non-finite values must be refused")
        for point in points {
            XCTAssertTrue(point.average.isFinite)
            XCTAssertTrue(point.minimum.isFinite)
            XCTAssertTrue(point.maximum.isFinite)
        }
    }

    func testDuplicateTimestampsCollapseToTheLatestValue() throws {
        let store = try HistoryStore(url: url)
        let sensor = SensorDescriptor(key: "temp:x", name: "X", kind: .temperature, group: "CPU")
        for value in [10.0, 20, 30] {
            try store.insert([(date: base, samples: [RecordedSample(sensor: sensor, value: value)])])
        }
        XCTAssertEqual(try store.rowCountForTesting("samples"), 1)

        let points = try store.series(keys: [sensor.key], from: base,
                                      to: base.addingTimeInterval(1),
                                      targetPoints: 10, now: base).first?.points ?? []
        XCTAssertEqual(points.map(\.average), [30])
    }

    /// The sensor catalogue only grows — every sensor any OS version ever
    /// reported stays in it — and an export asks for all of them at once.
    func testAQueryWiderThanSQLitesParameterLimit() throws {
        let store = try HistoryStore(url: url)
        let catalogue = sensors(1_500)
        try store.insert([(date: base, samples: catalogue.map {
            RecordedSample(sensor: $0, value: 55)
        })])

        let series = try store.series(keys: catalogue.map(\.key), from: base,
                                      to: base.addingTimeInterval(10),
                                      targetPoints: 100, now: base.addingTimeInterval(10))
        XCTAssertEqual(series.count, 1_500)
        XCTAssertEqual(Set(series.map(\.id)).count, 1_500, "chunking must not duplicate a series")

        // And the export path, which is what actually asks for all of them.
        let data = try HistoryExport.data(format: .json, store: store,
                                          from: base.addingTimeInterval(-10),
                                          to: base.addingTimeInterval(10), now: base)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["samples"] as? [[String: Any]])?.count, 1_500)
    }

    // MARK: - Fuzz

    /// Whatever the window, the answer has to be well formed: buckets aligned,
    /// strictly increasing, inside the range, and no more of them than asked for.
    func testBucketingInvariantsHoldForRandomWindows() throws {
        let store = try HistoryStore(url: url)
        let sensor = SensorDescriptor(key: "temp:x", name: "X", kind: .temperature, group: "CPU")
        try store.insert((0..<3_600).map { tick in
            (date: base.addingTimeInterval(Double(tick)),
             samples: [RecordedSample(sensor: sensor, value: Double(tick % 100))])
        })

        var random = Seeded(seed: 0xC0FFEE)
        for _ in 0..<300 {
            let offset = Double(Int.random(in: 0..<3_500, using: &random))
            let span = Double(Int.random(in: 1..<3_600, using: &random))
            let target = Int.random(in: 1..<1_000, using: &random)
            let from = base.addingTimeInterval(offset)
            let to = from.addingTimeInterval(span)

            let points = try store.series(keys: [sensor.key], from: from, to: to,
                                          targetPoints: target,
                                          now: base.addingTimeInterval(3_600))
                .first?.points ?? []
            guard !points.isEmpty else { continue }

            // Same ceiling the store uses; a bucket wide enough to fit the
            // budget, never one that only nearly fits.
            let bucket = Int64(max(1, (Int(span) + target - 1) / target))
            XCTAssertLessThanOrEqual(points.count, target + 2,
                                     "point budget overshot for span \(span) target \(target)")
            for (index, point) in points.enumerated() {
                let ts = Int64(point.date.timeIntervalSince1970)
                XCTAssertEqual(ts % bucket, 0, "bucket start not aligned")
                XCTAssertLessThan(point.date, to)
                XCTAssertLessThanOrEqual(point.minimum, point.average)
                XCTAssertLessThanOrEqual(point.average, point.maximum)
                if index > 0 { XCTAssertGreaterThan(point.date, points[index - 1].date) }
            }
        }
    }

    /// The detector decides when the fans get blamed for something. Random input
    /// must never produce a record that is impossible to interpret.
    ///
    /// Load switches between an idle and a busy regime rather than being drawn
    /// uniformly: a uniform draw satisfies a 20-second gate with probability
    /// ~1e-11, so it would exercise nothing but the rejection path.
    func testDetectorInvariantsUnderRandomInput() {
        var random = Seeded(seed: 0xBADC0DE)
        var detector = ThrottleDetector()
        var closed: [ThrottleEpisode] = []
        var opened = 0
        var openedWithoutGate = 0
        var recentCPU: [(date: Date, percent: Double)] = []
        var busy = false

        for tick in 0..<100_000 {
            let at = base.addingTimeInterval(Double(tick))
            // Regime switch roughly every 60 ticks, so gates are satisfied often
            // enough to produce episodes and broken often enough to close them.
            if Int.random(in: 0..<60, using: &random) == 0 { busy.toggle() }
            let cpu = busy
                ? Double.random(in: 55...100, using: &random)
                : Double.random(in: 0...80, using: &random)

            let input = ThrottleDetector.Input(
                date: at,
                cpuPercent: cpu,
                pressure: ThermalPressure(rawValue: Int.random(in: 0...3, using: &random)) ?? .nominal,
                maxTempC: Bool.random(using: &random)
                    ? Double.random(in: 20...110, using: &random) : nil,
                fanRPM: [0: Double.random(in: 0...5_000, using: &random)],
                fanNearCeiling: Bool.random(using: &random),
                profileName: "P",
                processes: [.init(name: "proc\(tick % 7)",
                                  cpuPercent: Double.random(in: 0...100, using: &random))])

            recentCPU.append((at, cpu))
            recentCPU.removeAll { at.timeIntervalSince($0.date) > 25 }

            // Exactly one update per tick: feeding the same input twice would
            // double every clock the detector keeps.
            switch detector.update(input) {
            case .opened(let episode):
                opened += 1
                // Necessary condition for the gate: nothing in the last 20
                // seconds fell below the demand threshold.
                let gateWindow = recentCPU.filter { at.timeIntervalSince($0.date) <= 20 }
                if gateWindow.count < 21 || gateWindow.contains(where: { $0.percent < 70 }) {
                    openedWithoutGate += 1
                }
                XCTAssertEqual(episode.start, at)
                XCTAssertNil(episode.end)
            case .closed(let episode):
                closed.append(episode)
            case .updated, .none:
                break
            }
        }

        XCTAssertEqual(openedWithoutGate, 0, "an episode opened without sustained demand")
        XCTAssertGreaterThan(opened, 0, "the generator never reached the gate")
        XCTAssertFalse(closed.isEmpty, "episodes opened but none ever closed")
        for episode in closed {
            let end = try? XCTUnwrap(episode.end)
            XCTAssertGreaterThanOrEqual(end ?? episode.start, episode.start)
            XCTAssertGreaterThanOrEqual(episode.meanCPUPercent, 0)
            XCTAssertLessThanOrEqual(episode.meanCPUPercent, 100)
            XCTAssertLessThanOrEqual(episode.processes.count, 3)
            let share = episode.processes.map(\.percent).reduce(0, +)
            XCTAssertLessThanOrEqual(share, 100.0001)
            for process in episode.processes {
                XCTAssertGreaterThanOrEqual(process.percent, 0)
            }
            if let peak = episode.peakTempC { XCTAssertTrue(peak.isFinite) }
            XCTAssertTrue((0...3).contains(episode.peakPressure))
        }
    }

    func testLiveWindowInvariantsUnderRandomInput() {
        var random = Seeded(seed: 0xFACADE)
        var window = LiveWindow(window: 60, capacity: 40)
        let keys = (0..<8).map { "temp:s\($0)" }

        for tick in 0..<20_000 {
            let at = base.addingTimeInterval(Double(tick) * Double.random(in: 0.1...3, using: &random))
            let present = keys.filter { _ in Bool.random(using: &random) }
            window.record(present.map {
                RecordedSample(sensor: SensorDescriptor(key: $0, name: $0,
                                                        kind: .temperature, group: "CPU"),
                               value: Bool.random(using: &random)
                                   ? Double.random(in: -50...150, using: &random) : .nan)
            }, at: at)

            for key in keys {
                let points = window.points(for: key)
                XCTAssertLessThanOrEqual(points.count, 40, "capacity exceeded")
                if let first = points.first, let last = points.last {
                    XCTAssertLessThanOrEqual(last.date.timeIntervalSince(first.date), 60.0001)
                    XCTAssertTrue(points.allSatisfy { $0.average.isFinite })
                }
                // Monotonic even though the generator deliberately steps the
                // clock backwards: a chart must never draw a line that doubles back.
                XCTAssertEqual(points.map(\.date), points.map(\.date).sorted())
            }
            XCTAssertGreaterThanOrEqual(window.span(now: at), 0)
        }
    }

    // MARK: - Helpers

    /// A minimal RFC 4180 reader, so the CSV assertions test the file as a
    /// consumer would parse it rather than as the writer happened to spell it.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"": quoted = true
            case ",":  row.append(field); field = ""
            case "\n": row.append(field); field = ""; rows.append(row); row = []
            default:   field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
