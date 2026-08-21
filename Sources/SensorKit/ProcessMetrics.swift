import Foundation
#if canImport(Darwin)
import Darwin

public struct ProcessInfoSample: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public var id: Int32 { pid }
}

/// Per-process CPU and memory via libproc.
///
/// Cannot see processes owned by other users or root without elevation. That's
/// accepted: match on what's visible rather than widening the daemon's
/// interface to fill the gap.
public final class ProcessMetrics: @unchecked Sendable {
    private var previousCPU: [Int32: (ns: UInt64, at: UInt64)] = [:]
    private let lock = NSLock()

    public init() {}

    public func sample(limit: Int = 40) -> [ProcessInfoSample] {
        var pids = [Int32](repeating: 0, count: 4096)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0,
                                      &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<Int32>.size

        let now = mach_absolute_time()
        var samples: [ProcessInfoSample] = []
        var seen = Set<Int32>()

        lock.lock()
        defer { lock.unlock() }

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            seen.insert(pid)

            var info = proc_taskinfo()
            let size = MemoryLayout<proc_taskinfo>.size
            let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
            guard read == Int32(size) else { continue }

            // Mach absolute time units — must be converted (AUDIT A-5).
            let totalTicks = info.pti_total_user &+ info.pti_total_system
            let totalNS = SystemMetrics.nanoseconds(fromMachTime: totalTicks)

            var cpuPercent = 0.0
            if let previous = previousCPU[pid] {
                let elapsedNS = SystemMetrics.nanoseconds(fromMachTime: now &- previous.at)
                if elapsedNS > 0 && totalNS >= previous.ns {
                    cpuPercent = Double(totalNS - previous.ns) / Double(elapsedNS) * 100
                }
            }
            previousCPU[pid] = (totalNS, now)

            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            guard !name.isEmpty else { continue }

            samples.append(ProcessInfoSample(pid: pid,
                                             name: name,
                                             cpuPercent: cpuPercent,
                                             memoryBytes: info.pti_resident_size))
        }

        previousCPU = previousCPU.filter { seen.contains($0.key) }

        return Array(samples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }
}
#endif
