import Foundation
#if canImport(AppKit)
import AppKit
import CoreGraphics
import IOKit.ps

/// The non-thermal inputs the rule engine needs: power, battery, displays, and
/// the frontmost app.
///
/// Everything here degrades to a documented default rather than throwing — a
/// rule that cannot be evaluated must read as "does not match", never as an
/// error that stalls the control loop.
public struct EnvironmentMetrics: Sendable {

    public struct Snapshot: Sendable, Equatable {
        public var onACPower: Bool
        public var batteryPercent: Double?
        public var externalDisplayCount: Int
        public var displaysAsleep: Bool
        public var frontmostBundleID: String?
        public var lowPowerMode: Bool

        public init(onACPower: Bool = true,
                    batteryPercent: Double? = nil,
                    externalDisplayCount: Int = 0,
                    displaysAsleep: Bool = false,
                    frontmostBundleID: String? = nil,
                    lowPowerMode: Bool = false) {
            self.onACPower = onACPower
            self.batteryPercent = batteryPercent
            self.externalDisplayCount = externalDisplayCount
            self.displaysAsleep = displaysAsleep
            self.frontmostBundleID = frontmostBundleID
            self.lowPowerMode = lowPowerMode
        }
    }

    public init() {}

    /// Must be called from the main actor: `NSWorkspace` and `NSScreen` are not
    /// safe to read from an arbitrary queue.
    @MainActor
    public func snapshot() -> Snapshot {
        let power = Self.powerSource()
        return Snapshot(
            onACPower: power.onAC,
            batteryPercent: power.percent,
            // The built-in panel is not "external"; a desktop Mac reports none.
            externalDisplayCount: max(0, NSScreen.screens.count - 1),
            displaysAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// Reads the IOKit power-source blob. A desktop with no battery reports
    /// AC with a nil percentage, which is the correct answer rather than a
    /// fabricated 100%.
    static func powerSource() -> (onAC: Bool, percent: Double?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return (true, nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        let onAC = providing != kIOPMBatteryPowerKey

        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (onAC, nil)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let max = description[kIOPSMaxCapacityKey] as? Double,
                  max > 0 else { continue }
            return (onAC, (current / max) * 100)
        }
        return (onAC, nil)
    }
}
#endif
