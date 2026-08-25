import Foundation
import SwiftUI
import SensorKit
import HistoryKit

/// Backs the History page of the Dashboard. Owns nothing but presentation
/// state — every read
/// goes through `AppModel.historyRecorder`, so there is still exactly one
/// database connection in the process.
@MainActor
final class HistoryViewModel: ObservableObject {

    @Published var range: HistoryRange = .hour {
        didSet { focus = nil; scheduleReload() }
    }
    @Published var selectedGroups: Set<String> {
        didSet { if selectedGroups != oldValue { scheduleReload() } }
    }
    /// Set by clicking an episode: the chart scrubs to that window until the
    /// user steps back out to the full range.
    @Published private(set) var focus: ClosedRange<Date>?

    @Published private(set) var series: [Series] = []
    @Published private(set) var episodes: [ThrottleEpisode] = []
    @Published private(set) var profileChanges: [ProfileChange] = []
    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var availableGroups: [String] = []
    @Published private(set) var status: HistoryRecorder.Status?
    @Published private(set) var openSession: RecordingSession?
    @Published private(set) var problem: String?
    @Published private(set) var isLoading = false

    @Published var sessionName: String = ""

    /// The window the last load actually covered. Held rather than recomputed
    /// so the chart's axis and its data can't disagree by a few seconds.
    @Published private(set) var visible: ClosedRange<Date>

    private let model: AppModel
    private var reloadTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        self.selectedGroups = ["CPU", "GPU", HistorySensors.fan, HistorySensors.load, HistorySensors.power]
        let now = Date()
        self.visible = now.addingTimeInterval(-HistoryRange.hour.duration)...now
    }

    /// Groups worth offering: whatever has actually been recorded, in a stable
    /// order, with the ones that can't share the chart's axes removed.
    var offeredGroups: [String] {
        let ordered = SensorCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.rawValue)
            .filter { availableGroups.contains($0) }
        let extras = [HistorySensors.fan, HistorySensors.load, HistorySensors.power]
            .filter { availableGroups.contains($0) }
        return (ordered + extras).filter { !HistorySensors.ungroupedInCharts.contains($0) }
    }

    /// Scrubs the chart to a window, with a little air either side.
    ///
    /// One implementation for every caller — an episode row, a spike on the
    /// Insights page — so "showing this event on the chart" cannot come to mean
    /// two slightly different windows.
    func focus(from start: Date, to end: Date) {
        // Never a zero-width window.
        let padding = max(60, end.timeIntervalSince(start) * 0.25)
        // `ClosedRange` traps when its bounds are inverted, so the bounds are
        // sorted rather than assumed. An event that ends before it starts
        // should not be possible — but it is a row in a database that older
        // builds also wrote, and a chart is not the place to find out.
        let bounds = [start.addingTimeInterval(-padding), end.addingTimeInterval(padding)].sorted()
        focus = bounds[0]...bounds[1]
        scheduleReload()
    }

    func focus(on episode: ThrottleEpisode) {
        focus(from: episode.start, to: episode.end ?? Date())
    }

    func focus(on spike: Spike) {
        focus(from: spike.start, to: spike.end ?? Date())
    }

    func clearFocus() {
        focus = nil
        scheduleReload()
    }

    // MARK: - Loading

    private func scheduleReload() {
        loadGeneration += 1
        let generation = loadGeneration
        reloadTask?.cancel()
        reloadTask = Task { await reload(expectedGeneration: generation) }
    }

    /// Bumped by every load. Two can be in flight at once — the five-second
    /// refresh and a reload triggered by changing the range — and they can
    /// finish in either order. Without this, a slow load carrying the *old*
    /// group selection could land after the fast one and repaint the chart with
    /// what the user just deselected.
    private var loadGeneration = 0

    func reload(expectedGeneration: Int? = nil) async {
        let window: ClosedRange<Date>
        if let focus {
            window = focus
        } else {
            let end = Date()
            window = end.addingTimeInterval(-range.duration)...end
        }

        let generation: Int
        if let expectedGeneration {
            generation = expectedGeneration
        } else {
            loadGeneration += 1
            generation = loadGeneration
        }
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let loaded = try await model.historyRecorder.window(groups: Array(selectedGroups),
                                                                from: window.lowerBound,
                                                                to: window.upperBound)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            visible = window
            series = loaded.groups
            episodes = loaded.episodes
            profileChanges = loaded.profileChanges
            sessions = loaded.sessions
            availableGroups = loaded.availableGroups
            problem = nil
            adoptRealGroupsIfInitialSelectionMatchedNothing()
        } catch {
            problem = error.localizedDescription
        }
        let status = await model.historyRecorder.status()
        let session = await model.historyRecorder.currentSession()
        guard generation == loadGeneration else { return }
        self.status = status
        self.openSession = session
    }

    /// The initial selection names "CPU" and "GPU", which is a guess about the
    /// hardware rather than a fact about it. This Mac reports no sensor Apple
    /// labels as either — all 14 die zones classify as `soc` — so the window
    /// opened with fans and load plotted and not one temperature.
    ///
    /// Runs at most once, and only when the guess matched nothing that was
    /// actually recorded, so it can never overrule a choice the user made. The
    /// flag is set before `selectedGroups` is touched: that assignment feeds
    /// back through `didSet` into another reload, and without the flag already
    /// set that reload would land here again.
    private func adoptRealGroupsIfInitialSelectionMatchedNothing() {
        guard !hasReconciledGroups else { return }
        hasReconciledGroups = true

        guard !availableGroups.isEmpty else {
            // Nothing recorded yet — this was not a mismatch, so leave the
            // default alone and let the next load decide.
            hasReconciledGroups = false
            return
        }
        let temperatureGroups = Set(SensorCategory.allCases.map(\.rawValue))
        let chosenAndPresent = selectedGroups.filter { availableGroups.contains($0) }
        guard !chosenAndPresent.contains(where: { temperatureGroups.contains($0) }) else { return }

        let present = offeredGroups.filter { temperatureGroups.contains($0) }
        guard !present.isEmpty else { return }
        selectedGroups = Set(present).union(chosenAndPresent)
    }

    /// Whether the one-shot group reconciliation above has already run.
    private var hasReconciledGroups = false

    /// Live refresh while the window is open.
    ///
    /// A scrubbed-to episode is a fixed window, but it is still reloaded: an
    /// episode that was open when it was clicked closes later, and the row
    /// would otherwise read "running" until the user navigated away.
    func refreshLoop() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    // MARK: - Commands

    func toggleSession() async {
        if openSession != nil {
            _ = await model.historyRecorder.endSession()
        } else {
            let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = await model.historyRecorder.startSession(
                name: name.isEmpty ? "Session" : name,
                profileName: model.activeProfile.name)
            sessionName = ""
        }
        await reload()
    }

    func clear() async {
        do {
            try await model.historyRecorder.clear()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        await reload()
    }

    /// True when an export of the visible window would carry application names,
    /// so the save panel can say so first (DESIGN §5.4).
    func exportWouldIncludeProcessNames() async -> Bool {
        await model.historyRecorder.exportIncludesProcessNames(from: visible.lowerBound,
                                                               to: visible.upperBound)
    }

    func export(_ format: HistoryExport.Format, to url: URL) async {
        do {
            let data = try await model.historyRecorder.export(format, from: visible.lowerBound,
                                                              to: visible.upperBound)
            try data.write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    var suggestedFileName: String {
        "M5Blade-history-\(Self.fileStamp.string(from: visible.upperBound))"
    }

    /// Awaits any reload this model started for itself.
    ///
    /// Changing the range or the group selection schedules a load in the
    /// background — the caller does not await it, and the newer load correctly
    /// discards an older one's results. That makes "the state has settled" a
    /// real condition rather than something a test can assume after one await.
    /// Bounded, so a reload that keeps scheduling another cannot hang a caller.
    func settle(maximumRounds: Int = 8) async {
        for _ in 0..<maximumRounds {
            guard let task = reloadTask else { return }
            reloadTask = nil
            await task.value
        }
    }

    /// Injects loaded state directly, so the scale and grouping logic can be
    /// tested against values a real database would take minutes to produce.
    /// Internal, so only `@testable import` can reach it.
    func applyForTesting(series: [Series]? = nil,
                         episodes: [ThrottleEpisode]? = nil,
                         profileChanges: [ProfileChange]? = nil,
                         availableGroups: [String]? = nil,
                         visible: ClosedRange<Date>? = nil,
                         status: HistoryRecorder.Status? = nil) {
        if let series { self.series = series }
        if let episodes { self.episodes = episodes }
        if let profileChanges { self.profileChanges = profileChanges }
        if let availableGroups { self.availableGroups = availableGroups }
        if let visible { self.visible = visible }
        if let status { self.status = status }
    }

    // MARK: - Chart scales

    /// Temperature axis top, rounded up so the line never touches the frame.
    var temperatureTop: Double {
        let peak = series
            .filter { $0.kind == .temperature }
            .flatMap { $0.points.map(\.maximum) }
            .max() ?? 0
        return max(100, (peak / 10).rounded(.up) * 10 + 10)
    }

    /// Percent series share the temperature axis's numbers, with their own
    /// labels on the right — Swift Charts has no second Y scale, so the mapping
    /// is explicit rather than implied. Power series map the same way, reading
    /// watts off the same right-hand numbers: on machines that pull more than
    /// ~100 W package the line simply reaches the top sooner.
    func plotted(_ point: SeriesPoint, kind: SensorKind) -> Double {
        switch kind {
        case .temperature: return point.average
        case .power:       return point.average / Self.powerFullScale * temperatureTop
        default:           return point.average / 100 * temperatureTop
        }
    }

    /// Watts treated as full-scale when mapped onto the plot. High enough that
    /// a laptop package never saturates at idle readings; the axis labels say
    /// "%" and "W" share the scale only up to this number.
    static let powerFullScale: Double = 120

    func percentLabel(forAxisValue value: Double) -> String {
        String(format: "%.0f%%", value / temperatureTop * 100)
    }
}
