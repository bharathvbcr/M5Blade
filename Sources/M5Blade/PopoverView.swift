import SwiftUI
import FanKit
import ProfileKit
import SensorKit
import HistoryKit

struct PopoverView: View {
    @ObservedObject var model: AppModel
    var onOpenSettings: () -> Void
    var onOpenDashboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let warning = model.concurrentControllerWarning {
                // I-9: another root writer of the same SMC keys. This outranks
                // the app's own degraded status — it explains refusals the app
                // did not cause.
                WarningBanner(message: warning)
            }
            if model.status.isDegraded || model.controlProblem != nil { banner }
            Divider()
            temperatures
            Divider()
            fanRows
            Divider()
            systemRow
            Divider()
            footer
        }
        .frame(width: 340)
        .appDialogs(model)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.activeProfile.name).font(.headline)
                    statusPill
                }
                // Line 2 is load-bearing: automation the user can't explain is
                // automation they'll disable.
                Text(model.resolution?.source.displayReason ?? "Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(model.profiles) { profile in
                    Button(profile.name) { model.selectProfile(profile.id) }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            // The label *is* the disclosure chevron, so the style's own indicator
            // has to go — otherwise macOS draws its arrow next to ours and the
            // profile switcher shows two down arrows.
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
    }

    private var statusPill: some View {
        Text(model.status.label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(model.status.isDegraded ? Color.orange.opacity(0.18)
                                                : Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var banner: some View {
        // A concrete failure beats a status label. "The helper refused a target
        // for fan 2" is actionable; "Watching" is not, and it is what the user
        // used to see when a write was being rejected every second.
        let text: String = model.controlProblem ?? {
            switch model.status {
            case .daemonUnavailable:      return "Helper not running — fans are on macOS control"
            case .unverifiedOS(let why):  return "Fan control unavailable: \(why)"
            case .emergency:              return "Critical temperature — fans at maximum"
            default:                      return ""
            }
        }()
        if !text.isEmpty {
            WarningBanner(message: text,
                          actionTitle: model.status == .daemonUnavailable ? "Set Up…" : nil,
                          action: model.status == .daemonUnavailable ? { model.openHelperSetup() } : nil)
        }
    }

    /// Same rule as the Sensors page: a name several sensors share needs its
    /// index, and the two views must not disagree about which those are.
    private var ambiguousNames: Set<String> {
        TemperatureSensors.ambiguousNames(in: model.temperatures)
    }

    private var temperatures: some View {
        VStack(spacing: 6) {
            // Hottest first, and never a calibration reference: three rows is
            // too few to spend one on a constant.
            ForEach(model.temperatures.lazy.filter { !$0.isReference }
                        .sorted { $0.celsius > $1.celsius }.prefix(3)) { reading in
                HStack {
                    Text(reading.displayName(isAmbiguous: ambiguousNames.contains(reading.name)))
                        .font(.callout).lineLimit(1)
                        .help(reading.name)
                    Spacer()
                    Sparkline(points: model.liveHistory
                        .points(for: HistorySensors.temperatureKey(reading)))
                        .frame(width: 64, height: 14)
                    Text(String(format: "%.0f°C", reading.celsius))
                        .font(.callout.monospacedDigit())
                }
            }
            if model.temperatures.isEmpty {
                HStack {
                    Text("Temperature sensors unavailable")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private var fanRows: some View {
        VStack(spacing: 8) {
            ForEach(model.fans) { fan in
                let reading = model.readings[fan.index]
                let rpm = reading?.actualRPM ?? 0
                // Duty, not control percent: a fan idling at its 1350 rpm minimum
                // is spinning, and reporting that as 0% contradicts the rpm shown
                // right beside it.
                let duty = fan.dutyPercent(forRPM: rpm)
                let stale = model.readingIsStale(fan.index)
                HStack(spacing: 8) {
                    Text("Fan \(fan.index + 1)").font(.callout)
                    Text(String(format: "%.0f rpm", rpm))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    if stale {
                        // A frozen number that looks live is worse than no
                        // number: this Mac's reads come back every tick, so
                        // anything older than a few of them is a wedged SMC,
                        // not a steady fan.
                        Text("stale")
                            .font(.caption2).foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18)).clipShape(Capsule())
                            .accessibilityLabel("reading out of date")
                    }
                    Spacer()
                    ProgressView(value: min(duty, 100), total: 100)
                        .frame(width: 90)
                    Text(String(format: "%.0f%%", duty))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                        .foregroundStyle(stale ? Color.secondary : Color.primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Fan \(fan.index + 1)")
                .accessibilityValue(stale
                    ? "reading out of date"
                    : String(format: "%.0f rpm, %.0f percent of maximum", rpm, duty))
            }
            if model.fans.isEmpty {
                Text("No controllable fans found")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var systemRow: some View {
        VStack(spacing: 6) {
            HStack {
                Text(String(format: "Load %.0f%%", model.cpuPercent))
                    .font(.callout.monospacedDigit())
                if let watts = model.cpuWattsReading {
                    Text(PowerText.watts(watts))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("CPU package power \(PowerText.watts(watts))")
                }
                Spacer()
                if let memory = model.memory {
                    // GiB, because that is what Activity Monitor and "About This Mac"
                    // mean by "GB" for memory. See `MemoryFormat`.
                    Text(String(format: "Memory %.1f / %.0f GB",
                                MemoryFormat.gibibytes(memory.used),
                                MemoryFormat.gibibytes(memory.total)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            availabilityRow
        }
        .padding(12)
    }

    /// What the machine can still absorb, both directions: memory it can hand
    /// out without evicting an app, and disk it can write before the volume is
    /// full. Absent rather than zero when a sample has not arrived yet.
    @ViewBuilder
    private var availabilityRow: some View {
        if model.memory != nil || model.availableDiskBytes != nil {
            HStack {
                if let memory = model.memory {
                    // Same basis as `used` above, so the pair cannot disagree.
                    // GB here is GiB — see `MemoryFormat`.
                    Text(String(format: "%.1f GB available",
                                MemoryFormat.gibibytes(memory.available)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if let bytes = model.availableDiskBytes {
                    // Storage is 1e9-based — Finder's convention. See `StorageFormat`.
                    Text(String(format: "%.0f GB available on disk",
                                StorageFormat.gigabytes(bytes)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings", action: onOpenSettings)
            Button("Dashboard", action: onOpenDashboard)
            Spacer()
            // The panic button. Never moves, always present.
            Button("Stock") { Task { await model.releaseToStock() } }
                .tint(.red)
        }
        .padding(12)
    }
}

/// A 60-second trace beside each temperature (UI.md §4).
///
/// Drawn from `AppModel.liveHistory` — `HistoryKit`'s in-memory tier — rather
/// than from the database, because that data is already in hand at the right
/// resolution and a popover should not wait on a round trip to open.
private struct Sparkline: View {
    let points: [SeriesPoint]

    var body: some View {
        Canvas { context, size in
            guard let locations = SparklineGeometry.path(for: points, in: size),
                  let first = locations.first else { return }
            var path = Path()
            path.move(to: first)
            for location in locations.dropFirst() { path.addLine(to: location) }
            context.stroke(path, with: .color(.secondary), lineWidth: 1)
        }
        .accessibilityHidden(true)   // the reading beside it carries the value
    }
}
