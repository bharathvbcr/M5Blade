import Foundation

/// Serialises a window of history for the user to take away (DESIGN §5.3).
///
/// CSV is wide — one column per sensor, one row per bucket — because that is
/// what a spreadsheet wants. JSON is tall and carries the metadata a CSV can't:
/// units, resolution, episodes, sessions, profile changes.
public enum HistoryExport {

    public enum Format: String, Sendable, CaseIterable, Identifiable {
        case csv
        case json

        public var id: String { rawValue }
        public var fileExtension: String { rawValue }
        public var displayName: String { rawValue.uppercased() }
    }

    /// Large enough that `bucketSeconds` always collapses to the tier's own
    /// resolution: an export is the stored data, never a resample of it.
    private static let fullResolution = 100_000_000

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func data(format: Format, store: HistoryStore,
                            from: Date, to: Date, now: Date = Date()) throws -> Data {
        switch format {
        case .csv:  return try csv(store: store, from: from, to: to, now: now)
        case .json: return try json(store: store, from: from, to: to, now: now)
        }
    }

    // MARK: - CSV

    private static func csv(store: HistoryStore, from: Date, to: Date, now: Date) throws -> Data {
        let sensors = try store.knownSensors()
        // `now` decides which tier answers the query, so it has to be the same
        // instant the caller reasoned about — defaulting to the wall clock here
        // would silently export an empty file for any window built from a
        // different reference time.
        let series = try store.series(keys: sensors.map(\.key), from: from, to: to,
                                      targetPoints: fullResolution, now: now)
        guard !series.isEmpty else {
            return Data("timestamp_unix,timestamp_iso\n".utf8)
        }

        // Columns follow the sensor catalogue, not the query result, so a sensor
        // with no data in this window still gets a column — an absent column and
        // an empty one mean different things.
        let columns = sensors.filter { sensor in series.contains { $0.id == sensor.key } }
        var byKey: [String: [Date: Double]] = [:]
        var dates = Set<Date>()
        for entry in series {
            byKey[entry.id] = Dictionary(uniqueKeysWithValues: entry.points.map { ($0.date, $0.average) })
            dates.formUnion(entry.points.map(\.date))
        }

        var output = "timestamp_unix,timestamp_iso"
        for column in columns {
            output += ",\(escape("\(column.name) (\(column.kind.unit))"))"
        }
        output += "\n"

        for date in dates.sorted() {
            output += "\(Int64(date.timeIntervalSince1970)),\(iso.string(from: date))"
            for column in columns {
                if let value = byKey[column.key]?[date] {
                    output += ",\(String(format: "%.2f", value))"
                } else {
                    output += ","
                }
            }
            output += "\n"
        }
        return Data(output.utf8)
    }

    /// RFC 4180: quote anything containing a comma, quote, or newline, and
    /// double the quotes inside. Sensor names come from a private API — they are
    /// not ours to assume are well behaved.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - JSON

    private struct Payload: Encodable {
        struct Sensor: Encodable {
            let key: String, name: String, kind: String, unit: String, group: String
        }
        struct Sample: Encodable {
            let key: String, timestamp: String
            let average: Double, minimum: Double, maximum: Double
        }
        struct Episode: Encodable {
            let start: String, end: String?, durationSeconds: Double?
            let peakTempC: Double?, peakThermalPressure: Int, meanCPUPercent: Double
            let profile: String, onBattery: Bool, externalDisplays: Int
            let fanRPMAtPeak: [String: Double]
            let processes: [Process]
        }
        struct Process: Encodable {
            let name: String, percentOfEpisodeCPU: Double
        }
        struct Spike: Encodable {
            let start: String, peak: String, end: String?, durationSeconds: Double?
            let fromTempC: Double, peakTempC: Double, riseC: Double
            let riseSeconds: Double, riseRateCPerMinute: Double
            let cpuAtStartPercent: Double, peakCPUPercent: Double
            let hottestGroup: String
            let peakFanRPM: Double, peakFanDutyPercent: Double
            let profile: String, profileChangedDuringRise: Bool, onBattery: Bool
            let cause: String, explanation: String
            let processNamesRecorded: Bool
            let processes: [Process]
        }
        struct Session: Encodable {
            let name: String, start: String, end: String?, profile: String
        }
        struct Change: Encodable {
            let timestamp: String, profile: String, reason: String
        }

        let exportedAt: String
        let rangeStart: String
        let rangeEnd: String
        let resolutionSeconds: Int
        let includesProcessNames: Bool
        let sensors: [Sensor]
        let samples: [Sample]
        let episodes: [Episode]
        let spikes: [Spike]
        let sessions: [Session]
        let profileChanges: [Change]
    }

    private static func json(store: HistoryStore, from: Date, to: Date, now: Date) throws -> Data {
        let sensors = try store.knownSensors()
        let series = try store.series(keys: sensors.map(\.key), from: from, to: to,
                                      targetPoints: fullResolution, now: now)
        let episodes = try store.episodes(from: from, to: to)
        let spikes = try store.spikes(from: from, to: to, limit: Int.max)

        let payload = Payload(
            exportedAt: iso.string(from: now),
            rangeStart: iso.string(from: from),
            rangeEnd: iso.string(from: to),
            resolutionSeconds: store.resolutionSeconds(from: from, now: now),
            includesProcessNames: episodes.contains { !$0.processes.isEmpty }
                || spikes.contains { !$0.processes.isEmpty },
            sensors: sensors.map {
                .init(key: $0.key, name: $0.name, kind: $0.kind.rawValue,
                      unit: $0.kind.unit, group: $0.group)
            },
            samples: series.flatMap { entry in
                entry.points.map {
                    Payload.Sample(key: entry.id, timestamp: iso.string(from: $0.date),
                                   average: $0.average, minimum: $0.minimum, maximum: $0.maximum)
                }
            },
            episodes: episodes.map { episode in
                .init(start: iso.string(from: episode.start),
                      end: episode.end.map { iso.string(from: $0) },
                      durationSeconds: episode.duration,
                      peakTempC: episode.peakTempC,
                      peakThermalPressure: episode.peakPressure,
                      meanCPUPercent: episode.meanCPUPercent,
                      profile: episode.profileName,
                      onBattery: episode.onBattery,
                      externalDisplays: episode.externalDisplayCount,
                      fanRPMAtPeak: Dictionary(uniqueKeysWithValues:
                        episode.fanRPMAtPeak.map { (String($0.key + 1), $0.value) }),
                      processes: episode.processes.map {
                          .init(name: $0.name, percentOfEpisodeCPU: $0.percent)
                      })
            },
            // The explanation is exported alongside the evidence, not instead of
            // it: whoever reads the file can check the reasoning against the
            // numbers rather than having to trust it.
            spikes: spikes.map { spike in
                let explanation = SpikeExplanation.explain(spike)
                return .init(start: iso.string(from: spike.start),
                             peak: iso.string(from: spike.peak),
                             end: spike.end.map { iso.string(from: $0) },
                             durationSeconds: spike.duration,
                             fromTempC: spike.fromTempC,
                             peakTempC: spike.peakTempC,
                             riseC: spike.riseC,
                             riseSeconds: spike.riseSeconds,
                             riseRateCPerMinute: spike.riseRatePerMinute,
                             cpuAtStartPercent: spike.cpuAtStartPercent,
                             peakCPUPercent: spike.peakCPUPercent,
                             hottestGroup: spike.hottestGroup,
                             peakFanRPM: spike.peakFanRPM,
                             peakFanDutyPercent: spike.peakFanDutyPercent,
                             profile: spike.profileName,
                             profileChangedDuringRise: spike.profileChanged,
                             onBattery: spike.onBattery,
                             cause: explanation.cause.rawValue,
                             explanation: explanation.headline,
                             processNamesRecorded: spike.recordedProcessNames,
                             processes: spike.processes.map {
                                 .init(name: $0.name, percentOfEpisodeCPU: $0.percent)
                             })
            },
            sessions: try store.sessions(from: from, to: to).map {
                .init(name: $0.name, start: iso.string(from: $0.start),
                      end: $0.end.map { date in iso.string(from: date) }, profile: $0.profileName)
            },
            profileChanges: try store.profileChanges(from: from, to: to).map {
                .init(timestamp: iso.string(from: $0.date), profile: $0.profileName, reason: $0.reason)
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}
