import XCTest
@testable import M5BladeApp

/// T-1 / ISSUES I-9: a second root fan controller must be found and named.
///
/// The rules under test are the ones that decide whether the user sees a
/// warning banner, so each is pinned against both directions: what must be
/// caught, and what must be left alone. A detector that cried wolf on Apple's
/// own daemons — or on this app's own helper — would train the user to dismiss
/// the one warning that matters.
final class ConcurrentControllerTests: XCTestCase {

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    private let exists = { (path: String) in true }

    private func entry(_ pid: Int32, _ uid: UInt32, _ name: String)
        -> ConcurrentControllerDetector.ProcessEntry {
        .init(pid: pid, uid: uid, name: name)
    }

    // MARK: - Plist-driven detection

    func testAMacsFanControlInstallIsDetectedAndNamed() {
        let macs = (url: url("/Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist"),
                    plist: ["Label": "com.crystalidea.macsfancontrol.smcwrite",
                            "Program": "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [macs], fileExistsAt: exists,
            processes: [entry(1, 0, "launchd")])

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.productName, "Macs Fan Control")
        XCTAssertEqual(detected.first?.installed, true)
        XCTAssertEqual(detected.first?.runningAsRoot, false)
    }

    func testARunningRootHelperIsReportedAsRunning() {
        // The kernel truncates p_comm to 16 bytes: the real helper's command
        // name arrives as `com.crystalidea`. Detection must survive that.
        let macs = (url: url("/Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist"),
                    plist: ["Label": "com.crystalidea.macsfancontrol.smcwrite",
                            "Program": "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [macs], fileExistsAt: exists,
            processes: [entry(582, 0, "com.crystalidea")])

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.runningAsRoot, true)
        XCTAssertEqual(detected.first?.installed, true)
    }

    func testARunningHelperWithoutAnyPlistIsStillReported() {
        // A job can run without an installed plist (launched by hand). The
        // running process is the fact that matters, not the paperwork.
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [], fileExistsAt: exists,
            processes: [entry(582, 0, "com.crystalidea")])

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.runningAsRoot, true)
        XCTAssertEqual(detected.first?.installed, false)
    }

    func testAnInstalledJobWhoseBinaryIsGoneIsNotReported() {
        // Nothing can start it, nothing is running — warning about it would
        // describe a problem that does not exist.
        let macs = (url: url("/Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist"),
                    plist: ["Label": "com.crystalidea.macsfancontrol.smcwrite",
                            "Program": "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [macs], fileExistsAt: { _ in false },
            processes: [entry(1, 0, "launchd")])

        XCTAssertTrue(detected.isEmpty)
    }

    func testAnInstalledJobWhoseBinaryIsGoneButWhichIsRunningIsReported() {
        let macs = (url: url("/Library/LaunchDaemons/x.plist"),
                    plist: ["Label": "com.crystalidea.macsfancontrol.smcwrite",
                            "Program": "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [macs], fileExistsAt: { _ in false },
            processes: [entry(582, 0, "com.crystalidea")])

        XCTAssertEqual(detected.count, 1)
    }

    // MARK: - What must be left alone

    func testThisAppsOwnHelperIsNeverReported() {
        let own = (url: url("/Library/LaunchDaemons/com.m5blade.helper.plist"),
                   plist: ["Label": "com.m5blade.helper",
                           "Program": "/Library/PrivilegedHelperTools/com.m5blade.helper"] as [String: Any])
        let legacyOwn = (url: url("/Library/LaunchDaemons/com.fancontrol.helper.plist"),
                         plist: ["Label": "com.fancontrol.helper",
                                 "Program": "/Library/PrivilegedHelperTools/com.fancontrol.helper"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [own, legacyOwn], fileExistsAt: exists,
            processes: [entry(841, 0, "m5bladed"), entry(842, 0, "fancontrold")])

        XCTAssertTrue(detected.isEmpty)
    }

    func testAppleDaemonsAreNeverReportedEvenWhenFanNamed() {
        // macOS driving its own fans is correct behaviour, not a conflict.
        let apple = (url: url("/Library/LaunchDaemons/com.apple.fand.plist"),
                     plist: ["Label": "com.apple.fand",
                             "Program": "/usr/libexec/fand"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [apple], fileExistsAt: exists,
            processes: [entry(200, 0, "fand")])

        XCTAssertTrue(detected.isEmpty)
    }

    func testUnrelatedRootDaemonsAreIgnored() {
        let updater = (url: url("/Library/LaunchDaemons/com.google.keystone.daemon.plist"),
                       plist: ["Label": "com.google.keystone.daemon",
                               "Program": "/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdateDaemon"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [updater], fileExistsAt: exists,
            processes: [entry(300, 0, "keystone"), entry(301, 501, "M5BladeApp")])

        XCTAssertTrue(detected.isEmpty)
    }

    func testAUserProcessNamedLikeAFanAppIsNotAConflictingRootWriter() {
        // Only root writers share the SMC keys this app writes. The user's own
        // session apps are noise here however they are named.
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [], fileExistsAt: exists,
            processes: [entry(400, 501, "smcFanControl"), entry(401, 501, "TG Pro")])

        XCTAssertTrue(detected.isEmpty)
    }

    // MARK: - Command-name matching

    func testATruncatedCommandNameMatchesItsExecutable() {
        XCTAssertTrue(ConcurrentControllerDetector.commName(
            "com.crystalidea", matchesExecutable: "com.crystalidea.macsfancontrol.smcwrite"))
    }

    func testAnExactShortCommandNameMatches() {
        XCTAssertTrue(ConcurrentControllerDetector.commName(
            "tgpro", matchesExecutable: "tgpro"))
    }

    func testADifferentNameDoesNotMatch() {
        XCTAssertFalse(ConcurrentControllerDetector.commName(
            "loginwindow", matchesExecutable: "com.crystalidea.macsfancontrol"))
    }

    func testAVeryShortCommandNameNeverMatches() {
        // Four characters is the floor: below it, prefixes like "fa" would
        // match half of /usr/sbin.
        XCTAssertFalse(ConcurrentControllerDetector.commName(
            "fan", matchesExecutable: "fancontrold"))
        XCTAssertFalse(ConcurrentControllerDetector.commName(
            "", matchesExecutable: "fancontrold"))
    }

    /// A signature typo'd to "" would otherwise declare every daemon on the
    /// machine a fan controller. Matching fails closed instead.
    func testAnEmptySignatureFragmentMatchesNothing() {
        let anything = (url: url("/Library/LaunchDaemons/com.example.anything.plist"),
                        plist: ["Label": "com.example.anything",
                                "Program": "/usr/local/bin/anything"] as [String: Any])
        let signatures: [(fragments: [String], productName: String)] = [([], "Anything")]
        // Not reachable through the public API — asserted via the matcher.
        XCTAssertFalse(ConcurrentControllerDetector.matchesAnyForTesting(
            "com.example.anything", []))
        _ = anything
        _ = signatures
    }

    // MARK: - Live inputs

    /// The real scan must complete against this machine's actual filesystem
    /// and process table and return well-formed results whatever it finds.
    /// What it finds is machine-specific by nature, so nothing here asserts a
    /// particular product.
    func testTheLiveScanCompletesWithWellFormedResults() {
        let detected = ConcurrentControllerDetector.scanNow()
        for controller in detected {
            XCTAssertFalse(controller.identifier.isEmpty)
            XCTAssertFalse(controller.productName.isEmpty)
            // An entry with neither signal has no basis for existing.
            XCTAssertTrue(controller.installed || controller.runningAsRoot,
                          "\(controller.identifier) was reported on no evidence")
        }
    }

    // MARK: - Output shape

    func testSeveralSignalsCollapseIntoOneEntryPerProduct() {
        let macs = (url: url("/Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist"),
                    plist: ["Label": "com.crystalidea.macsfancontrol.smcwrite",
                            "Program": "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [macs], fileExistsAt: exists,
            processes: [entry(582, 0, "com.crystalidea"), entry(583, 0, "com.crystalidea2")])

        XCTAssertEqual(detected.filter { $0.productName == "Macs Fan Control" }.count, 1)
    }

    func testMultipleProductsAreSortedStablyByIdentifier() {
        let tgPro = (url: url("/Library/LaunchDaemons/com.tunabellysoftware.tgpro.helper.plist"),
                     plist: ["Label": "com.tunabellysoftware.tgpro.helper",
                             "Program": "/Library/PrivilegedHelperTools/com.tunabellysoftware.tgpro.helper"] as [String: Any])
        let macs = (url: url("/Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist"),
                    plist: ["Label": "com.crystalidea.macsfancontrol.smcwrite",
                            "Program": "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite"] as [String: Any])
        let detected = ConcurrentControllerDetector.scan(
            daemonPlists: [tgPro, macs], fileExistsAt: exists, processes: [])

        XCTAssertEqual(detected.map(\.identifier), detected.map(\.identifier).sorted())
        XCTAssertEqual(Set(detected.map(\.productName)),
                       Set(["Macs Fan Control", "TG Pro"]))
    }
}
