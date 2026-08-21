import XCTest
@testable import SensorKit

/// What the memory readout means, and why it used to disagree with Activity
/// Monitor by gigabytes.
///
/// Measured on this Mac before the fix: 35.80 GB reported against Activity
/// Monitor's 41.45 GB. Two independent errors, both of which had to go:
///
///  1. `used` was `active + wired + compressed`. `active_count` counts *file-backed*
///     pages as well as anonymous ones, so it charged the disk cache to the user
///     while leaving out the inactive anonymous pages that are genuinely spoken
///     for. The size and even the sign of the error depend on how warm the cache
///     is, which is why it looked like drift rather than a formula bug.
///  2. The total was rendered by dividing bytes by 1e9. `physicalMemory` here is
///     68,719,476,736 — exactly 64 GiB, and exactly what Activity Monitor and
///     "About This Mac" both call 64 GB. Dividing by 1e9 renders it as 69 GB.
///
/// The arithmetic is tested against a fabricated kernel sample so it does not
/// depend on how much memory this machine happens to be using; the live section
/// then checks the real reading is self-consistent.
final class SystemMetricsTests: XCTestCase {

    private let pageSize: UInt64 = 16_384
    private let sixtyFourGiB: UInt64 = 68_719_476_736

    /// A kernel sample shaped like the one measured on this Mac: plenty of
    /// inactive anonymous memory, and a large file cache. Those are what make the
    /// two formulas disagree, so a fixture without them would pass either way.
    private func sample() -> vm_statistics64 {
        var stats = vm_statistics64()
        stats.internal_page_count = 2_000_000     // anonymous
        stats.external_page_count = 1_300_000     // file-backed
        stats.purgeable_count = 100_000
        stats.active_count = 1_600_000            // what the old formula read
        stats.inactive_count = 1_700_000
        stats.speculative_count = 10_000
        stats.wire_count = 400_000
        stats.compressor_page_count = 20_000
        stats.free_count = 200_000
        return stats
    }

    private func usage() -> MemoryUsage {
        MemoryUsage(vmStatistics: sample(), pageSize: pageSize, physicalMemory: sixtyFourGiB)
    }

    // MARK: - The decomposition

    func testAppMemoryIsAnonymousPagesLessPurgeable() {
        XCTAssertEqual(usage().app, 1_900_000 * pageSize)
    }

    func testCachedFilesIsFileBackedPlusPurgeable() {
        XCTAssertEqual(usage().cachedFiles, 1_400_000 * pageSize)
    }

    /// Speculative read-ahead holds file data, so it is cache rather than free.
    /// Activity Monitor's "unused" excludes it for the same reason.
    func testFreeExcludesSpeculativeReadAhead() {
        XCTAssertEqual(usage().free, 190_000 * pageSize)
    }

    func testUsedIsAppPlusWiredPlusCompressed() {
        XCTAssertEqual(usage().used, (1_900_000 + 400_000 + 20_000) * pageSize)
    }

    /// The regression, stated as the difference it makes.
    ///
    /// The old formula is computed here rather than described, so this fails if
    /// anyone reintroduces it — and the magnitude is the point: 4.9 GB on this
    /// fixture, 5.65 GB measured on the real machine.
    func testUsedIsNotTheOldActivePageFormula() {
        let old = (UInt64(sample().active_count)
                   + UInt64(sample().wire_count)
                   + UInt64(sample().compressor_page_count)) * pageSize
        XCTAssertNotEqual(usage().used, old)
        XCTAssertEqual(usage().used - old, 300_000 * pageSize,
                       "the old formula under-reported by the inactive anonymous pages")
    }

    /// Every category together must account for the machine's pageable memory.
    /// A decomposition whose parts do not add up is one where a category has been
    /// double-counted or dropped.
    func testTheCategoriesReconstructTheMachine() {
        let u = usage()
        let accounted = Double(u.used + u.cachedFiles + u.free)
        XCTAssertEqual(accounted / Double(u.total), 1, accuracy: 0.15)
    }

    // MARK: - Values the kernel should never report, and must not break on

    /// `purgeable_count` above `internal_page_count` is not meaningful, but it is
    /// representable — and on unsigned page counts `0 - 1` is how a memory
    /// readout comes to claim 18,446,744 TB.
    func testMorePurgeableThanAnonymousDoesNotUnderflow() {
        var stats = sample()
        stats.purgeable_count = stats.internal_page_count + 1
        let usage = MemoryUsage(vmStatistics: stats, pageSize: pageSize, physicalMemory: sixtyFourGiB)
        XCTAssertEqual(usage.app, 0)
        XCTAssertLessThanOrEqual(usage.used, usage.total)
    }

    func testMoreSpeculativeThanFreeDoesNotUnderflow() {
        var stats = sample()
        stats.speculative_count = stats.free_count + 1
        let usage = MemoryUsage(vmStatistics: stats, pageSize: pageSize, physicalMemory: sixtyFourGiB)
        XCTAssertEqual(usage.free, 0)
    }

    func testAnEmptySampleIsAllZeroRatherThanNonsense() {
        let usage = MemoryUsage(vmStatistics: vm_statistics64(), pageSize: pageSize,
                                physicalMemory: sixtyFourGiB)
        XCTAssertEqual(usage.used, 0)
        XCTAssertEqual(usage.pressure, 0)
    }

    func testPressureIsBoundedEvenIfTheSampleExceedsPhysicalMemory() {
        let usage = MemoryUsage(vmStatistics: sample(), pageSize: pageSize, physicalMemory: 1)
        XCTAssertEqual(usage.pressure, 1, "a ratio presented as a fraction must not exceed one")
    }

    // MARK: - Units

    /// The other half of the discrepancy. 64 GiB is what the machine calls 64 GB.
    func testMemoryIsFormattedTheWayMacOSFormatsIt() {
        XCTAssertEqual(MemoryFormat.gibibytes(sixtyFourGiB), 64, accuracy: 0.001)
        XCTAssertNotEqual(Double(sixtyFourGiB) / 1e9, 64, accuracy: 0.5,
                          "1e9 is the storage convention and would render 64 GiB as 69 GB")
    }

    // MARK: - Live

    /// Whatever this machine is doing, the reading has to be self-consistent.
    func testTheLiveReadingIsCoherent() throws {
        let usage = try XCTUnwrap(SystemMetrics().memoryUsage(),
                                  "host_statistics64 failed on a machine that is running")
        XCTAssertGreaterThan(usage.total, 0)
        XCTAssertGreaterThan(usage.used, 0)
        XCTAssertLessThanOrEqual(usage.used, usage.total,
                                 "more memory is in use than the machine has")
        XCTAssertGreaterThanOrEqual(usage.pressure, 0)
        XCTAssertLessThanOrEqual(usage.pressure, 1)
        let accounted = Double(usage.used + usage.cachedFiles + usage.free)
        XCTAssertEqual(accounted / Double(usage.total), 1, accuracy: 0.2,
                       "the live categories do not add up to the machine")
    }

    func testPageSizeIsTheRealOne() {
        // 16 KiB on Apple Silicon. Hardcoding 4096 is the classic porting bug
        // (AUDIT A-5), and every page count above would be four times wrong.
        XCTAssertEqual(SystemMetrics.pageSize, 16_384)
    }

    // MARK: - CPU

    /// The first call has nothing to difference against and must say so rather
    /// than reporting an idle machine. `AppModel` holds its previous value on nil
    /// for exactly this reason — a fabricated 0% is not "unknown".
    func testTheFirstCPUSampleIsUnknownRatherThanZero() {
        XCTAssertNil(SystemMetrics().cpuUsage())
    }

    func testCPUPercentagesAreAWholeMachine() throws {
        let metrics = SystemMetrics()
        _ = metrics.cpuUsage()
        // Long enough for the scheduler to accumulate ticks on some core.
        Thread.sleep(forTimeInterval: 0.25)
        let usage = try XCTUnwrap(metrics.cpuUsage())

        XCTAssertEqual(usage.user + usage.system + usage.idle + usage.nice, 100, accuracy: 0.01,
                       "the four CPU states must partition the interval")
        XCTAssertGreaterThanOrEqual(usage.total, 0)
        XCTAssertLessThanOrEqual(usage.total, 100)
        XCTAssertFalse(usage.perCore.isEmpty)
        for core in usage.perCore {
            XCTAssertGreaterThanOrEqual(core, 0)
            XCTAssertLessThanOrEqual(core, 100)
        }
    }
}
