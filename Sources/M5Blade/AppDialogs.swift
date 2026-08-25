import SwiftUI
import AppKit

/// The sheet behind "Set Up…": the one command that fixes a missing or
/// stale-pinned helper, with a copy button, and what it will do spelled out
/// before it is run.
///
/// The command is derived from this bundle's actual location — the app may live
/// in /Applications, in ~/Downloads, or on a DMG mount, and an instruction
/// naming the wrong path is worse than none.
struct HelperSetupSheet: View {
    @ObservedObject var model: AppModel

    @State private var copied = false

    private var command: String { model.helperInstallCommand }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install the privileged helper")
                .font(.headline)

            Text("Fan control writes fan speeds directly to the SMC, which only root "
                   + "may do. The helper is a small launch daemon this app installs once; "
                   + "it refuses every client except this exact build of Fan Control.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Paste this into Terminal:")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .disabled(copied)
            }

            Label("Terminal will ask for your password. When the helper answers, "
                    + "the warning clears by itself — no restart needed.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { model.closeHelperSetup() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The two conversations every surface must be able to hold: the first-run
/// consent before fans come under this app's control, and helper setup. Both
/// are driven by `AppModel` state rather than by whichever view happened to
/// trigger the action, so the popover and the settings window tell the same
/// story instead of each carrying its own copy.
struct AppDialogs: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .alert("Take over fan control?", isPresented: Binding(
                get: { model.pendingControlConsent != nil },
                set: { if !$0 { model.cancelControlConsent() } }
            )) {
                Button("Enable") { model.confirmControlConsent() }
                Button("Cancel", role: .cancel) { model.cancelControlConsent() }
            } message: {
                Text("Fan Control will drive your fans through a privileged helper "
                       + "once per second. The safety floor, thermal-pressure floor, "
                       + "emergency release, and the helper's watchdog stay active the "
                       + "whole time, and you can hand the fans back to macOS at any "
                       + "moment from the menu bar.")
            }
            .sheet(isPresented: Binding(
                get: { model.showsHelperSetup },
                set: { if !$0 { model.closeHelperSetup() } }
            )) {
                HelperSetupSheet(model: model)
            }
    }
}

extension View {
    /// Consent alert + helper-setup sheet, attached wherever fan control can be
    /// requested or its absence reported.
    func appDialogs(_ model: AppModel) -> some View {
        modifier(AppDialogs(model: model))
    }
}
