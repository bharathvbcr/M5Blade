import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import HistoryKit

/// The History page of the Dashboard (UI.md §7).
///
/// The shared time axis is the whole point: temperature, fan duty and load over
/// the same window, with the active profile banded underneath and throttle
/// episodes shaded through. That combination is what answers "is my cooling
/// policy doing anything?" — which no single readout can.
///
/// The view model is owned by `DashboardWindowView`, not by this page: switching
/// to Sensors and back must not reset the range, the group selection, or a
/// chart scrubbed to an episode.
struct HistoryPage: View {
    /// Observed as well as passed to the view model: the attribution toggle
    /// reads and writes the model's own state rather than a second copy of it.
    @ObservedObject var model: AppModel
    @ObservedObject var viewModel: HistoryViewModel

    @State private var isConfirmingClear = false
    @State private var pendingExport: HistoryExport.Format?
    @State private var isConfirmingProcessNames = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let problem = viewModel.problem { banner(problem) }
            Divider()
            chart.frame(minHeight: 260)
            Divider()
            episodeList.frame(minHeight: 120, maxHeight: 200)
            Divider()
            footer
        }
        .task { await viewModel.refreshLoop() }
        .confirmationDialog("Delete all recorded history?",
                            isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Delete History", role: .destructive) {
                Task { await viewModel.clear() }
            }
        } message: {
            Text("Every sample, throttle episode and session is removed. This can't be undone.")
        }
        .confirmationDialog("This export includes application names",
                            isPresented: $isConfirmingProcessNames, titleVisibility: .visible) {
            Button("Export Anyway") { if let format = pendingExport { save(format) } }
            Button("Cancel", role: .cancel) { pendingExport = nil }
        } message: {
            Text("Throttle episodes in this window record which applications were running. "
                 + "Anyone you send the file to can read them.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $viewModel.range) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(viewModel.focus != nil)

            if viewModel.focus != nil {
                Button {
                    viewModel.clearFocus()
                } label: {
                    Label("Back to \(viewModel.range.label)", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
            }

            Spacer()

            ForEach(viewModel.offeredGroups, id: \.self) { group in
                Toggle(group, isOn: Binding(
                    get: { viewModel.selectedGroups.contains(group) },
                    set: { isOn in
                        if isOn { viewModel.selectedGroups.insert(group) }
                        else { viewModel.selectedGroups.remove(group) }
                    }))
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    private func banner(_ problem: String) -> some View {
        WarningBanner(message: problem)
    }

    // MARK: - Chart

    /// Height of the profile band strip, as a fraction of the temperature axis.
    /// The strip lives in negative y so it can never overlap a plotted line.
    private var stripHeight: Double { viewModel.temperatureTop * 0.07 }

    private var axisValues: [Double] {
        Array(stride(from: 0, through: viewModel.temperatureTop, by: 20))
    }

    /// The two axes share one scale but not one set of ticks: 100 °C is not a
    /// round percentage, so the right axis gets its own values mapped into plot
    /// units. Both then read in whole numbers.
    private var percentAxisValues: [Double] {
        [0.0, 25, 50, 75, 100].map { $0 / 100 * viewModel.temperatureTop }
    }

    @ViewBuilder
    private var chart: some View {
        if viewModel.series.allSatisfy({ $0.points.isEmpty }) {
            emptyChart
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Chart {
                    profileBands
                    episodeShading
                    seriesLines
                }
                .chartXScale(domain: viewModel.visible)
                .chartYScale(domain: -stripHeight...viewModel.temperatureTop)
                .chartYAxis {
                    celsiusAxisMarks(values: axisValues)
                    AxisMarks(position: .trailing, values: percentAxisValues) { value in
                        AxisValueLabel {
                            if let plotted = value.as(Double.self) {
                                Text(viewModel.percentLabel(forAxisValue: plotted))
                            }
                        }
                    }
                }
                .chartLegend(position: .bottom, spacing: 8)
                // Swift Charts renders nothing VoiceOver can read on its own.
                // A summary is not a substitute for a full chart descriptor, but
                // it is the difference between "chart" and knowing what is in it.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("History chart")
                .accessibilityValue(chartSummary)

                Text("Solid lines are temperatures (left axis). Dashed lines are percentages "
                     + "(right axis). Shaded bands are throttle episodes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    /// Three different reasons for an empty chart, and they call for three
    /// different sentences. Telling someone "nothing recorded" when they have
    /// simply switched every sensor off sends them looking for a bug.
    /// What the chart would tell you if you could see it.
    private var chartSummary: String {
        guard !viewModel.series.isEmpty else { return "no data" }
        let window = "\(viewModel.visible.lowerBound.formatted(date: .abbreviated, time: .shortened))"
            + " to \(viewModel.visible.upperBound.formatted(date: .abbreviated, time: .shortened))"
        let lines = viewModel.series.compactMap { series -> String? in
            guard let low = series.points.map(\.minimum).min(),
                  let high = series.points.map(\.maximum).max() else { return nil }
            let unit = series.kind == .temperature ? "degrees" : "percent"
            return String(format: "%@ %.0f to %.0f %@", series.name, low, high, unit)
        }
        let episodes = viewModel.episodes.isEmpty
            ? "no throttle episodes"
            : "\(viewModel.episodes.count) throttle episode\(viewModel.episodes.count == 1 ? "" : "s")"
        return ([window] + lines + [episodes]).joined(separator: ". ")
    }

    private var emptyChart: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
            if viewModel.isLoading {
                Text("Loading…").foregroundStyle(.secondary)
            } else if viewModel.selectedGroups.isEmpty {
                Text("No sensors selected").foregroundStyle(.secondary)
                Text("Pick one above to plot it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nothing recorded in this window yet").foregroundStyle(.secondary)
                Text("History records continuously, whether or not fan control is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ChartContentBuilder
    private var seriesLines: some ChartContent {
        ForEach(viewModel.series) { series in
            ForEach(series.points) { point in
                LineMark(x: .value("Time", point.date),
                         y: .value("Value", viewModel.plotted(point, kind: series.kind)),
                         series: .value("Series", series.name))
            }
            .foregroundStyle(by: .value("Series", series.name))
            .lineStyle(StrokeStyle(lineWidth: 1.5,
                                   dash: series.kind == .temperature ? [] : [4, 3]))
            .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private var episodeShading: some ChartContent {
        ForEach(clampedEpisodes) { shading in
            RectangleMark(xStart: .value("Start", shading.start),
                          xEnd: .value("End", shading.end),
                          yStart: .value("Bottom", 0.0),
                          yEnd: .value("Top", viewModel.temperatureTop))
            .foregroundStyle(.red.opacity(0.10))
        }
    }

    /// Which profile was active, as a strip under the plot. Without it the chart
    /// shows what happened but not what the machine was being told to do.
    @ChartContentBuilder
    private var profileBands: some ChartContent {
        ForEach(bands) { band in
            RectangleMark(xStart: .value("Start", band.start),
                          xEnd: .value("End", band.end),
                          yStart: .value("Bottom", -stripHeight),
                          yEnd: .value("Top", 0.0))
            .foregroundStyle(Self.bandColor(for: band.name).opacity(0.45))
            .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                // A label wider than its band spills over the neighbouring one
                // and mislabels it. Below roughly a tenth of the window there is
                // no room for a profile name, so the colour carries it alone.
                if band.isWideEnoughToLabel {
                    Text(band.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.leading, 3)
                }
            }
        }
    }

    private struct Band: Identifiable {
        let id: Date
        let name: String
        let start: Date
        let end: Date
        let isWideEnoughToLabel: Bool
    }

    private struct EpisodeShading: Identifiable {
        let id: Int64
        let start: Date
        let end: Date
    }

    /// Episodes clipped to the visible window. An episode that started before it
    /// or is still running extends past the edge; drawn unclipped a mark can end
    /// before it starts, which Charts renders as nothing at all.
    private var clampedEpisodes: [EpisodeShading] {
        viewModel.episodes.compactMap { episode in
            let start = max(episode.start, viewModel.visible.lowerBound)
            let end = min(episode.end ?? viewModel.visible.upperBound,
                          viewModel.visible.upperBound)
            guard end > start else { return nil }
            return EpisodeShading(id: episode.id, start: start, end: end)
        }
    }

    private var bands: [Band] {
        let changes = viewModel.profileChanges
        guard !changes.isEmpty else { return [] }
        let span = viewModel.visible.upperBound.timeIntervalSince(viewModel.visible.lowerBound)
        return changes.enumerated().compactMap { index, change in
            let start = max(change.date, viewModel.visible.lowerBound)
            let end = index + 1 < changes.count
                ? min(changes[index + 1].date, viewModel.visible.upperBound)
                : viewModel.visible.upperBound
            guard end > start else { return nil }
            let fraction = span > 0 ? end.timeIntervalSince(start) / span : 1
            return Band(id: change.date, name: change.profileName, start: start, end: end,
                        isWideEnoughToLabel: fraction >= 0.1)
        }
    }

    /// Stable per-name colour, so the same profile keeps its band colour between
    /// reloads and between ranges.
    private static func bandColor(for name: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .teal, .pink]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    // MARK: - Episodes

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Throttle episodes").font(.headline)
                Spacer()
                if !viewModel.sessions.isEmpty {
                    Text("\(viewModel.sessions.count) session\(viewModel.sessions.count == 1 ? "" : "s") in view")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            if viewModel.episodes.isEmpty {
                HStack {
                    Text("None in this window.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                List(viewModel.episodes) { episode in
                    // A Button, not a tap gesture: scrubbing the chart to an
                    // episode was otherwise reachable by pointer only — no
                    // keyboard focus, and invisible to VoiceOver.
                    Button {
                        viewModel.focus(on: episode)
                    } label: {
                        episodeRow(episode)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.accessibilityLabel(for: episode))
                    .accessibilityHint("Scrubs the chart to this episode")
                }
                .listStyle(.plain)
            }
        }
    }

    private func episodeRow(_ episode: ThrottleEpisode) -> some View {
        HStack(spacing: 10) {
            Text(episode.start, format: episodeTimeFormat)
                .font(.callout.monospacedDigit())
                .frame(width: 100, alignment: .leading)

            Text(episode.duration.map(HistoryFormatting.duration) ?? "running")
                .font(.callout.monospacedDigit())
                .foregroundStyle(episode.end == nil ? Color.orange : .secondary)
                .frame(width: 70, alignment: .leading)

            if let peak = episode.peakTempC {
                Text(String(format: "peak %.0f°C", peak)).font(.callout.monospacedDigit())
            }

            Text(episode.profileName).font(.caption).foregroundStyle(.secondary)

            Spacer()

            if let top = episode.processes.first {
                Text(String(format: "%@ %.0f%%", top.name, top.percent))
                    .font(.callout).lineLimit(1)
            } else if !model.recordsProcessNames {
                Text("app names not recorded").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
    }

    /// A bare "14:22" is wrong twice over: it forces a 24-hour clock on someone
    /// whose Mac is set to 12, and on a 7- or 30-day range it names an instant
    /// without saying which day. The window's own span decides which it needs.
    private var episodeTimeFormat: Date.FormatStyle {
        let span = viewModel.visible.upperBound.timeIntervalSince(viewModel.visible.lowerBound)
        return span > 24 * 3_600
            ? .dateTime.month(.abbreviated).day().hour().minute()
            : .dateTime.hour().minute()
    }

    private static func accessibilityLabel(for episode: ThrottleEpisode) -> String {
        var parts = [episode.start.formatted(date: .abbreviated, time: .shortened)]
        parts.append(episode.duration.map { "lasted \(HistoryFormatting.duration($0))" }
                     ?? "still running")
        if let peak = episode.peakTempC { parts.append(String(format: "peak %.0f degrees", peak)) }
        if let top = episode.processes.first {
            parts.append(String(format: "%@ accounted for %.0f percent", top.name, top.percent))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Session name", text: $viewModel.sessionName)
                    .frame(width: 150)
                    .disabled(viewModel.openSession != nil)

                Button(viewModel.openSession == nil ? "Start Session" : "Stop Session") {
                    Task { await viewModel.toggleSession() }
                }

                if let session = viewModel.openSession {
                    Text("Recording “\(session.name)”")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if let status = viewModel.status {
                    Text(Self.size(status.byteSize))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

                    // A gap in the chart has to be explainable by something the
                    // app tells you, not by ticks it quietly gave up on.
                    if status.droppedBatches > 0 {
                        Label("\(status.droppedBatches) samples dropped",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .help("The database could not be written to for a while. "
                                  + "Those seconds are missing from the record.")
                    }
                }

                Button("Clear History…") { isConfirmingClear = true }

                Menu("Export…") {
                    ForEach(HistoryExport.Format.allCases) { format in
                        Button(format.displayName) { beginExport(format) }
                    }
                }
                .fixedSize()
            }

            Toggle("Record application names with throttle episodes and spikes",
                   isOn: Binding(get: { model.recordsProcessNames },
                                 set: { enabled in
                                     Task { await model.setRecordsProcessNames(enabled) }
                                 }))
            .font(.caption)
            .help("Off by default. When on, an episode or a spike records which applications "
                  + "were responsible — which is what lets Insights name one. That is a "
                  + "timestamped record of what you run, kept on this Mac only, and included "
                  + "in exports.")
        }
        .padding(12)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func size(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    // MARK: - Export

    /// Explicitly main-actor: `Task {}` inside a nonisolated method runs on a
    /// background executor even when a button on the main thread started it, and
    /// both `@State` mutation and `NSSavePanel.runModal()` are main-thread-only.
    @MainActor
    private func beginExport(_ format: HistoryExport.Format) {
        pendingExport = format
        Task { @MainActor in
            if await viewModel.exportWouldIncludeProcessNames() {
                isConfirmingProcessNames = true
            } else {
                save(format)
            }
        }
    }

    @MainActor
    private func save(_ format: HistoryExport.Format) {
        pendingExport = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(viewModel.suggestedFileName).\(format.fileExtension)"
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.export(format, to: url) }
    }
}
