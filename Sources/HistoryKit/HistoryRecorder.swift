import Foundation
import FanKit

/// Owns the history database and everything that writes to it.
///
/// An actor for one reason: SQLite work must not run on the main thread, and a
/// single owner is what lets `HistoryStore` stay a plain non-`Sendable` class
/// with one connection. Every UI read goes through here too, so there is never
/// a second connection to reason about.
public actor HistoryRecorder {

    /// Samples are buffered and written in one transaction per flush rather
    /// than one transaction per tick (DESIGN §5.1).
    public static let flushInterval: TimeInterval = 10
    /// Rollup and pruning are watermark-bounded, so this is cheap; a minute is
    /// often enough that the raw tier never overshoots its two hours by much.
    public static let maintenanceInterval: TimeInterval = 60

    /// A batch is one tick. An hour of them at the 1 Hz control rate is the
    /// most a failing disk can hold onto before the oldest are dropped — enough
    /// to ride out a transient error, bounded enough that a permanent one
    /// cannot grow memory without limit.
    public static let maxBufferedBatches = 3_600

    public struct Status: Sendable, Equatable {
        public let isRecording: Bool
        /// Why history is unavailable, when it is. Surfaced, never swallowed.
        public let problem: String?
        public let byteSize: Int64
        public let oldestSample: Date?
        /// Ticks waiting to be written, and ticks given up on. Both are reported
        /// rather than inferred from a gap in a chart.
        public let pendingBatches: Int
        public let droppedBatches: Int

        /// A synthesised status, so a caller can render its failure states
        /// without having to arrange a failing disk.
        public init(isRecording: Bool, problem: String?, byteSize: Int64,
                    oldestSample: Date?, pendingBatches: Int, droppedBatches: Int) {
            self.isRecording = isRecording
            self.problem = problem
            self.byteSize = byteSize
            self.oldestSample = oldestSample
            self.pendingBatches = pendingBatches
            self.droppedBatches = droppedBatches
        }
    }

    /// Where the database lives. `nonisolated` because it is fixed at
    /// construction: making callers await an actor hop for a constant would be
    /// theatre. Exposed because the UI shows it — a path the app will not tell
    /// you is a path you cannot go and inspect.
    public nonisolated let url: URL
    private var store: HistoryStore?
    private var didAttemptOpen = false

    /// Why the database could not be opened, why the buffered samples could not
    /// be written, and why an event row could not be.
    ///
    /// Kept apart because they are cleared by different things: a successful
    /// buffer write used to clear `problem` outright, so a spike whose close had
    /// just failed reported a healthy recorder over a row still marked "in
    /// progress" on disk. A failure one subsystem could not recover from must not
    /// be erased by another subsystem succeeding. Reported worst-first — a
    /// database that never opened explains everything after it.
    private var openProblem: String?
    private var bufferProblem: String?
    private var eventProblem: String?
    private var problem: String? { openProblem ?? bufferProblem ?? eventProblem }

    private var buffer: [(date: Date, samples: [RecordedSample])] = []
    private var droppedBatches = 0
    private var lastFlush = Date.distantPast
    private var lastMaintenance = Date.distantPast

    private var detector = ThrottleDetector()
    private var spikeDetector = SpikeDetector()
    private var openEpisodeID: Int64 = 0
    private var openSpikeID: Int64 = 0
    /// The one event row of each kind that is still owed to the database.
    ///
    /// Samples are retried on the next flush; event rows used to be dropped with
    /// nothing but a message left behind, and the record that mattered most was
    /// the one most likely to be lost — a spike's *close* is the write that turns
    /// "still elevated" into a finished record, and losing it left the row open
    /// until the next launch swept it. At most one of each is outstanding: a
    /// later state of the same record supersedes the one before it, so this is a
    /// bounded amount of memory rather than a queue that can grow.
    private var unwrittenSpike: Spike?
    private var unwrittenEpisode: ThrottleEpisode?
    private var openSession: RecordingSession?
    private var lastProfileID: String?

    /// Process attribution is opt-in (DESIGN §5.4). The recorder refuses to
    /// store names when it is off, rather than trusting callers to filter.
    public private(set) var recordsProcessNames: Bool

    public init(url: URL = HistoryRecorder.defaultURL(), recordsProcessNames: Bool = false) {
        self.url = url
        self.recordsProcessNames = recordsProcessNames
        spikeDetector.setRecordsProcessNames(recordsProcessNames)
    }

    /// `~/Library/Application Support/FanControl/history.sqlite` — the same
    /// private directory the configuration lives in, never a shared location.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("FanControl/history.sqlite")
    }

    /// Turning attribution off means *forget*, not *stop adding*.
    ///
    /// Both detectors discard what they have already collected for the event in
    /// progress, and the open rows are rewritten without their names — otherwise
    /// the record on disk would keep the applications gathered before the user
    /// said stop, and go on carrying them into every later export.
    public func setRecordsProcessNames(_ enabled: Bool) {
        recordsProcessNames = enabled
        // Each spike also records whether names were being collected while it
        // happened, so an empty attribution list can be read years later without
        // consulting a setting that has since changed.
        spikeDetector.setRecordsProcessNames(enabled)
        detector.setRecordsProcessNames(enabled)
        guard !enabled else { return }
        forgetRecordedNames()
    }

    /// Strips names from the rows that are **still being written**.
    ///
    /// Deliberately not every row on disk. An event in progress is still being
    /// collected, so leaving its names would be collection continuing after the
    /// user said stop; a completed record is data the user already has, and a
    /// toggle that silently destroyed it would be a delete button wearing a
    /// switch's clothes. Removing the history is what *Clear History* is for,
    /// and it asks first.
    ///
    /// Without this the row would still be cleaned on the next tick — the
    /// detectors have already forgotten, so the next write carries nothing — but
    /// "next tick" is up to five seconds of the names sitting in a file the user
    /// could export in the meantime.
    private func forgetRecordedNames() {
        guard let store = connected() else { return }
        do {
            if openEpisodeID != 0 { try store.eraseProcessNames(episode: openEpisodeID) }
            if openSpikeID != 0 { try store.eraseProcessNames(spike: openSpikeID) }
        } catch {
            eventProblem = error.localizedDescription
        }
        // A record waiting to be written must lose them too, or the retry would
        // put back the names this call just took out.
        unwrittenSpike?.processes = []
        unwrittenEpisode?.processes = []
    }

    /// Opened lazily and only once: if the database can't be opened, history is
    /// off and says why, rather than retrying on every tick.
    private func connected() -> HistoryStore? {
        if let store { return store }
        guard !didAttemptOpen else { return nil }
        didAttemptOpen = true
        do {
            let opened = try HistoryStore(url: url)
            // A previous run may have been killed mid-episode. Left alone, that
            // row reads as "still running" forever and lands on every future
            // chart, because an open episode belongs to every later window.
            try opened.finalizeDanglingRecords()
            store = opened
            return opened
        } catch {
            openProblem = error.localizedDescription
            return nil
        }
    }

    public func status() -> Status {
        let store = connected()
        return Status(isRecording: store != nil,
                      problem: problem,
                      byteSize: store?.byteSize() ?? 0,
                      oldestSample: (try? store?.oldestSample()) ?? nil,
                      pendingBatches: buffer.count,
                      droppedBatches: droppedBatches)
    }

    // MARK: - Recording

    /// Which profile is active and why, as of this tick. Only transitions are
    /// stored; the caller passes it every tick rather than having to notice.
    public struct ProfileState: Sendable, Equatable {
        public let id: String
        public let name: String
        public let reason: String

        public init(id: String, name: String, reason: String) {
            self.id = id
            self.name = name
            self.reason = reason
        }
    }

    /// One tick, one hop: buffer the samples, run throttle detection, note the
    /// active profile, and flush when due. A separate call per concern would be
    /// a separate actor hop per concern, on the main thread's critical path.
    /// - Parameter spike: sudden-rise detection for this tick. Optional because
    ///   a caller recording samples for their own sake — a test, an import — has
    ///   no thermal context to give, and inventing one would manufacture spikes
    ///   that never happened.
    public func record(samples: [RecordedSample], at date: Date,
                       throttle: ThrottleDetector.Input,
                       spike: SpikeDetector.Input? = nil,
                       profile: ProfileState? = nil) {
        guard connected() != nil else { return }

        if !samples.isEmpty {
            buffer.append((date: date, samples: samples))
            trimBuffer()
        }

        var input = throttle
        if !recordsProcessNames { input.processes = [] }
        handle(detector.update(input))

        if var spikeInput = spike {
            if !recordsProcessNames { spikeInput.processes = [] }
            handle(spikeDetector.update(spikeInput))
        }

        if let profile { recordProfile(profile, at: date) }

        // `abs`, so a clock stepped backwards still flushes. Left as a forward
        // difference, a correction — an NTP step, a bad wake — strands `lastFlush`
        // in the future and the buffer stops being written until real time
        // catches up, dropping the oldest ticks once it fills. The rollup
        // watermark winds itself back for exactly this reason; so does this.
        if abs(date.timeIntervalSince(lastFlush)) >= Self.flushInterval {
            flush(now: date)
        }
    }

    /// Drops the oldest ticks once the buffer is full, and counts them. A chart
    /// with a gap in it should be explainable by something the app can tell you,
    /// not by memory it quietly threw away.
    private func trimBuffer() {
        guard buffer.count > Self.maxBufferedBatches else { return }
        let excess = buffer.count - Self.maxBufferedBatches
        buffer.removeFirst(excess)
        droppedBatches += excess
    }

    private func handle(_ event: ThrottleDetector.Event) {
        switch event {
        case .none:
            break
        case .opened(var episode):
            // A new record. The previous id is spent whether or not its last
            // write landed, and clearing it *before* the write is what stops a
            // failure here leaving the old row's id attached to this episode:
            // every later update would then have been written over a different
            // episode's row.
            openEpisodeID = 0
            episode.id = 0
            // Written the moment it opens, so a crash mid-episode still leaves a
            // record — with a null end, which reads as "in progress".
            write(episode, closed: false)
        case .updated(var episode):
            episode.id = openEpisodeID
            write(episode, closed: false)
        case .closed(var episode):
            episode.id = openEpisodeID
            write(episode, closed: true)
        }
    }

    /// Same lifecycle as an episode, and for the same reason: written on open so
    /// a crash mid-spike still leaves a record that `finalizeDanglingRecords`
    /// can close honestly.
    private func handle(_ event: SpikeDetector.Event) {
        switch event {
        case .none:
            break
        case .opened(var spike):
            openSpikeID = 0
            spike.id = 0
            write(spike, closed: false)
        case .updated(var spike):
            spike.id = openSpikeID
            write(spike, closed: false)
        case .closed(var spike):
            spike.id = openSpikeID
            write(spike, closed: true)
        }
    }

    /// Writes one event row, keeping it to retry if the write fails.
    ///
    /// - Parameter closed: whether this is the record's final state. A closed
    ///   record's id is spent either way: if the write failed, the retry carries
    ///   the id inside the record, so a spike that opens in the meantime cannot
    ///   have the stale close written over its row.
    /// - Parameter current: whether this is the event the recorder is tracking
    ///   *now*. False when a retry lands a record the detector has already moved
    ///   on from: writing an old close must not reset the id of the spike that
    ///   has opened since, or that spike's next tick inserts a second row for
    ///   itself instead of rewriting its own.
    private func write(_ spike: Spike, closed: Bool, current: Bool = true) {
        guard let store = connected() else { return }
        do {
            let id = try store.save(spike)
            if current { openSpikeID = closed ? 0 : id }
            // Only if this *is* the record that was owed. A later spike writing
            // successfully says nothing about an earlier one's close, and
            // clearing on any success is how that close was lost a second time —
            // the retry existed, and the first write after the disk came back
            // threw it away. `start` identifies the record; the id may still be
            // zero on both if the row was never inserted.
            if unwrittenSpike?.start == spike.start { unwrittenSpike = nil }
            clearEventProblemIfNothingOutstanding()
        } catch {
            if closed, current { openSpikeID = 0 }
            if supersedes(spike, unwrittenSpike) { unwrittenSpike = spike }
            eventProblem = error.localizedDescription
        }
    }

    private func write(_ episode: ThrottleEpisode, closed: Bool, current: Bool = true) {
        guard let store = connected() else { return }
        do {
            let id = try store.save(episode)
            if current { openEpisodeID = closed ? 0 : id }
            if unwrittenEpisode?.start == episode.start { unwrittenEpisode = nil }
            clearEventProblemIfNothingOutstanding()
        } catch {
            if closed, current { openEpisodeID = 0 }
            if supersedes(episode, unwrittenEpisode) { unwrittenEpisode = episode }
            eventProblem = error.localizedDescription
        }
    }

    /// Whether a record that just failed to write should replace the one already
    /// waiting. Only one of each kind is held, so when two different records are
    /// owed at once — a spike whose close failed, and the next spike opening
    /// while the disk is still refusing — one of them has to give way.
    ///
    /// A **closed** record wins. An open one is rewritten on the very next tick
    /// anyway, so dropping it costs a few seconds of a value nobody has read yet;
    /// a dropped close leaves a row that reads "still elevated" until the next
    /// launch sweeps it, which is a wrong answer rather than a stale one.
    private func supersedes(_ incoming: Spike, _ pending: Spike?) -> Bool {
        guard let pending else { return true }
        return incoming.end != nil || pending.end == nil
    }

    private func supersedes(_ incoming: ThrottleEpisode, _ pending: ThrottleEpisode?) -> Bool {
        guard let pending else { return true }
        return incoming.end != nil || pending.end == nil
    }

    /// Re-attempts the event rows a previous write could not land.
    ///
    /// Run wherever the buffer is written, so every path that makes the database
    /// current — a flush, a chart read, an export — makes it current in the same
    /// way. Without it a spike's close was simply lost: the row stayed open, and
    /// the next read reported a spike still in progress hours after it ended.
    /// A record still open is the one the detector is working on, so landing it
    /// keeps the recorder's id. A closed one is history the detector has already
    /// moved past, and must leave whatever is open now alone.
    private func retryUnwrittenEvents() {
        if let spike = unwrittenSpike {
            unwrittenSpike = nil
            write(spike, closed: spike.end != nil, current: spike.end == nil)
        }
        if let episode = unwrittenEpisode {
            unwrittenEpisode = nil
            write(episode, closed: episode.end != nil, current: episode.end == nil)
        }
    }

    /// A write succeeding says the database is usable again — but only once
    /// nothing is still owed to it. A one-shot write with no retry (a profile
    /// change, a session) is cleared by the next success, which is the most this
    /// can honestly claim: the failure is over, and what it cost is on disk.
    private func clearEventProblemIfNothingOutstanding() {
        guard unwrittenSpike == nil, unwrittenEpisode == nil else { return }
        eventProblem = nil
    }

    /// Writes the buffer and runs maintenance. Safe to call at any time —
    /// `AppModel` calls it on quit so the last few seconds aren't lost.
    ///
    /// The buffer is cleared only after the write commits. A full disk or a
    /// locked database used to lose whatever was in flight; now it is retried on
    /// the next flush and only ever dropped by `trimBuffer`, which counts what
    /// it drops.
    ///
    /// Insert before maintain, in that order: a sample buffered at 12:00:59 and
    /// flushed at 12:01:05 must be in the table before the rollup that closes
    /// the 12:00 minute, or it would be pruned having never been aggregated.
    public func flush(now: Date = Date()) {
        guard let store = connected() else { return }
        lastFlush = now
        writePending()
        // `abs` for the same reason `record` uses it: a clock stepped backwards
        // must not park the maintenance watermark in the future, where rollup
        // would stop running while `prune` went on being entitled to delete.
        guard problem == nil,
              abs(now.timeIntervalSince(lastMaintenance)) >= Self.maintenanceInterval else { return }
        lastMaintenance = now
        do {
            try store.maintain(now: now)
        } catch {
            bufferProblem = error.localizedDescription
        }
    }

    /// Brings the database up to date, and does nothing else.
    ///
    /// Separate from maintenance because a *read* needs what is in flight on disk
    /// but has no business running retention: a query is answered for a window,
    /// and passing that window's end in as "now" would run rollup and pruning
    /// against a clock from an hour ago every time someone scrubbed back to an
    /// old episode.
    ///
    /// Event rows first: an unwritten close is the record of something that has
    /// already finished, so a read that flushed the samples but not the close
    /// would draw a spike still in progress over a chart that has moved past it.
    private func writePending() {
        retryUnwrittenEvents()
        writeBuffer()
        // A failure with nothing left owed is over. Not every event write has a
        // retry — a profile change, a session — and left reported forever, one of
        // those would hold `problem` non-nil, which is what `flush` checks before
        // running maintenance: rollup would stop for good over a write that
        // failed once, an hour ago, and succeeded every time since.
        clearEventProblemIfNothingOutstanding()
    }

    private func writeBuffer() {
        guard let store = connected(), !buffer.isEmpty else { return }
        do {
            try store.insert(buffer)
            buffer.removeAll(keepingCapacity: true)
            bufferProblem = nil
        } catch {
            bufferProblem = error.localizedDescription
            trimBuffer()
        }
    }

    /// Records a profile change, skipping repeats — the band strip under the
    /// chart needs transitions, not a row per tick. Seeded from the database on
    /// first use so a relaunch doesn't write a duplicate transition.
    private func recordProfile(_ profile: ProfileState, at date: Date) {
        guard let store = connected() else { return }
        if lastProfileID == nil { lastProfileID = (try? store.lastProfileChange())?.profileID }
        guard lastProfileID != profile.id else { return }
        lastProfileID = profile.id
        do {
            try store.record(ProfileChange(date: date, profileID: profile.id,
                                           profileName: profile.name, reason: profile.reason))
        } catch {
            eventProblem = error.localizedDescription
        }
    }

    // MARK: - Sessions

    public func currentSession() -> RecordingSession? { openSession }

    @discardableResult
    public func startSession(name: String, profileName: String, at date: Date = Date()) -> RecordingSession? {
        guard let store = connected(), openSession == nil else { return openSession }
        var session = RecordingSession(name: name, start: date, profileName: profileName)
        do {
            session.id = try store.save(session)
            openSession = session
            return session
        } catch {
            eventProblem = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func endSession(at date: Date = Date()) -> RecordingSession? {
        guard let store = connected(), var session = openSession else { return nil }
        session.end = date
        do {
            try store.save(session)
            openSession = nil
            return session
        } catch {
            eventProblem = error.localizedDescription
            return nil
        }
    }

    // MARK: - Reading

    public struct Window: Sendable {
        public let groups: [Series]
        public let episodes: [ThrottleEpisode]
        public let profileChanges: [ProfileChange]
        public let sessions: [RecordingSession]
        public let availableGroups: [String]

        public init(groups: [Series], episodes: [ThrottleEpisode],
                    profileChanges: [ProfileChange], sessions: [RecordingSession],
                    availableGroups: [String]) {
            self.groups = groups
            self.episodes = episodes
            self.profileChanges = profileChanges
            self.sessions = sessions
            self.availableGroups = availableGroups
        }
    }

    /// Everything one screen of the History page needs, in a single hop —
    /// five separate awaits would let the chart and the episode list disagree
    /// about which window they are showing.
    ///
    /// `now` selects which storage tier can answer: raw seconds survive only two
    /// hours of *real* elapsed time, so it is the wall clock, not the end of the
    /// requested window. It is a parameter only so a test can supply its own.
    public func window(groups: [String], from: Date, to: Date,
                       targetPoints: Int = 600, now: Date = Date()) throws -> Window {
        guard let store = connected() else {
            throw HistoryError.unavailable(problem ?? "the database could not be opened")
        }
        // Anything still buffered belongs to this window; writing it first is
        // what makes the last ten seconds visible.
        writePending()
        return Window(groups: try store.groupSeries(groups: groups, from: from, to: to,
                                                    targetPoints: targetPoints, now: now),
                      episodes: try store.episodes(from: from, to: to),
                      profileChanges: try store.profileChanges(from: from, to: to),
                      sessions: try store.sessions(from: from, to: to),
                      availableGroups: try store.knownGroups())
    }

    /// Everything the Insights page needs: what spiked, what throttled, and
    /// whether attribution was even on. One hop, for the same reason `window` is
    /// one hop — two awaits would let the list and its summary disagree.
    public struct Insights: Sendable {
        public let spikes: [Spike]
        public let episodes: [ThrottleEpisode]
        /// The window these cover, so a summary can state it rather than assume.
        public let from: Date
        public let to: Date
        /// Whether attribution is on *now* — what the call to action depends on.
        /// Per-record truth lives on `Spike.recordedProcessNames`.
        public let recordsProcessNames: Bool

        public init(spikes: [Spike], episodes: [ThrottleEpisode],
                    from: Date, to: Date, recordsProcessNames: Bool) {
            self.spikes = spikes
            self.episodes = episodes
            self.from = from
            self.to = to
            self.recordsProcessNames = recordsProcessNames
        }
    }

    public func insights(from: Date, to: Date, limit: Int = 100) throws -> Insights {
        guard let store = connected() else {
            throw HistoryError.unavailable(problem ?? "the database could not be opened")
        }
        // A spike that opened seconds ago is still in the write buffer's window;
        // flushing first is what makes "why did it just spike?" answerable now
        // rather than at the next ten-second flush.
        writePending()
        return Insights(spikes: try store.spikes(from: from, to: to, limit: limit),
                        episodes: try store.episodes(from: from, to: to),
                        from: from, to: to,
                        recordsProcessNames: recordsProcessNames)
    }

    public func sensorSeries(keys: [String], from: Date, to: Date,
                             targetPoints: Int = 600, now: Date = Date()) throws -> [Series] {
        guard let store = connected() else {
            throw HistoryError.unavailable(problem ?? "the database could not be opened")
        }
        return try store.series(keys: keys, from: from, to: to,
                                targetPoints: targetPoints, now: now)
    }

    public func knownSensors() throws -> [SensorDescriptor] {
        guard let store = connected() else { return [] }
        return try store.knownSensors()
    }

    // MARK: - Export and housekeeping

    public func export(_ format: HistoryExport.Format, from: Date, to: Date,
                       now: Date = Date()) throws -> Data {
        guard let store = connected() else {
            throw HistoryError.unavailable(problem ?? "the database could not be opened")
        }
        writePending()
        return try HistoryExport.data(format: format, store: store, from: from, to: to, now: now)
    }

    /// Whether an export of this window would carry process names, so the save
    /// panel can warn before it writes them (DESIGN §5.4).
    public func exportIncludesProcessNames(from: Date, to: Date) -> Bool {
        guard let store = connected() else { return false }
        let episodes = (try? store.episodes(from: from, to: to)) ?? []
        if episodes.contains(where: { !$0.processes.isEmpty }) { return true }
        let spikes = (try? store.spikes(from: from, to: to)) ?? []
        return spikes.contains { !$0.processes.isEmpty }
    }

    public func clear() throws {
        guard let store = connected() else { return }
        buffer.removeAll()
        droppedBatches = 0
        openEpisodeID = 0
        openSpikeID = 0
        // Rows that were owed to a database that no longer has them. Retrying
        // one after the user asked for history to be cleared would put back a
        // record of exactly what they asked to be rid of.
        unwrittenSpike = nil
        unwrittenEpisode = nil
        openSession = nil
        lastProfileID = nil
        detector = ThrottleDetector()
        spikeDetector = SpikeDetector()
        spikeDetector.setRecordsProcessNames(recordsProcessNames)
        try store.clear()
    }

    // MARK: - Test hooks

    /// SQLite work done so far, in bytecode steps — see
    /// `HistoryStore.workUnitsForTesting`. What "this must not become O(n²)" is
    /// asserted against, in place of a stopwatch that measures the machine.
    func workUnitsForTesting() -> Int { connected()?.workUnitsForTesting ?? 0 }

    /// Makes every write fail, so the recorder's failure paths can be exercised
    /// without arranging a full disk. Reads keep working.
    func setWritesFailForTesting(_ failing: Bool) throws {
        guard let store = connected() else { return }
        try store.setWritesFailForTesting(failing)
    }

    /// Event rows the database has not accepted yet, which is what says a write
    /// failure is still outstanding rather than recovered from.
    func unwrittenEventCountForTesting() -> Int {
        (unwrittenSpike == nil ? 0 : 1) + (unwrittenEpisode == nil ? 0 : 1)
    }
}
