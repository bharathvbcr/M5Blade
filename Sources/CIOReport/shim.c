// The one file that knows IOReport's C surface. See include/CIOReport.h for
// why the CF detail is kept out of Swift's sight.
//
// Signatures verified against libIOReport on macOS 27 (M5 Pro, build 27G):
//   * CopyChannelsInGroup takes five arguments and returns a QUERY DICTIONARY
//     ({QueryOpts, IOReportChannels}), not the flat array older write-ups
//     describe.
//   * CreateSubscription takes a MUTABLE COPY of that dictionary and — unlike
//     every older example — a NULL task port. Passing mach_task_self() faults
//     inside libIOReport on this release.
//   * Sample elements carry their name under ChannelName, read via
//     IOReportChannelGetChannelName; the old IOReportChannelName key is absent.
#include "include/CIOReport.h"
#include <CoreFoundation/CoreFoundation.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;

extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group,
                                                   CFStringRef subgroup,
                                                   uint64_t a, uint64_t b,
                                                   uint64_t c);
extern IOReportSubscriptionRef IOReportCreateSubscription(
    void *task,
    CFMutableDictionaryRef subscriptions,
    CFMutableDictionaryRef *unsubscribed,
    uint64_t required,
    void *unspecified);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription,
                                             CFMutableDictionaryRef subscriptions,
                                             void *unspecified);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef sampleChannel,
                                             void *trailing);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);

static CFStringRef kChannelsKey;
static CFArrayRef channelList(CFDictionaryRef samples);

static IOReportSubscriptionRef subscription = NULL;
static CFMutableDictionaryRef channels = NULL;

int CIOReportSubscribe(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kChannelsKey = CFSTR("IOReportChannels");
    });

    if (subscription != NULL) return 0;

    // The "Energy Model" group carries whole-package energy accumulators
    // ("CPU Energy", "GPU Energy", …).
    CFDictionaryRef query = IOReportCopyChannelsInGroup(CFSTR("Energy Model"),
                                                        NULL, 0, 0, 0);
    if (query == NULL) return -1;

    // Subscription mutates its input; hand it a mutable copy it owns.
    channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    CFRelease(query);
    if (channels == NULL) return -1;

    CFMutableDictionaryRef unsubscribed = NULL;
    // NULL task port — see header note. A real port faults on this release.
    subscription = IOReportCreateSubscription(NULL, channels, &unsubscribed,
                                              0, NULL);
    if (unsubscribed != NULL) CFRelease(unsubscribed);
    if (subscription == NULL) {
        CFRelease(channels);
        channels = NULL;
        return -1;
    }
    return 0;
}

static CFStringRef channelName(CFDictionaryRef channel) {
    if (channel == NULL || CFGetTypeID(channel) != CFDictionaryGetTypeID()) {
        return NULL;
    }
    CFStringRef name = IOReportChannelGetChannelName(channel);
    return (name != NULL && CFGetTypeID(name) == CFStringGetTypeID()) ? name : NULL;
}

static CFArrayRef channelList(CFDictionaryRef samples) {
    const void *raw = CFDictionaryGetValue(samples, kChannelsKey);
    return (raw != NULL && CFGetTypeID(raw) == CFArrayGetTypeID()) ? (CFArrayRef)raw : NULL;
}

static int64_t counterFor(CFDictionaryRef samples, CFStringRef wanted,
                          int *found) {
    *found = 0;
    CFArrayRef list = channelList(samples);
    if (list == NULL) return 0;

    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFStringRef name = channelName(channel);
        if (name == NULL) continue;
        if (CFStringCompare(name, wanted, kCFCompareCaseInsensitive)
                != kCFCompareEqualTo) {
            continue;
        }
        *found = 1;
        return IOReportSimpleGetIntegerValue(channel, NULL);
    }
    return 0;
}

int CIOReportSampleCounters(int64_t *cpu_energy_millijoules,
                            int64_t *gpu_energy_millijoules) {
    if (subscription == NULL || channels == NULL) return 0;
    CFDictionaryRef samples = IOReportCreateSamples(subscription, channels, NULL);
    if (samples == NULL) return 0;

    int cpuFound = 0, gpuFound = 0;
    int64_t cpu = counterFor(samples, CFSTR("CPU Energy"), &cpuFound);
    int64_t gpu = counterFor(samples, CFSTR("GPU Energy"), &gpuFound);
    CFRelease(samples);

    if (cpuFound && cpu_energy_millijoules != NULL) *cpu_energy_millijoules = cpu;
    if (gpuFound && gpu_energy_millijoules != NULL) *gpu_energy_millijoules = gpu;
    return (cpuFound ? 1 : 0) | (gpuFound ? 2 : 0);
}
