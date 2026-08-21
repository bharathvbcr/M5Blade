import XCTest
import FanKit
@testable import SensorKit

/// The SMC source, the merge, and the rule deciding what may be acted on — all
/// exercised as pure logic against traces taken from this Mac, so none of it
/// needs a warm machine or an open IOKit handle to fail.
final class SMCSensorSourceTests: XCTestCase {

    private func reading(_ name: String, _ celsius: Double,
                         key: String? = nil, ordinal: Int = 0)
    -> TemperatureSensors.Reading {
        TemperatureSensors.Reading(name: name, celsius: celsius,
                                   ordinal: ordinal, smcKey: key ?? name)
    }

    // MARK: - Key recognition

    func testRecognisesRawSMCKeys() {
        XCTAssertNotNil(SMCKeyName("Tp04"))
        XCTAssertNotNil(SMCKeyName("TG0B"))
        XCTAssertNotNil(SMCKeyName("TRD7"))
    }

    /// Every real HID name from this Mac has to fail the test, or the naming
    /// layer would stop translating it.
    func testRealSensorNamesAreNotMistakenForKeys() {
        for name in ["PMU tdie1", "PMU tcal", "gas gauge battery",
                     "NAND CH0 temp", "GPU MTR Temp Sensor1", ""] {
            XCTAssertNil(SMCKeyName(name), "\(name) was read as an SMC key")
        }
    }

    /// Fan keys and non-temperature keys are not this type's business, and a
    /// four-character string with punctuation is not a key at all.
    func testRejectsNonTemperatureShapes() {
        XCTAssertNil(SMCKeyName("F0Ac"))
        XCTAssertNil(SMCKeyName("#KEY"))
        XCTAssertNil(SMCKeyName("Tp0"))
        XCTAssertNil(SMCKeyName("Tp004"))
    }

    // MARK: - Naming

    /// The SMC gives no name, so the key is the name. Anything else would be
    /// invented.
    func testRawKeysAreLeftVerbatim() {
        XCTAssertEqual(SensorNaming.friendlyName(for: "Tp04"), "Tp04")
        XCTAssertEqual(SensorNaming.friendlyName(for: "TRD7"), "TRD7")
    }

    /// The regression this guards: `SensorNaming`'s rules match lowercased
    /// substrings, so without the key check `TANE` would come back "Neural
    /// Engine" and `TSOC` "Main chip" — confident labels for keys that carry no
    /// such claim.
    func testKeysDoNotCollideWithNamingRules() {
        for key in ["TANE", "TSOC", "TCPU", "TGPU", "TSSD", "TVRM"] {
            XCTAssertEqual(SensorNaming.friendlyName(for: key), key,
                           "\(key) was renamed by a prose rule")
        }
    }

    // MARK: - Classification

    /// Established by load tests on this Mac: `Tp` follows the processor and not
    /// the GPU, `Tg` follows the GPU.
    func testMeasuredFamiliesClassifyToTheirSubsystem() {
        XCTAssertEqual(SensorCategory.classify("Tp04"), .cpu)
        XCTAssertEqual(SensorCategory.classify("Tp1g"), .cpu)
        XCTAssertEqual(SensorCategory.classify("Tg08"), .gpu)
        XCTAssertEqual(SensorCategory.classify("Tg43"), .gpu)
    }

    /// `Tm` rose under both CPU-only and GPU-only load. Two subsystems fit that
    /// and the measurement picks neither, so it must not claim one.
    func testAmbiguousFamilyIsNotClaimedForCPUOrGPU() {
        XCTAssertEqual(SensorCategory.classify("Tm04"), .soc)
        XCTAssertEqual(SensorCategory.classify("Tm2n"), .soc)
    }

    /// Case is meaning here: `TG0B` is the battery gauge, `Tg08` a GPU sensor.
    func testKeyClassificationIsCaseSensitive() {
        XCTAssertNotEqual(SensorCategory.classify("TG0B"),
                          SensorCategory.classify("Tg08"))
        XCTAssertEqual(SensorCategory.classify("TG0B"), .other)
    }

    /// Unmeasured families get no subsystem. `TPD0` reads like a plausible CPU
    /// sensor and may well be one — that is not the same as knowing.
    func testUnmeasuredFamiliesFallThroughToOther() {
        for key in ["TPD0", "TRD7", "Tz0A", "Ts0P", "TU0V"] {
            XCTAssertEqual(SensorCategory.classify(key), .other, "\(key)")
        }
    }

    /// The prose rules must still work — adding the key path cannot cost the
    /// HID hub its categories.
    func testProseNamesStillClassifyAsBefore() {
        XCTAssertEqual(SensorCategory.classify("PMU tdie1"), .soc)
        XCTAssertEqual(SensorCategory.classify("gas gauge battery"), .battery)
        XCTAssertEqual(SensorCategory.classify("NAND CH0 temp"), .storage)
    }

    // MARK: - Merge

    /// The one measured overlap: `TG0B` comes back through both paths reading
    /// the same value, and must appear once.
    func testDuplicateKeysAreKeptOnce() {
        let merged = TemperatureSources.merge(
            hid: [reading("gas gauge battery", 33.3, key: "TG0B")],
            smc: [reading("TG0B", 33.3)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "gas gauge battery",
                       "the named reading should win, not the bare key")
    }

    /// The HID `TP1b` and the SMC `TPD0` are different sensors. Nothing about
    /// the shared `T` prefix may merge them.
    func testDistinctKeysAreBothKept() {
        let merged = TemperatureSources.merge(
            hid: [reading("PMU tdie1", 61.3, key: "TP1b")],
            smc: [reading("TPD0", 80.0)])
        XCTAssertEqual(Set(merged.map(\.smcKey)), ["TP1b", "TPD0"])
    }

    /// De-duplication compares keys exactly. Folding case would drop a real GPU
    /// sensor because a battery gauge happened to share its spelling.
    func testMergeDoesNotFoldCase() {
        let merged = TemperatureSources.merge(
            hid: [reading("gas gauge battery", 33.3, key: "TG0B")],
            smc: [reading("Tg0b", 64.9)])
        XCTAssertEqual(merged.count, 2)
    }

    /// A reading with no key cannot be shown to duplicate anything, so it stays.
    func testKeylessSMCReadingsSurvive() {
        let keyless = TemperatureSensors.Reading(name: "Tp04", celsius: 75, smcKey: "")
        let merged = TemperatureSources.merge(
            hid: [reading("gas gauge battery", 33.3, key: "TG0B")],
            smc: [keyless])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeOrderIsStableAcrossCallOrder() {
        let hid = [reading("PMU tdie2", 58.8, key: "TP2b"),
                   reading("PMU tdie10", 59.4, key: "TPab")]
        let smc = [reading("Tg08", 64.8), reading("Tp04", 75.2)]
        XCTAssertEqual(TemperatureSources.merge(hid: hid, smc: smc).map(\.smcKey),
                       TemperatureSources.merge(hid: hid.reversed(),
                                                smc: smc.reversed()).map(\.smcKey))
    }

    /// `tdie2` must sort before `tdie10`, as it already does for the HID source
    /// alone — the merge re-sorts, so it has to preserve that.
    func testMergeSortsDigitsNumerically() {
        let merged = TemperatureSources.merge(
            hid: [reading("PMU tdie10", 59.4, key: "TPab"),
                  reading("PMU tdie2", 58.8, key: "TP2b")],
            smc: [])
        XCTAssertEqual(merged.map(\.name), ["PMU tdie2", "PMU tdie10"])
    }

    // MARK: - What may drive a fan

    /// The reason the whitelist exists. `TR0Z` held 51.82 °C through a 32 °C
    /// swing; on a cool machine that is above every real reading, so letting it
    /// into the curve input would pin the fans to a constant.
    func testConstantKeyCannotDriveTheCurve() {
        let input = TemperatureSources.attributed([reading("TR0Z", 51.82),
                                                   reading("Tp00", 45.0)])
        XCTAssertEqual(input.map(\.name), ["Tp00"])
    }

    /// Measured constants that are plainly not temperatures at all, and would
    /// otherwise pass the plausibility window: `TVMX`/`TVmS`/`TVms` sit at
    /// exactly 61.00, and nine `Tz1*` keys read 0.00.
    func testNonSensorKeysCannotDriveTheCurve() {
        let readings = [reading("TVMX", 61.0), reading("TVms", 61.0),
                        reading("Tz11", 0.0), reading("TVMD", 4.0)]
        XCTAssertTrue(TemperatureSources.attributed(readings).isEmpty)
    }

    /// The two families load testing established. These are what the SMC
    /// contributes to the curve, and all it contributes.
    func testMeasuredFamiliesMayDriveTheCurve() {
        let input = TemperatureSources.attributed([reading("Tp04", 88.0),
                                                   reading("Tg08", 79.0)])
        XCTAssertEqual(Set(input.map(\.name)), ["Tp04", "Tg08"])
    }

    /// `Tm` rose under both CPU-only and GPU-only load. Unsettled, so it informs
    /// the display but does not move a fan.
    func testUnsettledFamilyIsShownButNotTrusted() {
        XCTAssertEqual(SensorCategory.classify("Tm04"), .soc)
        XCTAssertTrue(TemperatureSources.attributed([reading("Tm04", 91.0)]).isEmpty)
    }

    /// Named sensors keep the rule they have always had: everything but a
    /// calibration reference, whatever its temperature.
    func testNamedSensorsKeepTheExistingRule() {
        let input = TemperatureSources.attributed([
            reading("PMU tdie1", 73.5, key: "TP1b"),
            reading("PMU tcal", 51.8, key: "TP0Z"),
            reading("gas gauge battery", 33.9, key: "TG0B"),
        ])
        XCTAssertEqual(input.map(\.name), ["PMU tdie1", "gas gauge battery"])
    }

    /// With no SMC readings present the curve input is exactly what the HID
    /// source alone would have produced — adding the source must not change the
    /// fan behaviour of anyone who has not opted in.
    func testHIDOnlyInputIsUnchanged() {
        let hidOnly = [reading("PMU tdie1", 73.5, key: "TP1b"),
                       reading("PMU tcal", 51.8, key: "TP0Z"),
                       reading("NAND CH0 temp", 36.0, key: "TN0n")]
        XCTAssertEqual(TemperatureSources.attributed(hidOnly).map(\.celsius).max(),
                       hidOnly.lazy.filter { !$0.isReference }.map(\.celsius).max())
    }

    /// The battery finding that killed the flatness heuristic, kept as a
    /// regression: nine battery sensors held a span of exactly 0.00 °C across the
    /// same 32 °C swing that `TR0Z` sat through. They are real sensors, merely
    /// decoupled from the SoC, and nothing may exclude them for being still.
    func testFlatnessIsNotTreatedAsEvidence() {
        let battery = reading("gas gauge battery", 33.9, key: "TG0B")
        XCTAssertFalse(battery.isReference)
        XCTAssertEqual(TemperatureSources.attributed([battery]).count, 1)
    }

    // MARK: - Reference flagging

    /// The name rule is unchanged, and stays the only thing that marks a
    /// reference.
    func testReferencesAreRecognisedByName() {
        XCTAssertTrue(TemperatureSensors.Reading(name: "PMU tcal", celsius: 51.8).isReference)
        XCTAssertFalse(TemperatureSensors.Reading(name: "PMU tdie1", celsius: 61.3).isReference)
        XCTAssertFalse(TemperatureSensors.Reading(name: "TR0Z", celsius: 51.8).isReference,
                       "a bare key carries no such claim — the whitelist handles it")
    }

    // MARK: - Plausibility

    /// `TTPD` is a `flt ` key on this Mac reading −306783232 °C.
    func testImplausibleReadingsAreRejected() {
        XCTAssertFalse(PlausibleTemperature.admits(-306_783_232))
        XCTAssertFalse(PlausibleTemperature.admits(.nan))
        XCTAssertFalse(PlausibleTemperature.admits(.infinity))
        XCTAssertTrue(PlausibleTemperature.admits(102.07))
        XCTAssertTrue(PlausibleTemperature.admits(24.0))
    }
}
