import XCTest
import FanKit
import SimSupport
@testable import ProfileKit

/// `config.json` is a plain file in Application Support. Anyone can edit it,
/// an older build can have written it, and a half-finished sync can truncate it.
/// The contract is that *no* content produces an unsafe or nondeterministic
/// running configuration — only a corrected one and a message.
final class ConfigurationFuzzTests: XCTestCase {

    private func randomCurve(_ rng: inout SplitMix64) -> FanCurve {
        let count = Int.random(in: 0...6, using: &rng)
        let points = (0..<count).map { _ in
            CurvePoint(tempC: Double.random(in: -40...160, using: &rng),
                       percent: Double.random(in: -100...300, using: &rng))
        }
        let sensorCount = Int.random(in: 0...3, using: &rng)
        let ids = (0..<sensorCount).map { _ in "sensor\(Int.random(in: 0...5, using: &rng))#0" }
        return FanCurve(points: points, sensorIDs: ids,
                        reduction: Bool.random(using: &rng) ? .max : .mean)
    }

    private func randomProfile(_ rng: inout SplitMix64, builtInIDs: [UUID]) -> Profile {
        let useBuiltInID = Int.random(in: 0..<4, using: &rng) == 0
        let id = useBuiltInID ? builtInIDs.randomElement(using: &rng)! : UUID()
        var curves: [Int: FanCurve] = [:]
        for _ in 0..<Int.random(in: 0...4, using: &rng) {
            curves[Int.random(in: -2...5, using: &rng)] = randomCurve(&rng)
        }
        return Profile(
            id: id,
            name: Bool.random(using: &rng) ? "" : "p\(Int.random(in: 0...99, using: &rng))",
            isBuiltIn: Bool.random(using: &rng),
            fanCurves: curves,
            settings: ControlSettings(
                ceilingPercent: Double.random(in: -100...1000, using: &rng),
                hysteresisC: Double.random(in: -50...500, using: &rng),
                slewUpRPMPerSec: Double.random(in: -1e5...1e5, using: &rng),
                slewDownRPMPerSec: Double.random(in: -1e5...1e5, using: &rng),
                smoothingAlpha: Double.random(in: -10...10, using: &rng)),
            releasesToSystem: Int.random(in: 0..<5, using: &rng) == 0)
    }

    private func randomConfiguration(_ rng: inout SplitMix64) -> Configuration {
        let builtInIDs = Profile.builtIns(fanCount: 2).map(\.id)
        let profiles = (0..<Int.random(in: 0...8, using: &rng)).map { _ in
            randomProfile(&rng, builtInIDs: builtInIDs)
        }
        let targets = profiles.map(\.id) + [UUID()]
        let rules = (0..<Int.random(in: 0...6, using: &rng)).map { i in
            Rule(name: "r\(i)",
                 enabled: Bool.random(using: &rng),
                 conditions: Bool.random(using: &rng) ? [] : [.powerSource(.ac)],
                 targetProfileID: targets.randomElement(using: &rng)!,
                 minDwell: Double.random(in: -100...100, using: &rng),
                 debounce: Double.random(in: -100...100, using: &rng))
        }
        return Configuration(profiles: profiles, rules: rules,
                             defaultProfileID: targets.randomElement(using: &rng)!)
    }

    /// After `reconcile`, these must hold for any input whatsoever.
    private func assertInvariants(_ config: Configuration, seed: UInt64, iteration: Int) {
        let context = "seed \(seed) iteration \(iteration)"

        let ids = config.profiles.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate profile ids — \(context)")

        for builtIn in Profile.builtIns(fanCount: 2) {
            XCTAssertTrue(ids.contains(builtIn.id), "missing built-in \(builtIn.name) — \(context)")
        }
        XCTAssertTrue(ids.contains(config.defaultProfileID), "dangling default — \(context)")

        for rule in config.rules {
            XCTAssertTrue(ids.contains(rule.targetProfileID), "dangling rule target — \(context)")
        }
        let ruleIDs = config.rules.map(\.id)
        XCTAssertEqual(ruleIDs.count, Set(ruleIDs).count, "duplicate rule ids — \(context)")

        for profile in config.profiles {
            XCTAssertFalse(profile.name.isEmpty, "unnamed profile — \(context)")
            XCTAssertEqual(profile.settings, profile.settings.sanitized(),
                           "unsanitized settings on \(profile.name) — \(context)")
            XCTAssertTrue(profile.fanCurves.keys.allSatisfy { $0 >= 0 },
                          "negative fan index on \(profile.name) — \(context)")
            if !profile.releasesToSystem {
                XCTAssertFalse(profile.fanCurves.isEmpty, "\(profile.name) has no curves — \(context)")
                for (fan, curve) in profile.fanCurves {
                    XCTAssertTrue(curve.isUsable, "unusable curve for fan \(fan) — \(context)")
                }
                // Every curve must be evaluable to a sane percentage.
                for temp in stride(from: -20.0, through: 130.0, by: 10) {
                    let pct = profile.curve(forFan: 0).percent(at: temp)
                    XCTAssertTrue(pct.isFinite && pct >= 0 && pct <= 100,
                                  "curve produced \(pct) at \(temp)°C — \(context)")
                }
            }
        }
    }

    func testReconcileProducesASafeConfigurationForAnyInput() {
        for seed in UInt64(1)...25 {
            var rng = SplitMix64(seed: seed)
            for iteration in 0..<40 {
                var config = randomConfiguration(&rng)
                config.reconcile(fanCount: 2)
                assertInvariants(config, seed: seed, iteration: iteration)
            }
        }
    }

    func testReconcileIsIdempotentForAnyInput() {
        for seed in UInt64(100)...115 {
            var rng = SplitMix64(seed: seed)
            for _ in 0..<40 {
                var config = randomConfiguration(&rng)
                config.reconcile(fanCount: 2)
                let once = config
                let second = config.reconcile(fanCount: 2).corrections
                XCTAssertEqual(second, [], "second pass still reported: \(second)")
                XCTAssertEqual(config, once)
            }
        }
    }

    /// A fuzzed config has to survive the round trip it will actually make:
    /// encode to JSON, write, read, decode, reconcile.
    func testFuzzedConfigurationsSurviveTheDiskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fancontrol-fuzz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(url: directory.appendingPathComponent("config.json"))

        for seed in UInt64(200)...210 {
            var rng = SplitMix64(seed: seed)
            for iteration in 0..<10 {
                var config = randomConfiguration(&rng)
                config.reconcile(fanCount: 2)
                try store.save(config)
                let loaded = store.loadOrDefault(fanCount: 2)
                assertInvariants(loaded.configuration, seed: seed, iteration: iteration)
                XCTAssertEqual(loaded.configuration.profiles.count, config.profiles.count)
            }
        }
    }

    /// Truncation, byte flips, and outright garbage. The requirement is not that
    /// these load — it is that they never produce an unsafe config and never
    /// destroy the user's file.
    func testCorruptedBytesNeverYieldAnUnsafeConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fancontrol-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(url: url)

        var rng = SplitMix64(seed: 0xBADC0DE)
        let good = try JSONEncoder().encode(Configuration.factoryDefault(fanCount: 2))

        for iteration in 0..<200 {
            var bytes = [UInt8](good)
            switch iteration % 4 {
            case 0: bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng)))
            case 1:
                for _ in 0..<Int.random(in: 1...12, using: &rng) where !bytes.isEmpty {
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] =
                        UInt8.random(in: 0...255, using: &rng)
                }
            case 2: bytes = (0..<Int.random(in: 0...400, using: &rng)).map { _ in
                        UInt8.random(in: 0...255, using: &rng) }
            default: bytes = Array("{\"version\":1,\"profiles\":[]}".utf8)
            }
            try Data(bytes).write(to: url)

            let loaded = store.loadOrDefault(fanCount: 2)
            assertInvariants(loaded.configuration, seed: 0, iteration: iteration)
        }
    }

    /// A decode failure must move the file aside, never delete it: those curves
    /// are hand-authored work the user cannot regenerate.
    func testAnUndecodableFileIsPreservedNotDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fancontrol-preserve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try Data("not json at all".utf8).write(to: url)

        let loaded = ConfigStore(url: url).loadOrDefault(fanCount: 2)
        XCTAssertNotNil(loaded.problem)

        let survivors = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(survivors.contains { $0.contains("invalid-") },
                      "the unreadable file was not kept: \(survivors)")
    }
}
