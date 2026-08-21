import XCTest
import FanKit
@testable import SensorKit

/// The one test here that touches real hardware.
///
/// Everything else about the SMC source is pure logic tested against recorded
/// traces, which is the right default — but "the toggle actually changes what
/// gets read" cannot be shown that way, and it is the whole point of the
/// setting. This skips rather than fails where there is no SMC to talk to, so a
/// VM or a CI box reports honestly instead of red.
final class TemperatureSourcesLiveTests: XCTestCase {

    /// Flipping the source on mid-run must add sensors, and flipping it off must
    /// put the set back exactly as it was.
    func testToggleChangesWhatIsReadAtRuntime() async throws {
        let sources = TemperatureSources(includeSMC: false)

        let hidOnly = await sources.readAll()
        try XCTSkipIf(hidOnly.isEmpty, "no HID sensors on this machine")

        await sources.setIncludeSMC(true)
        let both = await sources.readAll()
        try XCTSkipIf(both.count == hidOnly.count, "no SMC temperature keys on this machine")

        XCTAssertGreaterThan(both.count, hidOnly.count)

        // Everything the HID source reported is still there. The SMC must add to
        // the set, never displace part of it — the de-duplication rule keeps the
        // named reading, so no key may go missing or change its name.
        let hidKeys = Set(hidOnly.map(\.id))
        XCTAssertTrue(hidKeys.isSubset(of: Set(both.map(\.id))),
                      "turning the SMC on dropped a HID sensor")
        for reading in hidOnly {
            XCTAssertTrue(both.contains { $0.id == reading.id && $0.name == reading.name },
                          "\(reading.name) was renamed by the merge")
        }

        // Everything new is a bare SMC key, and every one of them is unique.
        let added = both.filter { !hidKeys.contains($0.id) }
        for reading in added {
            XCTAssertNotNil(SMCKeyName(reading.name),
                            "\(reading.name) is not a raw SMC key")
        }
        XCTAssertEqual(Set(both.map(\.id)).count, both.count, "the merge produced a duplicate id")

        await sources.setIncludeSMC(false)
        let restored = Set(await sources.readAll().map(\.id))
        XCTAssertEqual(restored, hidKeys,
                       "turning it back off did not restore the original set")
    }

    /// The safety property, on real readings: nothing the app cannot attribute
    /// may set the number a fan curve reads.
    func testCurveInputOnRealHardwareIsAllAttributable() async throws {
        let sources = TemperatureSources(includeSMC: true)
        let readings = await sources.readAll()
        try XCTSkipIf(readings.isEmpty, "no sensors on this machine")

        for reading in TemperatureSources.attributed(readings) {
            XCTAssertFalse(reading.isReference, "\(reading.name) is a calibration reference")
            if let key = SMCKeyName(reading.name) {
                XCTAssertTrue(TemperatureSources.eligibleFamilies.contains(key.family),
                              "\(reading.name) reached the curve input unattributed")
            }
        }

        // And the value itself is usable: finite, and inside the window both
        // sources filter on.
        if let max = await sources.maxTemperature() {
            XCTAssertTrue(PlausibleTemperature.admits(max), "curve input was \(max)")
        }
    }
}
