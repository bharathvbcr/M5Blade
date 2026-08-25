import Foundation
#if canImport(Darwin)
import Darwin

/// A fan controller other than this app that is installed on this machine.
///
/// I-9: Macs Fan Control's privileged helper was found installed and running
/// as root while this app's daemon held the fans. Two root writers of the same
/// SMC keys (`F0md`, `F0Tg`, …) do not coordinate with each other; the visible
/// symptom is indistinguishable from this app's own failures — a refused
/// `setTarget` because something else dropped the fan out of manual mode. The
/// app cannot stop another program from writing; it can refuse to stay quiet
/// about it.
struct ThirdPartyFanController: Equatable, Identifiable {
    /// The launchd label or bundle identifier the evidence was matched on.
    let identifier: String
    /// What a person calls it, so the banner does not show raw reverse-DNS.
    let productName: String
    /// Its LaunchDaemon plist exists in `/Library/LaunchDaemons`. Such a job is
    /// started by launchd at boot and again whenever its Mach service is hit,
    /// so "installed but not running" still means "will be running soon".
    var installed: Bool
    /// A root process matching its executable is alive right now.
    var runningAsRoot: Bool

    var id: String { identifier }

    /// Installed-but-idle still warrants telling the user, at lower urgency:
    /// launchd will start it at the next boot whether or not anyone asks.
    var severityLabel: String {
        if runningAsRoot { return "running as root" }
        return "installed"
    }
}

/// Detects third-party privileged fan controllers from an unprivileged process.
///
/// Everything here was verified to work without elevation on this machine:
///
/// * `/Library/LaunchDaemons/*.plist` are world-readable, and carry the label,
///   program path and Mach service name of every root job.
/// * `sysctl(KERN_PROC_ALL)` returns every process, including root's, with its
///   uid and 16-byte command name (`p_comm`). `proc_name()` and `proc_pidpath`
///   return nothing for another user's processes, so the sysctl form is the
///   one used here.
///
/// `p_comm` truncates to 16 bytes — `/Library/PrivilegedHelperTools/
/// com.crystalidea.macsfancontrol.smcwrite` shows up as `com.crystalidea` —
/// so matching compares the truncated prefix against the executable name
/// rather than demanding equality.
enum ConcurrentControllerDetector {

    struct ProcessEntry: Equatable, Sendable {
        let pid: Int32
        let uid: UInt32
        /// The 16-byte kernel command name, already truncated by the kernel.
        let name: String
    }

    /// Known third-party controllers. Matched against the LaunchDaemon label
    /// and the executable's file name, case-insensitively. Fragments rather
    /// than full identifiers, so a vendor renaming `com.vendor.foo` to
    /// `com.vendor.foo.helper` keeps matching.
    static let knownSignatures: [(fragments: [String], productName: String)] = [
        (["macsfancontrol", "crystalidea"], "Macs Fan Control"),
        (["tunabelly", "tgpro"], "TG Pro"),
        (["bjango", "istatmenus"], "iStat Menus"),
        (["lobotomo", "smcfancontrol"], "smcFanControl"),
        (["lubbbo"], "Lubbbo"),
    ]

    /// This app's own identifiers — never reported as third parties.
    static let ownIdentifiers: Set<String> = [
        "com.m5blade.app",
        "com.m5blade.helper",
        "com.m5blade.daemon",
        "com.fancontrol.app",
        "com.fancontrol.helper",
        "com.fancontrol.daemon",
    ]

    static let launchDaemonsDirectory = URL(fileURLWithPath: "/Library/LaunchDaemons",
                                            isDirectory: true)

    /// Scans for third-party fan controllers.
    ///
    /// Pure given its inputs: the directory listing, a file-existence probe,
    /// and the current process table all arrive as parameters, which is what
    /// makes the matching rules testable without installing anything.
    ///
    /// - Parameters:
    ///   - daemonPlists: `(url, parsed plist)` pairs read from the LaunchDaemons
    ///     directory. Malformed plists are skipped by the reader, not here.
    ///   - fileExistsAt: path existence probe (the real one checks through
    ///     symlinks, which PrivilegedHelperTools use).
    ///   - processes: the live process table.
    static func scan(daemonPlists: [(url: URL, plist: [String: Any])],
                     fileExistsAt: (String) -> Bool,
                     processes: [ProcessEntry]) -> [ThirdPartyFanController] {

        // One candidate per job, built from its LaunchDaemon plist. The
        // identifier is the label, so the plist pass and the process pass below
        // land on the same entry instead of two.
        struct Candidate {
            let identifier: String
            var productName: String
            var programNames: [String]
            var installed: Bool
            var runningAsRoot: Bool
        }

        var candidates: [Candidate] = []

        func upsert(_ candidate: Candidate) {
            if let index = candidates.firstIndex(where: { $0.identifier == candidate.identifier }) {
                if candidate.installed { candidates[index].installed = true }
                if candidate.runningAsRoot { candidates[index].runningAsRoot = true }
                if !candidate.programNames.isEmpty {
                    candidates[index].programNames = candidate.programNames
                }
                // The catalogue name beats a raw command name, so a plist found
                // later upgrades what the process pass guessed.
                candidates[index].productName = candidate.productName
            } else {
                candidates.append(candidate)
            }
        }

        let rootProcesses = processes.filter { $0.uid == 0 && $0.pid > 1 }

        // Pass 1 — installed jobs. A plist whose binary is gone cannot come
        // back, so it is kept only when something is actually running anyway;
        // warning about it would describe a problem that does not exist.
        for (url, plist) in daemonPlists {
            guard let identity = identity(of: url, plist) else { continue }
            // Our own helper is a root fan writer by design.
            if ownIdentifiers.contains(identity.label.lowercased()) { continue }

            let programNames = Self.programBasenames(plist)
            let matchedSignature = knownSignatures.first { signature in
                matchesAny(identity.label, signature.fragments)
                    || programNames.contains { matchesAny($0, signature.fragments) }
            }
            // Generalisation, so a controller nobody has catalogued yet is still
            // caught: a root job whose executable is named like a fan tool.
            // Apple's own thermal daemons are excluded — macOS driving its own
            // fans is correct behaviour, not a conflict.
            let looksLikeFanTool = matchedSignature == nil
                && !identity.label.hasPrefix("com.apple.")
                && programNames.contains { $0.lowercased().contains("fan") }

            guard matchedSignature != nil || looksLikeFanTool else { continue }
            let productName = matchedSignature?.productName ?? identity.label

            let binaryPresent = Self.programPaths(plist).contains(where: fileExistsAt)
            let running = !programNames.isEmpty && rootProcesses.contains { process in
                programNames.contains { programName in
                    commName(process.name, matchesExecutable: programName)
                }
            }
            guard binaryPresent || running else { continue }
            upsert(Candidate(identifier: identity.label, productName: productName,
                             programNames: programNames, installed: true,
                             runningAsRoot: running))
        }

        // Pass 2 — running jobs with no plist of their own (launched by hand,
        // or the plist lives somewhere this scan does not read). The running
        // process is the fact that matters, not the paperwork.
        for (fragments, productName) in knownSignatures {
            let alreadyFound = candidates.contains { $0.productName == productName }
            guard !alreadyFound else { continue }
            guard let process = rootProcesses.first(where: { matchesAny($0.name, fragments) })
            else { continue }
            upsert(Candidate(identifier: process.name, productName: productName,
                             programNames: [], installed: false, runningAsRoot: true))
        }

        return candidates.map {
            ThirdPartyFanController(identifier: $0.identifier,
                                    productName: $0.productName,
                                    installed: $0.installed,
                                    runningAsRoot: $0.runningAsRoot)
        }
        .sorted { $0.identifier < $1.identifier }
    }

    /// Convenience wrapper that gathers the real inputs itself.
    static func scanNow() -> [ThirdPartyFanController] {
        scan(daemonPlists: readLaunchDaemonPlists(),
             fileExistsAt: { FileManager.default.fileExists(atPath: $0) },
             processes: currentProcesses())
    }

    // MARK: - Inputs

    /// Every parseable plist in the LaunchDaemons directory. A malformed or
    /// unreadable one is skipped — one bad file must not cost the rest, and
    /// root-owned plists have been world-readable everywhere this was tested.
    static func readLaunchDaemonPlists(at directory: URL = launchDaemonsDirectory)
        -> [(url: URL, plist: [String: Any])] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "plist" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil),
                  let dictionary = plist as? [String: Any] else { return nil }
            return (url: url, plist: dictionary)
        }
    }

    /// Every process on the machine via `sysctl(KERN_PROC_ALL)`, which — unlike
    /// `proc_pidinfo`-based sampling — reports root's processes to an
    /// unprivileged caller, with uid and the 16-byte command name.
    static func currentProcesses() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        // Over-allocate: the table grows between the two sysctl calls, and the
        // second call fails outright if the buffer no longer fits it.
        var entries = [kinfo_proc](repeating: kinfo_proc(),
                                   count: size / MemoryLayout<kinfo_proc>.stride + 64)
        size = entries.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &entries, &size, nil, 0) == 0 else {
            return []
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return entries.prefix(count).map { entry in
            ProcessEntry(pid: entry.kp_proc.p_pid,
                         uid: entry.kp_eproc.e_ucred.cr_uid,
                         name: withUnsafeBytes(of: entry.kp_proc.p_comm) { raw in
                             String(cString: raw.baseAddress!
                                 .assumingMemoryBound(to: CChar.self))
                         })
        }
    }

    // MARK: - Matching

    private struct DaemonIdentity {
        let label: String
    }

    private static func identity(of url: URL, _ plist: [String: Any]) -> DaemonIdentity? {
        if let label = plist["Label"] as? String, !label.isEmpty {
            return DaemonIdentity(label: label)
        }
        // Label is technically required, but a file named like its label still
        // identifies the job well enough to warn about it.
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? nil : DaemonIdentity(label: stem)
    }

    private static func programBasenames(_ plist: [String: Any]) -> [String] {
        paths(of: plist).map { ($0 as NSString).lastPathComponent }
    }

    private static func programPaths(_ plist: [String: Any]) -> [String] {
        paths(of: plist)
    }

    /// Program path plus every ProgramArguments entry that looks like a path.
    private static func paths(of plist: [String: Any]) -> [String] {
        var result: [String] = []
        if let program = plist["Program"] as? String { result.append(program) }
        if let arguments = plist["ProgramArguments"] as? [Any] {
            for argument in arguments {
                guard let string = argument as? String, string.hasPrefix("/") else { continue }
                result.append(string)
            }
        }
        return result
    }

    /// Whether a fragment occurs anywhere case-insensitively. Empty fragments
    /// match everything, so they are rejected — a signature typo must fail
    /// closed into "not recognised", never open into "everything is TG Pro".
    static func matchesAny(_ haystack: String, _ fragments: [String]) -> Bool {
        fragments.contains { fragment in
            !fragment.isEmpty && haystack.localizedCaseInsensitiveContains(fragment)
        }
    }

    /// Internal alias so the fail-closed rule above is testable directly.
    static func matchesAnyForTesting(_ haystack: String, _ fragments: [String]) -> Bool {
        matchesAny(haystack, fragments)
    }

    /// Does the kernel's truncated command name belong to this executable?
    ///
    /// The kernel keeps 16 bytes (`MAXCOMLEN`) — `MAXCOMLEN - 1` characters plus
    /// the NUL. A long helper path arrives as a strict *prefix* of its real
    /// name, so equality on short names and prefix on truncated ones both work;
    /// requiring at least four characters stops a one-letter prefix from
    /// matching half the process table.
    static func commName(_ comm: String, matchesExecutable executable: String) -> Bool {
        guard comm.count >= 4 else { return false }
        let head = executable.prefix(comm.count)
        return comm.localizedCaseInsensitiveCompare(String(head)) == .orderedSame
    }
}
#endif
