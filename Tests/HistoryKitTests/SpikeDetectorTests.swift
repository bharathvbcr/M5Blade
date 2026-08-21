import XCTest
import FanKit
@testable import HistoryKit

/// The detector behind "my Mac suddenly spiked — why?".
///
/// The two failure modes that matter are opposites, so both are pinned here: a
/// bar so low that every afternoon warm-up becomes a "spike" (and the page
/// becomes noise), and one so high that the ninety-second fan ramp people
/// actually complain about leaves no record at all.
final class SpikeDetectorTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func input(_ offset: TimeInterval,
                       temp: Double?,
                       cpu: Double = 10,
                       group: String = "SoC",
                       profile: String = "Balanced",
                       processes: [ThrottleDetector.ProcessLoad] = []) -> SpikeDetector.Input {
        SpikeDetector.Input(date: base.addingTimeInterval(offset),
                            maxTempC: temp,
                            cpuPercent: cpu,
                            hottestGroup: group,
                            fanRPM: 3_200,
                            fanDutyPercent: 62,
                            profileName: profile,
                            processes: processes)
    }

    /// Feeds a flat idle stretch so there is a baseline to rise from.
    private func settle(_ detector: inout SpikeDetector, at temp: Double = 60,
                        from: TimeInterval = 0, count: Int = 3) {
        for index in 0..<count {
            _ = detector.update(input(from + Double(index) * 5, temp: temp))
        }
    }

    // MARK: - Declaring

    func testASuddenRiseOpensASpikeMeasuredFromTheCoolestSampleBeforeIt() {
        var detector = SpikeDetector()
        settle(&detector)

        guard case .opened(let spike) = detector.update(input(15, temp: 78, cpu: 90)) else {
            return XCTFail("a 60 → 78 °C rise inside 15 seconds should be a spike")
        }
        XCTAssertEqual(spike.start, base, "starts where the climb began, not where it crossed")
        XCTAssertEqual(spike.peak, base.addingTimeInterval(15))
        XCTAssertEqual(spike.fromTempC, 60)
        XCTAssertEqual(spike.peakTempC, 78)
        XCTAssertEqual(spike.riseC, 18)
        XCTAssertEqual(spike.cpuAtStartPercent, 10, "load at the baseline, not at the peak")
        XCTAssertEqual(spike.peakCPUPercent, 90)
        XCTAssertNil(spike.end, "still elevated")
    }

    /// The whole reason for the trailing window. Half a degree every twenty
    /// seconds reaches 90 °C eventually, and none of it is sudden.
    func testAGradualWarmUpIsNeverASpike() {
        var detector = SpikeDetector()
        for index in 0..<120 {
            let event = detector.update(input(Double(index) * 20, temp: 55 + Double(index) * 0.5))
            if case .opened = event {
                return XCTFail("a 1.5 °C/minute climb is drift, not a spike")
            }
        }
        XCTAssertNil(detector.current)
    }

    /// A cold machine waking up climbs fast and is not interesting.
    func testARiseThatNeverGetsHotIsNotASpike() {
        var detector = SpikeDetector()
        settle(&detector, at: 25)
        if case .opened = detector.update(input(15, temp: 55)) {
            XCTFail("55 °C is not hot on any Mac, however fast it got there")
        }
    }

    func testAProfileChangeDuringTheRiseIsRecorded() throws {
        var detector = SpikeDetector()
        settle(&detector)
        _ = detector.update(input(15, temp: 78))
        _ = detector.update(input(20, temp: 80, profile: "Silent"))

        let spike = try XCTUnwrap(detector.current)
        XCTAssertTrue(spike.profileChanged)
        XCTAssertEqual(spike.profileName, "Silent")
    }

    // MARK: - Closing

    func testTheSpikeEndsWhereItSettled_NotWhereWeNoticed() throws {
        var detector = SpikeDetector()
        settle(&detector)
        _ = detector.update(input(15, temp: 78))          // opens, rise of 18
        _ = detector.update(input(20, temp: 78))          // still up: settle point is 69

        var closed: Spike?
        for offset in stride(from: 25.0, through: 60.0, by: 5) {
            if case .closed(let spike) = detector.update(input(offset, temp: 65)) { closed = spike }
        }

        let spike = try XCTUnwrap(closed)
        XCTAssertEqual(spike.end, base.addingTimeInterval(20),
                       "ends at the last instant it was still elevated")
        XCTAssertEqual(spike.duration, 20)
        XCTAssertNil(detector.current)
    }

    /// A machine that simply stays hot is a sustained workload — the throttle
    /// detector's subject. Left open, this record would read "still elevated"
    /// for the rest of the day and shade every later window.
    func testASpikeThatNeverSettlesIsClosedRatherThanRunningForever() throws {
        var detector = SpikeDetector(configuration: .init(maximumDuration: 120))
        settle(&detector)

        var closures: [Spike] = []
        for offset in stride(from: 15.0, through: 900.0, by: 5) {
            if case .closed(let spike) = detector.update(input(offset, temp: 90)) {
                closures.append(spike)
            }
        }

        let spike = try XCTUnwrap(closures.first)
        XCTAssertEqual(spike.end, base.addingTimeInterval(120))
        // And exactly once. A machine that simply stays hot must not produce a
        // new spike every two minutes, each measured from a temperature it left
        // thirteen minutes ago.
        XCTAssertEqual(closures.count, 1, "one sustained hot period is not a chain of spikes")
        XCTAssertNil(detector.current)
    }

    /// Sleep. On the far side of it we have no idea what the machine did, so the
    /// record has to stop where observation stopped.
    func testASleepGapClosesTheSpikeAndDiscardsTheBaseline() {
        var detector = SpikeDetector()
        settle(&detector)
        _ = detector.update(input(15, temp: 78))

        guard case .closed(let spike) = detector.update(input(615, temp: 40)) else {
            return XCTFail("a ten-minute gap must close the open spike")
        }
        XCTAssertEqual(spike.end, base.addingTimeInterval(15))

        // And nothing may be declared against a baseline from before the gap.
        for offset in stride(from: 620.0, through: 640.0, by: 5) {
            if case .opened = detector.update(input(offset, temp: 95)) {
                XCTFail("a wake must not read as an instant 55 °C rise")
            }
        }
    }

    /// Regression. `isFinite` was the only guard, so a sensor reporting 1e9 —
    /// finite, and impossible — landed in the trailing window as a baseline no
    /// real reading could be measured against. The very next sample was a
    /// billion degrees below it, which is a spike under any threshold, and the
    /// bogus record then swallowed the genuine rise that followed it.
    func testAFiniteButImpossibleReadingCannotBecomeABaseline() {
        var detector = SpikeDetector()
        for (index, value) in [1e9, -1e9, 1e300, -273.16, 500.0].enumerated() {
            if case .opened = detector.update(input(Double(index) * 5, temp: value)) {
                XCTFail("\(value) is not a temperature and must not declare a spike")
            }
        }
        XCTAssertNil(detector.current)

        // And a genuine spike straight afterwards is still found, measured
        // against real readings rather than against the nonsense.
        settle(&detector, from: 25)
        guard case .opened(let spike) = detector.update(input(40, temp: 78, cpu: 90)) else {
            return XCTFail("a real spike after hostile input must still be found")
        }
        XCTAssertEqual(spike.fromTempC, 60, "the baseline came from the impossible reading")
    }

    func testAMissingTemperatureDoesNotCloseALiveSpike() {
        var detector = SpikeDetector()
        settle(&detector)
        _ = detector.update(input(15, temp: 78))

        XCTAssertEqual(detector.update(input(20, temp: nil)), .none)
        XCTAssertNotNil(detector.current, "a sensor that stopped reporting is not a cool one")
    }

    // MARK: - Attribution

    /// CPU-seconds, not peak percent. A process that ran for the whole rise is
    /// the cause; one that briefly touched 100% is a coincidence.
    func testAttributionRanksByCPUSecondsRatherThanPeakPercent() throws {
        var detector = SpikeDetector()
        detector.setRecordsProcessNames(true)
        settle(&detector)
        _ = detector.update(input(15, temp: 78, cpu: 95))

        for offset in stride(from: 20.0, through: 60.0, by: 5) {
            _ = detector.update(input(offset, temp: 85, cpu: 95, processes: [
                .init(name: "compiler", cpuPercent: 100),
                .init(name: "browser", cpuPercent: 20),
            ]))
        }
        // One tick of a spike that never ran: 400% for five seconds is 20
        // CPU-seconds, well under the compiler's accumulated total.
        _ = detector.update(input(65, temp: 85, cpu: 95, processes: [
            .init(name: "flash-in-the-pan", cpuPercent: 400),
        ]))

        let spike = try XCTUnwrap(detector.current)
        // 45 CPU-seconds for the compiler, 20 for the flash, 9 for the browser.
        XCTAssertEqual(spike.processes.map(\.name), ["compiler", "flash-in-the-pan", "browser"])
        XCTAssertEqual(spike.processes.first?.percent ?? 0, 45 / 74 * 100, accuracy: 0.5)
        XCTAssertTrue(spike.recordedProcessNames)
    }

    /// Off by default (DESIGN §5.4), and the record says so for itself rather
    /// than leaving a reader to guess from an empty list.
    func testASpikeRecordsWhetherNamesWereBeingCollected() {
        var detector = SpikeDetector()
        settle(&detector)
        guard case .opened(let spike) = detector.update(input(15, temp: 78)) else {
            return XCTFail("expected a spike")
        }
        XCTAssertFalse(spike.recordedProcessNames)
        XCTAssertTrue(spike.processes.isEmpty)
    }

    /// The gate that decides whether names are *collected* has to fire before
    /// the one that declares a spike, or attribution would always arrive late.
    func testTheAttributionGateIsMoreSensitiveThanTheDeclarationThreshold() {
        XCTAssertLessThan(SpikeDetector.Attribution.armRiseC,
                          SpikeDetector.Configuration().riseThresholdC)
        XCTAssertLessThanOrEqual(SpikeDetector.Attribution.armWindow,
                                 SpikeDetector.Configuration().riseWindow)
    }

    // MARK: - Derived values

    /// Every rate in the app divides by this.
    func testRiseSecondsIsNeverZero() {
        let instant = Spike(start: base, peak: base, fromTempC: 60, peakTempC: 90)
        XCTAssertGreaterThan(instant.riseSeconds, 0)
        XCTAssertTrue(instant.riseRatePerMinute.isFinite)
    }
}
