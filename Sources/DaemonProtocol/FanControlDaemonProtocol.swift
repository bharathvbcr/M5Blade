import Foundation

public let fanControlMachServiceName = "com.m5blade.helper"
public let m5bladeMachServiceName = "com.m5blade.helper"

/// The daemon's entire interface.
///
/// Deliberately minimal (AUDIT A-2). There is no generic `writeSMCKey` — that
/// would turn the helper into an arbitrary root SMC-write primitive.
@objc public protocol FanControlDaemonProtocol {
    func getVersion(reply: @escaping (String) -> Void)

    func getCapabilities(reply: @escaping (Int, String?, Bool, String?) -> Void)

    /// Set a fan target. The daemon clamps independently of whatever the app asks
    /// for, and rejects anything below its own hard floor.
    func setTarget(fan: Int, rpm: Double, reply: @escaping (Bool, String?) -> Void)

    func setManualMode(fan: Int, enabled: Bool, reply: @escaping (Bool, String?) -> Void)

    /// The panic path. Returns every fan to macOS.
    func releaseAll(reply: @escaping (Bool, String?) -> Void)

    /// Proof of life from the controlling app. The app sends this about once a
    /// second while it is driving fans. If no heartbeat *and* no arm arrives for
    /// more than `DaemonConstants.watchdogTimeout` (12 s), the watchdog releases
    /// every fan to macOS — so the effective tolerance is roughly twelve beats,
    /// not two. The age is measured as a magnitude on the stamps' wall clock,
    /// which makes the release survive a system clock stepped backwards past
    /// the last stamp rather than pinning the fans until wall time catches up.
    func heartbeat(maxTempC: Double, reply: @escaping (Bool) -> Void)

    func readFans(reply: @escaping (Data?, String?) -> Void)

    /// Firmware charge-limit state (DESIGN §6.3): read-only for the app; only
    /// the helper may touch the SMC key. Encoded as JSON `ChargeLimitStatus`
    /// for the same reason `readFans` is.
    func getChargeLimit(reply: @escaping (Data?, String?) -> Void)

    /// Sets the firmware charge limit to 80 or 100. Refused on unsupported
    /// hardware and verified by read-back; a write the firmware ignored is
    /// reported as a failure, not as success.
    func setChargeLimit(percent: Int, reply: @escaping (Bool, String?) -> Void)
}

/// What the helper knows about the firmware charge limit, as JSON across XPC.
public struct ChargeLimitStatus: Codable, Sendable, Equatable {
    /// Whether this machine exposes a charge-limit key at all.
    public var supported: Bool
    /// 80 or 100 when known; nil when the state cannot be decoded or the
    /// hardware has no key.
    public var percent: Int?
    /// Which firmware key backs the state, when there is one ("CHWA"/"BCLM").
    public var keyName: String?

    public init(supported: Bool, percent: Int?, keyName: String? = nil) {
        self.supported = supported
        self.percent = percent
        self.keyName = keyName
    }

    /// The state a machine with no charge-limit key reports. Common enough on
    /// current Macs that it deserves its one obvious encoding.
    public static let unsupported = ChargeLimitStatus(supported: false,
                                                      percent: nil, keyName: nil)
}

/// Where `install-helper.sh` puts the three files the helper needs to exist.
///
/// The script is the other copy of these paths; if either moves, both must. It
/// is worth the duplication because without it the app cannot tell "the helper
/// was never installed" apart from "the helper is installed and not answering",
/// and those two produce identical silence — a three second timeout and a
/// `false`. That is precisely what made a missing install look like a hardware
/// fault: the only thing the user was told was that the fans were not confirmed
/// back on macOS control.
public enum HelperInstallation {
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.m5blade.helper.plist"
    public static let executablePath = "/usr/local/libexec/m5bladed"
    public static let clientRequirementPath = "/Library/Application Support/M5Blade/client.requirement"

    /// What is actually on disk. Not "is it running" — launchd owns that — but
    /// enough to distinguish the two failures above.
    public enum State: Sendable, Equatable {
        case installed
        /// No launchd job and/or no helper binary. Nothing is listening.
        case notInstalled
        /// Installed, but with no pinned client signature. The helper refuses
        /// every connection in that state (`DaemonListenerDelegate`), which from
        /// the app side is indistinguishable from a helper that is simply gone.
        case installedWithoutClientRequirement
    }

    /// Existence is injected rather than read directly so the three states can be
    /// tested without root and without touching /Library.
    public static func state(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> State {
        guard exists(launchDaemonPlistPath), exists(executablePath) else { return .notInstalled }
        guard exists(clientRequirementPath) else { return .installedWithoutClientRequirement }
        return .installed
    }
}

public struct DaemonFanState: Codable, Sendable {
    public var index: Int
    public var actualRPM: Double
    public var targetRPM: Double?
    public var mode: UInt8?
    public var minRPM: Double?
    public var maxRPM: Double?

    public init(index: Int, actualRPM: Double, targetRPM: Double?, mode: UInt8?,
                minRPM: Double?, maxRPM: Double?) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.mode = mode
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

/// What the daemon actually knows about temperature when it clamps a request.
///
/// The distinction is the whole point: a daemon with no fresh heartbeat does not
/// know the machine is cool, it knows *nothing*, and those two must not produce
/// the same floor. The old code defaulted to 0 °C and therefore applied no floor
/// at all in precisely the situation — client stopped talking — where the floor
/// is the only thing left protecting the machine.
public enum TemperatureEvidence: Sendable, Equatable {
    case measured(Double)
    case unknown

    /// Treats a stale or absent heartbeat as unknown rather than as its last value.
    public static func from(lastHeartbeat: (tempC: Double, at: Date)?,
                            now: Date,
                            staleAfter: TimeInterval = DaemonConstants.watchdogTimeout) -> TemperatureEvidence {
        guard let beat = lastHeartbeat, beat.tempC.isFinite else { return .unknown }
        let age = now.timeIntervalSince(beat.at)
        guard age >= 0, age <= staleAfter else { return .unknown }
        return .measured(beat.tempC)
    }
}

public enum DaemonConstants {
    public static let heartbeatInterval: TimeInterval = 5
    public static let watchdogTimeout: TimeInterval = 12
    /// Absolute floor the daemon enforces regardless of the app's request.
    public static let hardFloorPercent: Double = 25
    public static let hardFloorTempC: Double = 60
    /// Headroom above the reported maximum. Ranges are advisory, so a little
    /// slack is allowed; an unbounded target is not.
    public static let overspeedAllowance: Double = 1.05
    /// How many consecutive incomplete releases the watchdog retries before it
    /// stops the fast retry loop. Bounded, because an unbounded retry against
    /// hardware that is never going to answer is a spin — but giving up used to
    /// mean *forever*, so after this budget one attempt per slow interval keeps
    /// the recovery path alive.
    public static let maxReleaseRetries = 5
    /// The cadence of the post-budget retry described above.
    public static let slowReleaseRetryInterval: TimeInterval = 60

    /// The daemon's hard clamp, as a pure function so it can be tested without
    /// root or hardware. Lives here rather than inside the daemon so there is one
    /// canonical statement of the policy.
    ///
    /// Total by construction: every input maps to a target inside
    /// `[0, maxRPM * overspeedAllowance]`. Callers must reject unknown fans and
    /// non-finite requests *before* calling — this function cannot express
    /// "refuse", and inventing a number for a fan we never discovered is exactly
    /// the failure this guards against.
    public static func clampRPM(_ requested: Double,
                                minRPM: Double,
                                maxRPM: Double,
                                temperature: TemperatureEvidence) -> Double {
        // The range is hardware-reported and therefore not trustworthy. A NaN or
        // inverted range used to flow straight through: `max`/`min` against NaN
        // return the *other* operand, so the result was silently NaN or the
        // unclamped request, and the totality claimed above was false in exactly
        // the case it was written to cover. `FanDescriptor` normalises this too;
        // this is the last line, so it does not assume the caller did.
        let low = minRPM.isFinite && minRPM >= 0 ? minRPM : 0
        let high = maxRPM.isFinite && maxRPM > low ? maxRPM : low

        // A non-finite request means "no idea" — resolve it upward, never to a
        // number that reads as a cool, quiet fan.
        var value = requested.isFinite ? max(0, requested) : high

        let needsFloor: Bool
        switch temperature {
        case .measured(let tempC): needsFloor = tempC.isFinite ? tempC >= hardFloorTempC : true
        case .unknown:             needsFloor = true
        }
        if needsFloor {
            value = max(value, low + (hardFloorPercent / 100) * (high - low))
        }
        return min(value, high * overspeedAllowance)
    }
}
