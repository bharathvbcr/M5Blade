import SwiftUI
import AppKit
import SensorKit

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
                sensorSources
                Divider()
                startup
                Divider()
                storage
            }
            .padding(16)
        }
        .onAppear { loginState = LoginItem.state }
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
