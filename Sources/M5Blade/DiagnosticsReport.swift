import Foundation
import FanKit

/// The clipboard bundle behind "Copy Diagnostics" in Settings › General.
///
/// Everything here was already needed to debug ISSUES.md I-3 — it took the
/// helper's log file, a `launchctl` dump, and the app's own state to piece that
/// story together. This report puts all of it one keystroke away: what the app
/// believes, what it is doing, what it is worried about, and the trail of
/// control-state transitions that led here.
///
/// Deliberately excluded: configuration *contents* (profiles and rules are the
/// user's own document; the report names the file so they can attach it if
/// they choose) and anything resembling process history unless attribution is
/// already opted into.
///
/// Built as a pure function over an input struct so tests exercise exactly the
/// formatting production shows, with no hardware, helper, or clock involved.
enum DiagnosticsReport {

    struct Input {
        var appName = "Fan Control"
        var appVersion: String
        var osVersion: String
        var hardwareModel: String
        var isTranslated: Bool
        var status: ControlStatus
        var autoMode: Bool
        var activeProfileName: String
        var resolutionReason: String
        var fans: [FanDescriptor]
        var readings: [Int: FanReading]
        var readingsUpdatedAt: [Int: Date]
        var maxTempC: Double?
        var hottestGroup: String
        var cpuPercent: Double
        /// One line from `PackagePower.diagnosticSummary()`. Empty means the
        /// caller had nothing to say, and the report omits the row entirely.
        var packagePowerSummary: String = ""
        var thermalPressure: ThermalPressure
        var isThrottling: Bool
        var concurrentControllers: [ThirdPartyFanController]
        var configProblem: String?
        var controlProblem: String?
        var chargeLimitProblem: String?
        var recordsProcessNames: Bool
        var includesSMCSensors: Bool
        var watchingSampleRate: WatchingSampleRate
        var configFileURL: URL
        var transitions: [(date: Date, from: ControlStatus, to: ControlStatus, reason: String)]
        var now: Date
    }

    static func build(_ input: Input) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        var lines: [String] = []
        lines.reserveCapacity(48 + input.transitions.count)

        lines.append("=== Fan Control diagnostics ===")
        lines.append("Generated: \(f.string(from: input.now))")
        lines.append("\(input.appName) \(input.appVersion) · macOS \(input.osVersion) · \(input.hardwareModel)")
        if input.isTranslated {
            lines.append("WARNING: running under Rosetta")
        }

        lines.append("")
        lines.append("--- State ---")
        lines.append("Control status : \(input.status.label)")
        lines.append("Auto mode      : \(input.autoMode ? "on (macOS drives)" : "off (this app drives)")")
        lines.append("Active profile : \(input.activeProfileName)")
        lines.append("Why            : \(input.resolutionReason)")
        lines.append("Hottest sensor : \(input.maxTempC.map { String(format: "%.1f °C", $0) } ?? "no reading")"
                     + (input.hottestGroup.isEmpty ? "" : " (\(input.hottestGroup))"))
        lines.append(String(format: "CPU load       : %.0f%%", input.cpuPercent))
        if !input.packagePowerSummary.isEmpty {
            lines.append("Package power  : \(input.packagePowerSummary)")
        }
        lines.append("Thermal state  : \(describe(input.thermalPressure))\(input.isThrottling ? " · throttle episode open" : "")")

        lines.append("")
        lines.append("--- Fans ---")
        if input.fans.isEmpty {
            lines.append("none discovered")
        }
        for fan in input.fans {
            let rpm = input.readings[fan.index]?.actualRPM
            let updated = input.readingsUpdatedAt[fan.index].map { f.string(from: $0) } ?? "never"
            let age: String
            if let at = input.readingsUpdatedAt[fan.index] {
                age = input.now.timeIntervalSince(at) >= AppModel.readingStalenessLimit
                    ? "STALE" : "\(Int(input.now.timeIntervalSince(at)))s ago"
            } else {
                age = "no reading"
            }
            let low = fan.minRPM.map { String(format: "%.0f", $0) } ?? "?"
            let high = fan.maxRPM.map { String(format: "%.0f", $0) } ?? "?"
            lines.append("Fan \(fan.index + 1): \(low)–\(high) rpm · now \(rpm.map { String(format: "%.0f", $0) } ?? "--") · read \(updated) (\(age))")
        }

        if !input.concurrentControllers.isEmpty {
            lines.append("")
            lines.append("--- Other fan controllers ---")
            for controller in input.concurrentControllers {
                lines.append("\(controller.productName) (\(controller.identifier))"
                             + (controller.runningAsRoot ? " — RUNNING AS ROOT" : " — installed, not running"))
            }
        }

        lines.append("")
        lines.append("--- Problems ---")
        if input.configProblem == nil && input.controlProblem == nil && input.chargeLimitProblem == nil {
            lines.append("none reported")
        }
        if let p = input.controlProblem { lines.append("Control  : \(p)") }
        if let p = input.configProblem { lines.append("Config   : \(p)") }
        if let p = input.chargeLimitProblem { lines.append("Charging : \(p)") }

        lines.append("")
        lines.append("--- Settings ---")
        lines.append("Process-name attribution : \(input.recordsProcessNames ? "on" : "off")")
        lines.append("SMC sensor source        : \(input.includesSMCSensors ? "on" : "off")")
        lines.append("Sampling while watching  : every \(Int(input.watchingSampleRate.interval)) s")
        lines.append("Config file              : \(input.configFileURL.path)")

        if !input.transitions.isEmpty {
            lines.append("")
            lines.append("--- Recent control transitions ---")
            for t in input.transitions.suffix(20) {
                let time = f.string(from: t.date)
                lines.append("\(time): \(t.from.label) → \(t.to.label) — \(t.reason)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func describe(_ pressure: ThermalPressure) -> String {
        switch pressure {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Hardware model, e.g. "Mac17,8". The one identifier that says which fan
    /// controller and which SMC key layout produced everything above.
    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
