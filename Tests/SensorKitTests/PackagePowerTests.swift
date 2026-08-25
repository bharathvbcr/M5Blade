import XCTest
import SensorKit

/// T-5: package power arithmetic. The IOReport plumbing is exercised live by
/// `smcfan power`; these pin the pure layer that turns counters into watts —
/// the part where a sign error or unit slip would render megawatts as a
/// plausible-looking chart line.
///
/// The per-channel state machine (`PackagePower.Series`) is driven here
/// directly with fabricated counter sequences, including the three failure
/// shapes measured on real hardware: the silent counter, the lazy flush, and
/// the unit mix-up.
final class PackagePowerTests: XCTestCase {

    /// One epoch, advanced arithmetically: instants built this way differ by
    /// exactly the requested interval, so assertions can hold micro-watt
    /// accuracy without fighting the wall clock between calls.
    private let epoch = ContinuousClock.now
    private func t(_ seconds: Double) -> ContinuousClock.Instant {
        epoch.advanced(by: .seconds(seconds))
    }

    // MARK: - Deltas

    func testADeltaNeedsAPreviousSample() {
        XCTAssertNil(PackagePower.delta(100, since: nil))
        XCTAssertEqual(PackagePower.delta(150, since: 100), 50)
    }

    func testABackwardsCounterIsNoMeasurementNotZeroWatts() {
        // Counters reset across sleep; the reading for that interval is "no
        // measurement". Zero would be a *claim* — that the package consumed
        // nothing across an interval we cannot measure, which is exactly the
        // idle-cool reading the type's contract refuses to produce. It must
        // surface as nil and render as no data.
        XCTAssertNil(PackagePower.delta(50, since: 100))
        XCTAssertNil(PackagePower.watts(delta: PackagePower.delta(50, since: 100),
                                       elapsedNS: 1e9))
    }

    // MARK: - Unit conversion

    func testMillijoulesOverOneSecondIsWatts() {
        // 1 J over 1 s = 1 W; the counter is millijoules.
        XCTAssertEqual(PackagePower.watts(delta: 1_000, elapsedNS: 1e9) ?? -1,
                       1.0, accuracy: 1e-9)
    }

    func testAShortIntervalScalesUp() {
        // Same energy in half the time is double the power.
        let watts = PackagePower.watts(delta: 1_000, elapsedNS: 0.5e9) ?? -1
        XCTAssertEqual(watts, 2.0, accuracy: 1e-9)
    }

    func testAnExactZeroDeltaIsSilenceNotIdle() {
        // Measured on macOS 27 beta / M5 Pro: counters that answer with a
        // value that never moves while cores spin. An idle package still
        // burns millijoules per second — well above the counter's one-mJ
        // resolution — so an exact zero over a real interval is firmware
        // silence, and rendering it as 0.0 W was the "0W" bug this fixes.
        XCTAssertNil(PackagePower.watts(delta: 0, elapsedNS: 1e9))
        XCTAssertNil(PackagePower.watts(delta: 0, elapsedNS: 60e9))
    }

    func testANonFiniteOrNegativeResultIsNotData() {
        XCTAssertNil(PackagePower.watts(delta: nil, elapsedNS: 1e9))
        XCTAssertNil(PackagePower.watts(delta: -5, elapsedNS: 1e9))
        XCTAssertNil(PackagePower.watts(delta: 1_000, elapsedNS: 0))
        XCTAssertNil(PackagePower.watts(delta: 1_000, elapsedNS: -1e9))
        XCTAssertNil(PackagePower.watts(delta: 1_000, elapsedNS: .nan))
    }

    func testAnImplausiblePowerReadingIsRejected() {
        // A unit mix-up on these channels has rendered megawatts before. The
        // chart must never see it.
        let megawatts = PackagePower.watts(delta: 2_000_000_000, elapsedNS: 1e9)
        XCTAssertNil(megawatts)
    }

    func testARealisticPackageLoadSurvivesTheCeiling() {
        // 30 W sustained for one second = 30_000 mJ.
        let watts = PackagePower.watts(delta: 30_000, elapsedNS: 1e9) ?? -1
        XCTAssertEqual(watts, 30.0, accuracy: 1e-9)
    }

    // MARK: - Series: the healthy path

    func testFirstObservationOnlyEstablishesTheBaseline() {
        var series = PackagePower.Series()
        XCTAssertNil(series.observe(counter: 1_000, at: t(0)))
        XCTAssertFalse(series.isDormant(at: t(1)))
    }

    func testAMovingCounterPublishesWattsEveryTick() {
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000, at: t(0))
        let first = series.observe(counter: 31_000, at: t(1))
        XCTAssertEqual(first ?? -1, 30.0, accuracy: 1e-9)
        // Steady accrual of 1 J/s keeps publishing 1 W.
        let second = series.observe(counter: 32_000, at: t(2))
        XCTAssertEqual(second ?? -1, 1.0, accuracy: 1e-9)
    }

    // MARK: - Series: the lazy flush

    func testABurstAfterSilentTicksAveragesAcrossTheWholeQuietSpan() {
        // The flush cadence measured on macOS 27 beta: minutes of exact-zero
        // deltas, then one jump. Differencing against the previous tick would
        // charge the whole quiet span's energy to the single second it
        // arrived in; the series divides by the span instead.
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000, at: t(0))
        for tick in 1...4 {
            XCTAssertNil(series.observe(counter: 1_000, at: t(Double(tick))),
                         "silent tick \(tick) must publish nothing")
        }
        let burst = series.observe(counter: 103_000, at: t(5))
        // 102_000 mJ over the 5 s since the baseline = 20.4 W average.
        XCTAssertEqual(burst ?? -1, 20.4, accuracy: 1e-6)

        // The next movement measures from the burst, not from the baseline.
        let next = series.observe(counter: 106_000, at: t(6))
        XCTAssertEqual(next ?? -1, 3.0, accuracy: 1e-9)
    }

    func testAStaleWindowBeyondTheCapIsAbandonedNotSmeared() {
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000, at: t(0))
        // One observation 121 s later. Energy spread over an unknown fraction
        // of more than two minutes must not publish; the window restarts.
        XCTAssertNil(series.observe(counter: 61_000, at: t(121)))
        // And the fresh window measures normally again.
        let recovered = series.observe(counter: 62_000, at: t(122))
        XCTAssertEqual(recovered ?? -1, 1.0, accuracy: 1e-9)
    }

    func testASameInstantResampleKeepsTheExistingWindow() {
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000, at: t(0))
        XCTAssertEqual(series.observe(counter: 2_000, at: t(1)) ?? -1, 1.0, accuracy: 1e-9)
        // Moved, but no time has passed since the last move: no window.
        XCTAssertNil(series.observe(counter: 2_500, at: t(1)))
        // The window survived; the next second measures across it.
        let next = series.observe(counter: 3_500, at: t(2))
        XCTAssertEqual(next ?? -1, 1.0, accuracy: 1e-9)
    }

    // MARK: - Series: withdrawal and recovery

    func testASilentRunWithdrawsTheSeries() {
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000, at: t(0))
        for tick in 1..<PackagePower.frozenSampleLimit {
            XCTAssertNil(series.observe(counter: 1_000, at: t(Double(tick))))
            XCTAssertFalse(series.isDormant(at: t(Double(tick) + 0.5)),
                           "withdrawn early, after \(tick) of "
                           + "\(PackagePower.frozenSampleLimit) silent samples")
        }
        let finalTick = Double(PackagePower.frozenSampleLimit)
        XCTAssertNil(series.observe(counter: 1_000, at: t(finalTick)))
        XCTAssertTrue(series.isDormant(at: t(finalTick)),
                      "a full run of silent samples must withdraw the series")
    }

    func testImplausibleBurstsWithdrawExactlyLikeSilence() {
        // A scale mix-up renders as megawatts. Sustained nonsense is a dead
        // channel wearing a live channel's clothes and gets the same
        // treatment as a counter that never moves.
        var series = PackagePower.Series()
        _ = series.observe(counter: 0, at: t(0))
        for tick in 1..<PackagePower.frozenSampleLimit {
            // 2_000_000 mJ in one second = 2000 W: past the physical ceiling.
            XCTAssertNil(series.observe(counter: Int64(tick) * 2_000_000,
                                        at: t(Double(tick))))
        }
        let finalTick = Double(PackagePower.frozenSampleLimit)
        XCTAssertNil(series.observe(counter: Int64(finalTick) * 2_000_000,
                                    at: t(finalTick)))
        XCTAssertTrue(series.isDormant(at: t(finalTick)))
    }

    func testOneImplausibleSampleDoesNotPoisonALiveSeries() {
        // A single glitched reading must not withdraw a series that is
        // otherwise healthy. Realistic shape: one nonsense jump upward, the
        // real counter then reappears below it (read as a sleep-style reset),
        // and honest differencing resumes.
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000, at: t(0))
        XCTAssertNil(series.observe(counter: 3_001_000, at: t(1)))   // 3000 W: nonsense
        XCTAssertNil(series.observe(counter: 62_000, at: t(2)))      // backwards vs glitch
        let resumed = series.observe(counter: 92_000, at: t(3))
        XCTAssertEqual(resumed ?? -1, 30.0, accuracy: 1e-6)
        XCTAssertFalse(series.isDormant(at: t(3)))
    }

    func testACounterResetRebaselinesWithoutCountingAsBroken() {
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000_000, at: t(0))
        // Sleep reset the counter: backwards, unmeasurable, transient.
        XCTAssertNil(series.observe(counter: 500, at: t(1)))
        XCTAssertFalse(series.isDormant(at: t(1)))
        // Life resumes from the new origin.
        let resumed = series.observe(counter: 1_500, at: t(2))
        XCTAssertEqual(resumed ?? -1, 1.0, accuracy: 1e-9)
    }

    func testAMissingChannelRebaselines() {
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000, at: t(0))
        // The channel vanished from the sample set: platform changed.
        XCTAssertNil(series.observe(counter: nil, at: t(1)))
        // Its return is a baseline, never a difference across the gap.
        XCTAssertNil(series.observe(counter: 900_000, at: t(2)))
        let next = series.observe(counter: 901_000, at: t(3))
        XCTAssertEqual(next ?? -1, 1.0, accuracy: 1e-9)
    }

    func testAWakeProbeRebaselinesAndTheNextCallMeasuresAgain() throws {
        var series = PackagePower.Series()
        _ = series.observe(counter: 1_000, at: t(0))
        for tick in 1...PackagePower.frozenSampleLimit {
            _ = series.observe(counter: 1_000, at: t(Double(tick)))
        }
        XCTAssertTrue(series.isDormant(at: t(15)))

        // Long after the retry interval, the probe fires: whatever comes back
        // re-baselines, and ten minutes are never divided across.
        let probeTime = t(Double(PackagePower.frozenSampleLimit)
                          + PackagePower.dormantRetryInterval + 1)
        XCTAssertNil(series.observe(counter: 5_000_000, at: probeTime))
        XCTAssertFalse(series.isDormant(at: probeTime))

        let revived = series.observe(counter: 5_030_000, at: probeTime.advanced(by: .seconds(1)))
        XCTAssertEqual(revived ?? -1, 30.0, accuracy: 1e-9)
    }

    // MARK: - Live reader contract

    func testTheFirstLiveSampleOnlyEstablishesTheBaseline() {
        let power = PackagePower()
        if power.isAvailable {
            let first = power.sample()
            // No interval to difference over yet.
            XCTAssertTrue(first.isUnavailable,
                          "first sample must be a baseline, got \(first)")
        }
        // Unavailable platforms (refused subscription) degrade to unavailable
        // readings rather than throwing — asserted by reaching here at all.
    }

    /// The diagnostics line always says *something* definite about both
    /// series — a blank or crashing summary would defeat its one purpose.
    func testDiagnosticSummaryAlwaysNamesBothSeries() {
        let summary = PackagePower().diagnosticSummary()
        XCTAssertTrue(summary.contains("CPU"), "got: \(summary)")
        XCTAssertTrue(summary.contains("GPU"), "got: \(summary)")
    }

    func testSuccessiveLiveSamplesArePlausibleWhenThePlatformSupportsThem() {
        let power = PackagePower()
        guard power.isAvailable else { return }   // nothing claimed off-platform
        _ = power.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let second = power.sample()
        if let watts = second.cpuWatts {
            XCTAssertGreaterThan(watts, 0,
                                 "an exact-zero watt reading must surface as nil")
            XCTAssertLessThanOrEqual(watts, PackagePower.plausibleWattsCeiling)
        }
        if let watts = second.gpuWatts {
            XCTAssertGreaterThan(watts, 0)
            XCTAssertLessThanOrEqual(watts, PackagePower.plausibleWattsCeiling)
        }
    }

    /// Concurrent sampling smoke test: the reader is shared by the app tick
    /// and any CLI invocation; the lock discipline must hold under contention
    /// without deadlock, torn state, or out-of-range publications.
    func testConcurrentSamplingStaysInRange() {
        let power = PackagePower()
        guard power.isAvailable else { return }   // nothing claimed off-platform
        _ = power.sample()

        let iterations = 40
        let threads = (0..<8).map { _ in
            Thread {
                for _ in 0..<iterations {
                    let sample = power.sample()
                    for watts in [sample.cpuWatts, sample.gpuWatts].compactMap({ $0 }) {
                        XCTAssertTrue(watts.isFinite)
                        XCTAssertGreaterThanOrEqual(watts, 0)
                        XCTAssertLessThanOrEqual(watts, PackagePower.plausibleWattsCeiling)
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }
        threads.forEach { $0.start() }
        for thread in threads {
            // Bounded wait: a wedged thread fails via timeout rather than hang.
            let deadline = Date().addingTimeInterval(30)
            while thread.isExecuting && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertFalse(thread.isExecuting, "sampling thread did not finish")
        }
    }

    // MARK: - Timebase

    func testNanosecondsAcrossAKnownInterval() throws {
        let start = ContinuousClock.now
        let end = start.advanced(by: .milliseconds(250))
        let ns = PackagePower.nanoseconds(from: start, to: end)
        XCTAssertEqual(ns, 250_000_000, accuracy: 1_000_000)
    }
}
