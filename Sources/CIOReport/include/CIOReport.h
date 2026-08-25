#ifndef CIOREPORT_H
#define CIOREPORT_H

#include <stdint.h>

// IOReport is exported by libIOReport.dylib but ships without public headers.
// All CoreFoundation detail lives in shim.c deliberately: Swift imports CF
// types as memory-managed classes, which does not survive hand-written
// retain/release against symbols it cannot see annotated. Plain integers cross
// this boundary instead.
//
// Energy channels accumulate since subscription; power = delta / interval.
// Everything degrades to an absent result rather than an error — a macOS
// release that renames these channels costs a chart series, not a crash.

/// Subscribes this task to the "Energy Model" group (CPU/GPU energy).
/// Returns 0 on success, nonzero when the system refused or no channel was found.
int CIOReportSubscribe(void);

/// One snapshot of the subscribed channels. Writes each requested channel's
/// cumulative counter when present and returns a bitmask: bit 0 = CPU valid,
/// bit 1 = GPU valid. A channel that answers but never changes is reported
/// valid here — deadness is a property the Swift layer judges over several
/// samples, not one.
int CIOReportSampleCounters(int64_t *cpu_energy_millijoules,
                            int64_t *gpu_energy_millijoules);

#endif /* CIOREPORT_H */
