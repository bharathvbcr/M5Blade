import Foundation

/// How a watt reading renders as text.
///
/// `%.0f` rounded every idle reading below half a watt down to "0W" —
/// indistinguishable from the fabricated zero a dead counter produces, and
/// read by the user as "power measurement is broken". One decimal below ten
/// watts keeps idle visibly distinct from absent; above ten, the decimal is
/// noise next to fan rpm and temperature.
///
/// Absent stays absent: nil renders as "—", never as zero. The one place that
/// knows a reading does not exist must not be asked to draw one.
enum PowerText {
    /// Below this, one decimal is kept.
    static let decimalBelowWatts: Double = 10

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value < decimalBelowWatts {
            return String(format: "%.1fW", value)
        }
        return String(format: "%.0fW", value)
    }
}
