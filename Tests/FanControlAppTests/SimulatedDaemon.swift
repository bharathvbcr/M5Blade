import Foundation
@testable import FanControlApp

/// A helper that behaves like the real one, including the way it says no.
///
/// The rule that matters is `DaemonCore.setTarget`'s: a target written to a fan
/// that is not under manual control is refused, not silently accepted. That
/// single refusal is what the app used to misread as "the watchdog dropped us"
/// and answer by re-arming — so a simulation that accepted every write would
/// reproduce nothing.
///
/// Every operation is recorded in order. The assertions that matter are about
/// ordering ("nothing re-armed a fan after the release"), which a snapshot of the
/// final state cannot express: a re-arm followed by a second release looks
/// identical to no re-arm at all.
final class SimulatedDaemon: FanControlChannel, @unchecked Sendable {

    enum Operation: Equatable, CustomStringConvertible {
        case version
        case heartbeat
        case setTarget(fan: Int, refused: Bool)
        case arm(fan: Int)
        case disarm(fan: Int)
        case releaseAll
        /// The hardware taken back by something that is not this app.
        case watchdogRelease

        var description: String {
            switch self {
            case .version:                    return "version"
            case .heartbeat:                  return "heartbeat"
            case .setTarget(let f, let r):    return "setTarget(\(f))\(r ? " refused" : "")"
            case .arm(let f):                 return "arm(\(f))"
            case .disarm(let f):              return "disarm(\(f))"
            case .releaseAll:                 return "releaseAll"
            case .watchdogRelease:            return "watchdogRelease"
            }
        }

        var isArm: Bool { if case .arm = self { return true }; return false }
    }

    private let lock = NSLock()
    private var _armed = Set<Int>()
    private var _log: [Operation] = []

    /// Fans the simulated hardware currently has under manual control.
    var armed: Set<Int> { lock.lock(); defer { lock.unlock() }; return _armed }
    var log: [Operation] { lock.lock(); defer { lock.unlock() }; return _log }

    /// Awaited inside `setTarget` when set, so a test can hold a control tick
    /// suspended at exactly the point the real one suspends on an XPC round trip.
    var beforeSetTarget: (@Sendable (Int) async -> Void)?
    /// Same, for arming — the slow operation on real hardware.
    var beforeSetManual: (@Sendable (Int, Bool) async -> Void)?

    /// Ways the real helper says no. Set between operations by the soak.
    ///
    /// `refuse` is a live helper declining (`DaemonFailure.refused`); `unreachable`
    /// is XPC itself failing. The app treats those very differently — one is worth
    /// re-arming against, the other is not — so a simulation that only had one
    /// kind would leave half the recovery logic unexercised.
    struct Faults: Sendable, Equatable {
        var refuseArm = false
        var refuseRelease = false
        var refuseTarget = false
        var unreachable = false

        static let healthy = Faults()
        var any: Bool { self != .healthy }
    }

    private var _faults = Faults()
    var faults: Faults {
        get { lock.lock(); defer { lock.unlock() }; return _faults }
        set { lock.lock(); _faults = newValue; lock.unlock() }
    }

    /// Takes every fan out of manual mode behind the app's back — what the
    /// daemon's own watchdog does after two missed heartbeats, and what a second
    /// root fan controller on the same machine does at any time (`ISSUES.md` I-9).
    /// The app is *supposed* to notice this and re-arm.
    func simulateWatchdogRelease() {
        lock.lock()
        _armed.removeAll()
        _log.append(.watchdogRelease)
        lock.unlock()
    }

    var currentGeneration: Int { 1 }
    var onDisconnect: (@Sendable (Int) -> Void)?

    /// Every mutation goes through here. Synchronous on purpose: `NSLock` may not
    /// be held across a suspension point, and a helper that took the lock in an
    /// `async` function would be a Swift 6 error rather than a warning.
    private func record(_ operation: Operation) {
        lock.lock(); defer { lock.unlock() }
        switch operation {
        case .arm(let fan):      _armed.insert(fan)
        case .disarm(let fan):   _armed.remove(fan)
        case .releaseAll:        _armed.removeAll()
        case .version, .heartbeat, .setTarget, .watchdogRelease: break
        }
        _log.append(operation)
    }

    /// Reads the armed set and logs the write it implies, as one atomic step —
    /// the two must not be separable, or a concurrent release could slip between
    /// them and the log would describe an ordering that never happened.
    private func recordWrite(fan: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let isArmed = _armed.contains(fan)
        _log.append(.setTarget(fan: fan, refused: !isArmed))
        return isArmed
    }

    private static let unreachable = DaemonFailure.connection("simulated: the helper could not be reached")

    func version() async -> Result<String, DaemonFailure> {
        record(.version)
        if faults.unreachable { return .failure(Self.unreachable) }
        return .success("simulated")
    }

    func heartbeat(maxTempC: Double) async -> Result<Void, DaemonFailure> {
        record(.heartbeat)
        if faults.unreachable { return .failure(Self.unreachable) }
        return .success(())
    }

    func setTarget(fan: Int, rpm: Double) async -> Result<Void, DaemonFailure> {
        await beforeSetTarget?(fan)
        let faults = self.faults
        if faults.unreachable { return .failure(Self.unreachable) }
        if faults.refuseTarget { return .failure(.refused("simulated: the helper refused the target")) }
        guard recordWrite(fan: fan) else {
            // Verbatim from `DaemonCore.RequestError.notUnderManualControl`, which
            // is what the helper log on this machine recorded at 18:55:22.
            return .failure(.refused("fan \(fan) is not under manual control — call setManualMode first"))
        }
        return .success(())
    }

    func setManual(fan: Int, enabled: Bool) async -> Result<Void, DaemonFailure> {
        await beforeSetManual?(fan, enabled)
        let faults = self.faults
        if faults.unreachable { return .failure(Self.unreachable) }
        // A refused arm changes nothing, which is what the helper guarantees when
        // it declines rather than when it fails to answer. Disarming is never
        // refused: the panic direction is the one that has to keep working.
        if faults.refuseArm && enabled {
            return .failure(.refused("simulated: the helper would not take manual control"))
        }
        record(enabled ? .arm(fan: fan) : .disarm(fan: fan))
        return .success(())
    }

    func releaseAll() async -> Result<Void, DaemonFailure> {
        let faults = self.faults
        if faults.unreachable { return .failure(Self.unreachable) }
        if faults.refuseRelease {
            // Refused, and the fans stay where they were — the case that must not
            // be reported to the user as "macOS is driving them now".
            return .failure(.refused("simulated: the release was not confirmed"))
        }
        record(.releaseAll)
        return .success(())
    }

    // MARK: - Assertions

    /// Whether any fan was armed after the last `releaseAll`.
    ///
    /// This is the safety property, not a cosmetic one. A fan armed after the
    /// release the user asked for is a fan under manual control that the app
    /// believes macOS is driving — so it sends no heartbeats, and nothing brings
    /// it back until the daemon's watchdog fires twelve seconds later.
    /// Whether any fan target was ever refused.
    ///
    /// The sharpest statement of the fix. The helper refuses a write to a fan
    /// that is not armed, and with the transitions serialised there is no longer
    /// any moment at which the app can issue one: a release cannot land between
    /// two of a tick's writes. So in a run with no simulated watchdog, a refusal
    /// is by definition an interleaving that should have been impossible.
    var hadRefusedWrite: Bool {
        log.contains { if case .setTarget(_, let refused) = $0 { return refused }; return false }
    }

    var reArmedAfterRelease: Bool {
        let operations = log
        guard let lastRelease = operations.lastIndex(of: .releaseAll) else { return false }
        return operations[lastRelease...].contains { $0.isArm }
    }
}
