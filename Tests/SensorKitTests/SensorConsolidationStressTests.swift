import XCTest
@testable import SensorKit

/// Randomised invariant checks on `consolidate`.
///
/// The hand-written cases prove it handles this Mac. These prove it cannot be
/// made to violate its contract by input we have not seen: a future macOS that
/// renames sensors, a Mac with different hardware, or an Apple bug that reuses
/// a LocationID. The invariants are the things the rest of the app relies on —
/// unique ids, no reading silently vanishing, stable ordering.
final class SensorConsolidationStressTests: XCTestCase {

    /// Deterministic generator: a failure must be reproducible from its seed,
    /// and `Package.swift` has no test-only dependencies to pull one in.
    private struct Random: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private let names = ["PMU tdie1", "PMU tdie2", "PMU tdie14", "PMU tcal",
                         "NAND CH0 temp", "gas gauge battery", "TZ0P", "", "sensor",
                         "eCPU core 1", "GPU1 Temp", "  ", "PMU tdie1"]
    private let keys = ["TP1b", "TP2b", "TPel", "TP0Z", "TN0n", "TG0B", "TG1B", "", "", ""]

    private func randomBatch(_ rng: inout Random, count: Int) -> [TemperatureSensors.Reading] {
        (0..<count).map { _ in
            TemperatureSensors.Reading(
                name: names.randomElement(using: &rng)!,
                celsius: Double.random(in: -40...150, using: &rng),
                smcKey: keys.randomElement(using: &rng)!)
        }
    }

    // MARK: - Invariants over random input

    func testInvariantsHoldOverManyRandomBatches() {
        for seed in 0..<400 {
            var rng = Random(seed: UInt64(seed) &+ 1)
            let raw = randomBatch(&rng, count: Int.random(in: 0...60, using: &rng))
            let out = TemperatureSensors.consolidate(raw)

            // 1. Ids are unique. A collision is a corrupted SwiftUI ForEach and
            //    two sensors sharing one history series.
            XCTAssertEqual(Set(out.map(\.id)).count, out.count,
                           "duplicate ids, seed \(seed)")

            // 2. Nothing is invented and nothing is silently dropped: every
            //    output name was an input name, and every input name survives.
            XCTAssertEqual(Set(out.map(\.name)), Set(raw.map(\.name)),
                           "name set changed, seed \(seed)")

            // 3. Consolidation only ever merges.
            XCTAssertLessThanOrEqual(out.count, raw.count, "grew, seed \(seed)")

            // 4. Ordinals are contiguous from zero within each name, which is
            //    what the "Battery sensor 1…6" numbering reads off.
            var byName: [String: [Int]] = [:]
            for reading in out { byName[reading.name, default: []].append(reading.ordinal) }
            for (name, ordinals) in byName {
                XCTAssertEqual(ordinals.sorted(), Array(0..<ordinals.count),
                               "ordinals not contiguous for '\(name)', seed \(seed)")
            }

            // 5. Every averaged value stays inside the range of its inputs, so
            //    consolidation can never manufacture a temperature.
            let lo = raw.map(\.celsius).min(), hi = raw.map(\.celsius).max()
            for reading in out where !raw.isEmpty {
                XCTAssertGreaterThanOrEqual(reading.celsius, lo! - 0.0001, "seed \(seed)")
                XCTAssertLessThanOrEqual(reading.celsius, hi! + 0.0001, "seed \(seed)")
            }
        }
    }

    /// Same input in a different order must give the same sensors in the same
    /// order — otherwise labels and chart series shuffle between ticks.
    func testOutputIsIndependentOfInputOrder() {
        for seed in 0..<200 {
            var rng = Random(seed: UInt64(seed) &+ 9_000)
            let raw = randomBatch(&rng, count: Int.random(in: 0...40, using: &rng))
            let a = TemperatureSensors.consolidate(raw)
            let b = TemperatureSensors.consolidate(raw.shuffled(using: &rng))

            // Keyed sensors must land in identical positions. Un-keyed ones
            // cannot be told apart at all, so only their multiset is defined.
            XCTAssertEqual(a.filter { !$0.smcKey.isEmpty }.map(\.id),
                           b.filter { !$0.smcKey.isEmpty }.map(\.id),
                           "keyed order depends on scan order, seed \(seed)")
            XCTAssertEqual(a.map(\.name).sorted(), b.map(\.name).sorted(), "seed \(seed)")
        }
    }

    // MARK: - The Apple-bug case

    /// If one key ever showed up under two names it would not be an identity.
    /// Merging would hide a sensor and give two rows the same id, so those
    /// readings must fall back to name-and-ordinal instead.
    func testOneKeyUnderTwoNamesNeverMergesOrCollides() {
        let raw = [
            TemperatureSensors.Reading(name: "PMU tdie1", celsius: 60, smcKey: "TP1b"),
            TemperatureSensors.Reading(name: "GPU1 Temp", celsius: 70, smcKey: "TP1b"),
        ]
        let out = TemperatureSensors.consolidate(raw)
        XCTAssertEqual(out.count, 2, "two different sensors were merged")
        XCTAssertEqual(Set(out.map(\.id)).count, 2, "ids collided")
        XCTAssertEqual(Set(out.map(\.celsius)), [60, 70], "a reading was lost")
    }

    /// The trustworthy keys in the same batch must not be punished for it.
    func testAConflictingKeyDoesNotDisturbTheRest() {
        let raw = [
            TemperatureSensors.Reading(name: "PMU tdie1", celsius: 60, smcKey: "TP1b"),
            TemperatureSensors.Reading(name: "GPU1 Temp", celsius: 70, smcKey: "TP1b"),
            TemperatureSensors.Reading(name: "PMU tdie2", celsius: 50, smcKey: "TP2b"),
            TemperatureSensors.Reading(name: "PMU tdie2", celsius: 52, smcKey: "TP2b"),
        ]
        let out = TemperatureSensors.consolidate(raw)
        let zone2 = out.filter { $0.name == "PMU tdie2" }
        XCTAssertEqual(zone2.count, 1, "a clean key stopped de-duplicating")
        XCTAssertEqual(zone2[0].celsius, 51, accuracy: 0.0001)
        XCTAssertEqual(zone2[0].id, "TP2b")
    }

    // MARK: - Degenerate input

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(TemperatureSensors.consolidate([]).isEmpty)
    }

    func testExtremeAndEqualValuesAreHandled() {
        let out = TemperatureSensors.consolidate([
            TemperatureSensors.Reading(name: "a", celsius: -273.15, smcKey: "K1  "),
            TemperatureSensors.Reading(name: "a", celsius: 1e6, smcKey: "K2  "),
            TemperatureSensors.Reading(name: "b", celsius: 0, smcKey: "K3  "),
            TemperatureSensors.Reading(name: "b", celsius: 0, smcKey: "K3  "),
        ])
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.first { $0.id == "K3  " }?.celsius, 0)
    }

    /// Names differing only by digits are the ones a naive sort gets wrong, and
    /// there are more of them than the 14 this Mac happens to have.
    func testLongNumericSeriesOrdersNumerically() {
        let raw = (1...120).map {
            TemperatureSensors.Reading(name: "zone \($0)", celsius: 50, smcKey: "K\($0)")
        }
        let names = TemperatureSensors.consolidate(raw.shuffled()).map(\.name)
        XCTAssertEqual(names, (1...120).map { "zone \($0)" })
    }

    /// 4096 services is far past anything real; this guards against accidental
    /// quadratic behaviour in the grouping, which would stall every UI tick.
    func testLargeInputConsolidatesQuickly() {
        let raw = (0..<4096).map {
            TemperatureSensors.Reading(name: "PMU tdie\($0 % 14 + 1)", celsius: 50,
                                       smcKey: "T\($0 % 14)")
        }
        let start = Date()
        let out = TemperatureSensors.consolidate(raw)
        XCTAssertEqual(out.count, 14)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "consolidate is too slow")
    }

    // MARK: - FourCC fuzz

    /// Whatever LocationID holds, the result is either a clean 4-character
    /// ASCII key or the empty string — never something that could collide with
    /// a real key or render as garbage in the UI.
    func testFourCCIsAlwaysCleanOrEmpty() {
        var rng = Random(seed: 12_345)
        for _ in 0..<20_000 {
            let key = TemperatureSensors.fourCC(UInt32.random(in: 0...UInt32.max, using: &rng))
            if !key.isEmpty {
                XCTAssertEqual(key.count, 4)
                XCTAssertTrue(key.allSatisfy { $0.isASCII && $0 >= " " && $0 < "\u{7f}" })
            }
        }
        // Boundary bytes: 0x20 is the lowest printable, 0x7e the highest.
        XCTAssertEqual(TemperatureSensors.fourCC(0x20202020), "    ")
        XCTAssertEqual(TemperatureSensors.fourCC(0x7e7e7e7e), "~~~~")
        XCTAssertEqual(TemperatureSensors.fourCC(0x7f7f7f7f), "")
        XCTAssertEqual(TemperatureSensors.fourCC(0x1f202020), "")
    }

    // MARK: - Naming fuzz

    /// Every sensor gets a non-empty label no matter what the hub calls it.
    func testFriendlyNameIsTotalOverArbitraryStrings() {
        var rng = Random(seed: 777)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCPMU0123456789 .-_/#")
        for _ in 0..<5_000 {
            let length = Int.random(in: 0...24, using: &rng)
            let raw = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
            let label = SensorNaming.friendlyName(for: raw)
            XCTAssertFalse(label.isEmpty, "blank label for '\(raw)'")
            XCTAssertFalse(label.hasPrefix(" "), "leading space for '\(raw)'")
            XCTAssertFalse(label.hasSuffix(" "), "trailing space for '\(raw)'")
        }
    }

    /// Classification and naming must agree about what a reference is, since
    /// the fan curve trusts one and the label trusts the other.
    func testReferenceFlagIsConsistentWithNaming() {
        for name in ["PMU tcal", "pmu TCAL", "Tcal", "PMU tcal 2"] {
            XCTAssertTrue(TemperatureSensors.Reading(name: name, celsius: 51.8).isReference, name)
            XCTAssertTrue(SensorNaming.friendlyName(for: name).lowercased().contains("calibration"),
                          "\(name) is flagged a reference but not labelled as one")
        }
    }
}
