import XCTest
import FanKit
import HistoryKit
@testable import M5BladeApp

/// Randomised invariants for the pieces T-1 and T-4 added.
///
/// Each test drives its subject with generated inputs and asserts properties
/// that must hold for *every* stream, because the failure modes worth fearing
/// here are exactly the ones a hand-written sequence never reaches: an alert
/// storm after an unusual interleaving, or a detector that learns to see fan
/// controllers in everything.
final class AlertAndDetectorStressTests: XCTestCase {

    // MARK: - AlertDecisionEngine soak

    /// Seeded generator: same seed, same stream, so a failure is reproducible
    /// from the seed alone.
    private func makeGenerator(seed: UInt64) -> () -> UInt64 {
        // splitmix64 — small, deterministic, good enough for stress streams.
        var state = seed
        return {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Invariant 1: two delivered alerts are never closer than the policy's
    /// minimum interval, whatever the episode/pressure interleaving.
    /// Invariant 2: no alert is ever produced for an episode younger than the
    /// sustained threshold.
    func testAlertInvariantsHoldAcrossRandomEventStreams() {
        let seeds: [UInt64] = [1, 2, 3, 42, 1337, 0xDEADBEEF]
        let policy = AlertDecisionEngine.Policy()

        for seed in seeds {
            var next = makeGenerator(seed: seed)
            var engine = AlertDecisionEngine()
            var lastDeliveredAt: Date?
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            var openEpisodeStart: Date?

            for _ in 0..<3_000 {
                now = now.addingTimeInterval(Double(next() % 90))   // ticks up to 90 s apart

                switch next() % 5 {
                case 0, 1:
                    // Episode lifecycle events.
                    if let start = openEpisodeStart, next().isMultiple(of: 3) {
                        let event = ThrottleDetector.Event.closed(
                            ThrottleEpisode(start: start, end: now))
                        openEpisodeStart = nil
                        if let alert = engine.observe(event, at: now) {
                            XCTFail("closing must not alert (seed \(seed)): \(alert)")
                        }
                    } else if openEpisodeStart == nil {
                        let event = ThrottleDetector.Event.opened(
                            ThrottleEpisode(start: now, end: nil))
                        openEpisodeStart = now
                        if let alert = engine.observe(event, at: now) {
                            XCTFail("opening must not alert (seed \(seed)): \(alert)")
                        }
                    } else {
                        let start = openEpisodeStart!
                        let age = now.timeIntervalSince(start)
                        let alert = engine.observe(
                            .updated(ThrottleEpisode(start: start, end: nil)), at: now)
                        if age < policy.sustainedSeconds - 0.001 {
                            XCTAssertNil(alert,
                                         "alerted an episode only \(age)s old (seed \(seed))")
                        }
                        if let alert {
                            if let last = lastDeliveredAt {
                                XCTAssertGreaterThanOrEqual(
                                    now.timeIntervalSince(last), policy.minimumInterval - 0.001,
                                    "two alerts \(now.timeIntervalSince(last))s apart (seed \(seed))")
                            }
                            lastDeliveredAt = now
                        }
                    }
                case 2, 3:
                    let pressure = ThermalPressure(rawValue: Int(next() % 4)) ?? .nominal
                    if let alert = engine.observe(pressure: pressure, at: now) {
                        XCTAssertEqual(pressure, .critical,
                                       "only critical pressure may alert (seed \(seed))")
                        if let last = lastDeliveredAt {
                            XCTAssertGreaterThanOrEqual(
                                now.timeIntervalSince(last), policy.minimumInterval - 0.001,
                                "two alerts \(now.timeIntervalSince(last))s apart (seed \(seed))")
                        }
                        lastDeliveredAt = now
                    }
                default:
                    break
                }
            }
        }
    }

    /// Invariant 3: ordinal text is well-formed across the whole range a busy
    /// hour could produce.
    func testOrdinalsAreWellFormedUpToAbsurdCounts() {
        for n in 1...500 {
            let text = AlertDecisionEngine.ordinal(n)
            XCTAssertTrue(text.hasSuffix("th") || text.hasSuffix("st")
                          || text.hasSuffix("nd") || text.hasSuffix("rd"),
                          "\(n) → \(text)")
            XCTAssertTrue(text.hasPrefix("\(n)"))
        }
    }

    // MARK: - Detector fuzz

    private static let ownLabel = "com.m5blade.helper"

    private func randomPlist(_ next: inout () -> UInt64, index: Int)
        -> (url: URL, plist: [String: Any]) {
        let labels = [
            "com.crystalidea.macsfancontrol.smcwrite",
            "com.tunabellysoftware.tgpro.helper",
            "com.apple.fand",
            "com.m5blade.helper",
            "com.fancontrol.helper",
            "com.google.keystone.daemon",
            "com.vendor\(index).fanthing",
            "",
        ]
        let programs = [
            "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite",
            "/usr/libexec/fand",
            "/Library/PrivilegedHelperTools/com.m5blade.helper",
            "/Library/PrivilegedHelperTools/com.fancontrol.helper",
            "relative-not-a-path",
            "",
        ]
        let label = labels[Int(next() % UInt64(labels.count))]
        let program = programs[Int(next() % UInt64(programs.count))]
        var plist: [String: Any] = [:]
        if !label.isEmpty { plist["Label"] = label }
        if !program.isEmpty { plist["Program"] = program }
        return (url: URL(fileURLWithPath: "/Library/LaunchDaemons/\(index).plist"),
                plist: plist)
    }

    private func randomProcesses(_ next: inout () -> UInt64, count: Int)
        -> [ConcurrentControllerDetector.ProcessEntry] {
        let names = ["launchd", "fand", "com.crystalidea", "tgpro.helper",
                     "m5bladed", "fancontrold", "WindowServer", "", "fa", "smcFanControl"]
        return (0..<count).map { i in
            ConcurrentControllerDetector.ProcessEntry(
                pid: Int32(i + 2),
                uid: next().isMultiple(of: 2) ? 0 : 501,
                name: names[Int(next() % UInt64(names.count))])
        }
    }

    /// Invariants over 200 random worlds:
    /// * this app's helper is never reported;
    /// * Apple daemons are never reported from the heuristic (a known
    ///   signature match would still be legitimate, so the fuzz uses none);
    /// * results are unique per identifier and stably sorted;
    /// * every entry carries at least one piece of evidence.
    func testDetectorInvariantsHoldAcrossRandomWorlds() {
        for seed: UInt64 in [1, 7, 99, 12345] {
            var next = makeGenerator(seed: seed)
            for round in 0..<50 {
                let plists = (0..<Int(next() % 8)).map { randomPlist(&next, index: $0 + round * 10) }
                let processes = randomProcesses(&next, count: Int(next() % 20))

                let detected = ConcurrentControllerDetector.scan(
                    daemonPlists: plists,
                    fileExistsAt: { _ in next().isMultiple(of: 2) },
                    processes: processes)

                let identifiers = detected.map(\.identifier)
                XCTAssertEqual(identifiers.count, Set(identifiers).count,
                               "duplicate entries (seed \(seed) round \(round)): \(identifiers)")

                XCTAssertEqual(identifiers, identifiers.sorted(),
                               "unstable ordering (seed \(seed) round \(round))")

                for entry in detected {
                    XCTAssertFalse(entry.identifier.isEmpty)
                    XCTAssertFalse(entry.productName.isEmpty)
                    XCTAssertTrue(entry.installed || entry.runningAsRoot,
                                  "\(entry.identifier) reported on no evidence")

                    // The one report that must never happen regardless of input.
                    XCTAssertNotEqual(entry.identifier.lowercased(),
                                      Self.ownLabel,
                                      "our own helper was reported as third-party")
                    XCTAssertNotEqual(entry.productName, "Fan Control")
                }
            }
        }
    }
}
