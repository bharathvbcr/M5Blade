import Foundation
import ServiceManagement

/// Launch at login, via `SMAppService.mainApp` (UI.md §10).
///
/// This registers *the app bundle itself* — it has nothing to do with the
/// privileged helper, which is a LaunchDaemon installed separately by
/// `install-helper.sh` and starts at boot regardless of this setting.
///
/// macOS keys the registration to the bundle's identity and location. Moving or
/// re-signing the app invalidates it, which is why `status` is read back from the
/// system rather than mirrored in our own config.
enum LoginItem {

    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)

        var isOn: Bool { self == .enabled }

        /// Nil when there is nothing the user needs to know.
        var explanation: String? {
            switch self {
            case .enabled, .disabled:
                return nil
            case .requiresApproval:
                return "Approve Fan Control in System Settings › General › Login Items to finish enabling this."
            case .unavailable(let why):
                return why
            }
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:            return .enabled
        case .notRegistered:      return .disabled
        case .requiresApproval:   return .requiresApproval
        case .notFound:           return .unavailable("macOS can't find this app bundle — move it to Applications and try again.")
        @unknown default:         return .unavailable("Unknown login item status.")
        }
    }

    /// Returns the resulting state so the caller can show what actually happened
    /// rather than assuming the request succeeded.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> State {
        do {
            if enabled {
                // Registering while already registered throws; treat as success.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return state
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
