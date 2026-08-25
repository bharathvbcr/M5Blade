import Foundation
import FanKit
import PowerKit
import DaemonProtocol

/// The XPC surface. Deliberately thin: it translates calls into `DaemonCore`
/// requests and translates results back. Every decision, every piece of mutable
/// state, and every clamp lives in the actor.
public final class DaemonService: NSObject, FanControlDaemonProtocol, @unchecked Sendable {
    public static let version = "1.1.0"

    private let core: DaemonCore
    private let log: @Sendable (String) -> Void
    private var watchdogTimer: DispatchSourceTimer?
    /// Presentation state for the unconfirmed-mode notice. The timer's handler
    /// blocks are serialised, but each block only *spawns* a Task — the tick
    /// bodies themselves can overlap when one runs long (per-fan SMC reads cost
    /// tens of milliseconds), so this state is guarded rather than "owned" by
    /// whichever task happens to be running.
    private var lastLoggedUnconfirmed = Set<Int>()
    private var loggedGivingUp = false
    private let logStateLock = NSLock()
    private var signalSources: [DispatchSourceSignal] = []
    private let timerQueue = DispatchQueue(label: "com.m5blade.helper.watchdog")

    public init(backend: FanBackend, chargeLimit: ChargeLimitController? = nil,
                log: @escaping @Sendable (String) -> Void = { NSLog("[m5bladed] %@", $0) }) {
        self.core = DaemonCore(backend: backend, chargeLimit: chargeLimit)
        self.log = log
        super.init()
    }

    public func start() async {
        log(await core.start(now: Date()))
        startWatchdog()
        installSignalHandlers()
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.runWatchdogTick() }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func runWatchdogTick() async {
        let action = await core.watchdogTick(now: Date())

        // Logged on change only, so an unreadable mode key does not produce a
        // line every second — but logged at all, because "the daemon does not
        // know what state this fan is in" is the condition every stranded-fan
        // failure passes through on its way to becoming permanent.
        let unconfirmed = await core.unconfirmedFanIndices()
        let unconfirmedChanged = logStateLock.withLock {
            let changed = unconfirmed != lastLoggedUnconfirmed
            if changed { lastLoggedUnconfirmed = unconfirmed }
            return changed
        }
        if unconfirmedChanged {
            if unconfirmed.isEmpty {
                log("all fan modes verified again")
            } else {
                log("cannot verify fan mode(s) \(unconfirmed.sorted().map(String.init).joined(separator: ","))"
                    + " — believing the last write until the hardware answers")
            }
        }

        switch action {
        case .idle:
            break
        case .released(let outcome):
            logStateLock.withLock { loggedGivingUp = false }
            log("watchdog timeout — \(outcome.summary)")
        case .releaseIncomplete(let outcome, let attempt):
            logStateLock.withLock { loggedGivingUp = false }
            log("watchdog release incomplete (attempt \(attempt)) — \(outcome.summary)")
        case .givingUp(let outcome):
            // The state is already on disk once; repeating it every second for
            // as long as the machine stays wedged used to grow an unrotated
            // /var/log file by megabytes a day without changing what it said.
            // The slow-cadence retry in DaemonCore produces real released/
            // incomplete lines when anything changes, so silence here is safe.
            let first = logStateLock.withLock {
                if loggedGivingUp { return false }
                loggedGivingUp = true
                return true
            }
            if first {
                log("watchdog gave up fast retries after \(DaemonConstants.maxReleaseRetries)"
                    + " attempts — will keep trying every \(Int(DaemonConstants.slowReleaseRetryInterval))s"
                    + " — \(outcome.summary)")
            }
        }
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: timerQueue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task {
                    let outcome = await self.core.releaseAll()
                    self.log("signal \(sig) — \(outcome.summary)")
                    exit(outcome.isComplete ? 0 : 1)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - FanControlDaemonProtocol

    public func getVersion(reply: @escaping (String) -> Void) {
        reply(Self.version)
    }

    public func getCapabilities(reply: @escaping (Int, String?, Bool, String?) -> Void) {
        Task {
            let caps = await core.capabilities()
            let count = await core.knownFanCount()
            reply(count, caps.modeKeySuffix, caps.hasFtstUnlock, caps.generationHint)
        }
    }

    public func setTarget(fan: Int, rpm: Double, reply: @escaping (Bool, String?) -> Void) {
        Task {
            switch await core.setTarget(fan: fan, rpm: rpm, now: Date()) {
            case .success:
                reply(true, nil)
            case .failure(let error):
                log("rejected setTarget: \(error.localizedDescription)")
                reply(false, error.localizedDescription)
            }
        }
    }

    public func setManualMode(fan: Int, enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        Task {
            switch await core.setManualMode(fan: fan, enabled: enabled, now: Date()) {
            case .success:
                reply(true, nil)
            case .failure(let error):
                log("rejected setManualMode: \(error.localizedDescription)")
                reply(false, error.localizedDescription)
            }
        }
    }

    public func releaseAll(reply: @escaping (Bool, String?) -> Void) {
        Task {
            let outcome = await core.releaseAll()
            if outcome.isComplete {
                reply(true, nil)
            } else {
                log("releaseAll incomplete — \(outcome.summary)")
                reply(false, outcome.summary)
            }
        }
    }

    public func heartbeat(maxTempC: Double, reply: @escaping (Bool) -> Void) {
        Task {
            await core.heartbeat(maxTempC: maxTempC, at: Date())
            reply(true)
        }
    }

    public func readFans(reply: @escaping (Data?, String?) -> Void) {
        Task {
            let states = await core.readFans()
            do {
                reply(try JSONEncoder().encode(states), nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
    }

    // MARK: Charge limit

    public func getChargeLimit(reply: @escaping (Data?, String?) -> Void) {
        Task {
            let status = await core.chargeLimitStatus()
            do {
                reply(try JSONEncoder().encode(status), nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
    }

    public func setChargeLimit(percent: Int, reply: @escaping (Bool, String?) -> Void) {
        Task {
            switch await core.setChargeLimit(percent: percent) {
            case .success:
                log("charge limit set to \(percent)")
                reply(true, nil)
            case .failure(let failure):
                log("rejected setChargeLimit: \(failure.reason)")
                reply(false, failure.reason)
            }
        }
    }
}

/// Rejects any client that isn't the app we shipped alongside this helper.
/// Without this the Mach service is an unauthenticated root control channel
/// reachable by every process on the machine (AUDIT A-2).
public final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: DaemonService
    private let requirement: String?

    public init(service: DaemonService, requirement: String?) {
        self.service = service
        self.requirement = requirement
    }

    public func listener(_ listener: NSXPCListener,
                         shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else {
            NSLog("[m5bladed] WARNING: no code signing requirement configured — refusing connection")
            return false
        }
        // Below macOS 13 there is no supported way to pin the peer's code
        // signature on an NSXPCConnection. Refuse rather than accept an
        // unauthenticated root control channel: the deployment target is 14, so
        // this branch is unreachable in practice and exists so that lowering the
        // target cannot silently open the socket.
        guard #available(macOS 13.0, *) else {
            NSLog("[m5bladed] code signing requirements unavailable on this OS — refusing connection")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FanControlDaemonProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
