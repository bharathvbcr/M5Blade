import XCTest
import SwiftUI
import ProfileKit
import SensorKit
import SimSupport
@testable import M5BladeApp

/// The panel's availability readout: what the machine can still absorb — memory
/// it can hand out without evicting an app, disk it can write before the volume
/// is full — sampled by the production tick and drawn in the system row.
@MainActor
final class AvailabilityReadoutTests: XCTestCase {

    private var directory: URL!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvailabilityReadoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Wired through the real tick path, not around it: one sample on a machine
    /// that is running must populate both host readouts coherently.
    func testATickSamplesMemoryAndDiskAvailability() async {
        model = AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("config.json")),
                         historyURL: directory.appendingPathComponent("history.sqlite"),
                         defaults: InMemoryDefaults(),
                         daemon: SimulatedDaemon(),
                         sources: ScriptedTemperatureSource(readings: []))
        await model.tickForTesting()

        XCTAssertNotNil(model.memory, "the tick ran but produced no memory sample")
        XCTAssertNotNil(model.availableDiskBytes, "the tick ran but produced no disk sample")
        if let bytes = model.availableDiskBytes {
            XCTAssertGreaterThan(bytes, 0, "a mounted startup volume has positive capacity")
        }
        // Available shares `used`'s basis, so the paired readout cannot disagree.
        if let memory = model.memory {
            XCTAssertLessThanOrEqual(memory.used, memory.total)
            XCTAssertEqual(memory.available, memory.total - memory.used)
        }
    }

    private var popoverSize: CGSize { CGSize(width: 340, height: 520) }

    private func popover() -> some View {
        PopoverView(model: model, onOpenSettings: {}, onOpenDashboard: {})
    }

    func testPopoverDrawsTheAvailabilityRow() {
        model = Fixture.model(directory: directory)
        model.applyForTesting(cpuPercent: 34,
                              memory: MemoryUsage(total: 68_719_476_736, app: 30_000_000_000,
                                                  wired: 6_000_000_000, compressed: 2_000_000_000,
                                                  cachedFiles: 18_000_000_000, free: 12_719_476_736),
                              availableDiskBytes: 182_000_000_000)
        XCTAssertEqual(model.memory?.available, 12_719_476_736 + 18_000_000_000,
                       "the fixture must exercise the complement, not a coincidence")
        RenderHarness.assertDraws(popover(), "popover with availability row", size: popoverSize)
    }

    /// Each half draws alone when the other sample has not arrived yet, and a
    /// nearly-full volume renders its long figure without breaking the row.
    func testPopoverWithOneSidedAndAbsurdAvailability() {
        model = Fixture.model(directory: directory)
        model.applyForTesting(availableDiskBytes: 99_999_999_999_999)
        RenderHarness.assertDraws(popover(), "disk-only availability", size: popoverSize)

        model = Fixture.model(directory: directory)
        model.applyForTesting(memory: MemoryUsage(total: 1, app: 0, wired: 0,
                                                  compressed: 0, cachedFiles: 0, free: 1))
        RenderHarness.assertDraws(popover(), "memory-only availability", size: popoverSize)
    }
}
