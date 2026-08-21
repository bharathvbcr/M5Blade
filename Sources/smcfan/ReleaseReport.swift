import Foundation
import FanKit

/// What `smcfan` says, and exits with, after trying to hand fans back.
///
/// `releaseAll` cannot throw — a panic path that can abort halfway is not a
/// panic path — so a caller that ignores its `ReleaseOutcome` has no way of
/// knowing the release did not happen. `smcfan auto` ignored it: every mode
/// write could be rejected (no root, or `thermalmonitord` still holding the fans
/// on M3/M4) and the command still printed "returned to macOS" and exited 0.
///
/// Split out of the command so what the user is told can be tested without root
/// or hardware. `DaemonCore` and `DaemonService` already check the outcome; this
/// is the same contract for the CLI.
struct ReleaseReport: Equatable {
    var standardOut: [String] = []
    var standardError: [String] = []
    var exitCode: Int32 = 0
}

/// Turn an outcome into what the user is told.
///
/// `unverified` is deliberately not a failure — the write was accepted and only
/// the read-back was unavailable — but it is not silent either, because "we
/// wrote auto" is not "the fan is on auto".
func releaseReport(_ outcome: ReleaseOutcome, subject: String) -> ReleaseReport {
    var report = ReleaseReport()
    guard outcome.isComplete else {
        report.standardError.append("\(subject) NOT returned to macOS — \(outcome.summary)")
        report.exitCode = 1
        return report
    }
    if outcome.unverified.isEmpty {
        report.standardOut.append("\(subject) returned to macOS.")
    } else {
        report.standardOut.append("\(subject) returned to macOS, but not every fan could be confirmed — \(outcome.summary)")
    }
    return report
}

/// Release one fan, in the same vocabulary `releaseAll` uses for the rest.
///
/// `setMode` reports the write, not the result: on M3/M4 an accepted mode write
/// can be overridden by `thermalmonitord`, so the mode is read back rather than
/// assumed. A mode that cannot be read is `unverified`, not success.
func releaseOne(_ backend: some FanBackend, fan: Int) async -> ReleaseOutcome {
    var outcome = ReleaseOutcome()
    do {
        try await backend.setMode(.auto, fan: fan)
    } catch {
        outcome.failed[fan] = String(describing: error)
        return outcome
    }
    guard let mode = (try? await backend.readFan(fan))?.mode else {
        outcome.unverified.append(fan)
        return outcome
    }
    if mode.isUserControlled {
        outcome.failed[fan] = "still in \(mode) mode after writing auto"
    } else {
        outcome.released.append(fan)
    }
    return outcome
}
