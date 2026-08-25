import XCTest
@testable import SensorKit

/// Measured kernel behaviour this pins (see ISSUES.md H-2): every
/// `mach_host_self()` call mints one more send-right *reference* on the same
/// host-port name. Unbounded, it climbs to the kernel's per-name ceiling of
/// 65_535 references — about nine hours of 1 Hz polling — where it pins.
/// The fix caches one right for the life of the process; this asserts polls
/// move that counter by exactly zero.
final class MachPortStressTests: XCTestCase {

    func testRepeatedPollsMintNoNewHostPortReferences() throws {
        let probe = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, probe) }

        func urefs() -> mach_port_urefs_t {
            var refs: mach_port_urefs_t = 0
            let kr = mach_port_get_refs(mach_task_self_, probe,
                                        MACH_PORT_RIGHT_SEND, &refs)
            return kr == KERN_SUCCESS ? refs : .max
        }

        let metrics = SystemMetrics()
        // Warm the cache exactly as the running app has by the second tick.
        _ = metrics.memoryUsage()
        _ = metrics.cpuUsage()

        let before = urefs()
        for _ in 0..<400 {           // 400 polls ≈ 3½ min of controlling cadence
            _ = metrics.memoryUsage()
            _ = metrics.cpuUsage()
        }
        let after = urefs()

        XCTAssertEqual(after, before,
                       "\(after - before) send-right references leaked across 800 polls")
    }
}
