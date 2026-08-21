import Foundation

/// The window a reading has to fall in to be treated as a temperature.
///
/// One owner for every source and every consumer, because they all need the same
/// answer and each had reached it separately: the HID hub applied this window to
/// its own readings, the SMC source wrote its own copy of it, and the history
/// detectors checked only `isFinite` and so had no window at all. Three
/// definitions of one rule is how the detector comes to admit a value the sensor
/// layer rejects — which is exactly what happened. A spike was declared against a
/// baseline of 1e9 °C, and it swallowed the real rise that followed it.
///
/// It lives in `FanKit` because that is the module every side already depends on.
///
/// The range is deliberately generous. It is not a plausibility model of Apple
/// Silicon; it is a guard against a reading that cannot be a temperature at all.
/// A machine in a freezer and a die about to halt are both inside it. These are
/// not:
///
/// - `TTPD` is a `flt ` key that reads **−306783232 °C** on this Mac.
/// - A sensor that has stopped reporting can return `NaN` or an infinity.
/// - A finite `1e9` is none of the above and still not a temperature.
///
/// A key that fails the window is dropped **per read**, never struck from the
/// catalogue: a sensor that goes bad for one sample should come back on the next,
/// and one that never recovers costs a single wasted read.
public enum PlausibleTemperature {

    /// Colder than any environment a Mac survives being switched on in, hotter
    /// than any silicon that has not already halted.
    public static let range: ClosedRange<Double> = -50...200

    public static var minimumC: Double { range.lowerBound }
    public static var maximumC: Double { range.upperBound }

    /// Whether a reading may be treated as a measurement.
    ///
    /// The `isFinite` check is not redundant with the range: every comparison
    /// against `NaN` is false, so "not too hot" and "not too cold" would both
    /// pass it through.
    public static func admits(_ celsius: Double) -> Bool {
        celsius.isFinite && range.contains(celsius)
    }

    /// The reading, or nil when it is not one. The `Optional` form is what
    /// callers holding an already-optional temperature want.
    public static func validated(_ celsius: Double?) -> Double? {
        guard let celsius, admits(celsius) else { return nil }
        return celsius
    }
}
