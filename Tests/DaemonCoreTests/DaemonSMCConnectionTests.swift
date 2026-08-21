import XCTest
import Foundation
import FanKit
import DaemonCore

/// The daemon's own composition, exercised against the real SMC.
///
/// Everything else in this target runs `DaemonCore` on `SimulatedFanBackend`,
/// which has no connection to open — so the entire suite passed green while the
/// shipped helper could not read a single key. `fancontrold` builds
/// `DaemonCore(backend: SMCFanBackend())` and nothing else, and `connect()` was
/// not part of `FanBackend`: there was no call for the daemon to be missing, and
/// no type error to catch its absence. The helper came up "listening" and then
/// answered every request with "SMC not initialised — no fans discovered",
/// including `releaseAll`.
///
/// These need a reachable AppleSMC, so they skip rather than fail where there is
/// none — a check that could not run must not report the same result as one that
/// ran and passed. All three are read-only: nothing here writes to the hardware.
final class DaemonSMCConnectionTests: XCTestCase {

    /// A gate, not an assertion. `connect()`'s entire job is to open the
    /// connection, so its failure means there is no usable SMC to test against.
    private func requireReachableSMC() async throws {
        do {
            try await SMCFanBackend().connect()
        } catch {
            throw XCTSkip("no reachable AppleSMC on this machine: \(error)")
        }
    }

    /// The bug, at the altitude it shipped at.
    func testDaemonStartupReachesTheSMCWithoutAnExplicitConnect() async throws {
        try await requireReachableSMC()

        let core = DaemonCore(backend: SMCFanBackend())
        let line = await core.start(now: Date())

        XCTAssertFalse(line.hasPrefix("SMC init failed"),
                       "the daemon cannot open the SMC it exists to drive: \(line)")
    }

    /// `releaseAll` re-probes when its descriptor set is empty, because a daemon
    /// whose discovery failed at boot is precisely the one that still has to hand
    /// the fans back. That re-probe is this call, and on a cold backend it threw.
    ///
    /// Asserted through discovery rather than through `releaseAll` itself: the
    /// release path writes `auto` to every fan mode key, and a test has no
    /// business taking a running machine's fans away from whatever is driving
    /// them. Compared against a connected backend rather than against a fixed
    /// count, so the expectation holds on a fanless Mac too.
    func testDiscoveryWorksOnABackendThatWasNeverConnected() async throws {
        try await requireReachableSMC()

        let connected = SMCFanBackend()
        try await connected.connect()
        let expected = try await connected.discoverFans()

        let cold = SMCFanBackend()
        let actual = try await cold.discoverFans()

        XCTAssertEqual(actual.map(\.index), expected.map(\.index),
                       "the panic path's re-probe cannot see the fans it must release")
    }

    /// The quieter half of the same defect. `capabilities()` and the probes
    /// behind it never throw, so a closed connection did not fail there — every
    /// `exists` check reported absent and the answer was *cached*. That is a
    /// permanent wrong answer for the life of the process: no mode key, and no
    /// `Ftst`, which on M3/M4 skips the unlock and turns every mode write into an
    /// 0x82.
    func testCapabilitiesDoNotDependOnAnExplicitConnect() async throws {
        try await requireReachableSMC()

        let connected = SMCFanBackend()
        try await connected.connect()
        let expected = await connected.capabilities()

        let cold = SMCFanBackend()
        let actual = await cold.capabilities()

        XCTAssertEqual(actual.modeKeySuffix, expected.modeKeySuffix,
                       "mode key casing probed on a closed connection and cached as unresolved")
        XCTAssertEqual(actual.hasFtstUnlock, expected.hasFtstUnlock,
                       "Ftst probed on a closed connection and cached as absent")
    }
}
