import Foundation
import os
import DaemonProtocol

/// Why a helper request did not succeed.
///
/// This type exists because every one of these used to arrive at the UI as the
/// same bare `false`. A helper that was never installed, a helper that refused
/// our code signature, a helper that hung, and a helper that answered "no, fan 0
/// is not under manual control" are four different problems with four different
/// fixes, and the app could report none of them.
enum DaemonFailure: Error, Sendable, Equatable {
    /// No launchd job and/or no helper binary on disk.
    case notInstalled
    /// Installed, but no pinned client signature — the helper refuses every
    /// connection until `install-helper.sh` writes one.
    case noClientRequirement
    /// XPC itself failed. Carries AppKit's own text, which distinguishes a Mach
    /// service that is not registered from a connection the helper rejected
    /// because this build's cdhash no longer matches what it pinned.
    case connection(String)
    /// Reached, but silent past the budget for that operation.
    case timedOut(after: TimeInterval)
    /// The helper answered and said no, with its own reason.
    case refused(String)

    /// User-facing, and specific enough to act on.
    ///
    /// Deliberately free of build-system vocabulary: whoever reads these is
    /// using the app, not developing it, and "run make install" names a tool
    /// they do not have. The fix each message points at is offered as a button
    /// wherever a banner shows it.
    var message: String {
        switch self {
        case .notInstalled:
            return "Fan control needs its privileged helper, which is not installed yet."
        case .noClientRequirement:
            return "The helper refuses every connection because no client signature was pinned when it was installed — reinstall it."
        case .connection(let why):
            return "The helper could not be reached (\(why)). If this app was rebuilt or moved since the helper was installed, its pinned signature no longer matches — reinstall the helper."
        case .timedOut(let after):
            return "the helper did not answer within \(Int(after))s"
        case .refused(let why):
            return why
        }
    }

    /// Whether the fix for this failure is reinstalling the helper — the case
    /// where a banner can offer one concrete action instead of advice.
    var isFixedByReinstall: Bool {
        switch self {
        case .notInstalled, .noClientRequirement, .connection: return true
        case .timedOut, .refused: return false
        }
    }

    /// Whether this means nobody is on the other end. A `refused` came *from* a
    /// live helper and must not be reported as one that is missing.
    var helperIsUnreachable: Bool {
        if case .refused = self { return false }
        return true
    }
}

extension String {
    /// A failure message with its trailing sentence period removed, for
    /// composing into a longer sentence that adds its own.
    var trimmedSentence: String {
        hasSuffix(".") ? String(dropLast()) : self
    }
}

/// The helper, as everything above it needs to see it.
///
/// Extracted so `AppModel`'s control-state machine can be driven against a
/// simulated helper. That machine decides when the fans are armed, when they are
/// handed back, and what the app claims to be doing — and until this seam existed
/// none of it was tested at all, because the only implementation needed a root
/// daemon, an installed launchd job, and real hardware. The bug this seam was
/// added to pin down had been live on a real machine instead, where its evidence
/// was a line in `/var/log/fancontrold.log`.
///
/// Class-bound: `onDisconnect` is assignable, and every implementation is a
/// long-lived object holding a connection rather than a value.
protocol FanControlChannel: AnyObject, Sendable {
    /// Identifies the current connection's lifetime, for filtering stale drops.
    var currentGeneration: Int { get }
    var onDisconnect: (@Sendable (Int) -> Void)? { get set }

    func version() async -> Result<String, DaemonFailure>
    @discardableResult
    func setTarget(fan: Int, rpm: Double) async -> Result<Void, DaemonFailure>
    @discardableResult
    func setManual(fan: Int, enabled: Bool) async -> Result<Void, DaemonFailure>
    @discardableResult
    func releaseAll() async -> Result<Void, DaemonFailure>
    @discardableResult
    func heartbeat(maxTempC: Double) async -> Result<Void, DaemonFailure>
    /// Firmware charge-limit state (T-3). Unavailable is a `.failure`, and an
    /// unsupported machine is a successful `.unsupported` status — different
    /// facts with different banners.
    func chargeLimitStatus() async -> Result<ChargeLimitStatus, DaemonFailure>
    @discardableResult
    func setChargeLimit(percent: Int) async -> Result<Void, DaemonFailure>
}

/// Client half of the XPC channel. Owns the connection and hops every reply to
/// the main actor so the UI never touches an XPC queue (AUDIT A-4).
final class DaemonClient: FanControlChannel, @unchecked Sendable {
    /// Everything here also goes to the unified log, so a failure can be read
    /// back after the fact rather than only while the popover is open:
    ///
    ///     log stream --predicate 'subsystem == "com.m5blade.app"' --level debug
    static let log = Logger(subsystem: "com.m5blade.app", category: "daemon")

    private var connection: NSXPCConnection?
    private let lock = NSLock()

    private(set) var isConnected = false

    /// Identifies one connection's lifetime. Handed to `onDisconnect` so the app
    /// can tell "the connection I am using died" from "a connection I already
    /// replaced died" — the drop is delivered asynchronously on an XPC queue, so
    /// a notification for a dead generation can easily land *after* a newer
    /// connection has been established and armed. Acting on that stale
    /// notification is how a working control session got marked helper-not-running
    /// one tick after it started.
    private var generation = 0
    var currentGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    var onDisconnect: (@Sendable (Int) -> Void)?

    /// Longest a single request may take before it is treated as failed.
    ///
    /// The control loop awaits these on the main actor. A request that never
    /// completes does not just lose one fan update — it stops every subsequent
    /// tick and freezes the UI, which is how a dead helper turned into a hung
    /// app. Every call is therefore bounded.
    static let requestTimeout: TimeInterval = 3

    /// Arming is the one operation that is legitimately slow.
    ///
    /// On M3/M4 the helper has to run the `Ftst` unlock and wait for
    /// `thermalmonitord` to drop the fan out of mode 3 — documented at 3–6s, and
    /// `SMCFanBackend.unlockIfNeeded` allows up to 10. Against the general 3s
    /// budget that meant `setManualMode` timed out *before the hardware could
    /// possibly answer*, so taking control could never succeed on that
    /// generation: the app reported a refusal, released, and tried again. This
    /// covers the unlock with margin. Awaiting it does not block the main thread
    /// — `enableControl` is async and merely suspends — so the UI stays live.
    static let armTimeout: TimeInterval = 15

    /// What the helper's install looks like on disk right now. Re-read rather
    /// than cached: `make install` can happen while the app is running, and a
    /// cached "not installed" would outlive the fix.
    var installState: HelperInstallation.State { HelperInstallation.state() }

    /// Connects if the helper is installed. Returns false when it is not —
    /// previously this returned true unconditionally, which made every
    /// `guard daemon.connect()` in the app dead code: `NSXPCConnection.resume()`
    /// succeeds against a Mach service that does not exist, and the failure only
    /// surfaces on the first call, three seconds later.
    func connect() -> Bool {
        switch installState {
        case .notInstalled, .installedWithoutClientRequirement:
            Self.log.error("connect refused: \(self.failureForInstallState()?.message ?? "", privacy: .public)")
            return false
        case .installed:
            break
        }

        lock.lock(); defer { lock.unlock() }
        if connection != nil { return true }

        let c = NSXPCConnection(machServiceName: fanControlMachServiceName,
                                options: .privileged)
        generation += 1
        let mine = generation
        c.remoteObjectInterface = NSXPCInterface(with: FanControlDaemonProtocol.self)
        c.invalidationHandler = { [weak self] in
            self?.handleDrop(generation: mine, why: "connection invalidated")
        }
        c.interruptionHandler = { [weak self] in
            self?.handleDrop(generation: mine, why: "connection interrupted")
        }
        c.resume()
        connection = c
        isConnected = true
        Self.log.debug("connected to \(fanControlMachServiceName, privacy: .public) as generation \(mine, privacy: .public)")
        return true
    }

    private func failureForInstallState() -> DaemonFailure? {
        switch installState {
        case .installed:                        return nil
        case .notInstalled:                     return .notInstalled
        case .installedWithoutClientRequirement: return .noClientRequirement
        }
    }

    private func handleDrop(generation dead: Int, why: String) {
        lock.lock()
        // Only tear down if the dead connection is still the current one. A late
        // invalidation for a replaced generation must not discard a live one.
        let isCurrent = dead == generation
        if isCurrent {
            connection = nil
            isConnected = false
        }
        lock.unlock()
        Self.log.error("helper connection \(dead, privacy: .public) dropped: \(why, privacy: .public)")
        onDisconnect?(dead)
    }

    private func proxy(onError: @escaping @Sendable (DaemonFailure) -> Void) -> FanControlDaemonProtocol? {
        if let failure = failureForInstallState() { onError(failure); return nil }
        guard connect() else {
            onError(.connection("no connection could be established"))
            return nil
        }
        // Connection and generation read together under the lock: they are a
        // pair, and a drop between the two reads would attach this call's error
        // handler to a generation it does not belong to.
        lock.lock()
        let connection = self.connection
        let mine = generation
        lock.unlock()
        guard let connection else {
            onError(.connection("the connection was dropped before the request was sent"))
            return nil
        }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            // This error is the whole diagnosis and used to be discarded. It is
            // what says "service not found" versus "code signature requirement
            // not met" — the difference between a missing install and a stale one.
            self?.handleDrop(generation: mine, why: error.localizedDescription)
            onError(.connection(error.localizedDescription))
        } as? FanControlDaemonProtocol
    }

    /// The last thing that went wrong, for callers that want to report a reason
    /// without threading a `Result` through. Lock-guarded because it is written
    /// from XPC reply queues and the timeout queue, and read from the main actor.
    private var _lastFailure: DaemonFailure?
    var lastFailure: DaemonFailure? {
        lock.lock(); defer { lock.unlock() }
        return _lastFailure
    }

    private func record<T>(_ result: Result<T, DaemonFailure>, op: String) {
        lock.lock()
        switch result {
        case .success: _lastFailure = nil
        case .failure(let failure): _lastFailure = failure
        }
        lock.unlock()

        switch result {
        case .success:
            Self.log.debug("\(op, privacy: .public) ok")
        case .failure(let failure):
            Self.log.error("\(op, privacy: .public) failed: \(failure.message, privacy: .public)")
        }
    }

    /// Runs one XPC request with exactly-once completion.
    ///
    /// Three things can finish a request: the reply block, the proxy's error
    /// handler, and the timeout. Previously only the first of those resumed the
    /// continuation, so a connection that dropped mid-call left the caller
    /// awaiting forever. `Resumer` makes the first finisher win and the rest
    /// no-ops — resuming a continuation twice is a crash, not a warning — and it
    /// logs whichever one won, so the reason is recorded exactly once.
    private func request<T: Sendable>(
        _ op: String,
        timeout: TimeInterval = DaemonClient.requestTimeout,
        _ body: @escaping @Sendable (FanControlDaemonProtocol,
                                     @escaping @Sendable (Result<T, DaemonFailure>) -> Void) -> Void
    ) async -> Result<T, DaemonFailure> {
        let resumer = Resumer<Result<T, DaemonFailure>> { [weak self] result in
            self?.record(result, op: op)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<T, DaemonFailure>, Never>) in
            resumer.attach(cont)

            guard let p = proxy(onError: { resumer.finish(.failure($0)) }) else { return }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumer.finish(.failure(.timedOut(after: timeout)))
            }
            body(p) { resumer.finish($0) }
        }
    }

    /// One-shot resume guard. Small and explicit rather than an actor, because
    /// it has to be callable from an XPC reply queue without hopping.
    ///
    /// `notify` runs exactly once, for the finisher that won, outside the lock.
    private final class Resumer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var pending: T?
        private var done = false
        private let notify: (@Sendable (T) -> Void)?

        init(notify: (@Sendable (T) -> Void)? = nil) {
            self.notify = notify
        }

        func attach(_ cont: CheckedContinuation<T, Never>) {
            lock.lock()
            if done, let pending {
                lock.unlock()
                cont.resume(returning: pending)
                return
            }
            continuation = cont
            lock.unlock()
        }

        func finish(_ value: T) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let cont = continuation
            continuation = nil
            if cont == nil { pending = value }
            lock.unlock()
            notify?(value)
            cont?.resume(returning: value)
        }
    }

    // MARK: - Operations

    func version() async -> Result<String, DaemonFailure> {
        await request("getVersion") { p, done in p.getVersion { done(.success($0)) } }
    }

    /// What the helper reports about the hardware it owns. A struct rather than
    /// a tuple so it is unambiguously `Sendable` across the XPC reply queue.
    struct Capabilities: Sendable {
        let fanCount: Int
        let modeKeySuffix: String?
        let hasFtstUnlock: Bool
        let generationHint: String?
    }

    func capabilities() async -> Result<Capabilities, DaemonFailure> {
        await request("getCapabilities") { p, done in
            p.getCapabilities { count, suffix, ftst, hint in
                done(.success(Capabilities(fanCount: count, modeKeySuffix: suffix,
                                           hasFtstUnlock: ftst, generationHint: hint)))
            }
        }
    }

    /// The helper's own refusal text — "fan 0 is not under manual control",
    /// "target rpm is not a finite number" — reaches the caller instead of being
    /// flattened to `false`.
    @discardableResult
    func setTarget(fan: Int, rpm: Double) async -> Result<Void, DaemonFailure> {
        await request("setTarget(fan: \(fan), rpm: \(Int(rpm)))") { p, done in
            p.setTarget(fan: fan, rpm: rpm) { ok, why in
                done(ok ? .success(()) : .failure(.refused(why ?? "the helper refused the target and gave no reason")))
            }
        }
    }

    @discardableResult
    func setManual(fan: Int, enabled: Bool) async -> Result<Void, DaemonFailure> {
        await request("setManualMode(fan: \(fan), enabled: \(enabled))",
                      timeout: Self.armTimeout) { p, done in
            p.setManualMode(fan: fan, enabled: enabled) { ok, why in
                done(ok ? .success(()) : .failure(.refused(why ?? "the helper refused the mode change and gave no reason")))
            }
        }
    }

    /// The panic path. Fails when the helper could not confirm that every fan is
    /// back on macOS control — including when it never answered — and now says
    /// which of those it was.
    @discardableResult
    func releaseAll() async -> Result<Void, DaemonFailure> {
        await request("releaseAll") { p, done in
            p.releaseAll { ok, why in
                done(ok ? .success(()) : .failure(.refused(why ?? "the helper could not confirm the release and gave no reason")))
            }
        }
    }

    @discardableResult
    func heartbeat(maxTempC: Double) async -> Result<Void, DaemonFailure> {
        await request("heartbeat") { p, done in
            p.heartbeat(maxTempC: maxTempC) { ok in
                done(ok ? .success(()) : .failure(.refused("the helper rejected the heartbeat")))
            }
        }
    }

    func readFans() async -> [DaemonFanState] {
        let result: Result<[DaemonFanState], DaemonFailure> = await request("readFans") { p, done in
            p.readFans { data, why in
                guard let data else {
                    done(.failure(.refused(why ?? "the helper returned no fan data")))
                    return
                }
                do {
                    done(.success(try JSONDecoder().decode([DaemonFanState].self, from: data)))
                } catch {
                    done(.failure(.refused("undecodable fan data: \(error)")))
                }
            }
        }
        return (try? result.get()) ?? []
    }

    /// Charge-limit state. An installed helper built before this message
    /// existed never answers it at all, so any failure here means "state
    /// unknown", not "unsupported hardware" — those must not render the same.
    func chargeLimitStatus() async -> Result<ChargeLimitStatus, DaemonFailure> {
        await request("getChargeLimit") { p, done in
            p.getChargeLimit { data, why in
                guard let data else {
                    done(.failure(.refused(why ?? "the helper returned no charge-limit status")))
                    return
                }
                do {
                    done(.success(try JSONDecoder().decode(ChargeLimitStatus.self, from: data)))
                } catch {
                    done(.failure(.refused("undecodable charge-limit status: \(error)")))
                }
            }
        }
    }

    @discardableResult
    func setChargeLimit(percent: Int) async -> Result<Void, DaemonFailure> {
        await request("setChargeLimit(\(percent))") { p, done in
            p.setChargeLimit(percent: percent) { ok, why in
                done(ok ? .success(())
                        : .failure(.refused(why ?? "the helper refused the charge-limit change and gave no reason")))
            }
        }
    }

    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
        isConnected = false
    }
}
