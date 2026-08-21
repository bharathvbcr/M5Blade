import SwiftUI
import ProfileKit

/// Everything the user can author, in one window.
///
/// Edits persist as they are made — `AppModel` writes the config on every
/// mutation — so there is no OK/Cancel to get wrong. The one exception is the
/// curve editor, where a drag is a continuous gesture and Apply is the commit.
///
/// Only things you change. The sensor readout moved to the Dashboard, next to
/// the recorded history of those same sensors, where it is actually useful.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.controlProblem { banner(problem) }
            if let problem = model.configProblem { banner(problem) }
            TabView {
                GeneralTab(model: model)
                    .tabItem { Label("General", systemImage: "gearshape") }
                ProfilesTab(model: model)
                    .tabItem { Label("Profiles", systemImage: "slider.horizontal.3") }
                CurveEditorView(model: model)
                    .tabItem { Label("Curves", systemImage: "chart.xyaxis.line") }
                AutomationTab(model: model)
                    .tabItem { Label("Automation", systemImage: "wand.and.stars") }
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private func banner(_ problem: String) -> some View {
        WarningBanner(message: problem, actionTitle: "Show File") {
            NSWorkspace.shared.activateFileViewerSelecting([model.configFileURL])
        }
    }
}
