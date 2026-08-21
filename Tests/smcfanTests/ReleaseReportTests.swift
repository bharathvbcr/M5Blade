import XCTest
import FanKit
@testable import smcfan

/// `smcfan auto` is what the uninstaller and any script around this tool call to
/// be sure the fans are back under macOS. It used to discard the
/// `ReleaseOutcome` and print "returned to macOS" unconditionally, so a release
/// in which every mode write was rejected — no root, or `thermalmonitord` still
/// holding the fans on M3/M4 — was indistinguishable from one that worked.
final class ReleaseReportTests: XCTestCase {

    private func assertClaimsNoSuccess(_ report: ReleaseReport,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(report.exitCode, 0, "a failed release must not exit 0", file: file, line: line)
        XCTAssertTrue(report.standardOut.isEmpty,
                      "nothing belongs on stdout when the release failed: \(report.standardOut)",
                      file: file, line: line)
        XCTAssertEqual(report.standardError.count, 1, file: file, line: line)
        // Not merely "does not say success" — it has to say the opposite, out
        // loud, on stderr.
        XCTAssertTrue(report.standardError.first?.contains("NOT returned to macOS") == true,
                      "a failed release did not say so: \(report.standardError)",
                      file: file, line: line)
    }

    /// Never subscripts: a regression that empties these arrays must fail the
    /// assertion it belongs to, not trap and take the rest of the suite with it.
    private func assertContains(_ lines: [String], _ needle: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(lines.contains { $0.contains(needle) },
                      "expected \"\(needle)\" in \(lines)", file: file, line: line)
    }

    // MARK: - The report itself

    func testRejectedWritesAreReportedAndExitNonZero() {
        var outcome = ReleaseOutcome()
        outcome.failed[0] = "writeRejected"
        outcome.failed[1] = "writeRejected"

        let report = releaseReport(outcome, subject: "All 2 fan(s)")

        assertClaimsNoSuccess(report)
        // The reason reaches the user, not just the fact of failure.
        assertContains(report.standardError, outcome.summary)
        assertContains(report.standardError, "writeRejected")
    }

    /// The case that motivated `hadNoFans`: writing to nothing is not success.
    func testNoFansIsNotSuccess() {
        var outcome = ReleaseOutcome()
        outcome.hadNoFans = true

        let report = releaseReport(outcome, subject: "All 0 fan(s)")

        assertClaimsNoSuccess(report)
        assertContains(report.standardError, "nothing was released")
    }

    /// A partial release is a failure, even though some fans came back.
    func testPartialReleaseIsAFailure() {
        var outcome = ReleaseOutcome()
        outcome.released = [0]
        outcome.failed[1] = "still in mode 1 after writing auto"

        let report = releaseReport(outcome, subject: "All 2 fan(s)")

        assertClaimsNoSuccess(report)
        assertContains(report.standardError, "released 0")
        assertContains(report.standardError, "fan 1 failed")
    }

    func testCompleteReleaseReportsSuccessAndExitsZero() {
        var outcome = ReleaseOutcome()
        outcome.released = [0, 1]

        let report = releaseReport(outcome, subject: "All 2 fan(s)")

        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.standardOut, ["All 2 fan(s) returned to macOS."])
        XCTAssertTrue(report.standardError.isEmpty)
    }

    /// `unverified` is not a failure — the write was accepted, only the read-back
    /// was unavailable — but it is not silent either. `DaemonCore` draws the same
    /// line, and the CLI must not draw a different one.
    func testUnverifiedSucceedsButSaysSo() {
        var outcome = ReleaseOutcome()
        outcome.released = [0]
        outcome.unverified = [1]

        let report = releaseReport(outcome, subject: "All 2 fan(s)")

        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.standardOut.count, 1)
        assertContains(report.standardOut, "not every fan could be confirmed")
        assertContains(report.standardOut, "unverified 1")
    }

    // MARK: - Against a backend

    /// End to end over the fault-injecting backend: every mode write rejected is
    /// what running `smcfan auto` without root looks like from here.
    func testReleaseAllWithEveryWriteRejectedReportsFailure() async {
        let backend = SimulatedFanBackend()
        var faults = SimulatedFanBackend.Faults()
        faults.rejectModeWrites = true
        await backend.setFaults(faults)

        let report = releaseReport(await backend.releaseAll(), subject: "All 2 fan(s)")

        assertClaimsNoSuccess(report)
    }

    /// The single-fan path. `setMode` reports the write, not the result: on M3/M4
    /// an accepted mode write can be overridden, and the fan stays manual.
    func testReleaseOneRejectsASilentlyIgnoredModeWrite() async {
        let backend = SimulatedFanBackend()
        try? await backend.setMode(.manual, fan: 0)
        var faults = SimulatedFanBackend.Faults()
        faults.modeWritesSilentlyIgnored = true
        await backend.setFaults(faults)

        let outcome = await releaseOne(backend, fan: 0)

        XCTAssertEqual(outcome.released, [])
        XCTAssertNotNil(outcome.failed[0])
        assertClaimsNoSuccess(releaseReport(outcome, subject: "Fan 0"))
        // The fan really is still under manual control — the report is not
        // pessimism, it is what the hardware says.
        let mode = await backend.mode(of: 0)
        XCTAssertEqual(mode, .manual)
    }

    func testReleaseOneReportsUnverifiedWhenTheModeCannotBeReadBack() async {
        let backend = SimulatedFanBackend()
        var faults = SimulatedFanBackend.Faults()
        faults.readsFail = true
        await backend.setFaults(faults)

        let outcome = await releaseOne(backend, fan: 0)

        XCTAssertEqual(outcome.unverified, [0])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(releaseReport(outcome, subject: "Fan 0").exitCode, 0)
    }

    func testReleaseOneSucceedsWhenTheFanComesBack() async {
        let backend = SimulatedFanBackend()
        try? await backend.setMode(.manual, fan: 0)

        let outcome = await releaseOne(backend, fan: 0)

        XCTAssertEqual(outcome.released, [0])
        XCTAssertEqual(releaseReport(outcome, subject: "Fan 0").standardOut,
                       ["Fan 0 returned to macOS."])
    }
}
