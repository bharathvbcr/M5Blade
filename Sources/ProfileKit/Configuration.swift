import Foundation
import FanKit

/// Everything the user can author, in one document.
///
/// Nothing here reaches hardware directly — the control loop still clamps
/// against `SafetyFloor`, and the daemon re-clamps again. A corrupt or hostile
/// config can produce a bad *preference*, never an unsafe fan target.
public struct Configuration: Sendable, Codable, Equatable {
    /// Bumped when the shape changes in a way that needs migration.
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [Profile]
    /// Evaluated top to bottom; first match wins, so array order is the priority.
    public var rules: [Rule]
    /// The profile chosen when no rule matches.
    public var defaultProfileID: UUID

    public init(version: Int = Configuration.currentVersion,
                profiles: [Profile],
                rules: [Rule] = [],
                defaultProfileID: UUID = Profile.balancedID) {
        self.version = version
        self.profiles = profiles
        self.rules = rules
        self.defaultProfileID = defaultProfileID
    }

    public static func factoryDefault(fanCount: Int) -> Configuration {
        Configuration(profiles: Profile.builtIns(fanCount: fanCount))
    }

    /// What a load found: what it had to change, and what it merely noticed.
    ///
    /// Kept apart deliberately. A *correction* mutated the user's configuration
    /// and must not recur on the next load — if it does, the repair did not
    /// take. A *warning* changed nothing, so it recurs by design: a rule with no
    /// conditions can never fire, but it is the user's rule and deleting it
    /// behind their back would be worse than saying so every time.
    public struct ReconcileReport: Sendable, Equatable {
        public var corrections: [String] = []
        public var warnings: [String] = []

        public var isEmpty: Bool { corrections.isEmpty && warnings.isEmpty }
        public var messages: [String] { corrections + warnings }
    }

    /// Re-add any built-in that a stored config predates, drop rules whose target
    /// profile no longer exists, and correct anything that would make the file
    /// and the running behaviour disagree.
    ///
    /// A config that quietly repairs itself is a config the user cannot debug —
    /// and every one of these corrections has a hand-edit or an older build
    /// behind it.
    @discardableResult
    public mutating func reconcile(fanCount: Int) -> ReconcileReport {
        var report = ReconcileReport()
        var corrections: [String] = []

        // Duplicate ids make `first(where:)` pick by array order, so which
        // profile a rule targets depends on where it happens to sit in the file.
        var seenProfileIDs = Set<UUID>()
        profiles.removeAll { profile in
            let duplicate = !seenProfileIDs.insert(profile.id).inserted
            if duplicate { corrections.append("Removed a second profile sharing the id of “\(profile.name)”.") }
            return duplicate
        }
        var seenRuleIDs = Set<UUID>()
        rules.removeAll { rule in
            let duplicate = !seenRuleIDs.insert(rule.id).inserted
            if duplicate { corrections.append("Removed a second rule sharing the id of “\(rule.name)”.") }
            return duplicate
        }

        let builtIns = Profile.builtIns(fanCount: fanCount)
        for builtIn in builtIns where !profiles.contains(where: { $0.id == builtIn.id }) {
            profiles.append(builtIn)
            corrections.append("Restored the missing built-in profile “\(builtIn.name)”.")
        }
        // A profile can't claim to be built-in unless its ID actually is one.
        let builtInIDs = Set(builtIns.map(\.id))
        for i in profiles.indices {
            profiles[i].isBuiltIn = builtInIDs.contains(profiles[i].id)
            corrections.append(contentsOf: profiles[i].repair())
        }

        let known = Set(profiles.map(\.id))
        let orphaned = rules.filter { !known.contains($0.targetProfileID) }
        for rule in orphaned {
            corrections.append("Removed rule “\(rule.name)”: it targets a profile that no longer exists.")
        }
        rules.removeAll { !known.contains($0.targetProfileID) }

        for rule in rules where rule.enabled && rule.conditions.isEmpty {
            report.warnings.append("Rule “\(rule.name)” has no conditions and can never match.")
        }

        if !known.contains(defaultProfileID) {
            defaultProfileID = Profile.balancedID
            corrections.append("The default profile was missing; reset to Balanced.")
        }
        report.corrections = corrections
        return report
    }
}

/// Reads and writes `Configuration` as JSON.
///
/// Writes are atomic: a crash mid-save leaves the previous config intact rather
/// than a truncated file. A file that fails to decode is moved aside rather than
/// deleted, so a user can recover hand-authored curves.
public struct ConfigStore: Sendable {
    public enum StoreError: LocalizedError, Equatable {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Could not read the configuration: \(why)"
            }
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/FanControl/config.json`
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("FanControl/config.json")
    }

    public static func `default`() -> ConfigStore { ConfigStore(url: defaultURL()) }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Returns nil when no config has been written yet — a first run, not an error.
    public func load() throws -> Configuration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("invalid-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            throw StoreError.unreadable(
                "Invalid UTF-8 encoding — the old file was kept at \(backup.lastPathComponent)")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            // Preserve the file — a decode failure is usually a shape change, and
            // the contents are hand-authored work the user cannot regenerate.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("invalid-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            throw StoreError.unreadable(
                "\(error.localizedDescription) — the old file was kept at \(backup.lastPathComponent)")
        }
    }

    public func save(_ configuration: Configuration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try Self.encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
    }

    /// Load, falling back to factory defaults on any failure. The reason is
    /// returned rather than swallowed so the UI can surface it — a config that
    /// silently resets to defaults is indistinguishable from one that was never
    /// saved.
    public func loadOrDefault(fanCount: Int) -> (configuration: Configuration, problem: String?) {
        var problems: [String] = []
        var configuration: Configuration
        do {
            configuration = try load() ?? .factoryDefault(fanCount: fanCount)
        } catch {
            problems.append(error.localizedDescription)
            configuration = .factoryDefault(fanCount: fanCount)
        }
        problems.append(contentsOf: configuration.reconcile(fanCount: fanCount).messages)
        return (configuration, problems.isEmpty ? nil : problems.joined(separator: "\n"))
    }
}
