import XCTest
@testable import M5BladeApp

/// The watt readout format. "%.0f" rounded every idle reading below half a
/// watt down to "0W" — indistinguishable from the fabricated zero a dead
/// counter produces, and read by users as "power measurement is broken".
/// These pin the replacement: one decimal while idle-scale, none above it,
/// and absence rendered as absence.
final class PowerTextTests: XCTestCase {

    func testIdleReadingsKeepOneDecimal() {
        XCTAssertEqual(PowerText.watts(0.44), "0.4W")
        XCTAssertEqual(PowerText.watts(0.47), "0.5W")
        XCTAssertEqual(PowerText.watts(3.25), "3.2W")   // printf rounds to even
        XCTAssertEqual(PowerText.watts(9.96), "10.0W")
    }

    func testLoadReadingsDropTheDecimal() {
        XCTAssertEqual(PowerText.watts(12.34), "12W")
        XCTAssertEqual(PowerText.watts(120.0), "120W")
    }

    func testExactZeroIsStillRenderedAsZeroWhenTheReaderSentIt() {
        // The reader never sends 0 for a dead counter any more — nil means
        // "no data" — but if a true zero ever arrives it renders honestly as
        // a small number, not as absence.
        XCTAssertEqual(PowerText.watts(0.0), "0.0W")
    }

    func testAbsenceStaysAbsent() {
        XCTAssertEqual(PowerText.watts(nil), "—")
        XCTAssertEqual(PowerText.watts(.nan), "—")
        XCTAssertEqual(PowerText.watts(.infinity), "—")
        XCTAssertEqual(PowerText.watts(-3), "—")
    }
}
