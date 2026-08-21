import XCTest
import FanKit
@testable import HistoryKit

final class ThrottleDetectorTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func input(_ second: Int,
                       cpu: Double = 90,
                       pressure: ThermalPressure = .nominal,
                       temp: Double? = 70,
                       fanNearCeiling: Bool = false,
                       processes: [ThrottleDetector.ProcessLoad] = []) -> ThrottleDetector.Input {
        ThrottleDetector.Input(date: base.addingTimeInterval(Double(second)),
                               cpuPercent: cpu,
                               pressure: pressure,
                               maxTempC: temp,
                               fanRPM: [0: 3000],
                               fanNearCeiling: fanNearCeiling,
                               profileName: "Balanced",
                               onBattery: false,
                               externalDisplayCount: 0,
                               processes: processes)
    }

    /// The whole point of the gate: macOS runs cores below maximum for reasons
    /// that have nothing to do with heat, and an idle machine reporting serious
    /// pressure must not produce an episode.
    func testPressureAloneDoesNotDeclareAnEpisodeWithoutSustainedLoad() {
        var detector = ThrottleDetector()
        for second in 0...120 {
            let event = detector.update(input(second, cpu: 5, pressure: .critical, temp: 99))
            XCTAssertEqual(event, .none)
        }
        XCTAssertNil(detector.current)
    }

    func testGateMustHoldForTwentySecondsBeforePressureCounts() {
        var detector = ThrottleDetector()
        for second in 0..<20 {
            XCTAssertEqual(detector.update(input(second, pressure: .serious)), .none,
                           "second \(second) is still inside the 20s gate")
        }
        guard case .opened = detector.update(input(20, pressure: .serious)) else {
            return XCTFail("the gate has held for 20s; the episode should open")
        }
        XCTAssertEqual(detector.current?.start, base.addingTimeInterval(20))
    }

    /// A brief dip below the load threshold restarts the gate — "continuously",
    /// not "cumulatively".
    func testGateRestartsWhenLoadDrops() {
        var detector = ThrottleDetector()
        for second in 0..<19 { _ = detector.update(input(second, pressure: .serious)) }
        _ = detector.update(input(19, cpu: 10, pressure: .serious))
        for second in 20..<40 {
            XCTAssertEqual(detector.update(input(second, pressure: .serious)), .none)
        }
        guard case .opened = detector.update(input(40, pressure: .serious)) else {
            return XCTFail("the gate restarted at second 20 and re-qualifies at 40")
        }
    }

    /// Without the primary signal it takes two supporting ones — temperature
    /// alone is not enough.
    func testOneSupportingSignalIsNotEnough() {
        var detector = ThrottleDetector()
        for second in 0...60 {
            XCTAssertEqual(detector.update(input(second, pressure: .fair, temp: 99)), .none)
        }
    }

    func testTwoSupportingSignalsDeclareWithoutSeriousPressure() {
        var detector = ThrottleDetector()
        for second in 0..<20 {
            _ = detector.update(input(second, pressure: .fair, temp: 99, fanNearCeiling: true))
        }
        guard case .opened = detector.update(input(20, pressure: .fair, temp: 99,
                                                   fanNearCeiling: true)) else {
            return XCTFail("temperature plus a fan at its ceiling is corroboration enough")
        }
    }

    func testEpisodeEndsAtTheLastInstantTheConditionHeldNotWhenConfirmed() {
        var detector = ThrottleDetector()
        for second in 0...30 { _ = detector.update(input(second, pressure: .serious)) }

        // Condition last held at second 30; the close is confirmed 15s after that.
        for second in 31..<45 {
            XCTAssertEqual(detector.update(input(second, pressure: .nominal)), .none)
        }
        guard case .closed(let episode) = detector.update(input(45, pressure: .nominal)) else {
            return XCTFail("15 clear seconds have passed; the episode should close")
        }
        XCTAssertEqual(episode.end, base.addingTimeInterval(30))
        XCTAssertEqual(episode.duration, 10)
        XCTAssertNil(detector.current)
    }

    /// Hysteresis: a one-sample dip must not split an episode in two.
    func testShortDipDoesNotSplitAnEpisode() {
        var detector = ThrottleDetector()
        for second in 0...25 { _ = detector.update(input(second, pressure: .serious)) }
        for second in 26..<31 {
            XCTAssertEqual(detector.update(input(second, pressure: .nominal)), .none)
        }
        guard case .updated = detector.update(input(31, pressure: .serious)) else {
            return XCTFail("the same episode should still be running")
        }
        XCTAssertEqual(detector.current?.start, base.addingTimeInterval(20))
    }

    func testPeaksAndFanSpeedsAreCapturedAtTheHottestMoment() {
        var detector = ThrottleDetector()
        for second in 0...20 { _ = detector.update(input(second, pressure: .serious, temp: 80)) }

        var hot = input(21, pressure: .critical, temp: 101)
        hot.fanRPM = [0: 4400, 1: 4300]
        _ = detector.update(hot)
        _ = detector.update(input(22, pressure: .serious, temp: 85))

        let episode = try? XCTUnwrap(detector.current)
        XCTAssertEqual(episode?.peakTempC, 101)
        XCTAssertEqual(episode?.peakPressure, ThermalPressure.critical.rawValue)
        XCTAssertEqual(episode?.fanRPMAtPeak, [0: 4400, 1: 4300],
                       "fan speeds belong to the peak, not to the last sample")
    }

    func testAttributionIsShareOfCPUSecondsNotInstantaneousPercent() {
        var detector = ThrottleDetector()
        for second in 0...20 { _ = detector.update(input(second, pressure: .serious)) }

        // swift-frontend runs hot for 10s; Finder spikes for 1s.
        for second in 21...30 {
            _ = detector.update(input(second, pressure: .serious,
                                      processes: [.init(name: "swift-frontend", cpuPercent: 80),
                                                  .init(name: "Finder", cpuPercent: 8)]))
        }
        _ = detector.update(input(31, pressure: .serious,
                                  processes: [.init(name: "Finder", cpuPercent: 100)]))

        let processes = try? XCTUnwrap(detector.current?.processes)
        XCTAssertEqual(processes?.first?.name, "swift-frontend")
        let share = try? XCTUnwrap(processes?.first?.percent)
        XCTAssertEqual(share ?? 0, 800 / (800 + 80 + 100) * 100, accuracy: 0.01)
    }

    /// A sleep/wake gap between two ticks must not be billed to whatever process
    /// happened to be running either side of it.
    func testLongGapsAreClampedInAttribution() {
        var detector = ThrottleDetector()
        for second in 0...20 { _ = detector.update(input(second, pressure: .serious)) }
        _ = detector.update(input(21, pressure: .serious,
                                  processes: [.init(name: "kernel_task", cpuPercent: 100)]))
        // Ten minutes later, still throttling.
        _ = detector.update(input(621, pressure: .serious,
                                  processes: [.init(name: "kernel_task", cpuPercent: 100)]))

        let seconds = detector.accumulatedCPUSeconds["kernel_task"] ?? 0
        XCTAssertEqual(seconds, 61, accuracy: 0.001, "600s gap clamps to 60s, plus the 1s tick")
    }

    /// The detector attributes only what it is given; `HistoryRecorder` is what
    /// strips process loads when attribution is switched off.
    func testEpisodeCarriesNoProcessesWhenNoneAreSupplied() {
        var detector = ThrottleDetector()
        for second in 0...25 { _ = detector.update(input(second, pressure: .serious)) }
        XCTAssertEqual(detector.current?.processes, [])
    }
}
