import Foundation
import SMCKit
import FanKit
import SensorKit

// smcfan — Phase 1 probe tool.
//
// Everything except `set`/`auto` is read-only and needs no privileges. Run
// `smcfan probe` first: it verifies the struct layout, the mode key casing, and
// the fan ranges on YOUR machine before anything is ever written.

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Print a release report and hand back its exit status. The status is the
/// point: `smcfan auto` is what `uninstall-helper.sh` and anyone scripting
/// around this tool calls to be sure the fans are back under macOS.
@discardableResult
func emit(_ report: ReleaseReport) -> Int32 {
    report.standardOut.forEach(out)
    report.standardError.forEach(err)
    return report.exitCode
}

func usage() {
    out("""
    smcfan — SMC fan and sensor probe

    USAGE
      smcfan probe              Verify hardware support (read-only, start here)
      smcfan fans               List fans with current rpm and mode
      smcfan sensors [--smc]    List temperature sensors (--smc adds the SMC's own)
      smcfan keys <prefix>      Dump SMC keys matching a prefix, e.g. F0
      smcfan watch [seconds]    Live readout until interrupted
      smcfan set <fan> <rpm>    Set target rpm            (requires root)
      smcfan auto [fan]         Return fan(s) to macOS    (requires root)

    Reads need no privileges. Writes require root and are refused otherwise.
    """)
}

@discardableResult
func requireRoot(_ action: String) -> Bool {
    guard getuid() == 0 else {
        err("'\(action)' requires root. Re-run with sudo.")
        return false
    }
    return true
}

func runProbe() async {
    out("Hardware   : \(SystemMetrics.hardwareModel)")
    out("macOS      : \(ProcessInfo.processInfo.operatingSystemVersionString)")
    out("Page size  : \(SystemMetrics.pageSize) bytes")
    out("Translated : \(SystemMetrics.isTranslated ? "YES — refusing, build arm64" : "no")")
    out("")

    let smc = SMCConnection()
    do {
        try await smc.open()
        out("SMC        : connected (struct layout verified at 80 bytes)")
    } catch {
        err("SMC        : FAILED — \(error)")
        return
    }

    guard let fanCount = try? await smc.readUInt8(SMCKey("FNum")) else {
        err("FNum       : unreadable — this Mac may have no controllable fans")
        return
    }
    out("Fans       : \(fanCount)")
    if fanCount == 0 {
        out("")
        out("No fans reported. If this is a MacBook Air, that is expected —")
        out("it is passively cooled. Monitoring will work; control will not.")
        return
    }

    var suffix: String?
    if await smc.exists(SMCKey("F0Md")) { suffix = "Md" }
    else if await smc.exists(SMCKey("F0md")) { suffix = "md" }

    let hasFtst = await smc.exists(SMCKey("Ftst"))

    out("Mode key   : \(suffix.map { "F0\($0)" } ?? "NOT FOUND — control unavailable")")
    out("Ftst key   : \(hasFtst ? "present — Ftst unlock required (M3/M4 path)" : "absent — direct mode writes (M1 or M5 path)")")

    switch (suffix, hasFtst) {
    case ("md", false): out("Generation : M5-style — easiest case, no unlock needed")
    case ("Md", true):  out("Generation : M3/M4-style — unlock sequence required")
    case ("Md", false): out("Generation : M1/M2 or Intel — direct writes")
    default:            out("Generation : unrecognised — stay in monitor-only mode")
    }

    out("")
    for i in 0..<Int(fanCount) {
        // The probe reports what it can address and says so when it cannot,
        // rather than reading a truncated key and printing another fan's rpm.
        guard let acKey = SMCKey.fan(i, "Ac"),
              let mnKey = SMCKey.fan(i, "Mn"),
              let mxKey = SMCKey.fan(i, "Mx") else {
            out(String(format: "Fan %d     : not addressable — no four-character SMC key", i))
            continue
        }
        let actual = (try? await smc.readDouble(acKey)) ?? -1
        let minRPM = try? await smc.readDouble(mnKey)
        let maxRPM = try? await smc.readDouble(mxKey)
        var mode = "?"
        if let suffix, let modeKey = SMCKey.fan(i, suffix),
           let raw = try? await smc.readUInt8(modeKey) {
            mode = FanMode(rawValue: raw).map { "\($0) (\(raw))" } ?? "unknown (\(raw))"
        }
        let range = (minRPM != nil && maxRPM != nil)
            ? String(format: "%.0f–%.0f rpm", minRPM!, maxRPM!)
            : "range not reported"
        out(String(format: "Fan %d      : %.0f rpm · %@ · mode %@", i, actual, range, mode))
    }

    out("")
    let sensors = TemperatureSensors()
    if sensors.isAvailable {
        let readings = sensors.readAll()
        out("Sensors    : \(readings.count) temperature sensor(s) via HID")
        let ambiguous = TemperatureSensors.ambiguousNames(in: readings)
        for r in readings.prefix(8) {
            let label = r.displayName(isAmbiguous: ambiguous.contains(r.name))
            out(String(format: "             %-28@ %.1f °C", label as NSString, r.celsius))
        }
        if readings.count > 8 { out("             … \(readings.count - 8) more") }
    } else {
        out("Sensors    : HID sensor API unavailable — temperatures will be missing")
    }

    out("")
    out("Nothing was written. If the mode key was found and the fan ranges look")
    out("sane, the hardware supports control. Install the helper to proceed.")
    await smc.close()
}

func listFans() async {
    let backend = SMCFanBackend()
    do {
        try await backend.connect()
        let fans = try await backend.discoverFans()
        for fan in fans {
            let r = try await backend.readFan(fan.index)
            out(String(format: "Fan %d  %.0f rpm  target %@  mode %@  [%.0f–%.0f]",
                       fan.index, r.actualRPM,
                       r.targetRPM.map { String(format: "%.0f", $0) } ?? "—",
                       r.mode.map { "\($0)" } ?? "?",
                       fan.effectiveMin, fan.effectiveMax))
        }
    } catch {
        err("\(error)")
    }
}

func listSensors(includeSMC: Bool) async {
    let sensors = TemperatureSensors()
    guard sensors.isAvailable || includeSMC else {
        err("HID sensor API unavailable")
        return
    }
    let sources = TemperatureSources(includeSMC: includeSMC)
    let readings = await sources.readAll()
    let curveMax = await sources.maxTemperature()
    let ambiguous = TemperatureSensors.ambiguousNames(in: readings)
    let labels = readings.map { $0.displayName(isAmbiguous: ambiguous.contains($0.name)) }

    // Both names. The left column is what the app shows; the right is the
    // hardware name, kept so a reading can still be cross-checked against
    // another tool or an Apple bug report.
    func pad(_ s: String, _ width: Int) -> String {
        s + String(repeating: " ", count: max(0, width - s.count))
    }
    let labelWidth = labels.map(\.count).max() ?? 0
    let rawWidth = readings.map(\.name.count).max() ?? 0

    for (reading, label) in zip(readings, labels) {
        out(pad(label, labelWidth) + "  " + pad(reading.name, rawWidth)
            + String(format: "  %6.1f °C", reading.celsius)
            + "  " + SensorCategory.classify(reading.name).rawValue)
    }
    out("")
    out(String(format: "%d sensor(s). Curve input: %@",
               readings.count,
               curveMax.map { String(format: "%.1f °C", $0) } ?? "none"))
    if includeSMC {
        out("Four-character names are raw SMC keys — the SMC reports no name for")
        out("them and this tool does not invent one. Only the Tp and Tg families")
        out("reach the curve input; the rest are shown but not trusted to drive a fan.")
    }
}

func dumpKeys(prefix: String) async {
    let smc = SMCConnection()
    try? await smc.open()
    let suffixes = ["Ac", "Tg", "Mn", "Mx", "Md", "md", "Sf", "Tp"]
    for s in suffixes {
        let key = SMCKey(prefix + s)
        guard let info = try? await smc.keyInfo(key) else { continue }
        let value = try? await smc.read(key)
        let decoded = value?.doubleValue.map { String(format: "%.2f", $0) } ?? "—"
        out(String(format: "%@  type %@  size %d  r%@w%@  = %@",
                   key.description, info.typeString, info.dataSize,
                   info.isReadable ? "+" : "-", info.isWritable ? "+" : "-", decoded))
    }
    await smc.close()
}

func watch(seconds: Int) async {
    let backend = SMCFanBackend()
    let sensors = TemperatureSensors()
    let metrics = SystemMetrics()
    try? await backend.connect()
    guard let fans = try? await backend.discoverFans() else { err("no fans"); return }

    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    _ = metrics.cpuUsage()
    while Date() < deadline {
        let temp = sensors.maxTemperature()
        let cpu = metrics.cpuUsage()?.total ?? 0
        var line = String(format: "%@  cpu %5.1f%%  temp %@",
                          ISO8601DateFormatter().string(from: Date()),
                          cpu,
                          temp.map { String(format: "%.1f°C", $0) } ?? "  —  ")
        for fan in fans {
            if let r = try? await backend.readFan(fan.index) {
                line += String(format: "  fan%d %.0f", fan.index, r.actualRPM)
            }
        }
        out(line)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

func setFan(_ index: Int, rpm: Double) async -> Int32 {
    guard requireRoot("set") else { return 1 }
    let backend = SMCFanBackend()
    do {
        try await backend.connect()
        _ = try await backend.discoverFans()
        try await backend.setMode(.manual, fan: index)
        try await backend.setTarget(rpm: rpm, fan: index)
        out(String(format: "Fan %d target set to %.0f rpm.", index, rpm))
        out("This process is not supervising the fan. Run 'smcfan auto \(index)' when done.")
        return 0
    } catch {
        err("\(error)")
        // The rollback is the part that matters most here: if it did not take,
        // the fan this command half-configured is still under manual control
        // with nothing supervising it, and saying so is the whole job.
        emit(releaseReport(await backend.releaseAll(), subject: "Fans"))
        return 1
    }
}

func autoFan(_ index: Int?) async -> Int32 {
    guard requireRoot("auto") else { return 1 }
    let backend = SMCFanBackend()
    do {
        try await backend.connect()
        let fans = try await backend.discoverFans()
        if let index {
            return emit(releaseReport(await releaseOne(backend, fan: index),
                                      subject: "Fan \(index)"))
        }
        return emit(releaseReport(await backend.releaseAll(),
                                  subject: "All \(fans.count) fan(s)"))
    } catch {
        err("\(error)")
        return 1
    }
}

// MARK: - Entry

/// Returns the process exit status. The write commands are the ones scripts act
/// on, so they report failure in the status as well as on stderr.
func runCommand(_ args: [String]) async -> Int32 {
    guard let command = args.first else { usage(); return 0 }
    switch command {
    case "probe":   await runProbe()
    case "fans":    await listFans()
    case "sensors": await listSensors(includeSMC: args.contains("--smc"))
    case "keys":    await dumpKeys(prefix: args.count > 1 ? args[1] : "F0")
    case "watch":   await watch(seconds: args.count > 1 ? Int(args[1]) ?? 30 : 30)
    case "set":
        guard args.count > 2, let fan = Int(args[1]), let rpm = Double(args[2]) else {
            err("usage: smcfan set <fan> <rpm>"); return 1
        }
        return await setFan(fan, rpm: rpm)
    case "auto":
        return await autoFan(args.count > 1 ? Int(args[1]) : nil)
    default:
        usage()
    }
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
Task {
    // `exit` flushes stdout, so the report is on the terminal before we go.
    exit(await runCommand(arguments))
}
dispatchMain()
