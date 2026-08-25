import Foundation
#if canImport(Darwin)
import Darwin

public struct CPUUsage: Sendable, Equatable {
    public var user: Double
    public var system: Double
    public var idle: Double
    public var nice: Double
    public var perCore: [Double]

    public var total: Double { user + system + nice }
}

/// Memory decomposed the way Activity Monitor decomposes it.
///
/// The categories are not interchangeable and picking the wrong one is not a
/// rounding error. `active_count` — what this used to report as "used" — counts
/// *file-backed* pages alongside anonymous ones, so it charges the disk cache to
/// the user while omitting the inactive anonymous pages that are genuinely spoken
/// for. Measured on a 64 GiB M5 Pro: 35.80 GB against Activity Monitor's 41.45 GB,
/// a 5.65 GB under-report, and it moves in either direction depending on how much
/// of the cache is warm.
///
/// Activity Monitor's decomposition, which this now mirrors exactly:
///
///     Memory Used  = App Memory + Wired + Compressed
///     App Memory   = internal_page_count - purgeable_count
///     Cached Files = external_page_count + purgeable_count
///
/// `app + wired + compressed + cachedFiles + free` reconstructs the machine's
/// pageable memory, which is the invariant `MemoryDecompositionTests` asserts.
public struct MemoryUsage: Sendable, Equatable {
    public var total: UInt64
    /// Anonymous, non-purgeable pages: Activity Monitor's "App Memory".
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File-backed and purgeable pages: Activity Monitor's "Cached Files". The
    /// kernel reclaims these on demand, which is why they are not `used` — but
    /// they are not `free` either, so they are reported rather than hidden.
    public var cachedFiles: UInt64
    /// Genuinely unallocated, with speculative read-ahead excluded — those pages
    /// hold file data and are counted in `cachedFiles`.
    public var free: UInt64

    public init(total: UInt64, app: UInt64, wired: UInt64,
                compressed: UInt64, cachedFiles: UInt64, free: UInt64) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.free = free
    }

    public var used: UInt64 { app + wired + compressed }

    /// The fraction of physical memory that is spoken for. Reads the same basis
    /// as `used`, so the number beside the bar and the bar cannot disagree.
    ///
    /// Not the kernel's `memorystatus` pressure *level* — that is a three-valued
    /// signal (normal/warn/critical) and this is a ratio. `ThermalPressure` is
    /// the app's control input; this is a readout.
    public var pressure: Double {
        total == 0 ? 0 : min(1, Double(used) / Double(total))
    }

    /// What the machine can still absorb without evicting an application:
    /// everything not counted as `used`, computed as `total - used` so a
    /// readout pairing the two cannot disagree. Free pages and cached files are
    /// the bulk of it; the remainder is memory no category accounts for.
    ///
    /// Deliberately not called "free": `free` alone excludes the file cache,
    /// and charging that cache to the user is the exact mis-report this
    /// decomposition exists to correct (ISSUES I-1). Saturates like every other
    /// subtraction in this file — a fabricated sample where `used` exceeds
    /// `total` must not underflow into an exabyte readout.
    public var available: UInt64 {
        total > used ? total - used : 0
    }
}

extension MemoryUsage {
    /// Builds the decomposition from a raw kernel sample.
    ///
    /// Separated from the `host_statistics64` call so the arithmetic is a pure
    /// function of a struct a test can fabricate — including the shapes the
    /// kernel should never produce but that must not be allowed to underflow a
    /// `UInt64` into a 16-exabyte reading. Every subtraction here saturates for
    /// that reason: `purgeable_count` exceeding `internal_page_count` is not
    /// meaningful, but it is representable, and `0 &- 1` on an unsigned page
    /// count is how a memory readout comes to say 18,446,744 TB.
    public init(vmStatistics stats: vm_statistics64, pageSize: UInt64, physicalMemory: UInt64) {
        func bytes(_ pages: UInt64) -> UInt64 {
            pages.multipliedReportingOverflow(by: pageSize).partialValue
        }
        func saturatingDifference(_ a: UInt32, _ b: UInt32) -> UInt64 {
            UInt64(a > b ? a - b : 0)
        }

        let purgeable = UInt64(stats.purgeable_count)
        self.init(
            total: physicalMemory,
            app: bytes(saturatingDifference(stats.internal_page_count, stats.purgeable_count)),
            wired: bytes(UInt64(stats.wire_count)),
            compressed: bytes(UInt64(stats.compressor_page_count)),
            cachedFiles: bytes(UInt64(stats.external_page_count) + purgeable),
            // `free_count` includes speculative read-ahead, which holds file data
            // and is already counted in `cachedFiles` — Activity Monitor's
            // "unused" excludes it for the same reason.
            free: bytes(saturatingDifference(stats.free_count, stats.speculative_count)))
    }
}

/// Bytes as macOS itself renders memory: 1024-based, labelled "GB".
///
/// The second half of the same bug. `physicalMemory` on this Mac is
/// 68,719,476,736 bytes — exactly 64 GiB, and exactly what "About This Mac" and
/// Activity Monitor both call 64 GB. Dividing by 1e9 renders that as 69 GB, so
/// even a perfectly correct `used` was being compared against a total that
/// disagreed with every other reading on the machine.
///
/// Storage is the opposite convention (1e9) and deliberately not this function's
/// business — it exists so there is one place that knows which is which.
public enum MemoryFormat {
    public static let bytesPerGiB: Double = Double(1 << 30)

    public static func gibibytes(_ bytes: UInt64) -> Double {
        Double(bytes) / bytesPerGiB
    }
}

/// Bytes as Finder renders storage: 1e9-based, labelled "GB".
///
/// The convention `MemoryFormat` deliberately does not own — its comment names
/// storage as the opposite convention and points here, so each convention keeps
/// exactly one place that knows which is which.
public enum StorageFormat {
    public static let bytesPerGB: Double = 1e9

    public static func gigabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / bytesPerGB
    }
}

/// Host-level CPU and memory.
///
/// Two Apple Silicon traps handled here (AUDIT A-5):
///   * page size is 16384, not 4096 — never hardcode it
///   * mach_absolute_time is not nanoseconds — apply the timebase ratio
public final class SystemMetrics: @unchecked Sendable {
    private var previousTicks: [[UInt32]] = []
    private let lock = NSLock()

    public init() {}

    /// Queried once; correct on both architectures.
    public static let pageSize: UInt64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.pagesize", &size, &len, nil, 0) == 0, size > 0 { return size }
        return UInt64(vm_kernel_page_size)
    }()

    public static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    // MARK: - Host port

    /// The cached host port.
    ///
    /// `mach_host_self()` returns a *new* send right on every call. Both polls
    /// used to call it inline and drop the right on the floor: at one call each
    /// per tick, a controller running for days leaked send rights without bound,
    /// and readings died once the task's port table exhausted. The host port is
    /// valid for the life of the process, so it is acquired once — through this
    /// seam, which tests replace to count acquisitions instead of leaking for
    /// real.
    internal static var hostPortFactory: () -> mach_port_t = { mach_host_self() }
    private static let hostPortLock = NSLock()
    private static var cachedHostPort: mach_port_t?

    internal static func currentHostPort() -> mach_port_t {
        hostPortLock.lock()
        defer { hostPortLock.unlock() }
        if let cached = cachedHostPort { return cached }
        let port = hostPortFactory()
        cachedHostPort = port
        return port
    }

    /// Test hook: the cache is process-wide by design, so a suite that wants to
    /// count acquisitions must be able to start from empty.
    internal static func resetCachedHostPortForTesting() {
        hostPortLock.lock()
        cachedHostPort = nil
        hostPortLock.unlock()
    }

    /// Convert Mach absolute time units to nanoseconds.
    public static func nanoseconds(fromMachTime ticks: UInt64) -> UInt64 {
        ticks * timebase.numer / max(1, timebase.denom)
    }

    public func cpuUsage() -> CPUUsage? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(Self.currentHostPort(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var current: [[UInt32]] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }

        lock.lock()
        let previous = previousTicks
        previousTicks = current
        lock.unlock()

        guard previous.count == current.count else { return nil }

        var user = 0.0, system = 0.0, idle = 0.0, nice = 0.0
        var perCore: [Double] = []

        for i in 0..<current.count {
            let du = Double(current[i][0] &- previous[i][0])
            let ds = Double(current[i][1] &- previous[i][1])
            let di = Double(current[i][2] &- previous[i][2])
            let dn = Double(current[i][3] &- previous[i][3])
            let sum = du + ds + di + dn
            guard sum > 0 else { perCore.append(0); continue }
            perCore.append((du + ds + dn) / sum * 100)
            user += du; system += ds; idle += di; nice += dn
        }

        let sum = user + system + idle + nice
        guard sum > 0 else { return nil }
        return CPUUsage(user: user / sum * 100,
                        system: system / sum * 100,
                        idle: idle / sum * 100,
                        nice: nice / sum * 100,
                        perCore: perCore)
    }

    public func memoryUsage() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size /
                                           MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.currentHostPort(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryUsage(vmStatistics: stats, pageSize: SystemMetrics.pageSize,
                           physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// Free space on a volume, as Finder reports "available": the unallocated
    /// figure plus space the system can purge on demand (caches, local
    /// snapshots). The stricter `.volumeAvailableCapacityKey` reads permanently
    /// low and would disagree with every other number the machine shows.
    ///
    /// One statfs call, so it is sampled each tick beside CPU and memory for
    /// free — and published only on change like they are.
    public func availableDiskSpace(at url: URL = URL(fileURLWithPath: "/")) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage, bytes >= 0 else {
            return nil
        }
        return UInt64(bytes)
    }

    /// Refuse to run under Rosetta — page size and SMC format selection are
    /// both unreliable when translated (AUDIT A-11).
    public static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    public static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
#endif
