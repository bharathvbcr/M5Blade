import Foundation

/// What a stored series measures. Determines which axis a chart puts it on and
/// how an export labels it — never inferred from the value.
public enum SensorKind: String, Sendable, Codable, CaseIterable {
    case temperature
    case rpm
    case power
    case percent
    case charge

    public var unit: String {
        switch self {
        case .temperature: return "°C"
        case .rpm:         return "rpm"
        case .power:       return "W"
        case .percent:     return "%"
        case .charge:      return "mAh"
        }
    }
}

/// Identity of one recorded series.
///
/// `key` is the stable identifier written to the database; `name` is what a
/// person reads. `group` is the display bucket a chart aggregates by ("CPU",
/// "GPU", "Fan") — supplied by the caller rather than derived here, so
/// `HistoryKit` doesn't have to know how sensors are classified.
public struct SensorDescriptor: Sendable, Hashable, Codable {
    public let key: String
    public let name: String
    public let kind: SensorKind
    public let group: String

    public init(key: String, name: String, kind: SensorKind, group: String) {
        self.key = key
        self.name = name
        self.kind = kind
        self.group = group
    }
}

/// One value for one sensor. Timestamps belong to the batch, not the sample —
/// every sample in a tick shares an instant.
public struct RecordedSample: Sendable, Hashable {
    public let sensor: SensorDescriptor
    public let value: Double

    public init(sensor: SensorDescriptor, value: Double) {
        self.sensor = sensor
        self.value = value
    }
}

/// One bucket of a queried series. `average`, `minimum` and `maximum` are equal
/// when the bucket holds a single raw sample; the distinction only appears once
/// downsampling has happened, and the chart draws the band from it.
public struct SeriesPoint: Sendable, Hashable, Identifiable {
    public let date: Date
    public let average: Double
    public let minimum: Double
    public let maximum: Double

    public var id: Date { date }

    public init(date: Date, average: Double, minimum: Double, maximum: Double) {
        self.date = date
        self.average = average
        self.minimum = minimum
        self.maximum = maximum
    }

    /// A single un-aggregated reading, where the three statistics coincide.
    public init(date: Date, value: Double) {
        self.init(date: date, average: value, minimum: value, maximum: value)
    }
}

public struct Series: Sendable, Identifiable {
    /// Either a sensor key or a group name, depending on which query produced it.
    public let id: String
    public let name: String
    public let kind: SensorKind
    public let points: [SeriesPoint]

    public init(id: String, name: String, kind: SensorKind, points: [SeriesPoint]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.points = points
    }
}

/// Shared wording for the numbers this module hands back.
///
/// Every surface that shows an episode, a spike or a session prints a duration,
/// and each one used to format it for itself. Two copies of a formatting
/// decision is how the same 300 seconds comes to read "5m 0s" in one list and
/// "5m" in the next.
public enum HistoryFormatting {
    /// Whole seconds under a minute, minutes and seconds above it, and the
    /// seconds dropped when there are none.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }
}

/// One application's share of an event's CPU-seconds, 0–100.
///
/// Shared by throttle episodes and spikes: both answer "which app was
/// responsible?", and two structures for that would be two JSON encodings of
/// the same fact in the same database.
public struct ProcessShare: Sendable, Codable, Equatable, Hashable {
    public let name: String
    /// Share of the event's total CPU-seconds, 0–100.
    public let percent: Double

    public init(name: String, percent: Double) {
        self.name = name
        self.percent = percent
    }
}

/// A thermal throttle episode, as defined by DESIGN §3.2/§3.3.
///
/// `processes` is empty unless the user has opted into process attribution
/// (DESIGN §5.4) — an empty list therefore means "not recorded", not "no
/// process was responsible", and the UI says so.
/// Not `Codable` on purpose: `JSONEncoder` writes an `[Int: Double]` dictionary
/// as a flat alternating array, which would make `fanRPMAtPeak` unreadable in an
/// export. `HistoryExport` maps it to string keys instead.
public struct ThrottleEpisode: Sendable, Identifiable, Equatable {
    /// Kept as a nested name so existing call sites read the same; there is only
    /// one type behind it.
    public typealias ProcessShare = HistoryKit.ProcessShare

    public var id: Int64
    public var start: Date
    public var end: Date?
    public var peakTempC: Double?
    public var peakPressure: Int
    public var meanCPUPercent: Double
    public var profileName: String
    public var onBattery: Bool
    public var externalDisplayCount: Int
    public var fanRPMAtPeak: [Int: Double]
    public var processes: [ProcessShare]

    public init(id: Int64 = 0,
                start: Date,
                end: Date? = nil,
                peakTempC: Double? = nil,
                peakPressure: Int = 0,
                meanCPUPercent: Double = 0,
                profileName: String = "",
                onBattery: Bool = false,
                externalDisplayCount: Int = 0,
                fanRPMAtPeak: [Int: Double] = [:],
                processes: [ProcessShare] = []) {
        self.id = id
        self.start = start
        self.end = end
        self.peakTempC = peakTempC
        self.peakPressure = peakPressure
        self.meanCPUPercent = meanCPUPercent
        self.profileName = profileName
        self.onBattery = onBattery
        self.externalDisplayCount = externalDisplayCount
        self.fanRPMAtPeak = fanRPMAtPeak
        self.processes = processes
    }

    /// Nil while the episode is still open — an in-progress episode has no
    /// duration yet, and showing one would be a guess.
    public var duration: TimeInterval? {
        end.map { $0.timeIntervalSince(start) }
    }
}

/// A user-marked window, so two runs of the same benchmark can be compared.
public struct RecordingSession: Sendable, Identifiable, Codable, Equatable {
    public var id: Int64
    public var name: String
    public var start: Date
    public var end: Date?
    public var profileName: String

    public init(id: Int64 = 0, name: String, start: Date, end: Date? = nil, profileName: String = "") {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.profileName = profileName
    }
}

/// Which profile was active from `date` until the next change. Drawn as the
/// band strip under the chart — the thing that makes "did my policy do
/// anything?" answerable.
public struct ProfileChange: Sendable, Identifiable, Codable, Equatable {
    public var date: Date
    public var profileID: String
    public var profileName: String
    public var reason: String

    public var id: Date { date }

    public init(date: Date, profileID: String, profileName: String, reason: String) {
        self.date = date
        self.profileID = profileID
        self.profileName = profileName
        self.reason = reason
    }
}

/// The ranges the History and Insights pages offer, matching UI.md §7.
public enum HistoryRange: String, Sendable, CaseIterable, Identifiable {
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case week = "7d"
    case month = "30d"

    public var id: String { rawValue }

    public var duration: TimeInterval {
        switch self {
        case .hour:     return 3_600
        case .sixHours: return 6 * 3_600
        case .day:      return 24 * 3_600
        case .week:     return 7 * 24 * 3_600
        case .month:    return 30 * 24 * 3_600
        }
    }

    public var label: String { rawValue }
}
