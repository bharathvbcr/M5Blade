import Foundation

/// Groups sensors for display.
///
/// Classification is by name, because that is all Apple's HID sensor hub gives
/// us — there is no metadata saying "this die sensor is the GPU cluster". Names
/// that don't clearly indicate a subsystem land in `soc` or `other` rather than
/// being guessed into a category they might not belong to.
/// The raw values are stable codes for `Codable` and `id`, not labels — read
/// `title` for anything a person sees.
public enum SensorCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case cpu = "CPU"
    case gpu = "GPU"
    case soc = "SoC"
    case memory = "Memory"
    case storage = "Storage"
    case battery = "Battery"
    case power = "Power"
    case display = "Display"
    case ambient = "Ambient"
    case other = "Other"

    public var id: String { rawValue }

    /// Group heading, in the same plain English as the sensor names underneath
    /// it (`SensorNaming`). "SoC" in particular means nothing to most people.
    public var title: String {
        switch self {
        case .cpu:      return "Processor"
        case .gpu:      return "Graphics"
        case .soc:      return "Main chip"
        case .memory:   return "Memory"
        case .storage:  return "Storage"
        case .battery:  return "Battery"
        case .power:    return "Power"
        case .display:  return "Display"
        case .ambient:  return "Ambient"
        case .other:    return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .cpu:      return "cpu"
        case .gpu:      return "cpu.fill"
        case .soc:      return "square.stack.3d.up"
        case .memory:   return "memorychip"
        case .storage:  return "internaldrive"
        case .battery:  return "battery.100"
        case .power:    return "bolt"
        case .display:  return "display"
        case .ambient:  return "thermometer.medium"
        case .other:    return "sensor"
        }
    }

    /// What this group means, shown under its heading. `soc` in particular needs
    /// explaining — users look for "CPU" and find die sensors instead.
    public var explanation: String {
        switch self {
        case .cpu:     return "Processor cores and clusters."
        case .gpu:     return "Graphics cores and the Neural Engine."
        case .soc:     return "Sensors spread across the main chip. Apple reports each as a die temperature without saying which part of the chip it covers, so they are numbered by zone rather than split into processor and graphics."
        case .memory:  return "Unified memory."
        case .storage: return "The internal SSD — its controller and flash chips."
        case .battery: return "The battery pack and the gauge that measures it."
        case .power:   return "Power delivery and charging."
        case .display: return "The built-in display."
        case .ambient: return "Air and case temperatures around the machine."
        case .other:   return "Sensors whose names don't say which part they measure."
        }
    }

    /// Order groups by how much people care, not alphabetically.
    public var sortOrder: Int {
        switch self {
        case .cpu: return 0
        case .gpu: return 1
        case .soc: return 2
        case .memory: return 3
        case .storage: return 4
        case .battery: return 5
        case .power: return 6
        case .display: return 7
        case .ambient: return 8
        case .other: return 9
        }
    }

    /// Longest, most specific patterns are checked first so "ecpu" doesn't get
    /// swallowed by a broader match.
    private static let patterns: [(needle: String, category: SensorCategory)] = [
        ("gas gauge", .battery), ("battery", .battery), ("charger", .power),
        // pACC / eACC are Apple Silicon's performance and efficiency core
        // clusters — the closest thing to a real "CPU" sensor these Macs expose.
        ("ecpu", .cpu), ("pcpu", .cpu), ("eacc", .cpu), ("pacc", .cpu),
        ("cpu", .cpu), ("core", .cpu), ("efficiency", .cpu), ("performance", .cpu),
        ("gpu", .gpu), ("agx", .gpu), ("neural", .gpu), ("ane", .gpu),
        ("nand", .storage), ("ssd", .storage), ("nvme", .storage), ("flash", .storage),
        ("dram", .memory), ("memory", .memory), ("lpddr", .memory),
        ("display", .display), ("lcd", .display), ("backlight", .display),
        ("ambient", .ambient), ("tamb", .ambient), ("palm", .ambient), ("enclosure", .ambient),
        ("pmic", .power), ("power", .power), ("vrm", .power), ("watt", .power),
        ("tdie", .soc), ("tcal", .soc), ("die", .soc), ("soc", .soc), ("pmu", .soc),
    ]

    public static func classify(_ sensorName: String) -> SensorCategory {
        // A bare SMC key is not a name and must not be matched like one. The
        // substring rules below are case-insensitive, which is right for prose
        // like "eCPU core 3" and wrong for keys: on this Mac `TG0B` is a battery
        // gauge and `Tg08` is a GPU sensor, and folding their case merges them.
        // `SensorNaming` exempts a key-shaped name that the calibration rule
        // claims, so this exempts it too. The two have to reach the same verdict
        // about the same string or the Sensors tab groups a sensor one way and
        // labels it another.
        if let key = SMCKeyName(sensorName),
           !SensorNaming.isCalibrationReference(sensorName) {
            return classify(smcKey: key)
        }

        let lowered = sensorName.lowercased()
        for (needle, category) in patterns where lowered.contains(needle) {
            return category
        }
        return .other
    }

    /// Group a raw SMC key by its two-character family.
    ///
    /// Only families this machine's behaviour actually established are named.
    /// The temptation is to read the third and fourth characters as a core index
    /// — Macs Fan Control ships a per-model table that does exactly that, and on
    /// this Mac it labels eight "CPU Super Core" sensors where the hardware
    /// reports six super cores, while omitting `Tp00` and `Tp0C`, the two
    /// hottest keys in the family. A family is as far as the evidence goes.
    ///
    /// Measured on this Mac, mean change across every key in the family:
    ///
    /// | family | keys | CPU-only load | GPU-only load |
    /// |--------|------|---------------|---------------|
    /// | `Tp`   |   23 | +5 … +10 °C   | −0.9 °C       |
    /// | `Tg`   |   42 | (not isolated)| +14.4 °C      |
    /// | `Tm`   |   40 | +25 °C        | +6.8 °C       |
    ///
    /// `Tp` moves with the processor and ignores the GPU; `Tg` moves with the
    /// GPU. `Tm` moves with both, which is what unified memory would do and also
    /// what a shared area of the die would do — the measurement does not
    /// separate them, so it lands in `soc` rather than being called either.
    public static func classify(smcKey: SMCKeyName) -> SensorCategory {
        switch smcKey.family {
        case "Tp": return .cpu
        case "Tg": return .gpu
        case "Tm": return .soc
        default:   return .other
        }
    }
}
