import Foundation

/// Battery condition as this Mac reports it, decomposed the way DESIGN §6
/// specifies — and honestly about what a given firmware omits.
///
/// Measured on Mac17,8 (M5 Pro, macOS 27): `AppleSmartBattery` exposes
/// `CurrentCapacity`, `MaxCapacity`, `CycleCount`, `AppleRawBatteryVoltage`,
/// `Amperage`, `ExternalConnected`, `IsCharging` and a nested `BatteryData`
/// carrying `DesignCapacity`, `NominalChargeCapacity` and
/// `FullChargeCapacity`. It does **not** expose a top-level temperature or
/// permanent-failure status; those stay absent here rather than being guessed,
/// so a missing reading always means "not reported by this firmware".
public struct BatteryHealth: Sendable, Equatable {
    /// Whether a battery is present at all. Desktops report none, which is the
    /// correct answer rather than a fabricated 100%.
    public var batteryInstalled: Bool?
    /// Current charge, percent of full.
    public var chargePercent: Double?
    /// Apple's smoothed "Maximum Capacity" figure. Deliberately labelled as
    /// Apple's: it is recalibrated over time and will disagree with the raw
    /// ratio below (DESIGN §6.2).
    public var appleMaxPercent: Double?
    public var cycleCount: Int?
    public var designCapacityMah: Double?
    /// Raw measured full-charge capacity (`NominalChargeCapacity`). Noisier
    /// than Apple's figure and usually the lower of the two.
    public var nominalCapacityMah: Double?
    public var fullChargeCapacityMah: Double?
    public var voltageMillivolts: Double?
    /// Signed: negative while discharging.
    public var amperageMilliamps: Double?
    public var isCharging: Bool?
    public var externalConnected: Bool?

    /// The unsmoothed capacity ratio (DESIGN §6.1). This is the number that
    /// answers "how much of the original cells remain" literally; presenting it
    /// next to `appleMaxPercent` without commentary would generate bug reports
    /// about overnight degradation, which is why every surface that shows one
    /// shows both.
    public var rawHealthPercent: Double? {
        guard let nominal = nominalCapacityMah,
              let design = designCapacityMah,
              nominal >= 0, design > 0 else { return nil }
        return min(100, nominal / design * 100)
    }

    public init(batteryInstalled: Bool? = nil,
                chargePercent: Double? = nil,
                appleMaxPercent: Double? = nil,
                cycleCount: Int? = nil,
                designCapacityMah: Double? = nil,
                nominalCapacityMah: Double? = nil,
                fullChargeCapacityMah: Double? = nil,
                voltageMillivolts: Double? = nil,
                amperageMilliamps: Double? = nil,
                isCharging: Bool? = nil,
                externalConnected: Bool? = nil) {
        self.batteryInstalled = batteryInstalled
        self.chargePercent = chargePercent
        self.appleMaxPercent = appleMaxPercent
        self.cycleCount = cycleCount
        self.designCapacityMah = designCapacityMah
        self.nominalCapacityMah = nominalCapacityMah
        self.fullChargeCapacityMah = fullChargeCapacityMah
        self.voltageMillivolts = voltageMillivolts
        self.amperageMilliamps = amperageMilliamps
        self.isCharging = isCharging
        self.externalConnected = externalConnected
    }
}

extension BatteryHealth {

    /// Builds health from an IORegistry property dump. Pure given its input,
    /// which is what makes it testable against shapes measured from real
    /// firmware — including the ones where keys are missing.
    public init(registry properties: [String: Any]) {
        self.init()

        if let installed = Self.bool(properties["BatteryInstalled"]) {
            batteryInstalled = installed
        }
        if let capacity = Self.percent(properties["CurrentCapacity"]) {
            chargePercent = capacity
        }
        if let max = Self.percent(properties["MaxCapacity"]) {
            appleMaxPercent = max
        }
        if let cycles = properties["CycleCount"] as? Int {
            cycleCount = max(0, cycles)
        }
        if let voltage = Self.double(properties["AppleRawBatteryVoltage"])
            ?? Self.double(properties["Voltage"]) {
            voltageMillivolts = voltage
        }
        if let amps = Self.double(properties["Amperage"]) {
            amperageMilliamps = amps
        }
        if let charging = Self.bool(properties["IsCharging"]) {
            isCharging = charging
        }
        if let connected = Self.bool(properties["ExternalConnected"]
                                     ?? properties["AppleRawExternalConnected"]) {
            externalConnected = connected
        }

        // Capacities live in a nested gauge dictionary on current firmware.
        // Older builds carried some of them at the top level, so both places
        // are consulted and the nested value wins — it is the fresher source.
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        designCapacityMah = Self.double(batteryData["DesignCapacity"])
            ?? Self.double(properties["DesignCapacity"])
        nominalCapacityMah = Self.double(batteryData["NominalChargeCapacity"])
        fullChargeCapacityMah = Self.double(batteryData["FullChargeCapacity"])
    }

    private static func double(_ any: Any?) -> Double? {
        guard let any else { return nil }
        switch any {
        case let n as Int:    return n >= 0 ? Double(n) : Double(n)
        case let n as UInt32: return Double(n)
        case let n as UInt64: return n <= UInt64(Int64.max) ? Double(n) : nil
        case let n as Double: return n.isFinite ? n : nil
        default: return nil
        }
    }

    /// Capacity percentages arrive as integers 0–100 on every firmware
    /// measured; a fraction-looking value (>0, <1) is treated with suspicion
    /// rather than rescaled, because guessing scales is how readouts drift
    /// from reality.
    private static func percent(_ any: Any?) -> Double? {
        guard let value = double(any), value >= 0, value <= 100 else { return nil }
        return value
    }

    private static func bool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool:   return b
        case let n as Int:    return n != 0
        case let s as String: return s == "Yes" || s == "true"
        default: return nil
        }
    }
}

#if canImport(IOKit)
import IOKit

/// Reads the live `AppleSmartBattery` registry node. Unprivileged — this node
/// is world-readable by design, unlike the SMC keys that control it.
public enum BatteryReader {

    /// Nil when there is no battery node: a desktop, or a registry that has
    /// been renamed out from under us. Callers show "no battery", never zeros.
    public static func read() -> BatteryHealth? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSmartBattery"),
                                           &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return BatteryHealth(registry: dict)
    }
}
#endif
