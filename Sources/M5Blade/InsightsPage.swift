import SwiftUI
import SensorKit
import HistoryKit

/// Why the machine got hot.
///
/// The rest of the Dashboard shows *what* happened — a chart, a sensor list.
/// This page is the only one that answers a question, so it is built around one:
/// "it suddenly spiked, what was that?". Every row names a cause, shows the
/// measurements that cause was inferred from, and can put the moment on the
/// History chart next door.
struct InsightsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var viewModel: InsightsViewModel
    /// Hands a window to the History page and switches to it. The payoff of
    /// putting these on one window instead of two.
    var onShowOnChart: (ClosedRange<Date>) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rightNow
                if let problem = viewModel.problem { WarningBanner(message: problem, shape: .card) }
                spikesHeader
                if viewModel.findings.isEmpty {
                    emptyState
                } else {
                    patterns
                    ForEach(viewModel.findings) { finding in
                        findingCard(finding)
                    }
                }
                if viewModel.wouldBenefitFromAttribution { attributionCallToAction }
                throttleSummary
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Right now

    private var rightNow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Right now").font(.headline)
                Text(viewModel.statusLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                Text(viewModel.activeProfileName).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 12) {
                Text(viewModel.currentTempC.map { String(format: "%.0f°", $0) } ?? "--°")
                    .font(.system(size: 34, weight: .medium).monospacedDigit())
                    .foregroundStyle(tint(for: viewModel.currentTempC))
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.currentSummary)
                        .font(.callout.monospacedDigit())
                    // Bar as well as number: severity is never carried by colour
                    // alone (UI.md §11).
                    ProgressView(value: min(max(viewModel.currentTempC ?? 0, 0), 110), total: 110)
                        .frame(width: 220)
                        .tint(tint(for: viewModel.currentTempC))
                }
                Spacer()
            }

            if let open = viewModel.openFinding {
                Label("Rising now — \(open.explanation.headline)",
                      systemImage: "arrow.up.right.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Spikes

    private var spikesHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.headline).font(.headline)
                Text("A spike is a rise of at least \(Int(SpikeDetector.Configuration().riseThresholdC)) °C "
                     + "within \(Int(SpikeDetector.Configuration().riseWindow / 60)) minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $viewModel.range) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("Time range")
        }
    }

    /// What repeats, when anything does. One spike is an event; the same cause
    /// four times is the thing worth acting on.
    @ViewBuilder
    private var patterns: some View {
        let cause = viewModel.dominantCause
        let offender = viewModel.repeatOffender
        if cause != nil || offender != nil {
            HStack(spacing: 8) {
                if let offender {
                    chip("\(offender.name) — \(offender.count) of them", systemImage: "repeat")
                }
                if let cause {
                    chip("Mostly \(cause.cause.label.lowercased()) (\(cause.count))",
                         systemImage: cause.cause.symbolName)
                }
                Spacer()
            }
        }
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }

    private func findingCard(_ finding: InsightsViewModel.Finding) -> some View {
        let spike = finding.spike
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(spike.start, format: timeFormat)
                    .font(.callout.monospacedDigit())
                    .frame(width: 104, alignment: .leading)

                Label(finding.explanation.cause.label,
                      systemImage: finding.explanation.cause.symbolName)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15)).clipShape(Capsule())

                Text(finding.explanation.headline).font(.headline).lineLimit(2)

                Spacer(minLength: 8)

                Button("Show on chart") {
                    onShowOnChart(chartWindow(for: spike))
                }
                .controlSize(.small)
                .accessibilityHint("Scrubs the History chart to this spike")
            }

            HStack(spacing: 10) {
                Text(finding.explanation.detail)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(spike.end == nil
                     ? "still elevated"
                     : "lasted \(HistoryFormatting.duration(spike.duration ?? 0))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(spike.end == nil ? Color.orange : .secondary)
            }

            if let suggestion = finding.explanation.suggestion {
                Text(suggestion).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(for: finding))
    }

    /// `ClosedRange` traps on inverted bounds, and an open spike's end is not
    /// yet known — so the window is built from sorted bounds, never assumed.
    private func chartWindow(for spike: Spike) -> ClosedRange<Date> {
        let bounds = [spike.start, spike.end ?? Date()].sorted()
        return bounds[0]...bounds[1]
    }

    private var timeFormat: Date.FormatStyle {
        viewModel.range.duration > 24 * 3_600
            ? .dateTime.month(.abbreviated).day().hour().minute()
            : .dateTime.hour().minute()
    }

    private static func accessibilityLabel(for finding: InsightsViewModel.Finding) -> String {
        let spike = finding.spike
        return [spike.start.formatted(date: .abbreviated, time: .shortened),
                finding.explanation.cause.label,
                finding.explanation.headline,
                finding.explanation.detail].joined(separator: ", ")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nothing sudden recorded in this window", systemImage: "checkmark.circle")
                .font(.callout)
            Text("Spikes are recorded continuously, whether or not this app is driving the fans. "
                 + "If your Mac has ramped up recently and nothing is listed, widen the range — "
                 + "or it warmed up gradually rather than jumping.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Attribution

    /// Offered here rather than only in the History footer, because this is the
    /// page where its absence is felt: without it a spike can be measured but
    /// not blamed on anything.
    private var attributionCallToAction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Application names were not recorded for these spikes",
                  systemImage: "person.crop.circle.badge.questionmark")
                .font(.callout)
            Text("With this on, a spike records which applications were using the processor while "
                 + "it happened. That is a timestamped record of what you run, kept on this Mac "
                 + "only, and included in exports.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Record application names",
                   isOn: Binding(get: { viewModel.recordsProcessNames },
                                 set: { enabled in
                                     Task { await viewModel.setRecordsProcessNames(enabled) }
                                 }))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Throttling

    /// Spikes and throttle episodes are different findings and are kept
    /// separate: a spike is a fast rise, an episode is running out of cooling.
    /// A machine can do either without the other.
    private var throttleSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Thermal throttling").font(.headline)
            if viewModel.episodes.isEmpty {
                Text("None in this window — the machine never ran out of cooling headroom.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let count = viewModel.episodes.count
                Text("\(count) episode\(count == 1 ? "" : "s") — sustained load with no thermal "
                     + "headroom left. The History page lists them with their durations.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(viewModel.episodes.prefix(3)) { episode in
                    HStack(spacing: 10) {
                        Text(episode.start, format: timeFormat)
                            .font(.caption.monospacedDigit())
                            .frame(width: 104, alignment: .leading)
                        if let peak = episode.peakTempC {
                            Text(String(format: "peak %.0f °C", peak)).font(.caption.monospacedDigit())
                        }
                        if let top = episode.processes.first {
                            Text(String(format: "%@ %.0f%%", top.name, top.percent))
                                .font(.caption).lineLimit(1)
                        }
                        Spacer()
                        Button("Show on chart") {
                            let bounds = [episode.start, episode.end ?? Date()].sorted()
                            onShowOnChart(bounds[0]...bounds[1])
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tint(for celsius: Double?) -> Color {
        switch celsius ?? 0 {
        case ..<60:  return .green
        case ..<80:  return .yellow
        case ..<95:  return .orange
        default:     return .red
        }
    }
}
