import SwiftUI
import AppKit
import PowerKit
import SensorKit
import ProfileKit

/// Startup, control mode, and where things live on disk.
struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @State private var loginState: LoginItem.State = .disabled
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controlMode
                Divider()
                concurrentControllers
                Divider()
                alerts
                Divider()
                menuBarSection
                Divider()
                battery
                Divider()
                sensorSources
                Divider()
                startup
                Divider()
                storage
                Divider()
                configFileSection
                Divider()
                diagnostics
            }
            .padding(16)
        }
        .onAppear {
            loginState = LoginItem.state
            refreshAlerterState()
            model.refreshBattery()
        }
    }

    // MARK: - Menu bar

    /// What the status item draws, and how hard the sampling tick works while
    /// macOS owns the fans. Both are honest trade-offs presented as choices:
    /// width against the notch, and record resolution against sensor cost.
    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu bar").font(.headline)

            Picker("Readout", selection: Binding(
                get: { model.statusDisplayMode },
                set: { model.setStatusDisplayMode($0) }
            )) {
                ForEach(StatusDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .help("A notched MacBook can clip a wide menu bar item with no way to detect it. Pick a narrower readout if yours disappears.")

            Picker("Sensor polling while watching", selection: Binding(
                get: { model.watchingSampleRate },
                set: { model.setWatchingSampleRate($0) }
            )) {
                ForEach(WatchingSampleRate.allCases, id: \.self) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .pickerStyle(.radioGroup)

            Text(model.watchingSampleRate.explanation)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Diagnostics

    /// One button that answers "what is the app doing?" — the report is built
    /// from published state only, so it cannot contradict what the screen
    /// shows. The confirmation is transient feedback that the clipboard now
    /// holds something, nothing more.
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics").font(.headline)
            HStack {
                Button("Copy Diagnostics") { copyDiagnostics() }
                if copiedRecently {
                    Label("Copied", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.green)
                        .transition(.opacity)
                        .accessibilityLabel("Diagnostics copied to clipboard")
                }
                Spacer()
            }
            Text("Status, fans, problems, and the recent control-state transitions — everything needed to describe a misbehaviour in one paste.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @State private var copiedRecently = false

    private func copyDiagnostics() {
        let report = model.makeDiagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copiedRecently = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedRecently = false
        }
    }

    // MARK: - Configuration file

    /// Export, import, and where it all lives. The import asks first — it
    /// *replaces* the working profiles and rules — and reports what the
    /// reconciliation changed on the way in.
    @State private var importCandidate: Data?
    @State private var importMessage: String?

    private var configFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration").font(.headline)
            HStack {
                Button("Show File") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.configFileURL])
                }
                Button("Export…") { exportConfiguration() }
                Button("Import…") { pickImportFile() }
                Spacer()
            }
            let backupNote = "Profiles, rules, and the default — one JSON document at "
                + "~/Library/Application Support/M5Blade/config.json. The last "
                + "\(ConfigStore.backupCount) good versions are kept beside it as "
                + "config.backup-*.json."
            Text(backupNote)
                .font(.caption).foregroundStyle(.secondary)

            if let message = importMessage {
                WarningBanner(message: message,
                              shape: .card,
                              actionTitle: "Dismiss") { importMessage = nil }
            }
        }
        .confirmationDialog("Replace your configuration?", isPresented: Binding(
            get: { importCandidate != nil },
            set: { if !$0 { importCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                if let data = importCandidate {
                    importMessage = model.importConfiguration(data) ?? "Imported."
                }
                importCandidate = nil
            }
            Button("Cancel", role: .cancel) { importCandidate = nil }
        } message: {
            Text(importMessageText)
        }
    }

    private var importMessageText: String {
        guard let summary = importCandidate.flatMap({ model.importSummary($0) }) else {
            return "This file cannot be read as an M5Blade configuration."
        }
        var text = "The file holds \(summary.profiles) profile(s) and "
            + "\(summary.rules) rule(s). Your current configuration is backed up first."
        if !summary.notices.isEmpty {
            text += "\n\n" + summary.notices.joined(separator: "\n")
        }
        return text
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "M5Blade-config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A failed export must not look like a successful one: this file is
        // what bug reports are asked to attach, and a zero-byte or half-written
        // export used to land silently. `configurationExportData` returns nil
        // when encoding fails rather than empty data pretending to be a file.
        guard let data = model.configurationExportData() else {
            importMessage = "The configuration could not be encoded for export."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            importMessage = "The export could not be written: \(error.localizedDescription)"
        }
    }

    private func pickImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        importCandidate = data
    }

    // MARK: - Battery

    /// T-3. Health is read-only and always shown when a battery exists; the
    /// charge-limit controls exist only behind an explicit opt-in (T-3b),
    /// because DESIGN §6.3 recommends against third-party limiting and this
    /// is the point where that recommendation is either accepted or
    /// consciously overridden.
    @ViewBuilder
    private var battery: some View {
        if let health = model.batteryHealth, health.batteryInstalled != false {
            VStack(alignment: .leading, spacing: 8) {
                Text("Battery").font(.headline)

                HStack(spacing: 16) {
                    if let charge = health.chargePercent {
                        labeledValue("Charge", String(format: "%.0f%%", charge))
                    }
                    if let raw = health.rawHealthPercent {
                        labeledValue("Capacity (raw)", String(format: "%.0f%%", raw))
                    }
                    if let apple = health.appleMaxPercent {
                        labeledValue("Capacity (Apple)", String(format: "%.0f%%", apple))
                    }
                    if let cycles = health.cycleCount {
                        labeledValue("Cycles", "\(cycles)")
                    }
                    Spacer()
                }

                // Both capacity figures are shown together or neither: one
                // alone invites "which of these is true?", which is exactly
                // the disagreement DESIGN §6.2 says to expect and explain.
                if health.rawHealthPercent != nil || health.appleMaxPercent != nil {
                    Text("The two capacity figures disagree by design — Apple's number is smoothed "
                           + "over time, the raw one is measured. Expect drift between them.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                chargeLimitSection(health)

                Button("Open Battery Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func chargeLimitSection(_ health: BatteryHealth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Firmware charge limit").font(.subheadline.weight(.medium))

            if let status = model.chargeLimit {
                if status.supported {
                    Text(stateDescription(chargeState(status.percent)))
                        .font(.caption.monospacedDigit())

                    Toggle(isOn: Binding(
                        get: { model.chargeLimitControlOptedIn },
                        set: { model.setChargeLimitControlOptedIn($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow changing it from here")
                            Text("Writes go through the privileged helper to the SMC. Modern macOS may "
                                    + "refuse them for apps other than Apple's own — every attempt is "
                                    + "verified by reading back what actually took.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if model.chargeLimitControlOptedIn {
                        Picker("Set limit to", selection: Binding(
                            get: { status.percent ?? 100 },
                            set: { percent in Task { await model.setChargeLimit(percent: percent) } }
                        )) {
                            Text("80%").tag(80)
                            Text("100%").tag(100)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        .disabled(status.percent == nil)
                    }

                    if let problem = model.chargeLimitProblem {
                        WarningBanner(message: problem, shape: .card)
                    }
                } else {
                    // The helper answered and reported no key: the one case
                    // where "not supported" is a measurement.
                    Label("This Mac's firmware exposes no third-party charge limit. macOS's own "
                            + "Charge Limit lives in System Settings → Battery.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // No answer yet — which on this machine usually means the helper
                // is not installed or its pinned signature is stale. That state
                // used to render as "not supported", stating as fact something
                // nobody had measured.
                Label("The charge-limit state is not known yet — it comes from the privileged "
                        + "helper, which has not answered. Install or repair it from the "
                        + "warning banner above.",
                      systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func chargeState(_ percent: Int?) -> ChargeLimitState {
        switch percent {
        case 80: return .limitedTo80
        case 100: return .fullCharge
        default: return .unsupported
        }
    }

    private func stateDescription(_ state: ChargeLimitState) -> String {
        switch state {
        case .limitedTo80: return "Holding at 80%"
        case .fullCharge: return "No limit — charges to full"
        case .unknown(let raw):
            return "Unrecognised state (raw \(raw)) — leaving it alone"
        case .unsupported: return "Limit state could not be read — leaving it alone"
        }
    }

    // MARK: - Alerts

    @State private var alertsEnabled = true
    @State private var alertsDenied = false

    private func refreshAlerterState() {
        alertsEnabled = model.alerter.isEnabled
        alertsDenied = model.alerter.authorizationDenied
    }

    /// T-4 / DESIGN §3.5. Authorization is requested only when an alert first
    /// fires — this toggle never triggers a permission prompt by itself.
    private var alerts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications").font(.headline)

            Toggle(isOn: Binding(
                get: { alertsEnabled },
                set: { enabled in
                    alertsEnabled = enabled
                    model.alerter.isEnabled = enabled
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify about sustained thermal throttling")
                    Text("At most one notification every 15 minutes, and only once an episode "
                           + "has run for over two minutes. Everything is recorded in History "
                           + "either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if alertsEnabled && alertsDenied {
                WarningBanner(message: "Notification permission was not granted, so these "
                                    + "alerts cannot reach you. Allow Fan Control in System "
                                    + "Settings → Notifications to turn them on.",
                              shape: .card)
            }
        }
    }

    // MARK: - Concurrent controllers

    /// T-1 / I-9. Shown even when empty is false — the section only exists when
    /// there is something to say, so its absence stays meaningful.
    @ViewBuilder
    private var concurrentControllers: some View {
        if !model.concurrentControllers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other fan controllers").font(.headline)
                ForEach(model.concurrentControllers) { controller in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(controller.productName).font(.callout)
                            Text(controller.severityLabel)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(controller.runningAsRoot
                                            ? Color.orange.opacity(0.18)
                                            : Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                            Spacer()
                        }
                        Text(controller.identifier)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(controller.productName) \(controller.severityLabel)")
                }
                WarningBanner(
                    message: "Two privileged fan controllers writing the same SMC keys will keep "
                           + "overruling each other. Refused writes that name a fan “not under manual "
                           + "control” can be caused by either program.",
                    shape: .card)
            }
        }
    }

    // MARK: - Auto mode

    private var controlMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fan control").font(.headline)

            Toggle(isOn: Binding(
                get: { model.autoMode },
                set: { wantsAuto in
                    busy = true
                    Task { await model.setAutoMode(wantsAuto); busy = false }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic — let macOS control the fans")
                    Text(model.autoMode
                         ? "macOS is managing the fans. This app is only watching."
                         : "This app is driving the fans using the active profile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(busy || (!model.autoMode ? false : !model.canLeaveAutoMode))

            if !model.canLeaveAutoMode, model.autoMode {
                Label(unavailableReason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Label("Turning this on always works — it hands the fans back immediately. Turning it off needs the privileged helper.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var unavailableReason: String {
        if case .unverifiedOS(let why) = model.status { return "Fan control unavailable: \(why)" }
        if model.fans.isEmpty { return "No controllable fans were found on this Mac." }
        return "Fan control is unavailable."
    }

    // MARK: - Sensor sources

    /// The SMC source is opt-in, and the toggle has to say what it costs rather
    /// than only what it gives. Counts come from the live reading rather than
    /// from a number written here, because they differ per Mac and a hardcoded
    /// "292" would be wrong on the next one.
    private var sensorSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sensors").font(.headline)

            Toggle(isOn: Binding(
                get: { model.includesSMCSensors },
                set: { wantsSMC in Task { await model.setIncludesSMCSensors(wantsSMC) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read the SMC's own temperature sensors")
                    Text(model.includesSMCSensors
                         ? "Reading both sources. \(sensorSummary)"
                         : "Reading the HID sensor hub only. \(sensorSummary)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Label("The SMC reports no names, so these appear as raw four-character keys. Only the processor and graphics families have been shown by measurement to track their subsystem — those are charted and can drive a fan curve. The rest are displayed live and left at that.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)

            if model.includesSMCSensors {
                Label("Each sample costs about 57 ms more, and the extra charted sensors grow the history database. Turning this back off keeps everything already recorded — those series just stop growing.",
                      systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "292 shown · 87 charted", from what is actually being read right now.
    private var sensorSummary: String {
        let shown = model.temperatures.count
        guard shown > 0 else { return "No sensors reporting yet." }
        let charted = TemperatureSources.attributed(model.temperatures).count
        return "\(shown) shown · \(charted) charted."
    }

    // MARK: - Startup

    private var startup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Startup").font(.headline)

            Toggle(isOn: Binding(
                get: { loginState.isOn },
                set: { loginState = LoginItem.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Fan Control at login")
                    Text("Starts the menu bar app when you log in. The privileged helper is separate and already starts at boot once installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let explanation = loginState.explanation {
                WarningBanner(message: explanation,
                              shape: .card,
                              actionTitle: loginState == .requiresApproval ? "Open Login Items" : nil,
                              action: loginState == .requiresApproval
                                  ? { LoginItem.openSystemSettings() } : nil)
            }

            Button("Re-check") { loginState = LoginItem.state }
                .controlSize(.small)
                .help("macOS ties this to the app's location and signature — rebuilding or moving the app can reset it.")
        }
    }

    // MARK: - Storage

    private var storage: some View {
        VStack(alignment: .leading, spacing: 14) {
            fileRow(title: "Configuration",
                    url: model.configFileURL,
                    explanation: "Profiles, curves, and rules are written here on every edit.")

            // The size and the clear button deliberately live in the History
            // window instead of being repeated here — one control, one place.
            fileRow(title: "History",
                    url: model.historyFileURL,
                    explanation: "Sensors, fan speeds, throttle episodes, and profile "
                               + "changes. The Dashboard's History page shows its size and can clear it.")
        }
    }

    private func fileRow(title: String, url: URL, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack {
                Text(url.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
                // A history database that hasn't been created yet has nothing to
                // reveal, and Finder silently does nothing rather than saying so.
                .disabled(!FileManager.default.fileExists(atPath: url.path))
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
    }
}
