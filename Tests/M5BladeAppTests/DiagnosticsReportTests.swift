import XCTest
import FanKit
import ProfileKit
import SensorKit
import HistoryKit
@testable import M5BladeApp

/// The diagnostics report: what it contains, that it degrades gracefully when
/// nothing is known, and that its staleness arithmetic agrees with the
/// popover's.
///
/// The whole point of the report is to be pasteable evidence. A report that
/// crashed on empty state, or said "STALE" where the UI showed a live fan,
/// would be worse than no button at all — so both are pinned here.
@MainActor
final class DiagnosticsReportTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private func input(
        status: ControlStatus = .controlling,
        fans: [FanDescriptor] = [],
        readings: [Int: FanReading] = [:],
        readingsUpdatedAt: [Int: Date] = [:],
        controlProblem: String? = nil,
        transitions: [(date: Date, from: ControlStatus, to: ControlStatus, reason: String)] = []
    ) -> DiagnosticsReport.Input {
        DiagnosticsReport.Input(
            appVersion: "1.2.3",
            osVersion: "macOS 27.0",
            hardwareModel: "Mac17,8",
            isTranslated: false,
            status: status,
            autoMode: false,
            activeProfileName: "Balanced",
            resolutionReason: "Pinned",
            fans: fans,
            readings: readings,
            readingsUpdatedAt: readingsUpdatedAt,
            maxTempC: 71.5,
            hottestGroup: "SoC",
            cpuPercent: 42,
            thermalPressure: .serious,
            isThrottling: true,
            concurrentControllers: [],
            configProblem: nil,
            controlProblem: controlProblem,
            chargeLimitProblem: nil,
            recordsProcessNames: true,
            includesSMCSensors: false,
            watchingSampleRate: .standard,
            configFileURL: URL(fileURLWithPath: "/tmp/config.json"),
            transitions: transitions,
            now: now)
    }

    func testHeaderNamesPlatformAndVersion() {
        let text = DiagnosticsReport.build(input())
        XCTAssertTrue(text.contains("Fan Control diagnostics"))
        XCTAssertTrue(text.contains("1.2.3"))
        XCTAssertTrue(text.contains("macOS 27.0"))
        XCTAssertTrue(text.contains("Mac17,8"))
    }

    /// Every fact the user could read off the main window appears in words.
    func testStateSectionMirrorsPublishedReadouts() {
        let text = DiagnosticsReport.build(input())
        XCTAssertTrue(text.contains("Controlling"))
        XCTAssertTrue(text.contains("Balanced"))
        XCTAssertTrue(text.contains("71.5 °C (SoC)"))
        XCTAssertTrue(text.contains("serious"))
        XCTAssertTrue(text.contains("throttle episode open"))
    }

    /// A fan whose last successful read predates the staleness limit is marked
    /// in the report with exactly the word the popover uses for it.
    func testStaleFanIsMarked() {
        let fans = Fixture.fans(2)
        let readings = Fixture.readings(fans)
        let text = DiagnosticsReport.build(input(
            fans: fans,
            readings: readings,
            readingsUpdatedAt: [
                0: now.addingTimeInterval(-2),   // fresh
                1: now.addingTimeInterval(-AppModel.readingStalenessLimit - 30),
            ]))

        XCTAssertTrue(text.contains("Fan 1:"))
        XCTAssertTrue(text.contains("2s ago"))
        XCTAssertTrue(text.contains("STALE"), "fan 1's reading is past the limit")
    }

    /// No readings at all must not crash and must not invent numbers.
    func testFansWithoutReadingsRenderPlaceholders() {
        let fans = Fixture.fans(1)
        let text = DiagnosticsReport.build(input(fans: fans))
        XCTAssertTrue(text.contains("now --"))
        XCTAssertTrue(text.contains("no reading"))
    }

    /// The power-telemetry row appears only when the caller had something to
    /// say — an absent reading must not render as an empty label.
    func testPackagePowerSummaryRowIsConditional() {
        let quiet = DiagnosticsReport.build(input())
        XCTAssertFalse(quiet.contains("Package power"))

        var loud = input()
        loud.packagePowerSummary = "CPU withdrawn — counter silent or implausible; GPU no channel data"
        let text = DiagnosticsReport.build(loud)
        XCTAssertTrue(text.contains("Package power  : CPU withdrawn"))
    }

    func testProblemsListedAndNoneReportedWhenEmpty() {
        let quiet = DiagnosticsReport.build(input())
        XCTAssertTrue(quiet.contains("none reported"))

        let loud = DiagnosticsReport.build(input(controlProblem: "the helper refused a target"))
        XCTAssertTrue(loud.contains("Control  : the helper refused a target"))
        XCTAssertFalse(loud.contains("none reported"))
    }

    /// The transition trail is what makes the report worth copying; entries
    /// render from → to with their reason.
    func testTransitionsAreIncluded() {
        let earlier = now.addingTimeInterval(-120)
        let later = now.addingTimeInterval(-60)
        let text = DiagnosticsReport.build(input(transitions: [
            (earlier, .controlling, .watching, "handed back to macOS (Stock)"),
            (later, .watching, .controlling, "manual control taken"),
        ]))

        XCTAssertTrue(text.contains("→ Watching — handed back to macOS (Stock)"))
        XCTAssertTrue(text.contains("→ Controlling — manual control taken"))
        // Both timestamps present, in order.
        let firstRange = text.range(of: formatter.string(from: earlier))!
        let secondRange = text.range(of: formatter.string(from: later))!
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
    }

    /// A translated process invalidates everything else in the report; it says
    /// so loudly rather than leaving the reader to notice rpm figures that
    /// cannot be real.
    func testRosettaWarningAppears() {
        var input = input()
        input.isTranslated = true
        XCTAssertTrue(DiagnosticsReport.build(input).contains("WARNING: running under Rosetta"))
    }

    /// Hardware model via sysctl — the one environmental fact this type reads
    /// itself. It must produce *something* on every Mac, including CI runners.
    func testHardwareModelIsNonEmpty() {
        XCTAssertFalse(DiagnosticsReport.hardwareModel().isEmpty)
    }
}
