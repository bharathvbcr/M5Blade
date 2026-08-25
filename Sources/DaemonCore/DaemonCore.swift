import Foundation
import FanKit
import PowerKit
import DaemonProtocol

/// The privileged half's decision-making, with no XPC and no globals.
///
/// An actor rather than a class guarded by a `DispatchQueue`. The previous
/// design mutated `fans`, `manualFans`, and `lastReportedTemp` from XPC reply
/// queues, from detached `Task`s, and from a signal-source queue simultaneously,
/// while only the watchdog actually used the queue — so the fan set could be
/// read mid-write and the temperature the clamp depends on was a data race.
/// Actor isolation makes that unrepresentable, and it makes the whole policy
/// testable against `SimulatedFanBackend` without root or hardware.
public actor DaemonCore {

    /// Requests the daemon refuses outright rather than interpreting.
    public enum RequestError: LocalizedError, Equatable {
        case noFansDiscovered
        case unknownFan(Int)
        case invalidRPM(Double)
        case notUnderManualControl(Int)
        /// The mode write was accepted and the fan is not in that mode. Distinct
        /// from `hardware`, which is a write the SMC refused outright.
        case modeDidNotTake(Int, wanted: FanMode, got: FanMode)
        case hardware(String)

        public var errorDescription: String? {
            switch self {
            case .noFansDiscovered:
                return "SMC not initialised — no fans discovered"
            case .unknownFan(let i):
                return "no such fan: \(i)"
            case .invalidRPM(let v):
                return "target rpm is not a finite number: \(v)"
            case .notUnderManualControl(let i):
                return "fan \(i) is not under manual control — call setManualMode first"
            case .modeDidNotTake(let i, let wanted, let got):
                return "fan \(i): wrote mode \(wanted) but the hardware reports mode \(got.rawValue) — thermalmonitord is holding this fan"
            case .hardware(let why):
                return why
            }
        }
    }

    /// What a watchdog tick decided, so the caller can log it and tests can
    /// assert on it without waiting in real time.
    public enum WatchdogAction: Sendable, Equatable {
        case idle
        case released(ReleaseOutcome)
        case releaseIncomplete(ReleaseOutcome, attempt: Int)
        case givingUp(ReleaseOutcome)
    }

    private let backend: FanBackend
    private var fans: [FanDescriptor] = []
    private var manualFans = Set<Int>()
    private var lastHeartbeat: (tempC: Double, at: Date)?
    /// When a fan most recently came under manual control — by a client arming
    /// it, or by adoption at startup.
    ///
    /// The watchdog needs this because arming and the first heartbeat cannot be
    /// simultaneous: the app arms every fan and *then* starts its 1 Hz loop, so
    /// the first beat is up to a second later. Measuring the timeout only from
    /// `lastHeartbeat` made a client that had just armed indistinguishable from
    /// one that had died, and the watchdog took the fans straight back off it.
    private var manualSince: Date?
    /// Fans whose last mode operation could not be checked against the hardware.
    ///
    /// Both directions are dangerous, and neither is detectable at the moment it
    /// happens. An unconfirmed *release* may have left the fan spinning with
    /// nothing tracking it. An unconfirmed *arm* may have recorded control we
    /// never obtained, so every later target is written into the void and
    /// reported to the app as success — which is precisely the lie the mode
    /// readback was added to stop.
    ///
    /// Both resolve the same way: keep the fan on a list, re-read it on every
    /// watchdog tick, and reconcile the record the moment the hardware can
    /// answer. Empty on healthy hardware, so it costs nothing in the normal case.
    private var unconfirmed = Set<Int>()
    private var releaseRetries = 0
    /// When the slow-cadence retry after giving up may run again.
    private var nextSlowRetry: Date?
    private var lastReleaseOutcome: ReleaseOutcome?
    /// Set once the watchdog has fired and not yet been cleared by a fresh
    /// heartbeat, so a client that stopped talking cannot resume driving fans
    /// simply by sending another `setTarget`.
    private var watchdogTripped = false

    public init(backend: FanBackend, chargeLimit: ChargeLimitController? = nil) {
        self.backend = backend
        self.chargeLimit = chargeLimit
    }

    // MARK: - Charge limit (DESIGN §6.3)

    private let chargeLimit: ChargeLimitController?

    /// The firmware charge-limit state. Nil controller means the daemon was
    /// built without one, which reports as unsupported — indistinguishable,
    /// deliberately, from hardware that has no key.
    public func chargeLimitStatus() async -> ChargeLimitStatus {
        guard let chargeLimit else { return .unsupported }
        let (state, support) = await chargeLimit.status()
        guard support.isSupported else { return .unsupported }
        return ChargeLimitStatus(supported: true, percent: state.percent,
                                 keyName: support.hasAppleSiliconKey ? "CHWA" : "BCLM")
    }

    /// Applies policy, writes through the controller, and reports what the
    /// read-back verified — never what the write claimed.
    public func setChargeLimit(percent: Int) async -> Result<Void, ChargeLimitWriteFailure> {
        guard let chargeLimit else {
            return .failure(ChargeLimitWriteFailure(
                reason: "this helper was built without charge-limit control"))
        }
        let battery = BatteryReader.read()
        switch ChargeLimitPolicy.validate(percent: percent,
                                          support: await chargeLimit.support(),
                                          batteryInstalled: battery?.batteryInstalled) {
        case .failure(let rejection):
            return .failure(ChargeLimitWriteFailure(
                reason: Self.chargeLimitRejectionText(rejection)))
        case .success:
            break
        }
        switch await chargeLimit.set(percent: percent) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(ChargeLimitWriteFailure(reason: error.message))
        }
    }

    static func chargeLimitRejectionText(_ rejection: ChargeLimitPolicy.Rejection) -> String {
        switch rejection {
        case .unsupportedPercent(let requested):
            return "only 80 or 100 may be set (asked for \(requested))"
        case .noFirmwareKey:
            return "this Mac's SMC exposes no charge-limit key; use System Settings → Battery"
        case .noBattery:
            return "this Mac has no battery to limit"
        }
    }

    // MARK: - Lifecycle

    /// Brings up the backend. Returns a log line; never throws, because a daemon
    /// that exits on a failed probe leaves nothing listening to release the fans.
    /// `now` is explicit rather than defaulted, here and on `setManualMode`,
    /// because both now seed the watchdog's clock. A default would let a caller
    /// stamp wall-clock time into a synthetic timeline and get a watchdog that
    /// either never fires or fires immediately — silently, and only in whichever
    /// direction the two clocks happened to differ.
    @discardableResult
    public func start(now: Date) async -> String {
        do {
            fans = try await backend.discoverFans()
        } catch {
            fans = []
            return "SMC init failed: \(String(describing: error))"
        }
        let caps = await backend.capabilities()
        var line = "\(fans.count) fan(s); \(caps.generationHint)"

        let adopted = await adoptFansAlreadyUnderManualControl(now: now)
        if !adopted.isEmpty {
            line += "; adopted fan(s) \(adopted.sorted().map(String.init).joined(separator: ",")) "
                + "found under manual control at startup — releasing in "
                + "\(Int(DaemonConstants.watchdogTimeout))s unless a client takes over"
        }
        return line
    }

    /// Claims any fan the hardware says is already under manual control.
    ///
    /// launchd restarts this helper on `KeepAlive`, and the replacement starts
    /// with an empty `manualFans` — so every fan a crashed instance had pinned
    /// was invisible to it. The watchdog saw nothing under manual control,
    /// reported idle forever, and the fan sat at whatever rpm it was last given
    /// with nothing in the system able to notice. The app cannot recover from
    /// this either: its own release path runs through this daemon.
    ///
    /// Adoption rather than an immediate release, because a helper restarted
    /// underneath a *running* app should let that app take over rather than
    /// yanking the fans between its ticks. `manualSince` starts the same grace
    /// window arming gets; if no client claims them, the watchdog releases them.
    private func adoptFansAlreadyUnderManualControl(now: Date) async -> Set<Int> {
        var adopted = Set<Int>()
        for fan in fans {
            guard let reading = try? await backend.readFan(fan.index),
                  let mode = reading.mode, mode.isUserControlled
            else { continue }
            adopted.insert(fan.index)
        }
        guard !adopted.isEmpty else { return [] }
        manualFans.formUnion(adopted)
        manualSince = now
        return adopted
    }

    public func knownFanCount() -> Int { fans.count }
    public func manualFanIndices() -> Set<Int> { manualFans }

    public func capabilities() async -> FanCapabilities {
        await backend.capabilities()
    }

    // MARK: - Safety

    private func requireFan(_ index: Int) throws -> FanDescriptor {
        guard !fans.isEmpty else { throw RequestError.noFansDiscovered }
        guard let fan = fans.first(where: { $0.index == index }) else {
            throw RequestError.unknownFan(index)
        }
        return fan
    }

    /// The daemon's own floor, independent of the app's `SafetyFloor` so a bug or
    /// a compromise on the app side cannot lower it.
    private func clamp(rpm: Double, fan: FanDescriptor, now: Date) throws -> Double {
        guard rpm.isFinite else { throw RequestError.invalidRPM(rpm) }
        return DaemonConstants.clampRPM(rpm,
                                        minRPM: fan.effectiveMin,
                                        maxRPM: fan.effectiveMax,
                                        temperature: .from(lastHeartbeat: lastHeartbeat, now: now))
    }

    // MARK: - Requests

    public func heartbeat(maxTempC: Double, at now: Date) {
        // A finite-but-absurd temperature must not reach the clamp as
        // "measured": one reading of TTPD's −306783232 °C would otherwise read
        // as an ice-cold machine and switch the daemon's independent hard floor
        // *off* — the exact input the floor exists to survive. Implausible
        // values are stored as NaN, which `TemperatureEvidence.from` maps to
        // `.unknown`, and unknown applies the floor.
        let plausible = PlausibleTemperature.admits(maxTempC) ? maxTempC : .nan
        lastHeartbeat = (plausible, now)
        watchdogTripped = false
        releaseRetries = 0
    }

    /// Sets a fan target. Refuses for a fan that is not under manual control:
    /// writing a target to a fan macOS is driving is a write into the void, and
    /// reporting it as success is how the app came to believe it was controlling
    /// fans it had already handed back.
    public func setTarget(fan index: Int, rpm: Double, now: Date) async -> Result<Double, RequestError> {
        do {
            let fan = try requireFan(index)
            guard !watchdogTripped else { throw RequestError.notUnderManualControl(index) }
            guard manualFans.contains(index) else { throw RequestError.notUnderManualControl(index) }
            let clamped = try clamp(rpm: rpm, fan: fan, now: now)
            try await backend.setTarget(rpm: clamped, fan: index)
            return .success(clamped)
        } catch let error as RequestError {
            return .failure(error)
        } catch {
            return .failure(.hardware(String(describing: error)))
        }
    }

    /// Takes or gives back manual control of one fan.
    ///
    /// The rule is **observe, do not assume**, and it took two wrong versions to
    /// get here. Assuming symmetrically ("a failed operation changes nothing")
    /// forgets a fan whose hand-back was rejected. Assuming asymmetrically
    /// ("a failed arm means we hold nothing, a failed hand-back means we hold
    /// it") is wrong in both directions the moment the fan's prior state differs
    /// from the assumption:
    ///
    ///  * a failed *re*-arm of a fan that was already manual forgets a fan that
    ///    is still spinning, and nothing is left to release it;
    ///  * a failed hand-back of a fan that was never manual claims one macOS is
    ///    driving, and every later target is written into the void and reported
    ///    as success.
    ///
    /// The randomised lifecycle soak produces both inside a few hundred
    /// operations. So on failure the record is rebuilt from what the hardware
    /// actually reports — and when the hardware cannot report, the record is
    /// left exactly as it was, because an operation that tells us nothing must
    /// not change what we believe.
    public func setManualMode(fan index: Int, enabled: Bool, now: Date) async -> Result<Void, RequestError> {
        // Resolved first and separately: a fan that does not exist cannot be
        // "still under manual control", so the recovery below must not run for it.
        do {
            _ = try requireFan(index)
        } catch let error as RequestError {
            return .failure(error)
        } catch {
            return .failure(.hardware(String(describing: error)))
        }

        do {
            try await backend.setMode(enabled ? .manual : .auto, fan: index)
            switch await observedUserControl(fan: index) {
            case .some(let observed) where observed != enabled:
                // The write was accepted and the fan is in the other mode. On
                // M3/M4 `thermalmonitord` does exactly this.
                throw RequestError.modeDidNotTake(index,
                                                  wanted: enabled ? .manual : .auto,
                                                  got: enabled ? .system : .manual)
            case .some:
                recordManualState(fan: index, userControlled: enabled, now: now,
                                  claimedByClient: enabled, confirmed: true)
            case .none:
                // Wrote it, cannot look. Believe the write for now — it is the
                // best evidence available — but mark it for re-checking rather
                // than treating a guess as a fact.
                recordManualState(fan: index, userControlled: enabled, now: now,
                                  claimedByClient: enabled, confirmed: false)
            }
            return .success(())
        } catch {
            if let observed = await observedUserControl(fan: index) {
                recordManualState(fan: index, userControlled: observed, now: now,
                                  claimedByClient: false, confirmed: true)
            } else {
                // Failed, and the hardware cannot say what state it was left in.
                // Leave the record alone and re-check later.
                unconfirmed.insert(index)
            }
            if let request = error as? RequestError { return .failure(request) }
            return .failure(.hardware(String(describing: error)))
        }
    }

    /// Whether the hardware says this fan is under user control, or nil when it
    /// cannot say.
    ///
    /// Three answers, not two, and the third is the one that matters.
    /// `releaseAll` already reads the mode back because on M3/M4
    /// `thermalmonitord` can accept a mode write and then override it — "we
    /// wrote manual" is not "the fan is manual". Arming needs the same check for
    /// the same reason. But "unreadable" is not "not manual" either, and
    /// collapsing those two is how a spinning fan disappears from the records.
    /// `releaseAll` draws that line already (`unverified` is not `failed`); this
    /// is the same line, drawn once, for every caller.
    private func observedUserControl(fan index: Int) async -> Bool? {
        guard let reading = try? await backend.readFan(index), let mode = reading.mode else {
            return nil
        }
        return mode.isUserControlled
    }

    /// The single writer of the manual-control record.
    ///
    /// - Parameter claimedByClient: true only when a client successfully armed
    ///   this fan just now. That is the one event that proves a live client is
    ///   on the other end, so it is the only one allowed to restart the watchdog
    ///   grace window or clear a tripped watchdog. Reconciling the record after
    ///   a *failure* must do neither — otherwise a fan that keeps failing to
    ///   hand back would keep renewing its own reprieve.
    private func recordManualState(fan index: Int, userControlled: Bool,
                                   now: Date, claimedByClient: Bool, confirmed: Bool) {
        if confirmed { unconfirmed.remove(index) } else { unconfirmed.insert(index) }
        if userControlled {
            manualFans.insert(index)
            if claimedByClient {
                manualSince = now
                watchdogTripped = false
            } else if manualSince == nil {
                // Something is under manual control and no client has claimed
                // it. Give the watchdog a clock to measure from rather than none.
                manualSince = now
            }
        } else {
            manualFans.remove(index)
            if manualFans.isEmpty { manualSince = nil }
        }
    }

    /// Re-reads every fan whose state we could not confirm, and reconciles.
    ///
    /// This is the mechanism that makes an unverifiable window temporary rather
    /// than permanent. `ReleaseOutcome.unverified` is deliberately not a failure
    /// — a machine whose mode key cannot be read back would otherwise keep the
    /// watchdog retrying forever — but "we wrote it and could not look" is not
    /// "it took", in either direction. Without this, a period of unreadable
    /// modes left the daemon permanently wrong about which fans it owns, and
    /// nothing in the system would ever have noticed.
    ///
    /// Only fans on the list, never a full sweep. Re-reading every fan and
    /// claiming whatever looked manual would take fans away from another tool
    /// that legitimately owns them.
    private func reconcileUnconfirmed() async {
        guard !unconfirmed.isEmpty else { return }
        for index in unconfirmed.sorted() {
            guard let userControlled = await observedUserControl(fan: index) else { continue }
            unconfirmed.remove(index)
            // Deliberately no clock here, unlike `recordManualState`: this fan
            // was OURS moments ago — an unverified release means we wrote auto
            // and could not look — so there is no live-client grace window to
            // grant. A fresh `manualSince` would delay reclaiming a fan that is
            // still spinning by a whole watchdog period; the pre-existing
            // evidence (usually a stale heartbeat) is the correct clock basis,
            // and a genuinely live client refreshes everything by its next beat.
            if userControlled { manualFans.insert(index) } else { manualFans.remove(index) }
        }
        if manualFans.isEmpty { manualSince = nil }
    }

    /// Fans the daemon currently cannot verify. Exposed so the helper can log it
    /// and the stress suite can assert the precise contract: any disagreement
    /// between the daemon's records and the hardware must be one the daemon
    /// knows it cannot presently check.
    public func unconfirmedFanIndices() -> Set<Int> { unconfirmed }

    @discardableResult
    public func releaseAll() async -> ReleaseOutcome {
        let outcome = await backend.releaseAll()
        lastReleaseOutcome = outcome
        // Only the fans we genuinely released stop counting as manual. A fan we
        // failed to release is still under manual control and must keep being
        // treated that way.
        for index in outcome.released {
            manualFans.remove(index)
            unconfirmed.remove(index)
        }
        for index in outcome.unverified {
            // Written but not confirmed. We stop driving it and keep watching it.
            manualFans.remove(index)
            unconfirmed.insert(index)
        }
        if outcome.hadNoFans { manualFans.removeAll() }
        if manualFans.isEmpty { manualSince = nil }
        return outcome
    }

    public func readFans() async -> [DaemonFanState] {
        var states: [DaemonFanState] = []
        for fan in fans {
            guard let reading = try? await backend.readFan(fan.index) else { continue }
            states.append(DaemonFanState(index: fan.index,
                                         actualRPM: reading.actualRPM,
                                         targetRPM: reading.targetRPM,
                                         mode: reading.mode?.rawValue,
                                         minRPM: fan.minRPM,
                                         maxRPM: fan.maxRPM))
        }
        return states
    }

    // MARK: - Watchdog

    /// One watchdog evaluation. Time is a parameter so the timing rules are
    /// testable without waiting.
    public func watchdogTick(now: Date) async -> WatchdogAction {
        // Anything we could not verify is reconciled first, unconditionally. It
        // must run before the early exits below — otherwise an empty `manualFans`
        // reports idle forever over a fan that is still spinning — and it must
        // run even when fans *are* recorded, because the opposite error (a fan
        // recorded that macOS is actually driving) is what turns every later
        // target into a write into the void reported as success.
        await reconcileUnconfirmed()

        if watchdogTripped {
            // Already released once; keep retrying while something is still
            // under manual control — fast at first, then at the slow cadence.
            guard !manualFans.isEmpty else { return .idle }
            return await retryRelease(now: now)
        }

        // Nothing is under manual control, so there is nothing to take back and
        // nothing to panic about. Checked before the clock rather than after:
        // tripping here would re-write `auto` to every fan once a second, forever,
        // for fans macOS is already driving.
        guard !manualFans.isEmpty else { return .idle }

        // The clock the timeout runs against is the most recent evidence that a
        // live client is on the other end — a heartbeat, or the moment it armed
        // these fans. `max` rather than a preference for either: a stale
        // heartbeat left behind by a *previous* client must not consume the grace
        // window belonging to the one that just armed.
        let evidence = [lastHeartbeat?.at, manualSince].compactMap { $0 }.max()
        guard let since = evidence else { return await trip() }
        // The stamps are wall-clock `Date`s and wall clocks are stepped: back by
        // an NTP correction, forward across a resume. Measuring the age signed
        // fails open in the dangerous direction. A step *back* past `since`
        // makes the age negative, which reads as "no time has passed", so a dead
        // client's fans stayed pinned until wall time crawled past the stamp —
        // hours for a large correction. Silence across a jump *forward*, on the
        // other hand, is genuine staleness and must keep tripping.
        //
        // Reading the age as a magnitude covers both. The error it admits is
        // bounded: a correction smaller than the whole grace window still ages
        // out within one extra period once wall time passes the stamp, and a
        // live client refreshes its stamp about once a second, so a trip it did
        // not deserve is cleared by its very next beat (`heartbeat` resets
        // `watchdogTripped`). One spurious release cycle versus unbounded
        // pinning is the right side to err on — releasing is the reversible
        // direction everywhere else in this daemon too.
        guard abs(now.timeIntervalSince(since)) > DaemonConstants.watchdogTimeout else {
            return .idle
        }
        return await trip()
    }

    private func trip() async -> WatchdogAction {
        watchdogTripped = true
        releaseRetries = 0
        nextSlowRetry = nil
        let outcome = await releaseAll()
        if outcome.isComplete { return .released(outcome) }
        releaseRetries = 1
        return .releaseIncomplete(outcome, attempt: 1)
    }

    private func retryRelease(now: Date) async -> WatchdogAction {
        // Bounded: hardware that has rejected the same write five times in six
        // seconds is not going to accept the sixth, and hammering it once a
        // second forever is a spin, not a recovery. But "give up" used to mean
        // *forever*: the retry budget was spent within seconds of the trip, and
        // hardware (or thermalmonitord) that stops refusing minutes later never
        // saw another attempt — the fans stayed pinned until a client re-armed.
        // After the fast budget is spent, one attempt per slow interval keeps
        // the recovery path alive without spinning.
        guard releaseRetries < DaemonConstants.maxReleaseRetries else {
            // Entering the slow cadence schedules the first retry rather than
            // performing it: the fast budget was spent saying no, and one more
            // immediate write against hardware that just refused five writes is
            // the spin this branch exists to prevent.
            guard let next = nextSlowRetry else {
                nextSlowRetry = now.addingTimeInterval(DaemonConstants.slowReleaseRetryInterval)
                return .givingUp(lastReleaseOutcome ?? ReleaseOutcome())
            }
            guard now >= next else {
                return .givingUp(lastReleaseOutcome ?? ReleaseOutcome())
            }
            nextSlowRetry = now.advanced(by: DaemonConstants.slowReleaseRetryInterval)
            let outcome = await releaseAll()
            if outcome.isComplete { return .released(outcome) }
            return .releaseIncomplete(outcome, attempt: DaemonConstants.maxReleaseRetries + 1)
        }
        releaseRetries += 1
        let outcome = await releaseAll()
        if outcome.isComplete { return .released(outcome) }
        return .releaseIncomplete(outcome, attempt: releaseRetries)
    }
}
