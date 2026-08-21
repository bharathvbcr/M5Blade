import XCTest
import FanKit
@testable import HistoryKit

/// Adversarial and randomised input to the spike pipeline.
///
/// The unit tests pin the behaviour the design intends. These pin the
/// properties that must hold **whatever** arrives: a hostile sensor, a clock
/// that jumps, a machine that never cools, a sample rate no real Mac produces.
/// Randomised cases use a seeded generator, so a failure here is one you can run
/// again and get the same way.
final class SpikeStressTests: XCTestCase {

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
            .appendingPathComponent("SpikeStressTests-\(UUID().uuidString)")
        url = directory.appendingPathComponent("history.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Invariants

    /// Everything downstream — the chart window, the rise rate, the duration —
    /// assumes this ordering. Checked on every event a run produces, so a trace
    /// that breaks it fails here rather than by trapping in a SwiftUI layout.
    private func assertWellFormed(_ spike: Spike, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(spike.start, spike.peak, "\(context): peak before start",
                                 file: file, line: line)
        if let end = spike.end {
            XCTAssertLessThanOrEqual(spike.peak, end, "\(context): end before peak",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(end, spike.start, "\(context): end before start",
                                        file: file, line: line)
        }
        XCTAssertGreaterThan(spike.riseC, 0, "\(context): a spike that did not rise",
                             file: file, line: line)
        XCTAssertGreaterThanOrEqual(spike.riseSeconds, 1, "\(context): rise of no duration",
                                    file: file, line: line)
        XCTAssertTrue(spike.riseRatePerMinute.isFinite, "\(context): non-finite rate",
                      file: file, line: line)
        XCTAssertTrue(spike.peakTempC.isFinite && spike.fromTempC.isFinite,
                      "\(context): non-finite temperature", file: file, line: line)

        for share in spike.processes {
            XCTAssertTrue(share.percent.isFinite && share.percent > 0 && share.percent <= 100.001,
                          "\(context): share out of range (\(share.percent))", file: file, line: line)
        }
        let total = spike.processes.reduce(0) { $0 + $1.percent }
        XCTAssertLessThanOrEqual(total, 100.001, "\(context): shares sum above 100",
                                 file: file, line: line)
        XCTAssertEqual(Set(spike.processes.map(\.name)).count, spike.processes.count,
                       "\(context): the same application listed twice", file: file, line: line)
    }

    /// Drives a trace and returns everything it produced, checking the event
    /// grammar as it goes: no two opens without a close between them, no update
    /// or close without an open.
    @discardableResult
    private func run(_ detector: inout SpikeDetector,
                     _ inputs: [SpikeDetector.Input],
                     context: String = "trace",
                     file: StaticString = #filePath, line: UInt = #line) -> [Spike] {
        var closed: [Spike] = []
        var isOpen = false
        for input in inputs {
            switch detector.update(input) {
            case .none:
                break
            case .opened(let spike):
                XCTAssertFalse(isOpen, "\(context): opened while already open", file: file, line: line)
                isOpen = true
                assertWellFormed(spike, "\(context)/opened", file: file, line: line)
            case .updated(let spike):
                XCTAssertTrue(isOpen, "\(context): updated with nothing open", file: file, line: line)
                assertWellFormed(spike, "\(context)/updated", file: file, line: line)
            case .closed(let spike):
                XCTAssertTrue(isOpen, "\(context): closed with nothing open", file: file, line: line)
                isOpen = false
                assertWellFormed(spike, "\(context)/closed", file: file, line: line)
                closed.append(spike)
            }
        }
        return closed
    }

    // MARK: - Randomised traces

    /// Twenty thousand samples of a machine behaving badly in every way at once:
    /// jumps, stalls, clock corrections, dropouts, and a sensor occasionally
    /// reporting nonsense.
    func testRandomisedHostileTracesNeverProduceAMalformedSpike() {
        for seed in UInt64(1)...12 {
            var random = Seeded(seed: seed)
            var detector = SpikeDetector()
            detector.setRecordsProcessNames(true)

            var clock = base
            var temperature = 45.0
            var inputs: [SpikeDetector.Input] = []

            for step in 0..<20_000 {
                // Sampling intervals a real app produces, plus the ones it
                // does not: a stall, a sleep, and a clock corrected backwards.
                let roll = Int.random(in: 0..<100, using: &random)
                let dt: TimeInterval
                switch roll {
                case 0..<70:  dt = Double.random(in: 0.9...1.1, using: &random)
                case 70..<90: dt = 5
                case 90..<95: dt = Double.random(in: 60...900, using: &random)
                case 95..<97: dt = -Double.random(in: 1...120, using: &random)
                default:      dt = 0
                }
                clock = clock.addingTimeInterval(dt)

                temperature += Double.random(in: -6...6, using: &random)
                temperature = min(115, max(-5, temperature))

                // One sample in fifty is missing or nonsense.
                let reported: Double?
                switch Int.random(in: 0..<50, using: &random) {
                case 0: reported = nil
                case 1: reported = .nan
                case 2: reported = .infinity
                default: reported = temperature
                }

                let names = ["compiler", "browser", "indexer", "proc-\(step % 700)"]
                inputs.append(SpikeDetector.Input(
                    date: clock,
                    maxTempC: reported,
                    cpuPercent: Double.random(in: 0...100, using: &random),
                    hottestGroup: ["CPU", "GPU", "SoC", "Storage", ""].randomElement(using: &random)!,
                    fanRPM: Double.random(in: 0...6_000, using: &random),
                    fanDutyPercent: Double.random(in: 0...100, using: &random),
                    profileName: ["Balanced", "Silent", "Max cooling"].randomElement(using: &random)!,
                    processes: names.map {
                        .init(name: $0, cpuPercent: Double.random(in: 0...400, using: &random))
                    }))
            }

            run(&detector, inputs, context: "seed \(seed)")

            // Memory is bounded by the configuration, not by what arrived.
            XCTAssertLessThanOrEqual(detector.trailCount,
                                     SpikeDetector.Configuration().trailCapacity,
                                     "seed \(seed): trailing window outgrew its bound")
            XCTAssertLessThanOrEqual(detector.accumulatedCPUSeconds.count,
                                     SpikeDetector.Configuration().attributionCapacity,
                                     "seed \(seed): attribution outgrew its bound")
        }
    }

    /// The bound that matters most, isolated: a sample rate no real app produces
    /// must not let the trailing window grow with the caller's timing.
    func testAPathologicalSampleRateCannotGrowTheTrailingWindow() {
        var detector = SpikeDetector(configuration: .init(trailCapacity: 64))
        for step in 0..<20_000 {
            // 1 kHz — twenty seconds of samples, all inside the two-minute
            // window, so time alone would never trim them.
            _ = detector.update(SpikeDetector.Input(
                date: base.addingTimeInterval(Double(step) / 1_000),
                maxTempC: 50 + Double(step % 7),
                cpuPercent: 20))
        }
        XCTAssertLessThanOrEqual(detector.trailCount, 64)
    }

    /// A build system spawns a great many uniquely named short-lived processes.
    /// Without a bound the accumulator grows with the variety of what ran.
    func testAttributionIsBoundedByCapacityNotByProcessVariety() {
        var detector = SpikeDetector(configuration: .init(attributionCapacity: 32))
        detector.setRecordsProcessNames(true)
        for step in 0..<3 { _ = detector.update(input(Double(step) * 5, temp: 55, cpu: 90)) }

        // Kept inside `maximumDuration`, so the spike is still open to inspect:
        // 297 ticks at five seconds is 1485 s against a 1800 s bound, and 297
        // uniquely-named processes against a capacity of 32.
        for step in 3..<300 {
            _ = detector.update(input(Double(step) * 5, temp: 92, cpu: 95, processes: [
                .init(name: "swift-frontend", cpuPercent: 300),
                .init(name: "throwaway-\(step)", cpuPercent: 5),
            ]))
        }
        XCTAssertNotNil(detector.current, "precondition: the spike should still be open")
        XCTAssertLessThanOrEqual(detector.accumulatedCPUSeconds.count, 32)
        // And the one that actually mattered survived every eviction.
        XCTAssertEqual(detector.current?.processes.first?.name, "swift-frontend")
    }

    /// The same trace has to produce the same shares, whatever order the
    /// processes arrived in.
    ///
    /// The totals live in a dictionary, and Swift seeds its hashing per process:
    /// iterating one to add up CPU-seconds made the total — and every percentage
    /// divided by it — depend on which launch you were in, because
    /// floating-point addition is not associative. Small, but it is the number
    /// written to the database and read back out as "71% of it".
    func testSharesDoNotDependOnTheOrderProcessesArrivedIn() {
        let names = (0..<64).map { "proc-\($0)" }
        // The load belongs to the process, not to its position in the list, so
        // the two runs differ in arrival order and in nothing else.
        func shares(_ order: [Int]) -> [ProcessShare] {
            var attribution = ProcessAttribution(capacity: 256, topCount: 5)
            for step in 0..<40 {
                attribution.add(order.map {
                    .init(name: names[$0], cpuPercent: Double(($0 * 7 + step) % 17) + 0.5)
                }, dt: 1)
            }
            return attribution.top()
        }
        let forwards = shares(Array(0..<64))
        let backwards = shares(Array((0..<64).reversed()))
        XCTAssertEqual(forwards.map(\.name), backwards.map(\.name))
        // Exact equality, not `accuracy:` — the point is that the arithmetic is
        // reproducible, and a tolerance would hide precisely what this checks.
        XCTAssertEqual(forwards.map(\.percent), backwards.map(\.percent))
    }

    // MARK: - Adversarial specifics

    /// A machine that gets hot and simply stays hot for a week. Every spike must
    /// terminate, and the run must not accumulate open records.
    func testAWeekOfSustainedHeatTerminatesEverySpike() {
        var detector = SpikeDetector()
        var inputs: [SpikeDetector.Input] = []
        for step in 0..<3 { inputs.append(input(Double(step) * 5, temp: 50, cpu: 5)) }
        for step in 3..<(7 * 24 * 720) {          // a week at 5-second ticks
            inputs.append(input(Double(step) * 5, temp: 99, cpu: 95))
        }
        let closed = run(&detector, inputs, context: "sustained heat")

        XCTAssertGreaterThanOrEqual(closed.count, 1)
        for spike in closed {
            XCTAssertLessThanOrEqual(try! XCTUnwrap(spike.duration),
                                     SpikeDetector.Configuration().maximumDuration + 5,
                                     "a spike outlived its own bound")
        }
        // One long hot week is not a thousand spikes: after the first closes,
        // the baseline is the hot plateau and nothing rises 12 °C above it.
        XCTAssertEqual(closed.count, 1, "sustained heat produced \(closed.count) spikes")
    }

    /// Temperatures a sensor should never report, fed straight in.
    func testHostileTemperaturesAreRefusedRatherThanRecorded() {
        var detector = SpikeDetector()
        let hostile: [Double?] = [nil, .nan, .infinity, -.infinity, -273, 1e9, -1e9, 0]
        var inputs: [SpikeDetector.Input] = []
        for (index, value) in hostile.enumerated() {
            inputs.append(input(Double(index) * 5, temp: value, cpu: 50))
        }
        // Then a genuine spike, to prove the detector still works afterwards.
        for step in hostile.count..<(hostile.count + 3) {
            inputs.append(input(Double(step) * 5, temp: 58, cpu: 10))
        }
        inputs.append(input(Double(hostile.count + 4) * 5, temp: 92, cpu: 95))

        run(&detector, inputs, context: "hostile temperatures")
        XCTAssertNotNil(detector.current, "a real spike after hostile input must still be found")
    }

    /// A detector configured into nonsense must fail closed — quiet — rather
    /// than filling the database with events that never happened.
    func testNonsenseConfigurationIsClampedRatherThanTrusted() {
        let clamped = SpikeDetector.Configuration(riseWindow: 0, riseThresholdC: 0,
                                                  settleFraction: 5, clearSeconds: -10,
                                                  maximumGap: 0, maximumDuration: 0,
                                                  attributionCount: 0, attributionCapacity: -5,
                                                  trailCapacity: 0)
        XCTAssertGreaterThan(clamped.riseWindow, 0)
        XCTAssertGreaterThan(clamped.riseThresholdC, 0)
        XCTAssertTrue((0...1).contains(clamped.settleFraction))
        XCTAssertGreaterThanOrEqual(clamped.clearSeconds, 0)
        XCTAssertGreaterThan(clamped.maximumGap, 0)
        XCTAssertGreaterThanOrEqual(clamped.maximumDuration, clamped.riseWindow)
        XCTAssertGreaterThanOrEqual(clamped.attributionCount, 1)
        XCTAssertGreaterThanOrEqual(clamped.attributionCapacity, clamped.attributionCount)
        XCTAssertGreaterThanOrEqual(clamped.trailCapacity, 2)

        var detector = SpikeDetector(configuration: clamped)
        var inputs: [SpikeDetector.Input] = []
        for step in 0..<500 {
            inputs.append(input(Double(step), temp: 40 + Double(step % 3), cpu: 10))
        }
        let closed = run(&detector, inputs, context: "clamped config")
        XCTAssertTrue(closed.isEmpty, "a flat 40 °C trace produced \(closed.count) spikes")
    }

    /// Clocks move backwards — NTP corrections, a bad wake. Nothing may be
    /// declared against a baseline from the future, and nothing may hang.
    func testAClockRunningBackwardsProducesNoMalformedRecords() {
        var detector = SpikeDetector()
        var inputs: [SpikeDetector.Input] = []
        for step in 0..<200 {
            // Sawtooth time: forward five, back three, forever.
            let offset = Double(step) * 5 - Double(step % 7) * 3
            inputs.append(input(offset, temp: 50 + Double(step % 50), cpu: 60))
        }
        run(&detector, inputs, context: "backwards clock")
    }

    // MARK: - Privacy

    /// Turning attribution off means *forget*, not *stop adding*. Names gathered
    /// before the user said stop must not go on being written.
    func testSwitchingAttributionOffDiscardsWhatWasAlreadyCollected() throws {
        var detector = SpikeDetector()
        detector.setRecordsProcessNames(true)
        for step in 0..<3 { _ = detector.update(input(Double(step) * 5, temp: 55, cpu: 90)) }
        for step in 3..<12 {
            _ = detector.update(input(Double(step) * 5, temp: 92, cpu: 95,
                                      processes: [.init(name: "private-app", cpuPercent: 300)]))
        }
        XCTAssertFalse(try XCTUnwrap(detector.current).processes.isEmpty, "precondition")

        detector.setRecordsProcessNames(false)

        XCTAssertTrue(try XCTUnwrap(detector.current).processes.isEmpty,
                      "the open record still names an application")
        XCTAssertTrue(detector.accumulatedCPUSeconds.isEmpty,
                      "the accumulator still holds it")
        XCTAssertFalse(try XCTUnwrap(detector.current).recordedProcessNames)

        // And it stays gone through to the close, which is the row that lasts.
        var closed: Spike?
        for step in 12..<40 {
            if case .closed(let spike) = detector.update(input(Double(step) * 5, temp: 56, cpu: 5)) {
                closed = spike
            }
        }
        XCTAssertTrue(try XCTUnwrap(closed).processes.isEmpty)
    }

    /// The same rule for throttle episodes — the leak was in both, so the fix
    /// has to be provable in both.
    func testSwitchingAttributionOffAlsoDiscardsEpisodeNames() throws {
        var detector = ThrottleDetector()
        for step in 0..<40 {
            _ = detector.update(ThrottleDetector.Input(
                date: base.addingTimeInterval(Double(step)),
                cpuPercent: 95, pressure: .critical, maxTempC: 99,
                processes: [.init(name: "private-app", cpuPercent: 300)]))
        }
        XCTAssertFalse(try XCTUnwrap(detector.current).processes.isEmpty, "precondition")

        detector.setRecordsProcessNames(false)
        XCTAssertTrue(try XCTUnwrap(detector.current).processes.isEmpty)
        XCTAssertTrue(detector.accumulatedCPUSeconds.isEmpty)
    }

    /// Through the actor and onto disk: the open row must not keep the names
    /// after the toggle, because the user could export in the meantime.
    func testTheOpenRowOnDiskLosesItsNamesImmediately() async throws {
        let recorder = HistoryRecorder(url: url, recordsProcessNames: true)

        func tick(_ offset: TimeInterval, temp: Double, cpu: Double) async {
            let date = base.addingTimeInterval(offset)
            await recorder.record(
                samples: [],
                at: date,
                throttle: .init(date: date, cpuPercent: cpu, pressure: .nominal, maxTempC: temp),
                spike: .init(date: date, maxTempC: temp, cpuPercent: cpu, hottestGroup: "CPU",
                             processes: [.init(name: "private-app", cpuPercent: 380)]))
        }
        for step in 0..<3 { await tick(Double(step) * 5, temp: 58, cpu: 6) }
        for step in 3..<15 { await tick(Double(step) * 5, temp: 92, cpu: 95) }

        var insights = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                    to: base.addingTimeInterval(3_600))
        let status = await recorder.status()
        XCTAssertNil(status.problem, "a write failed: \(status.problem ?? "")")
        XCTAssertFalse(try XCTUnwrap(insights.spikes.first).processes.isEmpty, "precondition")

        await recorder.setRecordsProcessNames(false)

        insights = try await recorder.insights(from: base.addingTimeInterval(-60),
                                               to: base.addingTimeInterval(3_600))
        XCTAssertTrue(try XCTUnwrap(insights.spikes.first).processes.isEmpty,
                      "the row on disk still names it")
        let includes = await recorder.exportIncludesProcessNames(
            from: base.addingTimeInterval(-60), to: base.addingTimeInterval(3_600))
        XCTAssertFalse(includes, "an export would still have carried the name")
    }

    // MARK: - Persistence

    /// Random spikes through SQLite and back. Doubles are stored as REAL and
    /// dates as whole seconds, so this is where a lossy column would show.
    func testRandomSpikesSurvivePersistenceExactly() throws {
        var random = Seeded(seed: 99)
        let store = try HistoryStore(url: url)

        var written: [Spike] = []
        for index in 0..<400 {
            let start = base.addingTimeInterval(Double(index) * 600)
            let from = Double.random(in: -20...80, using: &random)
            var spike = Spike(
                start: start,
                peak: start.addingTimeInterval(Double(Int.random(in: 0...300, using: &random))),
                end: start.addingTimeInterval(Double(Int.random(in: 300...900, using: &random))),
                fromTempC: from,
                peakTempC: from + Double.random(in: 12...60, using: &random),
                cpuAtStartPercent: Double.random(in: 0...100, using: &random),
                peakCPUPercent: Double.random(in: 0...100, using: &random),
                hottestGroup: ["CPU", "GPU", "SoC", "Storage", "", "☃ 温度"].randomElement(using: &random)!,
                peakFanRPM: Double.random(in: 0...6_000, using: &random),
                peakFanDutyPercent: Double.random(in: 0...100, using: &random),
                profileName: ["Balanced", "", "a\"b,c\nd", String(repeating: "x", count: 400)]
                    .randomElement(using: &random)!,
                profileChanged: Bool.random(using: &random),
                onBattery: Bool.random(using: &random),
                recordedProcessNames: Bool.random(using: &random),
                processes: [.init(name: "app \(index) \u{202E}", percent: 71.25)])
            spike.id = try store.save(spike)
            written.append(spike)
        }

        let loaded = try store.spikes(from: base.addingTimeInterval(-60),
                                      to: base.addingTimeInterval(400 * 600 + 3_600),
                                      limit: 1_000)
        XCTAssertEqual(loaded.count, written.count)
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        for spike in written {
            XCTAssertEqual(byID[spike.id], spike, "spike \(spike.id) changed in the round trip")
        }
    }

    /// The query bound is a bound, not a suggestion — a UI asking for a window
    /// must not be handed ten thousand rows because a bug wrote them.
    func testTheSpikeQueryHonoursItsLimit() throws {
        let store = try HistoryStore(url: url)
        for index in 0..<500 {
            try store.save(Spike(start: base.addingTimeInterval(Double(index)),
                                 peak: base.addingTimeInterval(Double(index)),
                                 end: base.addingTimeInterval(Double(index) + 10),
                                 fromTempC: 60, peakTempC: 90))
        }
        XCTAssertEqual(try store.spikes(from: base.addingTimeInterval(-60),
                                        to: base.addingTimeInterval(3_600), limit: 25).count, 25)
        // Newest first, so a capped query returns the ones a user cares about.
        let capped = try store.spikes(from: base.addingTimeInterval(-60),
                                      to: base.addingTimeInterval(3_600), limit: 25)
        XCTAssertEqual(capped.first?.start, base.addingTimeInterval(499))
    }

    /// Event rows used to be kept forever. Small × unbounded is still unbounded.
    func testAgedEventsArePrunedButOpenOnesAreNot() throws {
        let store = try HistoryStore(url: url)
        let ancient = base.addingTimeInterval(-HistoryStore.eventRetention - 86_400)

        try store.save(Spike(start: ancient, peak: ancient, end: ancient.addingTimeInterval(60),
                             fromTempC: 60, peakTempC: 90))
        try store.save(Spike(start: ancient, peak: ancient, fromTempC: 60, peakTempC: 90))  // open
        try store.save(ThrottleEpisode(start: ancient, end: ancient.addingTimeInterval(60)))
        try store.save(RecordingSession(name: "old", start: ancient,
                                        end: ancient.addingTimeInterval(60)))
        try store.record(ProfileChange(date: ancient, profileID: "a", profileName: "Balanced",
                                       reason: "Default"))
        try store.save(Spike(start: base, peak: base, end: base.addingTimeInterval(60),
                             fromTempC: 60, peakTempC: 90))

        try store.maintain(now: base)

        XCTAssertEqual(try store.rowCountForTesting("spikes"), 2,
                       "the aged closed spike should go; the open one and the recent one stay")
        XCTAssertEqual(try store.rowCountForTesting("episodes"), 0)
        XCTAssertEqual(try store.rowCountForTesting("sessions"), 0)
        // Never the last profile change: it is what says which profile has been
        // active ever since, and the chart's first band has no label without it.
        XCTAssertEqual(try store.rowCountForTesting("profile_changes"), 1)
    }

    // MARK: - Throughput

    /// A spike rewrites its row on every tick, so a long one is thousands of
    /// UPDATEs against a growing database.
    func testAHalfHourSpikeAtOneHertzProducesOneRecord() async throws {
        let recorder = HistoryRecorder(url: url, recordsProcessNames: true)
        // Past the 1800-second duration bound, so the spike is closed by it
        // rather than left open at the end of the loop.
        await record(ticks: 1_900, into: recorder)
        await recorder.flush(now: base.addingTimeInterval(1_900))

        // Nothing was quietly dropped on the way. Without this a write that
        // failed reads as a *correctness* failure below — a spike with no end,
        // and no explanation of why — which is a bug report about the detector
        // for a fault in the disk.
        let status = await recorder.status()
        XCTAssertNil(status.problem, "a write failed: \(status.problem ?? "")")

        let insights = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                    to: base.addingTimeInterval(7_200))
        // One spike, closed by the duration bound, not a row per tick.
        XCTAssertEqual(insights.spikes.count, 1)
        XCTAssertEqual(try XCTUnwrap(insights.spikes.first).end, base.addingTimeInterval(1_800))
    }

    /// The property the throughput test was actually after: recording twice as
    /// many ticks costs about twice as much, not four times.
    ///
    /// This used to be a stopwatch — `elapsed < 30` around the same loop — which
    /// measures the machine as much as the code. On a loaded box it fails for
    /// reasons that have nothing to do with the query; on an idle one it passes
    /// however quadratic the plan became, because thirty seconds is a very long
    /// time. SQLite counts its own bytecode steps, and that number is a property
    /// of the statements and the data: the same trace costs the same under any
    /// load, on any machine, so the bound can be tight enough to mean something.
    func testRecordingCostsWorkLinearInTheNumberOfTicks() async throws {
        // Both runs stay inside the 1800-second duration bound, so both are
        // measuring the same thing: one open spike, rewritten on every tick.
        let short = await workToRecord(ticks: 900, named: "short")
        let long = await workToRecord(ticks: 1_800, named: "long")

        XCTAssertGreaterThan(short, 0, "no work was counted at all")
        // Linear work gives a ratio just under 2 — the schema and migration are a
        // fixed cost both runs pay. Quadratic gives 4.
        XCTAssertLessThan(Double(long), 2.5 * Double(short),
                          "twice the ticks cost \(Double(long) / Double(short))× the work")
    }

    private func workToRecord(ticks: Int, named name: String) async -> Int {
        let recorder = HistoryRecorder(url: directory.appendingPathComponent("\(name).sqlite"),
                                       recordsProcessNames: true)
        await record(ticks: ticks, into: recorder)
        await recorder.flush(now: base.addingTimeInterval(Double(ticks)))
        return await recorder.workUnitsForTesting()
    }

    /// One tick a second: cool for five, then hot, which is the shape that opens
    /// a spike and then makes every subsequent tick rewrite its row.
    private func record(ticks: Int, into recorder: HistoryRecorder) async {
        let sensor = SensorDescriptor(key: "temp:soc", name: "SoC",
                                      kind: .temperature, group: "SoC")
        for step in 0..<ticks {
            let date = base.addingTimeInterval(Double(step))
            let temp = step < 5 ? 55.0 : 95.0
            await recorder.record(
                samples: [RecordedSample(sensor: sensor, value: temp)],
                at: date,
                throttle: .init(date: date, cpuPercent: 95, pressure: .nominal, maxTempC: temp),
                spike: .init(date: date, maxTempC: temp, cpuPercent: 95, hottestGroup: "SoC",
                             processes: [.init(name: "compiler", cpuPercent: 300)]))
        }
    }

    /// Two readers and the writer against one connection. The actor serialises
    /// them; this is here to prove no query path deadlocks or sees a half-write.
    func testConcurrentInsightAndHistoryReadsDuringRecording() async throws {
        let recorder = HistoryRecorder(url: url, recordsProcessNames: true)
        let sensor = SensorDescriptor(key: "temp:soc", name: "SoC",
                                      kind: .temperature, group: "SoC")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for step in 0..<600 {
                    let date = self.base.addingTimeInterval(Double(step))
                    let temp = step < 5 ? 55.0 : 95.0
                    await recorder.record(
                        samples: [RecordedSample(sensor: sensor, value: temp)],
                        at: date,
                        throttle: .init(date: date, cpuPercent: 95,
                                        pressure: .nominal, maxTempC: temp),
                        spike: .init(date: date, maxTempC: temp, cpuPercent: 95,
                                     hottestGroup: "SoC",
                                     processes: [.init(name: "compiler", cpuPercent: 300)]))
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<50 {
                        _ = try? await recorder.insights(from: self.base.addingTimeInterval(-60),
                                                          to: self.base.addingTimeInterval(7_200))
                        _ = try? await recorder.window(groups: ["SoC"],
                                                       from: self.base.addingTimeInterval(-60),
                                                       to: self.base.addingTimeInterval(7_200),
                                                       now: self.base.addingTimeInterval(600))
                    }
                }
            }
        }

        let insights = try await recorder.insights(from: base.addingTimeInterval(-60),
                                                    to: base.addingTimeInterval(7_200))
        for spike in insights.spikes { assertWellFormed(spike, "concurrent") }
        let status = await recorder.status()
        XCTAssertNil(status.problem, "a read raced the writer: \(status.problem ?? "")")
        let owed = await recorder.unwrittenEventCountForTesting()
        XCTAssertEqual(owed, 0, "an event row was never written")
    }

    // MARK: - Helpers

    private func input(_ offset: TimeInterval, temp: Double?, cpu: Double = 10,
                       processes: [ProcessLoad] = []) -> SpikeDetector.Input {
        SpikeDetector.Input(date: base.addingTimeInterval(offset), maxTempC: temp,
                            cpuPercent: cpu, hottestGroup: "CPU", fanRPM: 3_000,
                            fanDutyPercent: 60, profileName: "Balanced", processes: processes)
    }
}
