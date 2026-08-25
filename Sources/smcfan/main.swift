import Foundation
import SMCKit
import FanKit
import DaemonProtocol
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
      smcfan status             Privileged helper: installed, pinned, running?
      smcfan fans               List fans with current rpm and mode
      smcfan sensors [--smc]    List temperature sensors (--smc adds the SMC's own)
      smcfan keys <prefix>      Dump SMC keys matching a prefix, e.g. F0
      smcfan power [seconds]    CPU/GPU package watts via IOReport (read-only)
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

/// Live CPU/GPU package power, so the IOReport channel names, deltas and unit
/// scaling are verified against this machine rather than assumed. The first
/// sample only establishes the baseline — exactly what the app's reader does.
func probePower(seconds: Int) async {
    let power = PackagePower()
    guard power.isAvailable else {
        err("IOReport subscription refused — package power unavailable on this macOS")
        return
    }
    out("IOReport subscribed. First sample establishes the baseline.")
    var last: PackagePower.Sample?
    var everMeasured = false
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let sample = power.sample()
        let cpu = sample.cpuWatts.map { String(format: "%6.2f W", $0) } ?? "   —  "
        let gpu = sample.gpuWatts.map { String(format: "%6.2f W", $0) } ?? "   —  "
        out("cpu \(cpu)   gpu \(gpu)")
        if sample.cpuWatts != nil || sample.gpuWatts != nil { everMeasured = true }
        last = sample
    }
    _ = last
    // Silence has a cause worth naming. A subscription that answers with
    // counters that never move is a platform fault — measured on macOS 27
    // beta, where Apple's own `powermetrics` reports 0 mW for every rail.
    if !everMeasured {
        err("")
        err("No measurement in \(seconds)s. If the machine is not truly idle at")
        err("counter resolution, the firmware is not maintaining these channels.")
        err("Cross-check with: sudo powermetrics -i 1000 -n 3 --samplers cpu_power,gpu_power")
    }
}


func dumpKeys(prefix: String) async {
    let smc = SMCConnection()
    try? await smc.open()
    // Enumerate what the machine actually exposes rather than probing a table
    // of guessed names — the whole point of this tool. `allKeys` costs ~12 ms
    // once; guessing suffixes silently reports nothing on any Mac whose key
    // spelling differs from the guess, which is exactly the failure this
    // command exists to rule out.
    let all: [SMCKey]
    do {
        all = try await smc.allKeys()
    } catch {
        err("key enumeration failed — \(error)")
        await smc.close()
        return
    }
    var printed = 0
    for key in all where key.description.hasPrefix(prefix) {
        guard let info = try? await smc.keyInfo(key) else { continue }
        let value = try? await smc.read(key)
        let decoded = value?.doubleValue.map { String(format: "%.2f", $0) } ?? "—"
        out(String(format: "%@  type %@  size %d  r%@w%@  = %@",
                   key.description, info.typeString, info.dataSize,
                   info.isReadable ? "+" : "-", info.isWritable ? "+" : "-", decoded))
        printed += 1
    }
    if printed == 0 { out("(no keys match prefix “\(prefix)” among \(all.count))") }
    await smc.close()
}

/// `smcfan status` — everything needed to answer "why won't the app reach the
/// helper", which is the one support question this project keeps generating:
/// a rebuilt app changes its cdhash, the installed helper pins the old one,
/// and every connection is refused until the helper is reinstalled.
///
/// Read-only and unprivileged. It reports what is on disk and in launchd's
/// domain, the pinned signature, and — when this binary is running from inside
/// an app bundle — whether that bundle's cdhash still matches the pin. Talking
/// to the helper over XPC would prove more but requires being the pinned app,
/// so presence of the process is as far as probing goes from here.
func runStatus() {
    out("Helper install state")
    switch HelperInstallation.state() {
    case .installed:
        out("  state      : installed")
    case .notInstalled:
        out("  state      : NOT INSTALLED — no launchd job and/or no helper binary")
    case .installedWithoutClientRequirement:
        out("  state      : installed WITHOUT a pinned client signature")
        out("               (the helper refuses every connection in this state)")
    }

    func present(_ path: String) -> String {
        FileManager.default.fileExists(atPath: path) ? "present" : "absent"
    }
    out("  plist      : \(present(HelperInstallation.launchDaemonPlistPath))  (\(HelperInstallation.launchDaemonPlistPath))")
    out("  binary     : \(present(HelperInstallation.executablePath))  (\(HelperInstallation.executablePath))")

    // Is the daemon actually alive? `pgrep -x` matches the process name only,
    // needs no privileges, and says nothing rather than guessing when absent.
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", "fancontrold"]
    pgrep.standardOutput = Pipe()
    pgrep.standardError = Pipe()
    let running = (try? pgrep.run()) != nil && pgrep.waitUntilExit(timeout: 5) && pgrep.terminationStatus == 0
    out("  process    : \(running ? "running" : "not running (launchd starts it on demand or at boot)")")

    let requirementPath = HelperInstallation.clientRequirementPath
    if let pinned = try? String(contentsOfFile: requirementPath, encoding: .utf8) {
        out("  pinned     : \(pinned.trimmingCharacters(in: .whitespacesAndNewlines))")
    } else {
        out("  pinned     : unreadable or missing (\(requirementPath))")
    }

    // When run from inside M5Blade.app — the installed layout puts this
    // binary in Contents/Resources — compare that bundle against the pin. A
    // bare build directory has nothing to compare, and saying so beats a
    // misleading "match". Bundle.main does not resolve for plain executables,
    // so the bundle is found by walking up from this binary's own path.
    func enclosingAppBundle() -> String? {
        let resolved = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = resolved.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" { return directory.path }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
    guard let appPath = enclosingAppBundle() else {
        out("")
        out("(not running from an app bundle — no cdhash comparison)")
        return
    }
    let codesign = Process()
    codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    // Three v's: ad-hoc signatures (this project's kind) only print CDHash
    // at maximum verbosity.
    codesign.arguments = ["-dvvv", appPath]
    let pipe = Pipe()
    codesign.standardOutput = pipe
    codesign.standardError = pipe   // codesign writes the detail block to stderr
    if (try? codesign.run()) != nil, codesign.waitUntilExit(timeout: 5),
       codesign.terminationStatus == 0,
       let data = try? pipe.fileHandleForReading.readToEnd(),
       let detail = String(data: data, encoding: .utf8),
       let cdhashLine = detail.split(separator: "\n").first(where: { $0.contains("CDHash=") }),
       let hash = cdhashLine.split(separator: "=").last {
        let pinnedLine = (try? String(contentsOfFile: requirementPath, encoding: .utf8)) ?? ""
        let match = pinnedLine.contains(hash)
        out("  this app   : \(appPath)")
        out("  cdhash     : \(hash) — \(match ? "matches the pin" : "DOES NOT match the pin — reinstall the helper")")
    } else {
        out("  this app   : \(appPath) — cdhash unavailable (unsigned?)")
    }

    let logPath = FileManager.default.isReadableFile(atPath: "/var/log/m5bladed.log")
        ? "/var/log/m5bladed.log"
        : "/var/log/fancontrold.log"
    if FileManager.default.isReadableFile(atPath: logPath),
       let log = try? String(contentsOfFile: logPath, encoding: .utf8) {
        let tail = log.split(separator: "\n").suffix(5)
        if !tail.isEmpty {
            out("")
            out("Last log lines (\(logPath)):")
            for line in tail { out("  \(line)") }
        }
    }
}

extension Process {
    /// Bounded wait: a status command must never hang on an external tool.
    @discardableResult
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning {
            if Date() > deadline { terminate(); return false }
            usleep(20_000)
        }
        return true
    }
}

func watch(seconds: Int) async {    let backend = SMCFanBackend()
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
    case "status":  runStatus()
    case "fans":    await listFans()
    case "sensors": await listSensors(includeSMC: args.contains("--smc"))
    case "keys":    await dumpKeys(prefix: args.count > 1 ? args[1] : "F0")
    case "power":   await probePower(seconds: args.count > 1 ? Int(args[1]) ?? 5 : 5)
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
