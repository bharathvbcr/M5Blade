import Foundation
import SMCKit

#if canImport(IOKit)

/// Live fan control over the SMC.
///
/// Handles the two generation-specific behaviours discovered by reverse
/// engineering, both probed at runtime rather than inferred from the model:
///
///  * **Mode key casing.** Uppercase `F0Md` through M4, lowercase `F0md` on M5.
///    The wrong casing returns SmcNotFound (0x84).
///  * **The `Ftst` unlock.** On M3/M4 `thermalmonitord` holds fans in mode 3 and
///    rejects mode writes with 0x82 until `Ftst=1` is set and the daemon yields
///    (3-6s). On M5 the key is absent and direct mode writes just work.
public actor SMCFanBackend: FanBackend {
    private let smc: SMCConnection
    private var descriptors: [FanDescriptor] = []
    private var modeKeyIsLowercase: Bool?
    private var hasFtst: Bool?
    private var unlocked = false

    public init(connection: SMCConnection = SMCConnection()) {
        self.smc = connection
    }

    /// Opens the SMC user client if it is not already open.
    ///
    /// The connection is this backend's own invariant, not a step its callers are
    /// trusted to remember — because one of them did not. `connect()` was never
    /// part of `FanBackend`, so `DaemonCore`, which only ever sees the protocol,
    /// had no way to call it and `fancontrold` never did. The daemon came up
    /// "listening", `discoverFans` threw `notConnected` into `start`'s catch, and
    /// every request after that failed with "SMC not initialised — no fans
    /// discovered". So did `releaseAll`, the one path that must always work.
    ///
    /// `SMCConnection.open()` returns immediately when the connection is already
    /// up, so paying for this on every operation costs an actor hop and buys an
    /// invariant no caller can forget.
    private func ensureOpen() async throws {
        try await smc.open()
    }

    /// Opens the connection eagerly, so a caller that wants to report an unusable
    /// SMC before doing anything else can. Nothing below depends on it.
    public func connect() async throws {
        try await ensureOpen()
    }

    public func disconnect() async {
        await smc.close()
    }

    // MARK: - Capability probing

    /// Determines the mode key casing present on this hardware.
    private func resolveModeKeyCasing() async -> Bool? {
        if let known = modeKeyIsLowercase { return known }
        // Unresolved, not resolved-wrong: on a closed connection every `exists`
        // probe reports absent, and this result is cached for the life of the
        // process. Returning nil leaves it to be probed again once the SMC is up.
        guard (try? await ensureOpen()) != nil else { return nil }
        if await smc.exists(SMCKey("F0Md")) {
            modeKeyIsLowercase = false
        } else if await smc.exists(SMCKey("F0md")) {
            modeKeyIsLowercase = true
        } else {
            return nil
        }
        return modeKeyIsLowercase
    }

    private func modeKey(_ index: Int) async -> SMCKey? {
        guard let lower = await resolveModeKeyCasing() else { return nil }
        // Composed through `SMCKey.fan`, not `SMCKey(_:)`, so a two-digit index
        // cannot be truncated into a different key. "F10md" is five characters;
        // the truncating initializer would silently make it "F10m".
        return SMCKey.fan(index, lower ? "md" : "Md")
    }

    public func ftstPresent() async -> Bool {
        if let known = hasFtst { return known }
        // Same hazard as the casing probe, with a worse payload: `Ftst` cached as
        // absent skips the M3/M4 unlock, and every mode write then fails 0x82.
        guard (try? await ensureOpen()) != nil else { return false }
        let present = await smc.exists(SMCKey("Ftst"))
        hasFtst = present
        return present
    }

    public func capabilities() async -> FanCapabilities {
        let casing = await resolveModeKeyCasing()
        return FanCapabilities(
            modeKeySuffix: casing.map { $0 ? "md" : "Md" },
            hasFtstUnlock: await ftstPresent(),
            fanCount: descriptors.count
        )
    }

    // MARK: - Discovery

    public func discoverFans() async throws -> [FanDescriptor] {
        try await ensureOpen()
        let count = Int(try await smc.readUInt8(SMCKey("FNum")))
        let lower = await resolveModeKeyCasing()
        let suffix = (lower ?? true) ? "md" : "Md"

        var result: [FanDescriptor] = []
        for i in 0..<count {
            // A fan we cannot name is a fan we cannot read, write, or release.
            // Listing it as discovered would put an index into the descriptor set
            // that every later operation throws on — including `releaseAll`,
            // which is the one path that must not be able to fail.
            guard let minKey = SMCKey.fan(i, "Mn"), let maxKey = SMCKey.fan(i, "Mx") else { continue }
            let minRPM = try? await smc.readDouble(minKey)
            let maxRPM = try? await smc.readDouble(maxKey)
            result.append(FanDescriptor(index: i,
                                        minRPM: minRPM,
                                        maxRPM: maxRPM,
                                        modeKeyName: "F\(i)\(suffix)"))
        }
        descriptors = result
        return result
    }

    public func readFan(_ index: Int) async throws -> FanReading {
        try await ensureOpen()
        guard let actualKey = SMCKey.fan(index, "Ac") else {
            throw SMCError.unaddressableFan(index)
        }
        let actual = try await smc.readDouble(actualKey)
        var target: Double?
        if let targetKey = SMCKey.fan(index, "Tg") {
            target = try? await smc.readDouble(targetKey)
        }
        var mode: FanMode?
        if let key = await modeKey(index), let raw = try? await smc.readUInt8(key) {
            mode = FanMode(rawValue: raw)
        }
        return FanReading(index: index, actualRPM: actual, targetRPM: target, mode: mode)
    }

    // MARK: - Unlock

    /// M3/M4 only. Writes Ftst=1 and waits for thermalmonitord to drop the fan
    /// out of mode 3. No-op where Ftst is absent (M1, M5).
    @discardableResult
    public func unlockIfNeeded(timeout: TimeInterval = 10) async throws -> Bool {
        guard await ftstPresent() else { return true }
        if unlocked { return true }
        guard let key = await modeKey(0) else { throw SMCError.keyNotFound(SMCKey("F0md")) }

        try await smc.writeUInt8(SMCKey("Ftst"), 1)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? await smc.readUInt8(key), raw != FanMode.system.rawValue {
                unlocked = true
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Leave Ftst set only if we succeeded; otherwise restore system control.
        try? await smc.writeUInt8(SMCKey("Ftst"), 0)
        return false
    }

    private func relock() async {
        guard await ftstPresent(), unlocked else { return }
        try? await smc.writeUInt8(SMCKey("Ftst"), 0)
        unlocked = false
    }

    // MARK: - Control

    public func setMode(_ mode: FanMode, fan: Int) async throws {
        // Before `modeKey`, so a closed connection reports itself rather than
        // surfacing as the unresolved casing probe's "key not found".
        try await ensureOpen()
        guard let key = await modeKey(fan) else {
            throw SMCError.keyNotFound(SMCKey("F\(fan)md"))
        }
        if mode.isUserControlled {
            guard try await unlockIfNeeded() else { throw SMCError.smcError(0x82) }
        }
        try await smc.writeUInt8(key, mode.rawValue)
        if mode == .auto || mode == .system { await relock() }
    }

    public func setTarget(rpm: Double, fan: Int) async throws {
        try await ensureOpen()
        guard let key = SMCKey.fan(fan, "Tg") else { throw SMCError.unaddressableFan(fan) }
        // A non-finite target must never reach `writeDouble`: its encoders clamp
        // with `min(limit, value)`, and every comparison against NaN is false, so
        // NaN silently encodes as the *limit* — a fan commanded to maximum by a
        // number that meant "no idea". Callers reject it too; this is the layer
        // that touches hardware, so it does not rely on them having done so.
        guard rpm.isFinite else { throw SMCError.nonFiniteTarget(fan) }
        try await smc.writeDouble(key, max(0, rpm))
    }

    /// Return every fan to the system. Called on shutdown, on watchdog timeout,
    /// and before sleep. Never throws — but never claims more than it achieved.
    ///
    /// Three things this used to get wrong, all of which reported success:
    ///
    ///  * With `descriptors` empty (SMC init failed at boot) it wrote nothing and
    ///    returned normally. It now re-probes, because a discovery that failed at
    ///    boot is exactly the situation where the panic path still has to work.
    ///  * Every write was `try?`, so a rejected write was indistinguishable from
    ///    a successful one.
    ///  * It never read the mode back. On M3/M4 a mode write can be accepted and
    ///    then overridden; "we wrote auto" is not "the fan is on auto".
    ///  * The re-probe above ran on a connection nobody had opened, so it threw
    ///    and the outcome came back `hadNoFans` — the panic path reporting
    ///    "nothing to release" on a machine whose fans it simply could not see.
    public func releaseAll() async -> ReleaseOutcome {
        var outcome = ReleaseOutcome()

        // The panic path runs against a backend nobody has necessarily talked to:
        // the daemon whose probe failed at boot is exactly the one that still has
        // to hand the fans back. A failure here surfaces below as no discoverable
        // fans, which `hadNoFans` already reports as *not* success.
        try? await ensureOpen()

        if descriptors.isEmpty {
            _ = try? await discoverFans()
        }
        guard !descriptors.isEmpty else {
            outcome.hadNoFans = true
            return outcome
        }

        for fan in descriptors {
            guard let key = await modeKey(fan.index) else {
                outcome.failed[fan.index] = "no addressable fan mode key on this hardware"
                continue
            }
            do {
                try await smc.writeUInt8(key, FanMode.auto.rawValue)
            } catch {
                outcome.failed[fan.index] = String(describing: error)
                continue
            }
            guard let raw = try? await smc.readUInt8(key) else {
                outcome.unverified.append(fan.index)
                continue
            }
            if FanMode(rawValue: raw)?.isUserControlled == true {
                outcome.failed[fan.index] = "still in mode \(raw) after writing auto"
            } else {
                outcome.released.append(fan.index)
            }
        }
        await relock()
        return outcome
    }
}
#endif
