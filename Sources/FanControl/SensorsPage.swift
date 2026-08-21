import SwiftUI
import Charts
import SensorKit
import HistoryKit

/// Every temperature sensor the machine exposes, grouped by subsystem, with a
/// live plot per group (UI.md §7.2 "Sensors"; DESIGN §5.3 specifies Swift Charts).
///
/// A page of the Dashboard rather than a tab of Settings: this is something you
/// read, not something you change, and it belongs beside the record of the same
/// sensors rather than beside the curve editor.
struct SensorsPage: View {
    @ObservedObject var model: AppModel
    @State private var expanded: Set<SensorCategory> = []
    @State private var showChart = true

    private struct Group: Identifiable {
        let category: SensorCategory
        let readings: [TemperatureSensors.Reading]
        var id: SensorCategory { category }

        /// Everything except calibration references. A constant 51.8 °C would
        /// drag the group average and, at idle, win "max" outright — so the
        /// summary would describe a sensor that never moves.
        var measured: [TemperatureSensors.Reading] { readings.filter { !$0.isReference } }

        var hottest: Double? { measured.map(\.celsius).max() }
        var average: Double? {
            let measured = self.measured
            guard !measured.isEmpty else { return nil }
            return measured.map(\.celsius).reduce(0, +) / Double(measured.count)
        }
    }

    /// Non-empty groups only — this Mac has no sensor Apple labels as GPU, and an
    /// empty "GPU" heading would imply the reading exists and is broken.
    private var groups: [Group] {
        Dictionary(grouping: model.temperatures) { SensorCategory.classify($0.name) }
            .map { Group(category: $0.key, readings: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    /// Names shared by more than one physical sensor need their ordinal shown.
    private var ambiguousNames: Set<String> {
        TemperatureSensors.ambiguousNames(in: model.temperatures)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.temperatures.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            groupCard(group)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.temperatures.count) sensors · \(groups.count) groups")
                    .font(.callout)
                Text(historySubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Plots", isOn: $showChart).toggleStyle(.switch).controlSize(.small)
        }
        .padding(12)
    }

    /// This page plots the live window only. The saved record is one tab away,
    /// and saying so here is the difference between "not kept" and "kept
    /// somewhere else".
    private var historySubtitle: String {
        let span = model.liveHistory.span(now: Date())
        if span < 20 { return "Collecting history…" }
        return String(format: "Live plot · last %.0f min · History has the saved record",
                      span / 60)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "thermometer.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("No temperature sensors available").font(.headline)
            Text("The HID sensor interface is private and unversioned. If macOS renamed or removed it, monitoring degrades to nothing rather than failing loudly.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Group

    private func groupCard(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded.contains(group.category) { expanded.remove(group.category) }
                else { expanded.insert(group.category) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded.contains(group.category)
                          ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 10)
                    Label(group.category.title, systemImage: group.category.symbolName)
                        .font(.headline)
                    Text("\(group.readings.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                    Spacer()
                    if let hottest = group.hottest, let average = group.average {
                        Text(String(format: "avg %.0f°  max %.0f°", average, hottest))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(tint(for: hottest))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showChart { chart(group) }

            if expanded.contains(group.category) {
                Text(group.category.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                sensorTable(group)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func chart(_ group: Group) -> some View {
        Chart {
            ForEach(group.measured) { reading in
                ForEach(model.liveHistory.points(for: HistorySensors.temperatureKey(reading))) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("°C", point.average)
                    )
                    .foregroundStyle(by: .value("Sensor", reading.id))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartLegend(.hidden)          // up to 42 series in one group — a legend is noise
        .chartYAxis { celsiusAxisMarks() }
        .chartXAxis { timeAxisMarks() }
        .frame(height: 120)
        .accessibilityLabel("\(group.category.title) temperature history")
        .accessibilityValue(group.hottest.map { String(format: "peak %.0f degrees", $0) } ?? "no data")
    }

    private func sensorTable(_ group: Group) -> some View {
        VStack(spacing: 0) {
            ForEach(group.readings) { reading in
                HStack {
                    Text(reading.displayName(isAmbiguous: ambiguousNames.contains(reading.name)))
                        .font(.callout).lineLimit(1)
                        // The plain-English label is a translation, so keep the
                        // hardware name reachable for anyone cross-checking
                        // against another tool.
                        .help(reading.name)
                    if reading.isReference {
                        // Listed, because hiding a sensor the machine reports
                        // invites "where did it go?" — but marked, because it
                        // is a fixed number and is in none of the statistics
                        // above, the plot, or the fan curves.
                        Text("fixed reference")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                            .help("A calibration constant, not a measurement. Excluded from the plot, the group summary and every fan curve.")
                    }
                    Spacer()
                    // Bar as well as number: never encode severity in colour
                    // alone (UI.md §11).
                    ProgressView(value: min(max(reading.celsius, 0), 110), total: 110)
                        .frame(width: 90)
                        .tint(reading.isReference ? .secondary : tint(for: reading.celsius))
                    Text(String(format: "%.1f°C", reading.celsius))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(reading.isReference ? .secondary : .primary)
                        .frame(width: 62, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func tint(for celsius: Double) -> Color {
        switch celsius {
        case ..<60:  return .green
        case ..<80:  return .yellow
        case ..<95:  return .orange
        default:     return .red
        }
    }
}
