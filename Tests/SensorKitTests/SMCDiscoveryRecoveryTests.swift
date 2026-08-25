import XCTest
import FanKit
import SMCKit
@testable import SensorKit

/// A transient first-poll failure used to be cached as an empty catalogue
/// forever: one refused `open()` silenced the whole SMC temperature source
/// until relaunch. These pin the replacement contract — failures are retried
/// on a cooldown, successes latch, and a genuine "no keys" answer latches too.
final class SMCDiscoveryRecoveryTests: XCTestCase {

    private actor ScriptedSMC: SMCTemperatureSensors.SMCKeySpace {
        struct Fault: Error {}
        var failOpens: Bool
        var keys: [SMCKey]
        private(set) var openAttempts = 0

        init(failOpens: Bool, keys: [SMCKey] = [SMCKey("Tp01")]) {
            self.failOpens = failOpens
            self.keys = keys
        }

        func setFailOpens(_ value: Bool) { failOpens = value }
        func setKeys(_ newKeys: [SMCKey]) { keys = newKeys }

        func open() throws {
            openAttempts += 1
            if failOpens { throw Fault() }
        }
        func close() {}
        func allKeys() throws -> [SMCKey] { keys }

        func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
            SMCKeyInfo(dataSize: 4, dataType: SMCDataType.flt.rawValue, attributes: 0x80)
        }

        func read(_ key: SMCKey) throws -> SMCValue {
            let info = try keyInfo(key)
            var bytes = [UInt8](repeating: 0, count: 4)
            withUnsafeBytes(of: Float(45.5).bitPattern.littleEndian) { bytes = [UInt8]($0) }
            return SMCValue(key: key, info: info, bytes: bytes)
        }
    }

    /// The regression: after the connection recovers, the very next poll must
    /// see real readings. Pre-fix this never happened — the empty catalogue
    /// was latched on the first failure.
    func testATransientFailureDoesNotLatchAnEmptyCatalogue() async {
        let smc = ScriptedSMC(failOpens: true)
        let source = SMCTemperatureSensors(connection: smc)

        let during = await source.readAll()
        XCTAssertTrue(during.isEmpty, "a failed open must degrade to no readings")

        await smc.setFailOpens(false)
        // Inside the retry cooldown the source stays quiet rather than
        // hammering a service that just refused it…
        let suppressed = await source.readAll()
        XCTAssertTrue(suppressed.isEmpty)
        // …and past it, discovery runs again and succeeds.
        await source.expireDiscoveryCooldownForTesting()
        let recovered = await source.readAll()
        XCTAssertEqual(recovered.map(\.name), ["Tp01"])
        XCTAssertEqual(recovered.first?.celsius ?? 0, 45.5, accuracy: 0.01)
    }

    /// A successful discovery that genuinely finds no temperature keys is an
    /// answer, not a failure — it must latch so a machine without SMC temps
    /// does not re-enumerate every poll.
    func testAGenuineNoKeysAnswerLatchesWithoutRetrying() async {
        let smc = ScriptedSMC(failOpens: false)
        await smc.setKeys([])
        let source = SMCTemperatureSensors(connection: smc)

        for _ in 0..<3 { _ = await source.readAll() }
        let attempts = await smc.openAttempts
        XCTAssertEqual(attempts, 1, "an answered discovery is final")
    }
}
