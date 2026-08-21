import Foundation

/// A sudden thermal rise, and everything observed around it.
///
/// This is the record behind "my Mac suddenly spikes — why?". A throttle
/// episode answers a different question: it needs *sustained* heavy load and
/// declares that the machine ran out of thermal headroom. Most of the spikes
/// people actually notice — the fans audibly ramping for ninety seconds — never
/// reach that bar, so they left no trace at all.
///
/// The record stores **evidence, not a verdict**. What caused it is computed
/// from these fields by `SpikeExplanation`, so improving the explanation is a
/// change to one pure function rather than a schema migration and a wait for
/// the next spike.
public struct Spike: Sendable, Identifiable, Equatable {

    public var id: Int64
    /// When the rise began — the coolest sample before it, not the moment the
    /// threshold was crossed. Otherwise the record would start halfway up.
    public var start: Date
    /// When the temperature peaked.
    public var peak: Date
    /// When it settled back down. Nil while still elevated.
    public var end: Date?

    public var fromTempC: Double
    public var peakTempC: Double

    /// Load at `start` and at the peak. The pair is the whole point: a rise with
    /// no change in load did not come from the CPU.
    public var cpuAtStartPercent: Double
    public var peakCPUPercent: Double

    /// Display group of the hottest sensor at the peak (`SensorCategory`'s raw
    /// value, or `""` when nothing reported). Says *which part* got hot.
    public var hottestGroup: String

    public var peakFanRPM: Double
    public var peakFanDutyPercent: Double

    public var profileName: String
    /// Whether the active profile changed during the rise — a fan policy that
    /// switched mid-rise is a candidate cause, not a coincidence.
    public var profileChanged: Bool
    public var onBattery: Bool

    /// Whether attribution was switched on while this spike was recorded
    /// (DESIGN §5.4). Stored per spike rather than read from the current
    /// setting, so a record made while it was off keeps saying "not recorded"
    /// after the user turns it on.
    public var recordedProcessNames: Bool
    /// Empty when `recordedProcessNames` is false, and also when it is true but
    /// nothing measurable was running — `SpikeExplanation` tells those apart.
    public var processes: [ProcessShare]

    public init(id: Int64 = 0,
                start: Date,
                peak: Date,
                end: Date? = nil,
                fromTempC: Double,
                peakTempC: Double,
                cpuAtStartPercent: Double = 0,
                peakCPUPercent: Double = 0,
                hottestGroup: String = "",
                peakFanRPM: Double = 0,
                peakFanDutyPercent: Double = 0,
                profileName: String = "",
                profileChanged: Bool = false,
                onBattery: Bool = false,
                recordedProcessNames: Bool = false,
                processes: [ProcessShare] = []) {
        self.id = id
        self.start = start
        self.peak = peak
        self.end = end
        self.fromTempC = fromTempC
        self.peakTempC = peakTempC
        self.cpuAtStartPercent = cpuAtStartPercent
        self.peakCPUPercent = peakCPUPercent
        self.hottestGroup = hottestGroup
        self.peakFanRPM = peakFanRPM
        self.peakFanDutyPercent = peakFanDutyPercent
        self.profileName = profileName
        self.profileChanged = profileChanged
        self.onBattery = onBattery
        self.recordedProcessNames = recordedProcessNames
        self.processes = processes
    }

    /// How much it climbed, in degrees.
    public var riseC: Double { peakTempC - fromTempC }

    /// How long the climb took. Never negative and never zero — a division by it
    /// has to be safe, and a spike whose peak is its first sample took at least
    /// one sampling interval to get there.
    public var riseSeconds: TimeInterval { max(1, peak.timeIntervalSince(start)) }

    /// Degrees per minute over the climb. The number that separates "it warmed
    /// up" from "it jumped".
    public var riseRatePerMinute: Double { riseC / riseSeconds * 60 }

    /// Nil while still elevated — showing a duration for something that has not
    /// finished would be a guess.
    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }

    /// How much more load was running at the peak than at the start.
    public var cpuRisePercentPoints: Double { peakCPUPercent - cpuAtStartPercent }
}

/// Turns a `Spike`'s evidence into something a person can act on.
///
/// Pure, and deliberately separate from the record: the detector's job is to
/// notice and measure, this one's is to explain. Every branch says what it is
/// inferring from, and the "we don't know" branch is a real answer rather than
/// a default that quietly claims the most common cause.
public struct SpikeExplanation: Sendable, Equatable {

    public enum Cause: String, Sendable, Equatable, CaseIterable {
        /// An application's CPU work.
        case application
        /// CPU load rose, but no single application could be named.
        case processorLoad
        /// The graphics/Neural Engine sensors led while load stayed flat.
        case graphics
        /// The SSD led — large copies, indexing, a Time Machine run.
        case storage
        /// The fan policy changed underneath it.
        case profileChange
        /// It got hot without the CPU doing more. Background system work, or
        /// something this app cannot see.
        case background

        public var label: String {
            switch self {
            case .application:   return "Application"
            case .processorLoad: return "Processor load"
            case .graphics:      return "Graphics"
            case .storage:       return "Storage"
            case .profileChange: return "Profile change"
            case .background:    return "Background work"
            }
        }

        public var symbolName: String {
            switch self {
            case .application:   return "app.badge"
            case .processorLoad: return "cpu"
            case .graphics:      return "cpu.fill"
            case .storage:       return "internaldrive"
            case .profileChange: return "slider.horizontal.3"
            case .background:    return "questionmark.circle"
            }
        }
    }

    public let cause: Cause
    /// One sentence naming what did it.
    public let headline: String
    /// The measurements the headline rests on, so the reader can disagree with it.
    public let detail: String
    /// What to do to get a better answer next time, when there is one.
    public let suggestion: String?

    // MARK: - Thresholds

    /// A named application has to own most of the work before it is *the*
    /// answer; below this several things were busy and naming one would be a
    /// story rather than a finding.
    static let dominantShare: Double = 45
    /// Load has to have actually gone up, not merely be high. A machine already
    /// at 90% that stays at 90% did not spike *because* of new CPU work.
    static let cpuRisePoints: Double = 20
    static let cpuPeakPercent: Double = 45

    public static func explain(_ spike: Spike) -> SpikeExplanation {
        let cpuRose = spike.cpuRisePercentPoints >= cpuRisePoints
            && spike.peakCPUPercent >= cpuPeakPercent
        let climb = String(format: "%.0f → %.0f °C in %@",
                           spike.fromTempC, spike.peakTempC,
                           HistoryFormatting.duration(spike.riseSeconds))
        let load = String(format: "load %.0f%% → %.0f%%",
                          spike.cpuAtStartPercent, spike.peakCPUPercent)
        let fans = spike.peakFanRPM > 0
            ? String(format: ", fans %.0f rpm (%.0f%%)", spike.peakFanRPM, spike.peakFanDutyPercent)
            : ""
        let evidence = "\(climb) · \(load)\(fans)"

        // A named application first, but only when it owned the work *and* the
        // work was CPU work. Attribution measures CPU-seconds, so a graphics
        // spike can carry a name that had nothing to do with the heat.
        if cpuRose, let top = spike.processes.first, top.percent >= dominantShare {
            let others = spike.processes.dropFirst().prefix(2)
                .map { String(format: "%@ %.0f%%", $0.name, $0.percent) }
                .joined(separator: ", ")
            return SpikeExplanation(
                cause: .application,
                headline: String(format: "%@ drove it — %.0f%% of the CPU work",
                                 top.name, top.percent),
                detail: others.isEmpty ? evidence : "\(evidence) · also \(others)",
                suggestion: nil)
        }

        if cpuRose {
            return SpikeExplanation(
                cause: .processorLoad,
                headline: String(format: "CPU load jumped %.0f points",
                                 spike.cpuRisePercentPoints),
                detail: evidence,
                suggestion: attributionSuggestion(spike))
        }

        // Load flat: whatever got hot, it was not new CPU work. The hottest
        // group is then the most specific thing we know.
        switch spike.hottestGroup {
        case "GPU":
            return SpikeExplanation(
                cause: .graphics,
                headline: "Graphics or Neural Engine work, not the CPU",
                detail: evidence,
                suggestion: attributionSuggestion(spike))
        case "Storage":
            return SpikeExplanation(
                cause: .storage,
                headline: "The SSD got hot — a large copy, indexing, or a backup",
                detail: evidence,
                suggestion: nil)
        default:
            break
        }

        if spike.profileChanged {
            return SpikeExplanation(
                cause: .profileChange,
                headline: "The fan profile changed to “\(spike.profileName)” during the rise",
                detail: evidence,
                suggestion: "Check this profile's curve — a quieter profile lets the machine run hotter.")
        }

        return SpikeExplanation(
            cause: .background,
            headline: "It got hot without the CPU doing more",
            detail: evidence,
            suggestion: attributionSuggestion(spike)
                ?? "Background system work — Spotlight indexing, a backup, or a sync — is the usual cause.")
    }

    /// Only offered when turning attribution on would actually have helped: if
    /// it was already on, the names simply weren't there to record.
    private static func attributionSuggestion(_ spike: Spike) -> String? {
        guard !spike.recordedProcessNames else { return nil }
        return "Turn on “Record application names” to find out which app was responsible next time."
    }
}
