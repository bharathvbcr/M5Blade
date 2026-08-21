import Foundation

/// The SQLite time series behind the History page (DESIGN §5).
///
/// Three tiers, each a strict downsample of the one before: raw seconds for two
/// hours, minute aggregates for two weeks, hour aggregates for two years. A
/// watermark in `meta` records how far each rollup has run, so the hourly job
/// only ever touches rows it hasn't seen — the cost doesn't grow with the size
/// of the database.
///
/// Not `Sendable`. One connection, owned by `HistoryRecorder`.
public final class HistoryStore {

    /// Oldest raw sample kept. Two hours at 1 Hz is ~144k rows for 20 sensors.
    public static let rawRetention: TimeInterval = 2 * 3_600
    public static let minuteRetention: TimeInterval = 14 * 24 * 3_600
    public static let hourRetention: TimeInterval = 2 * 365 * 24 * 3_600

    /// Episodes, spikes, sessions and profile changes are kept as long as the
    /// oldest samples they could be plotted against.
    ///
    /// They were kept forever, which looked harmless — a spike is a few hundred
    /// bytes and a machine produces a handful a day. But "small × unbounded" is
    /// still unbounded, and an event row that outlives every sample in its own
    /// window is a row the chart can never draw: the episode list would show a
    /// throttle from 2029 over a chart with nothing in it. They age out with the
    /// data that explains them.
    public static let eventRetention: TimeInterval = hourRetention

    private enum Tier {
        case raw, minute, hour

        var table: String {
            switch self {
            case .raw:    return "samples"
            case .minute: return "samples_minute"
            case .hour:   return "samples_hour"
            }
        }

        /// The narrowest bucket this tier can answer.
        var resolution: Int64 {
            switch self {
            case .raw:    return 1
            case .minute: return 60
            case .hour:   return 3_600
            }
        }

        /// Raw rows hold a single value; the aggregate tiers hold a triple.
        var columns: (average: String, minimum: String, maximum: String) {
            switch self {
            case .raw:            return ("value", "value", "value")
            case .minute, .hour:  return ("avg_value", "min_value", "max_value")
            }
        }
    }

    public let url: URL
    private let database: Database
    /// key → rowid, so the hot insert path never queries `sensors`.
    private var sensorIDs: [String: Int64] = [:]

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        database = try Database(path: url.path)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try migrate()
        try loadSensorIDs()
    }

    // MARK: - Schema

    /// v2 added `spikes`. Every statement below is `IF NOT EXISTS`, so the same
    /// block migrates a v1 database and creates a fresh one — there is one
    /// schema definition, not a base plus a list of patches that can disagree
    /// with it.
    private static let schemaVersion: Int32 = 2

    private func migrate() throws {
        guard database.userVersion < Self.schemaVersion else { return }

        // `WITHOUT ROWID` with a (sensor_id, ts) primary key stores rows
        // clustered in exactly the order the chart reads them. The separate ts
        // index is what makes rollup and pruning range scans instead of table
        // scans — both filter on time across all sensors.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sensors (
                id           INTEGER PRIMARY KEY,
                key          TEXT NOT NULL UNIQUE,
                name         TEXT NOT NULL,
                kind         TEXT NOT NULL,
                sensor_group TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS samples (
                sensor_id INTEGER NOT NULL REFERENCES sensors(id),
                ts        INTEGER NOT NULL,
                value     REAL    NOT NULL,
                PRIMARY KEY (sensor_id, ts)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);

            CREATE TABLE IF NOT EXISTS samples_minute (
                sensor_id INTEGER NOT NULL REFERENCES sensors(id),
                ts        INTEGER NOT NULL,
                avg_value REAL NOT NULL,
                min_value REAL NOT NULL,
                max_value REAL NOT NULL,
                PRIMARY KEY (sensor_id, ts)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS idx_samples_minute_ts ON samples_minute(ts);

            CREATE TABLE IF NOT EXISTS samples_hour (
                sensor_id INTEGER NOT NULL REFERENCES sensors(id),
                ts        INTEGER NOT NULL,
                avg_value REAL NOT NULL,
                min_value REAL NOT NULL,
                max_value REAL NOT NULL,
                PRIMARY KEY (sensor_id, ts)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS idx_samples_hour_ts ON samples_hour(ts);

            CREATE TABLE IF NOT EXISTS episodes (
                id                INTEGER PRIMARY KEY,
                started_at        INTEGER NOT NULL,
                ended_at          INTEGER,
                peak_temp         REAL,
                peak_pressure     INTEGER NOT NULL,
                mean_cpu          REAL NOT NULL,
                profile_name      TEXT NOT NULL,
                on_battery        INTEGER NOT NULL,
                external_displays INTEGER NOT NULL,
                fan_rpm_at_peak   TEXT NOT NULL,
                processes         TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_episodes_started ON episodes(started_at);

            CREATE TABLE IF NOT EXISTS spikes (
                id               INTEGER PRIMARY KEY,
                started_at       INTEGER NOT NULL,
                peaked_at        INTEGER NOT NULL,
                ended_at         INTEGER,
                from_temp        REAL NOT NULL,
                peak_temp        REAL NOT NULL,
                cpu_at_start     REAL NOT NULL,
                peak_cpu         REAL NOT NULL,
                hottest_group    TEXT NOT NULL,
                peak_fan_rpm     REAL NOT NULL,
                peak_fan_duty    REAL NOT NULL,
                profile_name     TEXT NOT NULL,
                profile_changed  INTEGER NOT NULL,
                on_battery       INTEGER NOT NULL,
                recorded_names   INTEGER NOT NULL,
                processes        TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_spikes_started ON spikes(started_at);

            CREATE TABLE IF NOT EXISTS sessions (
                id           INTEGER PRIMARY KEY,
                name         TEXT NOT NULL,
                started_at   INTEGER NOT NULL,
                ended_at     INTEGER,
                profile_name TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);

            CREATE TABLE IF NOT EXISTS profile_changes (
                ts           INTEGER PRIMARY KEY,
                profile_id   TEXT NOT NULL,
                profile_name TEXT NOT NULL,
                reason       TEXT NOT NULL
            );
            """)
        try database.setUserVersion(Self.schemaVersion)
    }

    private func loadSensorIDs() throws {
        let statement = try database.prepare("SELECT id, key FROM sensors")
        while try statement.step() {
            sensorIDs[statement.string(1)] = statement.int64(0)
        }
    }

    // MARK: - Meta

    private func meta(_ key: String) throws -> Int64? {
        let statement = try database.prepare("SELECT value FROM meta WHERE key = ?")
        statement.bind(1, key)
        return try statement.step() ? statement.int64(0) : nil
    }

    private func setMeta(_ key: String, _ value: Int64) throws {
        let statement = try database.prepare(
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        statement.bind(1, key).bind(2, value)
        try statement.run()
    }

    // MARK: - Writing

    /// Registers a sensor if it is new and returns its rowid. Re-registering an
    /// existing key refreshes the display name — sensor names come from a
    /// private API and can change between OS versions.
    @discardableResult
    public func register(_ sensor: SensorDescriptor) throws -> Int64 {
        if let id = sensorIDs[sensor.key] { return id }
        let insert = try database.prepare("""
            INSERT INTO sensors(key, name, kind, sensor_group) VALUES(?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET name = excluded.name,
                                           kind = excluded.kind,
                                           sensor_group = excluded.sensor_group
            """)
        insert.bind(1, sensor.key).bind(2, sensor.name)
              .bind(3, sensor.kind.rawValue).bind(4, sensor.group)
        try insert.run()

        let lookup = try database.prepare("SELECT id FROM sensors WHERE key = ?")
        lookup.bind(1, sensor.key)
        guard try lookup.step() else {
            throw HistoryError.sqlite("sensor \(sensor.key) vanished after insert")
        }
        let id = lookup.int64(0)
        sensorIDs[sensor.key] = id
        return id
    }

    /// One transaction per batch, not per sample.
    ///
    /// Two samples for the same sensor in the same second collapse — `ts` is
    /// whole seconds and the primary key includes it — so the later value wins.
    /// At a 1 Hz sample rate that is a rounding tie, not lost data.
    ///
    /// Non-finite values are dropped here as well as in `LiveWindow`: both tiers
    /// see the same batch and must agree about what is in it.
    public func insert(_ batches: [(date: Date, samples: [RecordedSample])]) throws {
        guard !batches.isEmpty else { return }
        var oldest = Int64.max
        try database.transaction {
            let insert = try database.prepare(
                "INSERT OR REPLACE INTO samples(sensor_id, ts, value) VALUES(?, ?, ?)")
            for batch in batches {
                let ts = Int64(batch.date.timeIntervalSince1970.rounded())
                for sample in batch.samples {
                    guard sample.value.isFinite else { continue }
                    let id = try register(sample.sensor)
                    insert.reset()
                    insert.bind(1, id).bind(2, ts).bind(3, sample.value)
                    try insert.run()
                    oldest = min(oldest, ts)
                }
            }
            try rewindRollup(toInclude: oldest)
        }
    }

    /// Winds the rollup watermarks back when a sample lands behind them.
    ///
    /// A batch buffered while writes were failing can be inserted long after its
    /// own timestamp — by then the rollup has already passed that minute and
    /// would never revisit it, while `prune` is entitled to delete it. Rewinding
    /// restores the invariant the whole retention scheme rests on: **nothing is
    /// deleted that has not been folded into the next tier.** Re-aggregating the
    /// buckets in between is idempotent, so the cost is a little work, not a
    /// wrong number.
    ///
    /// Both tiers, not just the minute one: a sample old enough to land behind
    /// the hour watermark would otherwise be rolled into a minute bucket that
    /// the hour rollup never revisits, and pruned at fourteen days having never
    /// reached the hour tier. That needs a fortnight-old write to happen, which
    /// is not a scenario worth *relying* on being impossible.
    private func rewindRollup(toInclude ts: Int64) throws {
        guard ts != .max else { return }
        for (key, bucket) in [(Self.minuteWatermark, Int64(60)), (Self.hourWatermark, Int64(3_600))] {
            guard let watermark = try meta(key), ts < watermark else { continue }
            try setMeta(key, (ts / bucket) * bucket)
        }
    }

    // MARK: - Rollup and retention

    private static let minuteWatermark = "rollup_minute_through"
    private static let hourWatermark = "rollup_hour_through"

    /// Fold every *completed* bucket into the next tier, then drop what has
    /// aged out. Idempotent: `INSERT OR REPLACE` plus a watermark means running
    /// it twice, or after a crash mid-run, produces the same rows.
    public func maintain(now: Date = Date()) throws {
        try rollup(from: .raw, to: .minute,
                   watermark: Self.minuteWatermark, bucket: 60, now: now)
        try rollup(from: .minute, to: .hour,
                   watermark: Self.hourWatermark, bucket: 3_600, now: now)
        try prune(now: now)
    }

    private func rollup(from source: Tier, to destination: Tier,
                        watermark: String, bucket: Int64, now: Date) throws {
        // Only whole buckets: the bucket containing `now` is still filling, and
        // averaging a partial minute would write a value that later samples
        // would contradict.
        let boundary = (Int64(now.timeIntervalSince1970) / bucket) * bucket
        let stored = try meta(watermark) ?? 0

        // A clock that steps backwards — an NTP correction, a bad wake — would
        // otherwise strand the watermark in the future: rollup would skip every
        // run until real time caught up, while `prune` deleted the samples
        // written in the meantime. Winding it back costs a re-aggregation of
        // buckets already written, which `INSERT OR REPLACE` makes a no-op.
        let start = min(stored, boundary)
        if start != stored { try setMeta(watermark, start) }
        guard boundary > start else { return }

        let columns = source.columns
        try database.transaction {
            let statement = try database.prepare("""
                INSERT OR REPLACE INTO \(destination.table)(sensor_id, ts, avg_value, min_value, max_value)
                SELECT sensor_id, (ts / \(bucket)) * \(bucket),
                       avg(\(columns.average)), min(\(columns.minimum)), max(\(columns.maximum))
                FROM \(source.table)
                WHERE ts >= ? AND ts < ?
                GROUP BY sensor_id, ts / \(bucket)
                """)
            statement.bind(1, start).bind(2, boundary)
            try statement.run()
            try setMeta(watermark, boundary)
        }
    }

    /// Drops what has aged out — but never ahead of the rollup.
    ///
    /// Retention alone would delete raw seconds two hours old whether or not
    /// they had been folded into minutes. A rollup that could not run must not
    /// be indistinguishable from one that ran and succeeded, so each tier is
    /// pruned only up to its own watermark: if rollup stalls, the tier grows
    /// past its retention instead of quietly losing data.
    private func prune(now: Date) throws {
        let seconds = Int64(now.timeIntervalSince1970)
        let minuteMark = try meta(Self.minuteWatermark) ?? 0
        let hourMark = try meta(Self.hourWatermark) ?? 0

        let cutoffs: [(table: String, cutoff: Int64)] = [
            ("samples", min(seconds - Int64(Self.rawRetention), minuteMark)),
            ("samples_minute", min(seconds - Int64(Self.minuteRetention), hourMark)),
            // Nothing downstream of the hour tier, so retention is the only bound.
            ("samples_hour", seconds - Int64(Self.hourRetention)),
        ]

        // Events are bounded by retention alone: nothing downstream aggregates
        // them, so there is no watermark to hold the deletion back. An event
        // still *open* is never deleted however old it is — it is the record of
        // something that has not finished, and `finalizeDanglingRecords` is what
        // closes those.
        let eventCutoff = seconds - Int64(Self.eventRetention)

        try database.transaction {
            for (table, cutoff) in cutoffs {
                let statement = try database.prepare("DELETE FROM \(table) WHERE ts < ?")
                statement.bind(1, cutoff)
                try statement.run()
            }

            // `ended_at IS NOT NULL`: a record still open is the record of
            // something that has not finished, whatever its age says.
            for table in ["episodes", "spikes", "sessions"] {
                let statement = try database.prepare(
                    "DELETE FROM \(table) WHERE started_at < ? AND ended_at IS NOT NULL")
                statement.bind(1, eventCutoff)
                try statement.run()
            }

            // Never the newest one. A profile change is not an event with a
            // duration — it is the statement "this profile from here on", so the
            // last row is what says which profile has been active ever since.
            // Ageing it out would leave the chart's first band unlabelled and
            // make the recorder write a duplicate transition on next launch.
            let changes = try database.prepare("""
                DELETE FROM profile_changes
                WHERE ts < ? AND ts < (SELECT max(ts) FROM profile_changes)
                """)
            changes.bind(1, eventCutoff)
            try changes.run()
        }
    }

    /// Pruning without rolling up first. Only a test wants this — it is how you
    /// check that retention cannot outrun aggregation.
    func pruneForTesting(now: Date) throws { try prune(now: now) }

    func rowCountForTesting(_ table: String) throws -> Int {
        let statement = try database.prepare("SELECT count(*) FROM \(table)")
        guard try statement.step() else { return 0 }
        return Int(statement.int64(0))
    }

    /// SQLite work done so far, in bytecode steps. What a throughput test should
    /// assert on instead of elapsed seconds: a plan that turned quadratic shows
    /// up here identically on a loaded machine and an idle one.
    var workUnitsForTesting: Int { database.workUnits }

    /// Makes every write fail, the way a full disk or a read-only volume does.
    ///
    /// The recorder's error paths — a spike that could not be closed, a buffer
    /// that could not be written — decide what the user is told and what state
    /// is left behind, and they are unreachable from a test otherwise. Reads go
    /// on working, so a test can still look at what the failure left on disk.
    func setWritesFailForTesting(_ failing: Bool) throws {
        try database.execute("PRAGMA query_only = \(failing ? 1 : 0)")
    }

    // MARK: - Reading

    /// The narrowest tier that still covers `from`. Raw is only kept for two
    /// hours, so anything older has to come from an aggregate — asking `samples`
    /// for yesterday would silently return an empty chart.
    private func tier(from: Date, now: Date) -> Tier {
        let age = now.timeIntervalSince(from)
        if age <= Self.rawRetention { return .raw }
        if age <= Self.minuteRetention { return .minute }
        return .hour
    }

    /// The tier row that *contains* `from`, rather than the first one at or after
    /// it.
    ///
    /// Aggregate rows are stored at bucket starts. Filtering on `ts >= from` with
    /// an unaligned `from` therefore drops the bucket the window opens inside —
    /// up to a minute of a day view, up to an hour of a month view, silently
    /// missing from the left edge. Snapping down includes it; a chart clips to
    /// its own x-domain and an export is more honest for carrying it.
    private func alignedStart(_ from: Date, tier: Tier) -> Int64 {
        let seconds = Int64(from.timeIntervalSince1970)
        return (seconds / tier.resolution) * tier.resolution
    }

    /// Bucket width that keeps a series inside `targetPoints` without ever
    /// claiming more resolution than the tier holds.
    ///
    /// Both divisions round *up*. Truncating the first one silently blew the
    /// budget whenever the span was between one and two times the target — a
    /// 1041-second window asked for 724 points came back with 1041, because
    /// 1041/724 truncates to a 1-second bucket. The caller's budget is a bound,
    /// not a suggestion.
    private func bucketSeconds(from: Date, to: Date, tier: Tier, targetPoints: Int) -> Int64 {
        let span = max(1, Int64(to.timeIntervalSince(from)))
        let points = Int64(max(1, targetPoints))
        let wanted = max(1, (span + points - 1) / points)
        let rounded = ((wanted + tier.resolution - 1) / tier.resolution) * tier.resolution
        return max(tier.resolution, rounded)
    }

    /// The resolution a query over this window can actually deliver — an export
    /// says which tier it came from rather than implying per-second data it
    /// doesn't have.
    public func resolutionSeconds(from: Date, now: Date = Date()) -> Int {
        Int(tier(from: from, now: now).resolution)
    }

    /// SQLite binds a bounded number of parameters per statement, and the sensor
    /// catalogue only grows — every sensor any OS version ever reported stays in
    /// it. An export asks for all of them at once, so the query is chunked
    /// rather than trusting that the machine will never have too many.
    private static let maxKeysPerQuery = 400

    /// One series per sensor key. Keys that have never been recorded are absent
    /// from the result rather than present and empty.
    public func series(keys: [String], from: Date, to: Date,
                       targetPoints: Int = 600, now: Date = Date()) throws -> [Series] {
        guard !keys.isEmpty else { return [] }
        guard keys.count <= Self.maxKeysPerQuery else {
            // Chunks hold disjoint key sets, so concatenating them is the same
            // result one oversized statement would have produced.
            return try stride(from: 0, to: keys.count, by: Self.maxKeysPerQuery)
                .flatMap { offset -> [Series] in
                    let chunk = Array(keys[offset..<min(offset + Self.maxKeysPerQuery, keys.count)])
                    return try series(keys: chunk, from: from, to: to,
                                      targetPoints: targetPoints, now: now)
                }
        }
        let tier = tier(from: from, now: now)
        let bucket = bucketSeconds(from: from, to: to, tier: tier, targetPoints: targetPoints)
        let columns = tier.columns
        let placeholders = keys.map { _ in "?" }.joined(separator: ",")

        let statement = try database.prepare("""
            SELECT s.key, s.name, s.kind,
                   (t.ts / \(bucket)) * \(bucket) AS bucket,
                   avg(t.\(columns.average)), min(t.\(columns.minimum)), max(t.\(columns.maximum))
            FROM \(tier.table) t JOIN sensors s ON s.id = t.sensor_id
            WHERE s.key IN (\(placeholders)) AND t.ts >= ? AND t.ts < ?
            GROUP BY s.key, bucket
            ORDER BY s.key, bucket
            """)
        var index: Int32 = 1
        for key in keys { statement.bind(index, key); index += 1 }
        statement.bind(index, alignedStart(from, tier: tier))
        statement.bind(index + 1, Int64(to.timeIntervalSince1970))

        return try collectSeries(statement)
    }

    /// One series per display group: the trace of the *hottest sensor in the
    /// group*, bucketed. A Mac reports a dozen die sensors; a line per sensor is
    /// unreadable, and averaging them hides the one actually driving the fans.
    ///
    /// Two levels of aggregation, and they are not interchangeable. The inner
    /// one collapses sensors at each instant — "how hot was this group then?".
    /// The outer one collapses time within the bucket — "and what did that look
    /// like over these twelve seconds?". Doing both at once, as this first did,
    /// makes `max` swallow everything: a group's average and minimum both came
    /// back as the bucket maximum, so every group line was drawn hotter than the
    /// hardware ever was and the band around it was meaningless.
    public func groupSeries(groups: [String], from: Date, to: Date,
                            targetPoints: Int = 600, now: Date = Date()) throws -> [Series] {
        guard !groups.isEmpty else { return [] }
        let tier = tier(from: from, now: now)
        let bucket = bucketSeconds(from: from, to: to, tier: tier, targetPoints: targetPoints)
        let columns = tier.columns
        let placeholders = groups.map { _ in "?" }.joined(separator: ",")

        let statement = try database.prepare("""
            SELECT sensor_group, sensor_group, min(kind), bucket,
                   avg(hottest_avg), min(hottest_min), max(hottest_max)
            FROM (
                SELECT s.sensor_group AS sensor_group, min(s.kind) AS kind,
                       (t.ts / \(bucket)) * \(bucket) AS bucket,
                       max(t.\(columns.average)) AS hottest_avg,
                       max(t.\(columns.minimum)) AS hottest_min,
                       max(t.\(columns.maximum)) AS hottest_max
                FROM \(tier.table) t JOIN sensors s ON s.id = t.sensor_id
                WHERE s.sensor_group IN (\(placeholders)) AND t.ts >= ? AND t.ts < ?
                GROUP BY s.sensor_group, t.ts
            )
            GROUP BY sensor_group, bucket
            ORDER BY sensor_group, bucket
            """)
        var index: Int32 = 1
        for group in groups { statement.bind(index, group); index += 1 }
        statement.bind(index, alignedStart(from, tier: tier))
        statement.bind(index + 1, Int64(to.timeIntervalSince1970))

        return try collectSeries(statement)
    }

    private func collectSeries(_ statement: Statement) throws -> [Series] {
        var order: [String] = []
        var names: [String: (name: String, kind: SensorKind)] = [:]
        var points: [String: [SeriesPoint]] = [:]

        while try statement.step() {
            let id = statement.string(0)
            if names[id] == nil {
                order.append(id)
                names[id] = (statement.string(1),
                             SensorKind(rawValue: statement.string(2)) ?? .temperature)
            }
            points[id, default: []].append(
                SeriesPoint(date: Date(timeIntervalSince1970: Double(statement.int64(3))),
                            average: statement.double(4),
                            minimum: statement.double(5),
                            maximum: statement.double(6)))
        }

        return order.map { id in
            Series(id: id,
                   name: names[id]?.name ?? id,
                   kind: names[id]?.kind ?? .temperature,
                   points: points[id] ?? [])
        }
    }

    /// Every sensor ever recorded, for the export column list and the picker.
    public func knownSensors() throws -> [SensorDescriptor] {
        let statement = try database.prepare(
            "SELECT key, name, kind, sensor_group FROM sensors ORDER BY sensor_group, name")
        var result: [SensorDescriptor] = []
        while try statement.step() {
            result.append(SensorDescriptor(key: statement.string(0),
                                           name: statement.string(1),
                                           kind: SensorKind(rawValue: statement.string(2)) ?? .temperature,
                                           group: statement.string(3)))
        }
        return result
    }

    /// Groups that actually have data, so the chart never offers a toggle that
    /// would draw nothing.
    public func knownGroups() throws -> [String] {
        let statement = try database.prepare(
            "SELECT DISTINCT sensor_group FROM sensors ORDER BY sensor_group")
        var result: [String] = []
        while try statement.step() { result.append(statement.string(0)) }
        return result
    }

    // MARK: - Episodes

    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    /// Writes a new episode (or updates an existing one when `id` is non-zero)
    /// and returns its id. An episode is written when it opens, so a crash
    /// mid-episode still leaves a record — with a null end, which the UI reads
    /// as "in progress".
    @discardableResult
    public func save(_ episode: ThrottleEpisode) throws -> Int64 {
        let fans = try Self.jsonEncoder.encode(
            Dictionary(uniqueKeysWithValues: episode.fanRPMAtPeak.map { (String($0.key), $0.value) }))
        let processes = try Self.jsonEncoder.encode(episode.processes)

        if episode.id != 0 {
            let update = try database.prepare("""
                UPDATE episodes SET ended_at = ?, peak_temp = ?, peak_pressure = ?, mean_cpu = ?,
                                    profile_name = ?, on_battery = ?, external_displays = ?,
                                    fan_rpm_at_peak = ?, processes = ?
                WHERE id = ?
                """)
            update.bind(1, episode.end.map { Int64($0.timeIntervalSince1970) })
                  .bind(2, episode.peakTempC)
                  .bind(3, Int64(episode.peakPressure))
                  .bind(4, episode.meanCPUPercent)
                  .bind(5, episode.profileName)
                  .bind(6, Int64(episode.onBattery ? 1 : 0))
                  .bind(7, Int64(episode.externalDisplayCount))
                  .bind(8, String(decoding: fans, as: UTF8.self))
                  .bind(9, String(decoding: processes, as: UTF8.self))
                  .bind(10, episode.id)
            try update.run()
            return episode.id
        }

        let insert = try database.prepare("""
            INSERT INTO episodes(started_at, ended_at, peak_temp, peak_pressure, mean_cpu,
                                 profile_name, on_battery, external_displays,
                                 fan_rpm_at_peak, processes)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insert.bind(1, Int64(episode.start.timeIntervalSince1970))
              .bind(2, episode.end.map { Int64($0.timeIntervalSince1970) })
              .bind(3, episode.peakTempC)
              .bind(4, Int64(episode.peakPressure))
              .bind(5, episode.meanCPUPercent)
              .bind(6, episode.profileName)
              .bind(7, Int64(episode.onBattery ? 1 : 0))
              .bind(8, Int64(episode.externalDisplayCount))
              .bind(9, String(decoding: fans, as: UTF8.self))
              .bind(10, String(decoding: processes, as: UTF8.self))
        try insert.run()
        return database.lastInsertRowID
    }

    /// Episodes overlapping the window — one that started before `from` and is
    /// still running belongs on the chart.
    public func episodes(from: Date, to: Date) throws -> [ThrottleEpisode] {
        let statement = try database.prepare("""
            SELECT id, started_at, ended_at, peak_temp, peak_pressure, mean_cpu,
                   profile_name, on_battery, external_displays, fan_rpm_at_peak, processes
            FROM episodes
            WHERE started_at < ? AND (ended_at IS NULL OR ended_at >= ?)
            ORDER BY started_at DESC
            """)
        statement.bind(1, Int64(to.timeIntervalSince1970))
        statement.bind(2, Int64(from.timeIntervalSince1970))

        var result: [ThrottleEpisode] = []
        while try statement.step() {
            let fans = (try? Self.jsonDecoder.decode([String: Double].self,
                                                     from: Data(statement.string(9).utf8))) ?? [:]
            let processes = (try? Self.jsonDecoder.decode([ThrottleEpisode.ProcessShare].self,
                                                          from: Data(statement.string(10).utf8))) ?? []
            result.append(ThrottleEpisode(
                id: statement.int64(0),
                start: Date(timeIntervalSince1970: Double(statement.int64(1))),
                end: statement.optionalInt64(2).map { Date(timeIntervalSince1970: Double($0)) },
                peakTempC: statement.optionalDouble(3),
                peakPressure: Int(statement.int64(4)),
                meanCPUPercent: statement.double(5),
                profileName: statement.string(6),
                onBattery: statement.int64(7) != 0,
                externalDisplayCount: Int(statement.int64(8)),
                fanRPMAtPeak: Dictionary(uniqueKeysWithValues:
                    fans.compactMap { key, value in Int(key).map { ($0, value) } }),
                processes: processes))
        }
        return result
    }

    // MARK: - Spikes

    /// Writes a new spike (or updates an existing one when `id` is non-zero) and
    /// returns its id. Written when the rise is declared, for the same reason an
    /// episode is: a crash mid-spike still leaves a record, with a null end that
    /// reads as "still elevated".
    @discardableResult
    public func save(_ spike: Spike) throws -> Int64 {
        let processes = try Self.jsonEncoder.encode(spike.processes)

        if spike.id != 0 {
            let update = try database.prepare("""
                UPDATE spikes SET peaked_at = ?, ended_at = ?, from_temp = ?, peak_temp = ?,
                                  cpu_at_start = ?, peak_cpu = ?, hottest_group = ?,
                                  peak_fan_rpm = ?, peak_fan_duty = ?, profile_name = ?,
                                  profile_changed = ?, on_battery = ?, recorded_names = ?,
                                  processes = ?
                WHERE id = ?
                """)
            update.bind(1, Int64(spike.peak.timeIntervalSince1970))
                  .bind(2, spike.end.map { Int64($0.timeIntervalSince1970) })
                  .bind(3, spike.fromTempC)
                  .bind(4, spike.peakTempC)
                  .bind(5, spike.cpuAtStartPercent)
                  .bind(6, spike.peakCPUPercent)
                  .bind(7, spike.hottestGroup)
                  .bind(8, spike.peakFanRPM)
                  .bind(9, spike.peakFanDutyPercent)
                  .bind(10, spike.profileName)
                  .bind(11, Int64(spike.profileChanged ? 1 : 0))
                  .bind(12, Int64(spike.onBattery ? 1 : 0))
                  .bind(13, Int64(spike.recordedProcessNames ? 1 : 0))
                  .bind(14, String(decoding: processes, as: UTF8.self))
                  .bind(15, spike.id)
            try update.run()
            return spike.id
        }

        let insert = try database.prepare("""
            INSERT INTO spikes(started_at, peaked_at, ended_at, from_temp, peak_temp,
                               cpu_at_start, peak_cpu, hottest_group, peak_fan_rpm,
                               peak_fan_duty, profile_name, profile_changed, on_battery,
                               recorded_names, processes)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insert.bind(1, Int64(spike.start.timeIntervalSince1970))
              .bind(2, Int64(spike.peak.timeIntervalSince1970))
              .bind(3, spike.end.map { Int64($0.timeIntervalSince1970) })
              .bind(4, spike.fromTempC)
              .bind(5, spike.peakTempC)
              .bind(6, spike.cpuAtStartPercent)
              .bind(7, spike.peakCPUPercent)
              .bind(8, spike.hottestGroup)
              .bind(9, spike.peakFanRPM)
              .bind(10, spike.peakFanDutyPercent)
              .bind(11, spike.profileName)
              .bind(12, Int64(spike.profileChanged ? 1 : 0))
              .bind(13, Int64(spike.onBattery ? 1 : 0))
              .bind(14, Int64(spike.recordedProcessNames ? 1 : 0))
              .bind(15, String(decoding: processes, as: UTF8.self))
        try insert.run()
        return database.lastInsertRowID
    }

    /// Spikes overlapping the window, newest first — the same containment rule
    /// as episodes, so one still in progress belongs to every window it reaches.
    public func spikes(from: Date, to: Date, limit: Int = 200) throws -> [Spike] {
        let statement = try database.prepare("""
            SELECT id, started_at, peaked_at, ended_at, from_temp, peak_temp,
                   cpu_at_start, peak_cpu, hottest_group, peak_fan_rpm, peak_fan_duty,
                   profile_name, profile_changed, on_battery, recorded_names, processes
            FROM spikes
            WHERE started_at < ? AND (ended_at IS NULL OR ended_at >= ?)
            ORDER BY started_at DESC
            LIMIT ?
            """)
        statement.bind(1, Int64(to.timeIntervalSince1970))
        statement.bind(2, Int64(from.timeIntervalSince1970))
        statement.bind(3, Int64(max(1, limit)))

        var result: [Spike] = []
        while try statement.step() {
            let processes = (try? Self.jsonDecoder.decode([ProcessShare].self,
                                                          from: Data(statement.string(15).utf8))) ?? []
            result.append(Spike(
                id: statement.int64(0),
                start: Date(timeIntervalSince1970: Double(statement.int64(1))),
                peak: Date(timeIntervalSince1970: Double(statement.int64(2))),
                end: statement.optionalInt64(3).map { Date(timeIntervalSince1970: Double($0)) },
                fromTempC: statement.double(4),
                peakTempC: statement.double(5),
                cpuAtStartPercent: statement.double(6),
                peakCPUPercent: statement.double(7),
                hottestGroup: statement.string(8),
                peakFanRPM: statement.double(9),
                peakFanDutyPercent: statement.double(10),
                profileName: statement.string(11),
                profileChanged: statement.int64(12) != 0,
                onBattery: statement.int64(13) != 0,
                recordedProcessNames: statement.int64(14) != 0,
                processes: processes))
        }
        return result
    }

    // MARK: - Attribution

    /// Empties one record's application list.
    ///
    /// Used when the user switches attribution off while an event is still open
    /// (DESIGN §5.4). Scoped to a single id on purpose: this is "stop collecting
    /// mine", not "delete what I already have" — that is `clear()`, which asks
    /// first.
    public func eraseProcessNames(episode id: Int64) throws {
        try eraseProcessNames(table: "episodes", id: id)
    }

    public func eraseProcessNames(spike id: Int64) throws {
        try eraseProcessNames(table: "spikes", id: id)
    }

    /// `table` is a literal this file supplies, never anything from outside.
    private func eraseProcessNames(table: String, id: Int64) throws {
        let statement = try database.prepare("UPDATE \(table) SET processes = '[]' WHERE id = ?")
        statement.bind(1, id)
        try statement.run()
    }

    // MARK: - Sessions

    @discardableResult
    public func save(_ session: RecordingSession) throws -> Int64 {
        if session.id != 0 {
            let update = try database.prepare(
                "UPDATE sessions SET name = ?, ended_at = ?, profile_name = ? WHERE id = ?")
            update.bind(1, session.name)
                  .bind(2, session.end.map { Int64($0.timeIntervalSince1970) })
                  .bind(3, session.profileName)
                  .bind(4, session.id)
            try update.run()
            return session.id
        }
        let insert = try database.prepare(
            "INSERT INTO sessions(name, started_at, ended_at, profile_name) VALUES(?, ?, ?, ?)")
        insert.bind(1, session.name)
              .bind(2, Int64(session.start.timeIntervalSince1970))
              .bind(3, session.end.map { Int64($0.timeIntervalSince1970) })
              .bind(4, session.profileName)
        try insert.run()
        return database.lastInsertRowID
    }

    public func sessions(from: Date, to: Date) throws -> [RecordingSession] {
        let statement = try database.prepare("""
            SELECT id, name, started_at, ended_at, profile_name FROM sessions
            WHERE started_at < ? AND (ended_at IS NULL OR ended_at >= ?)
            ORDER BY started_at DESC
            """)
        statement.bind(1, Int64(to.timeIntervalSince1970))
        statement.bind(2, Int64(from.timeIntervalSince1970))

        var result: [RecordingSession] = []
        while try statement.step() {
            result.append(RecordingSession(
                id: statement.int64(0),
                name: statement.string(1),
                start: Date(timeIntervalSince1970: Double(statement.int64(2))),
                end: statement.optionalInt64(3).map { Date(timeIntervalSince1970: Double($0)) },
                profileName: statement.string(4)))
        }
        return result
    }

    // MARK: - Profile changes

    public func record(_ change: ProfileChange) throws {
        let statement = try database.prepare("""
            INSERT OR REPLACE INTO profile_changes(ts, profile_id, profile_name, reason)
            VALUES(?, ?, ?, ?)
            """)
        statement.bind(1, Int64(change.date.timeIntervalSince1970))
                 .bind(2, change.profileID)
                 .bind(3, change.profileName)
                 .bind(4, change.reason)
        try statement.run()
    }

    /// Changes inside the window, plus the one immediately before it — without
    /// that leading row the first band on the chart would have no label.
    public func profileChanges(from: Date, to: Date) throws -> [ProfileChange] {
        // Start at the last change before the window when there is one, and at
        // the window edge when there isn't. (A `UNION ALL` of two ordered,
        // limited selects would read more naturally, but SQLite rejects ORDER BY
        // inside a compound branch.)
        let statement = try database.prepare("""
            SELECT ts, profile_id, profile_name, reason FROM profile_changes
            WHERE ts < ?
              AND ts >= coalesce((SELECT max(ts) FROM profile_changes WHERE ts < ?), ?)
            ORDER BY ts
            """)
        statement.bind(1, Int64(to.timeIntervalSince1970))
        statement.bind(2, Int64(from.timeIntervalSince1970))
        statement.bind(3, Int64(from.timeIntervalSince1970))

        var result: [ProfileChange] = []
        while try statement.step() {
            result.append(ProfileChange(date: Date(timeIntervalSince1970: Double(statement.int64(0))),
                                        profileID: statement.string(1),
                                        profileName: statement.string(2),
                                        reason: statement.string(3)))
        }
        return result
    }

    /// The most recently recorded profile, so the recorder doesn't write a
    /// duplicate row on every launch.
    public func lastProfileChange() throws -> ProfileChange? {
        let statement = try database.prepare(
            "SELECT ts, profile_id, profile_name, reason FROM profile_changes ORDER BY ts DESC LIMIT 1")
        guard try statement.step() else { return nil }
        return ProfileChange(date: Date(timeIntervalSince1970: Double(statement.int64(0))),
                             profileID: statement.string(1),
                             profileName: statement.string(2),
                             reason: statement.string(3))
    }

    // MARK: - Recovery

    /// Closes records left open by a crash, a force quit, or sleep.
    ///
    /// An episode and a session are both written when they *open*, so a record
    /// survives even if the app never gets to close it. The cost is that a
    /// dangling row reads as "still running" forever — and, because an open
    /// episode belongs to every later window, it would appear on every chart
    /// from then on. They are closed at the last sample actually recorded,
    /// which is when observation really stopped, never at a start-of-day `now`
    /// that would invent hours of episode.
    @discardableResult
    public func finalizeDanglingRecords(now: Date = Date()) throws -> (episodes: Int, sessions: Int, spikes: Int) {
        let observedUntil = Int64((try newestSample() ?? now).timeIntervalSince1970)

        var closedEpisodes = 0
        var closedSessions = 0
        var closedSpikes = 0
        try database.transaction {
            // `max(started_at, ?)` because a zero-length record is honest and a
            // negative-length one is a bug someone would have to debug later.
            let episodes = try database.prepare(
                "UPDATE episodes SET ended_at = max(started_at, ?) WHERE ended_at IS NULL")
            episodes.bind(1, observedUntil)
            try episodes.run()
            closedEpisodes = database.changes

            let sessions = try database.prepare(
                "UPDATE sessions SET ended_at = max(started_at, ?) WHERE ended_at IS NULL")
            sessions.bind(1, observedUntil)
            try sessions.run()
            closedSessions = database.changes

            // `peaked_at` rather than `started_at`: a spike's peak is always at
            // or after its start, so this is the bound that keeps end ≥ peak ≥
            // start — a record whose peak sits outside its own span would break
            // every rate this app computes from it.
            let spikes = try database.prepare(
                "UPDATE spikes SET ended_at = max(peaked_at, ?) WHERE ended_at IS NULL")
            spikes.bind(1, observedUntil)
            try spikes.run()
            closedSpikes = database.changes
        }
        return (closedEpisodes, closedSessions, closedSpikes)
    }

    // MARK: - Housekeeping

    /// Size on disk, WAL and shared-memory files included — an app that quietly
    /// grows a database on someone's SSD should at least say how big it is.
    public func byteSize() -> Int64 {
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        return paths.reduce(into: Int64(0)) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    /// How far back the record reaches, across all three tiers.
    public func oldestSample() throws -> Date? { try extremeSample("min") }

    /// How far forward it reaches — "when did observation stop?", which is what
    /// a record left open by a crash should be closed at.
    public func newestSample() throws -> Date? { try extremeSample("max") }

    /// One query shape for both ends. `aggregate` is a literal this file
    /// supplies, never anything that reached it from outside.
    private func extremeSample(_ aggregate: String) throws -> Date? {
        let statement = try database.prepare("""
            SELECT \(aggregate)(ts) FROM (
                SELECT \(aggregate)(ts) AS ts FROM samples_hour
                UNION ALL SELECT \(aggregate)(ts) FROM samples_minute
                UNION ALL SELECT \(aggregate)(ts) FROM samples
            )
            """)
        guard try statement.step(), !statement.isNull(0) else { return nil }
        return Date(timeIntervalSince1970: Double(statement.int64(0)))
    }

    /// Everything, including the sensor list — a "clear history" that left the
    /// catalogue behind would still name every app and sensor the user has run.
    public func clear() throws {
        try database.transaction {
            for table in ["samples", "samples_minute", "samples_hour",
                          "episodes", "spikes", "sessions", "profile_changes", "sensors", "meta"] {
                try database.execute("DELETE FROM \(table)")
            }
        }
        sensorIDs.removeAll()
        // Outside the transaction: VACUUM cannot run inside one.
        try database.execute("VACUUM")
    }
}
