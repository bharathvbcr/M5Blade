import Foundation
import FanKit

/// Deterministic generators and invariant checks for the stress suite.
///
/// Not linked by the app, the daemon, or the probe — only by test targets. It
/// lives here rather than being copied into each test file so that "what counts
/// as a safety violation" has exactly one definition; three copies of that
/// predicate would drift, and the copy that drifted would be the one that
/// stopped catching things.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    /// Seeded explicitly. A stress failure that cannot be reproduced is a rumour.
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// One sample handed to the control loop, including the ways a sample can be
/// broken.
public struct TraceSample: Sendable, Equatable {
    public let tempC: Double?
    public let pressure: ThermalPressure
    /// Seconds since the previous sample. Not always 1: sleep, stalls, and clock
    /// changes are part of the trace.
    public let dt: TimeInterval

    public init(tempC: Double?, pressure: ThermalPressure = .nominal, dt: TimeInterval = 1) {
        self.tempC = tempC
        self.pressure = pressure
        self.dt = dt
    }
}

/// Temperature traces designed to break a controller rather than to flatter it.
public enum Trace {

    /// Cold to critical and back, faster than any real machine.
    public static func ramp(from: Double, to: Double, steps: Int) -> [TraceSample] {
        guard steps > 1 else { return [TraceSample(tempC: from)] }
        return (0..<steps).map { i in
            let t = Double(i) / Double(steps - 1)
            return TraceSample(tempC: from + t * (to - from))
        }
    }

    /// Instant jumps between two temperatures — the worst case for hysteresis
    /// and slew limiting at the same time.
    public static func square(low: Double, high: Double, period: Int, steps: Int) -> [TraceSample] {
        (0..<steps).map { i in
            TraceSample(tempC: (i / max(1, period)) % 2 == 0 ? low : high)
        }
    }

    /// A realistic-looking noisy plateau: the case where a controller that does
    /// not smooth will chatter the fan audibly.
    public static func noisy(around: Double, amplitude: Double, steps: Int,
                             rng: inout SplitMix64) -> [TraceSample] {
        (0..<steps).map { _ in
            TraceSample(tempC: around + Double.random(in: -amplitude...amplitude, using: &rng))
        }
    }

    /// Everything at once: jumps, noise, dropouts, NaN, sleep gaps, clock jumps,
    /// and thermal pressure moving independently of temperature.
    public static func hostile(steps: Int, rng: inout SplitMix64) -> [TraceSample] {
        var samples: [TraceSample] = []
        samples.reserveCapacity(steps)
        var temp = 45.0
        for _ in 0..<steps {
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<55:
                temp += Double.random(in: -3...3, using: &rng)
            case 55..<70:
                temp = Double.random(in: 20...110, using: &rng)     // instant jump
            case 70..<75:
                samples.append(TraceSample(tempC: nil, dt: 1))       // sensor dropout
                continue
            case 75..<78:
                samples.append(TraceSample(tempC: .nan, dt: 1))      // broken sensor
                continue
            case 78..<80:
                samples.append(TraceSample(tempC: temp, dt: 4 * 3600))  // wake from sleep
                continue
            case 80..<82:
                samples.append(TraceSample(tempC: temp, dt: -600))   // clock moved back
                continue
            default:
                break
            }
            temp = min(120, max(-10, temp))
            let pressure = ThermalPressure(rawValue: Int.random(in: 0...3, using: &rng)) ?? .nominal
            samples.append(TraceSample(tempC: temp, pressure: pressure,
                                       dt: Double.random(in: 0.2...5, using: &rng)))
        }
        return samples
    }
}

/// The safety contract, in one place.
///
/// Every stress run asserts exactly this, so tightening the contract tightens
/// every test at once.
public enum ControlInvariants {

    public struct Violation: Error, CustomStringConvertible {
        public let step: Int
        public let message: String
        public var description: String { "step \(step): \(message)" }
    }

    /// - Parameters:
    ///   - decision: what the loop returned.
    ///   - fan: the fan it was computed for.
    ///   - floorTempC: the machine-wide sample that drove the floor, if any.
    ///   - previousRPM: the previous step's target, if any. The ceiling may be
    ///     exceeded *while descending* — a slew-limited ramp down from an
    ///     emergency cannot teleport to the new ceiling — but never while
    ///     climbing. Without this distinction the ceiling check would have to be
    ///     dropped entirely, which is how a ceiling stops being enforced.
    public static func check(_ decision: ControlDecision,
                             fan: FanDescriptor,
                             settings: ControlSettings,
                             floor: SafetyFloor,
                             floorTempC: Double?,
                             pressure: ThermalPressure,
                             previousRPM: Double? = nil,
                             step: Int) throws {
        guard decision.targetRPM.isFinite else {
            throw Violation(step: step, message: "non-finite target rpm")
        }
        guard decision.targetPercent.isFinite else {
            throw Violation(step: step, message: "non-finite target percent")
        }
        guard decision.targetRPM >= 0 else {
            throw Violation(step: step, message: "negative target rpm \(decision.targetRPM)")
        }
        guard decision.targetRPM <= fan.effectiveMax + 0.001 else {
            throw Violation(step: step,
                            message: "target \(decision.targetRPM) above the fan maximum \(fan.effectiveMax)")
        }
        guard decision.targetPercent >= -0.001, decision.targetPercent <= 100.001 else {
            throw Violation(step: step, message: "target percent \(decision.targetPercent) outside 0...100")
        }
        if decision.releaseToSystem { return }

        // The floor is computed from the *raw* machine maximum, deliberately —
        // if the loop ever filters that input, this is the assertion that fails.
        let sample = (floorTempC?.isFinite ?? false) ? floorTempC! : Double.nan
        let expectedFloor = floor.floorPercent(tempC: sample, pressure: pressure)
        guard decision.floorPercent >= expectedFloor - 0.001 else {
            throw Violation(step: step,
                            message: "reported floor \(decision.floorPercent) below the required \(expectedFloor)")
        }
        guard decision.targetPercent >= expectedFloor - 0.001 else {
            throw Violation(step: step,
                            message: "target \(decision.targetPercent)% below the safety floor \(expectedFloor)%")
        }
        if !decision.isEmergency {
            let ceiling = max(expectedFloor, min(100, max(0, settings.ceilingPercent)))
            let descending = previousRPM.map { decision.targetRPM <= $0 + 0.001 } ?? false
            guard decision.targetPercent <= ceiling + 0.001 || descending else {
                throw Violation(step: step,
                                message: "target \(decision.targetPercent)% climbed above the ceiling \(ceiling)%")
            }
        }
    }
}
