import Foundation
import SwiftUI
import SensorKit
import HistoryKit

/// Backs the Insights page: what spiked, why, and whether it keeps happening.
///
/// Owns no data of its own. Every read goes through `AppModel.historyRecorder`,
/// so there is still exactly one database connection in the process — the same
/// rule `HistoryViewModel` follows.
@MainActor
final class InsightsViewModel: ObservableObject {

    /// A spike with its explanation already computed, so the view never does
    /// analysis while laying out and every row explains itself the same way.
    struct Finding: Identifiable {
        let spike: Spike
        let explanation: SpikeExplanation
        var id: Int64 { spike.id }
    }

    @Published var range: HistoryRange = .day {
        didSet { if range != oldValue { scheduleReload() } }
    }

    @Published private(set) var findings: [Finding] = []
    @Published private(set) var episodes: [ThrottleEpisode] = []
    /// Whether attribution is on *now*, which is what the call to action asks
    /// about. Whether it was on for a given spike lives on that spike.
    @Published private(set) var recordsProcessNames = false
    @Published private(set) var problem: String?
    @Published private(set) var isLoading = false
    /// The window the last load actually covered, held rather than recomputed so
    /// a summary and the list it summarises can't disagree by a few seconds.
    @Published private(set) var visible: ClosedRange<Date>

    private let model: AppModel
    private var reloadTask: Task<Void, Never>?
    /// Bumped by every load, so a slow one landing after a fast one cannot
    /// repaint the page with a window the user has already moved off.
    private var loadGeneration = 0

    init(model: AppModel) {
        self.model = model
        let now = Date()
        self.visible = now.addingTimeInterval(-HistoryRange.day.duration)...now
        self.recordsProcessNames = model.recordsProcessNames
    }

    // MARK: - Loading

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { await reload() }
    }

    func reload() async {
        let end = Date()
        let window = end.addingTimeInterval(-range.duration)...end

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let loaded = try await model.historyRecorder.insights(from: window.lowerBound,
                                                                   to: window.upperBound)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            visible = window
            findings = loaded.spikes.map { Finding(spike: $0, explanation: .explain($0)) }
            episodes = loaded.episodes
            recordsProcessNames = loaded.recordsProcessNames
            problem = nil
        } catch {
            guard generation == loadGeneration else { return }
            problem = error.localizedDescription
        }
    }

    /// Live refresh while the window is open. A spike in progress has to stop
    /// reading "rising" once it settles, without the user navigating away.
    func refreshLoop() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Awaits any reload this model started for itself. Bounded, so a reload
    /// that keeps scheduling another cannot hang a caller.
    func settle(maximumRounds: Int = 8) async {
        for _ in 0..<maximumRounds {
            guard let task = reloadTask else { return }
            reloadTask = nil
            await task.value
        }
    }

    /// Injects loaded state directly, so the summaries can be tested against
    /// spikes a real machine would take days to produce.
    func applyForTesting(spikes: [Spike]? = nil,
                         episodes: [ThrottleEpisode]? = nil,
                         recordsProcessNames: Bool? = nil,
                         visible: ClosedRange<Date>? = nil,
                         problem: String? = nil) {
        if let spikes { findings = spikes.map { Finding(spike: $0, explanation: .explain($0)) } }
        if let episodes { self.episodes = episodes }
        if let recordsProcessNames { self.recordsProcessNames = recordsProcessNames }
        if let visible { self.visible = visible }
        if let problem { self.problem = problem }
    }

    // MARK: - Summary

    /// A spike that has not ended yet, if one is in progress. The page leads
    /// with it, because "it is happening right now" is the only case where the
    /// user can go and look at the thing causing it.
    var openFinding: Finding? { findings.first { $0.spike.end == nil } }

    var headline: String {
        let count = findings.count
        guard count > 0 else { return "No sudden spikes in the last \(range.spokenLabel)" }
        return "\(count) sudden spike\(count == 1 ? "" : "s") in the last \(range.spokenLabel)"
    }

    /// The cause behind the most spikes, and how many. Nil when there is nothing
    /// to generalise from — one spike is an event, not a pattern.
    var dominantCause: (cause: SpikeExplanation.Cause, count: Int)? {
        guard findings.count >= 2 else { return nil }
        let counts = Dictionary(grouping: findings, by: \.explanation.cause).mapValues(\.count)
        guard let best = counts.max(by: { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }),
              best.value >= 2 else { return nil }
        return (best.key, best.value)
    }

    /// The application named in the most spikes. Only counts a spike where that
    /// application actually dominated it — a process at 5% of three spikes is
    /// not the reason for any of them.
    var repeatOffender: (name: String, count: Int)? {
        var counts: [String: Int] = [:]
        for finding in findings {
            guard finding.explanation.cause == .application,
                  let top = finding.spike.processes.first else { continue }
            counts[top.name, default: 0] += 1
        }
        guard let best = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }),
              best.value >= 2 else { return nil }
        return (best.key, best.value)
    }

    /// True when spikes were recorded but none of them could name an
    /// application *and* turning attribution on would have changed that.
    var wouldBenefitFromAttribution: Bool {
        guard !recordsProcessNames else { return false }
        return findings.contains { !$0.spike.recordedProcessNames }
    }

    func setRecordsProcessNames(_ enabled: Bool) async {
        await model.setRecordsProcessNames(enabled)
        recordsProcessNames = model.recordsProcessNames
    }

    // MARK: - Right now

    /// What the machine is doing this second, in one line. The Insights page
    /// opens with it so "is it happening now?" is answered before any history.
    var currentSummary: String {
        let temp = model.maxTempC.map { String(format: "%.0f °C", $0) } ?? "no reading"
        var parts = [temp]
        if let category = SensorCategory(rawValue: model.hottestGroup) {
            parts.append("hottest: \(category.title.lowercased())")
        }
        parts.append(String(format: "load %.0f%%", model.cpuPercent))
        if let duty = currentFanDuty {
            parts.append(String(format: "fans %.0f%%", duty))
        }
        return parts.joined(separator: " · ")
    }

    var currentFanDuty: Double? {
        let duties = model.fans.compactMap { fan -> Double? in
            guard let reading = model.readings[fan.index] else { return nil }
            return fan.dutyPercent(forRPM: reading.actualRPM)
        }
        return duties.max()
    }

    var currentTempC: Double? { model.maxTempC }
    var statusLabel: String { model.status.label }
    var activeProfileName: String { model.activeProfile.name }
}

extension HistoryRange {
    /// "24h" reads fine on a segmented control and badly in a sentence.
    var spokenLabel: String {
        switch self {
        case .hour:     return "hour"
        case .sixHours: return "6 hours"
        case .day:      return "24 hours"
        case .week:     return "7 days"
        case .month:    return "30 days"
        }
    }
}
