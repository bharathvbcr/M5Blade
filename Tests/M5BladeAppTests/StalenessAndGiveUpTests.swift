import XCTest
import FanKit
import ProfileKit
import SensorKit
import SimSupport
@testable import M5BladeApp

/// Two defects found by audit, both about the control path telling the truth.
///
/// 1. A sensor layer that dies mid-run left every fan curve evaluating a
///    permanently frozen temperature while `ControlLoop`'s stale-data release —
///    its whole reason for existing — sat unreachable: the loop only releases on
///    samples that *arrive* nil, and a failed read never nilled anything after
///    the first success. The fans were driven from ice while the popover said
///    "Controlling" over normal-looking numbers.
///
/// 2. Three refused writes in a row put the app in "Helper not running" and
///    offered the reinstall sheet — even when the give-up path's own release had
///    just succeeded, proving the helper alive and answering.
@MainActor
final class StalenessAndGiveUpTests: XCTestCase {

    private var directory: URL!
    private var daemon: SimulatedDaemon!
    private var model: AppModel!
    private var temps: ScriptedTemperatureSource!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StalenessAndGiveUpTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        daemon = SimulatedDaemon()
        temps = ScriptedTemperatureSource(readings: Fixture.temperatures(4))
        model = AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("config.json")),
                         historyURL: directory.appendingPathComponent("history.sqlite"),
                         defaults: InMemoryDefaults.acknowledgingControlRisk(),
                         daemon: daemon,
                         sources: temps)
    }

    override func tearDownWithError() throws {
        model = nil
        daemon = nil
        temps = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// The sensor layer stops reporting mid-control. Past the staleness limit
    /// the loop must treat its input as missing and hand the fans back, exactly
    /// as it does when no sensor has ever reported.
    func testTemperaturesThatStopArrivingReleaseTheFans() async throws {
        let fans = Fixture.fans(2)
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(4))
        await model.enableControl()
        XCTAssertEqual(model.status, .controlling, "the fixture must be driving")

        // The HID hub goes away (sleep/wake does this). readAll() now returns
        // nothing; the displayed array stays standing but ages out.
        await temps.setReadings([])
        model.applyForTesting(temperaturesUpdatedAt: Date().addingTimeInterval(-11))

        await model.tickForTesting()

        XCTAssertEqual(model.status, .watching,
                       "control kept driving fans from a frozen temperature")
        XCTAssertTrue(daemon.armed.isEmpty,
                      "fans stayed armed with no live input driving them: \(daemon.log)")
        XCTAssertNil(model.controlProblem)
    }

    /// Fresh readings keep control alive across ticks — the guard must not
    /// release a healthy machine.
    func testFreshTemperaturesKeepControlEngaged() async {
        let fans = Fixture.fans(2)
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(4))
        await model.enableControl()

        await temps.setReadings(Fixture.temperatures(4))
        model.applyForTesting(temperaturesUpdatedAt: Date())
        await model.tickForTesting()

        XCTAssertEqual(model.status, .controlling)
        XCTAssertEqual(daemon.armed, [0, 1])
    }

    /// A helper that answers — the give-up release succeeded — must not be
    /// announced as "not running". The honest story is "control kept failing,
    /// so the fans were handed back"; the reinstall sheet is for an absent
    /// helper, and sending a user there for a live daemon teaches them to
    /// ignore the banner.
    func testAGiveUpWithALivingHelperDoesNotClaimItIsNotRunning() async {
        let fans = Fixture.fans(2)
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(4))
        await model.enableControl()
        XCTAssertEqual(model.status, .controlling)

        // The helper lives but refuses every target — a wedged mode key is the
        // documented real-world shape of this.
        daemon.faults.refuseTarget = true
        for _ in 0..<AppModel.maxControlFailures {
            await model.tickForTesting()
        }

        XCTAssertEqual(model.status, .watching,
                       "a confirmed handover must not render as 'helper unavailable'")
        XCTAssertTrue(daemon.armed.isEmpty)
        XCTAssertNil(model.controlProblem)
    }
}

/// Scripts what the sensor layer reports, tick by tick. An actor to match the
/// real reader's isolation.
actor ScriptedTemperatureSource: TemperatureReadingSource {
    private var current: [TemperatureSensors.Reading]

    init(readings: [TemperatureSensors.Reading]) {
        self.current = readings
    }

    func setReadings(_ newReadings: [TemperatureSensors.Reading]) {
        current = newReadings
    }

    func readAll() -> [TemperatureSensors.Reading] { current }

    func setIncludeSMC(_ enabled: Bool) {}
}
