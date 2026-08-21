import Foundation

public struct ControlSettings: Sendable, Codable, Equatable {
    public var ceilingPercent: Double
    public var hysteresisC: Double
    public var slewUpRPMPerSec: Double
    public var slewDownRPMPerSec: Double
    public var smoothingAlpha: Double

    public init(ceilingPercent: Double = 95,
                hysteresisC: Double = 3,
                slewUpRPMPerSec: Double = 200,
                slewDownRPMPerSec: Double = 100,
                smoothingAlpha: Double = 0.3) {
        self.ceilingPercent = ceilingPercent
        self.hysteresisC = hysteresisC
        self.slewUpRPMPerSec = slewUpRPMPerSec
        self.slewDownRPMPerSec = slewDownRPMPerSec
        self.smoothingAlpha = smoothingAlpha
    }

    /// Bounds every field to a range the control loop can act on.
    ///
    /// The loop defends itself against nonsense too, but silently ignoring a
    /// hand-edited `slewUpRPMPerSec: -400` leaves the user with a file that says
    /// one thing and a fan that does another. Correcting it here means the
    /// stored config and the running behaviour always agree.
    public func sanitized() -> ControlSettings {
        func bounded(_ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
        }
        return ControlSettings(
            ceilingPercent: bounded(ceilingPercent, 0...100, default: 95),
            hysteresisC: bounded(hysteresisC, 0...25, default: 3),
            slewUpRPMPerSec: bounded(slewUpRPMPerSec, 0...10_000, default: 200),
            slewDownRPMPerSec: bounded(slewDownRPMPerSec, 0...10_000, default: 100),
            smoothingAlpha: bounded(smoothingAlpha, 0.01...1, default: 0.3))
    }
}

public struct ControlDecision: Sendable, Equatable {
    public let targetRPM: Double
    public let targetPercent: Double
    public let floorPercent: Double
    public let isEmergency: Bool
    public let releaseToSystem: Bool
    public let reason: String
}

/// Per-fan control loop: EMA smoothing, hysteresis, floor/ceiling clamping, and
/// slew limiting. Pure state machine — no I/O, so it is fully testable without
/// hardware.
public struct ControlLoop: Sendable {
    public let fan: FanDescriptor
    public var curve: FanCurve
    public var settings: ControlSettings
    public var floor: SafetyFloor

    private var smoothedTemp: Double?
    private var heldTemp: Double?
    private var lastRPM: Double?

    /// If no valid sample arrives within this window, release to system mode.
    public var stalenessLimit: TimeInterval = 10
    private var lastSampleTime: Date?

    /// Longest gap that still counts as "the previous tick". Anything larger is
    /// a discontinuity — sleep/wake, a suspended process, a clock adjustment —
    /// and the smoothing and slew state from before it describe a machine that
    /// no longer exists. Slew-limiting across a 4-hour sleep would also make the
    /// per-second rate limit meaningless in exactly the moment it matters.
    public var maxTickInterval: TimeInterval = 10

    public init(fan: FanDescriptor,
                curve: FanCurve,
                settings: ControlSettings = ControlSettings(),
                floor: SafetyFloor = SafetyFloor()) {
        self.fan = fan
        self.curve = curve
        self.settings = settings
        self.floor = floor
    }

    public mutating func reset() {
        smoothedTemp = nil
        heldTemp = nil
        lastRPM = nil
        lastSampleTime = nil
    }

    /// Advance one tick.
    ///
    /// Two temperatures, deliberately:
    ///
    /// - `curveTempC` is what the *user's* curve is evaluated at — the reduction
    ///   over the sensors this fan is mapped to (AUDIT A-3). It is smoothed and
    ///   held by hysteresis, because that is noise on a preference.
    /// - `floorTempC` is the machine-wide maximum and drives the safety floor,
    ///   the emergency check, and staleness. It is read raw: filtering a safety
    ///   input just delays the safety response (AUDIT A-1).
    ///
    /// Passing the same value for both reproduces the old single-sensor
    /// behaviour, which is what an unmapped curve does.
    public mutating func step(curveTempC: Double?,
                              floorTempC: Double?,
                              pressure: ThermalPressure,
                              now: Date,
                              dt: TimeInterval) -> ControlDecision {

        // A non-finite reading is missing data wearing a number's clothes.
        let floorSample = (floorTempC?.isFinite ?? false) ? floorTempC : nil

        guard let raw = floorSample else {
            let gap = lastSampleTime.map { now.timeIntervalSince($0) }
            if let gap, gap >= 0, gap < stalenessLimit {
                // Tolerate a brief gap by holding the previous decision — but
                // hold it *above the unknown-temperature floor*. This branch used
                // to report `floorPercent: 0`, which is not "the floor is zero",
                // it is "we did not compute one". A machine whose sensors blink
                // out is not a machine known to be cool, and the daemon already
                // applies its hard floor to exactly this evidence; the two halves
                // must not disagree about what an unreadable sensor means.
                let unknownFloor = floor.floorPercent(tempC: .nan, pressure: pressure)
                let emergency = floor.requiresEmergency(tempC: .nan, pressure: pressure)
                let held = max(lastRPM ?? fan.rpm(forPercent: 100),
                               fan.rpm(forPercent: emergency ? 100 : unknownFloor))
                lastRPM = held
                return ControlDecision(targetRPM: held,
                                       targetPercent: fan.percent(forRPM: held),
                                       floorPercent: unknownFloor,
                                       isEmergency: emergency,
                                       releaseToSystem: false,
                                       reason: "sensor gap — holding at the unknown-temperature floor")
            }
            reset()
            return ControlDecision(targetRPM: 0, targetPercent: 0, floorPercent: 0,
                                   isEmergency: false, releaseToSystem: true,
                                   reason: "sensor data stale — released to system")
        }

        // A gap larger than one tick means the state we are carrying describes a
        // machine from before a sleep, a stall, or a clock change. Drop it rather
        // than smoothing across the discontinuity or slew-limiting from an rpm
        // the fan left behind hours ago.
        let elapsed = lastSampleTime.map { now.timeIntervalSince($0) } ?? dt
        if elapsed < 0 || elapsed > maxTickInterval { reset() }
        let effectiveDt = min(max(0, dt), maxTickInterval)

        lastSampleTime = now

        // The curve reads its own sensors; an unmapped or broken mapping falls
        // back to the machine-wide maximum, which is the conservative direction.
        let curveRaw = (curveTempC?.isFinite ?? false) ? curveTempC! : raw

        // 1. EMA smoothing
        let alpha = max(0.01, min(1, settings.smoothingAlpha.isFinite ? settings.smoothingAlpha : 0.3))
        let smoothed = smoothedTemp.map { $0 + alpha * (curveRaw - $0) } ?? curveRaw
        smoothedTemp = smoothed

        // 2. Hysteresis — only move the working temperature on a meaningful change
        let hysteresis = settings.hysteresisC.isFinite ? max(0, settings.hysteresisC) : 0
        let working: Double
        if let held = heldTemp, abs(smoothed - held) < hysteresis {
            working = held
        } else {
            working = smoothed
            heldTemp = smoothed
        }

        // 3. Curve, floor, ceiling. Floor always wins over the user's curve.
        //
        // Smoothing and hysteresis exist to stop the *curve* chasing sensor noise;
        // they must never delay a safety response. The floor and the emergency
        // check therefore both read the raw sample, per AUDIT A-1
        // (`staticFloor(for: maxTemp)` — the measured maximum, not a filtered one).
        // Feeding `working` here let the floor lag the real temperature by the EMA
        // time constant plus the hysteresis band — on a 1 °C/s ramp that is ~5 °C,
        // or ~13 percentage points of floor in the steep part of the static curve.
        let emergency = floor.requiresEmergency(tempC: raw, pressure: pressure)
        let floorPct = floor.floorPercent(tempC: raw, pressure: pressure)
        let requestedCeiling = settings.ceilingPercent.isFinite
            ? min(100, max(0, settings.ceilingPercent)) : 100
        let ceiling = emergency ? 100 : max(floorPct, requestedCeiling)

        var percent = max(curve.percent(at: working), floorPct)
        percent = min(percent, ceiling)

        // 4. Slew limiting on the RPM domain. A negative or non-finite rate would
        // invert the limiter — `previous + (-500)` drags the target *down* on the
        // way up — so rates are clamped to non-negative before they are used.
        var rpm = fan.rpm(forPercent: percent)
        if let previous = lastRPM, effectiveDt > 0, !emergency {
            let maxUp = Self.rate(settings.slewUpRPMPerSec) * effectiveDt
            let maxDown = Self.rate(settings.slewDownRPMPerSec) * effectiveDt
            if rpm > previous { rpm = min(rpm, previous + maxUp) }
            if rpm < previous { rpm = max(rpm, previous - maxDown) }
        }

        // The floor is enforced after slew, so ramping never dips below it.
        rpm = max(rpm, fan.rpm(forPercent: floorPct))
        lastRPM = rpm

        let reason: String
        if emergency { reason = "emergency — ceiling released" }
        else if percent <= floorPct + 0.001 { reason = "safety floor" }
        else { reason = "curve" }

        return ControlDecision(targetRPM: rpm,
                               targetPercent: fan.percent(forRPM: rpm),
                               floorPercent: floorPct,
                               isEmergency: emergency,
                               releaseToSystem: false,
                               reason: reason)
    }

    /// A slew rate that cannot invert the limiter. Zero means "do not move",
    /// which is a coherent (if useless) setting; negative is not.
    private static func rate(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
