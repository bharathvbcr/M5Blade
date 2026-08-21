import XCTest
@testable import DaemonProtocol

/// The three ways the helper can be absent used to be one way: a three second
/// timeout and a `false`. Every test here asserts a distinction the app could
/// not previously make, and each of them is a different instruction to the user.
final class HelperInstallationTests: XCTestCase {

    private func state(present: Set<String>) -> HelperInstallation.State {
        HelperInstallation.state { present.contains($0) }
    }

    /// The state this machine was actually in: `make install` never completed,
    /// so nothing was listening and every request timed out.
    func testNothingOnDiskIsNotInstalled() {
        XCTAssertEqual(state(present: []), .notInstalled)
    }

    /// A launchd job with no binary is not an install. launchctl will bootstrap
    /// it and the job will fail to spawn, which from the app looks identical to
    /// a helper that is merely busy.
    func testLaunchDaemonWithoutExecutableIsNotInstalled() {
        XCTAssertEqual(state(present: [HelperInstallation.launchDaemonPlistPath]),
                       .notInstalled)
    }

    func testExecutableWithoutLaunchDaemonIsNotInstalled() {
        XCTAssertEqual(state(present: [HelperInstallation.executablePath]),
                       .notInstalled)
    }

    /// The trap: everything is installed and running, and the helper still
    /// refuses every connection, because `DaemonListenerDelegate` returns false
    /// when no requirement was pinned. Reporting this as "not installed" would
    /// send the user looking in the wrong place.
    func testInstalledWithoutRequirementIsItsOwnState() {
        XCTAssertEqual(state(present: [HelperInstallation.launchDaemonPlistPath,
                                       HelperInstallation.executablePath]),
                       .installedWithoutClientRequirement)
    }

    func testAllThreeFilesIsInstalled() {
        XCTAssertEqual(state(present: [HelperInstallation.launchDaemonPlistPath,
                                       HelperInstallation.executablePath,
                                       HelperInstallation.clientRequirementPath]),
                       .installed)
    }

    /// These constants are a second copy of paths that live in shell, and a copy
    /// that drifts is worse than no check at all: the app would report "not
    /// installed" about a helper that is installed somewhere else, forever. So
    /// the scripts are the fixture. If a path moves in either direction, this
    /// fails rather than the app quietly lying.
    func testPathsAgreeWithTheInstallAndUninstallScripts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaemonProtocolTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root

        for script in ["Scripts/install-helper.sh", "Scripts/uninstall-helper.sh"] {
            let text = try String(contentsOf: root.appendingPathComponent(script), encoding: .utf8)
            for path in [HelperInstallation.launchDaemonPlistPath,
                         HelperInstallation.executablePath] {
                XCTAssertTrue(text.contains(path), "\(script) no longer mentions \(path)")
            }
            // The uninstaller removes the whole support directory rather than the
            // requirement file by name, so match the directory both agree on.
            let supportDir = (HelperInstallation.clientRequirementPath as NSString)
                .deletingLastPathComponent
            XCTAssertTrue(text.contains(supportDir), "\(script) no longer mentions \(supportDir)")
        }
    }
}
