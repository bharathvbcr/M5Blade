import Foundation

/// How much of the live readout the status item shows.
///
/// The full "42° 3120" pair is what the app has always drawn, and it is the
/// right default. But a notched MacBook clips menu bar items silently — there
/// is no API to detect that it happened (`StatusItemController`) — so the
/// alternatives are choices rather than automatic behaviour.
public enum StatusDisplayMode: String, CaseIterable, Sendable {
    /// Temperature and fastest-fan rpm. The historical readout.
    case full
    /// Temperature only — half the width, nothing clipped behind the notch.
    case temperatureOnly
    /// The fan icon alone.
    case iconOnly

    var label: String {
        switch self {
        case .full:            return "Temperature & speed"
        case .temperatureOnly: return "Temperature only"
        case .iconOnly:        return "Icon only"
        }
    }

    /// The text drawn beside the icon, or nil when there is none.
    ///
    /// Pure so `StatusItemController` renders exactly what a test can assert,
    /// and so the three modes cannot drift into three formatting opinions.
    public static func title(for mode: StatusDisplayMode,
                             tempC: Double?, maxRPM: Double?) -> String? {
        let temp = tempC.map { String(format: "%.0f°", $0) } ?? "--°"
        switch mode {
        case .iconOnly:
            return nil
        case .temperatureOnly:
            return " \(temp)"
        case .full:
            let rpm = maxRPM.map { String(format: "%.0f", $0) } ?? "----"
            return " \(temp) \(rpm)"
        }
    }
}

/// How often sensors are sampled while macOS owns the fans.
///
/// Controlling is always 1 Hz (AUDIT A-6): the control loop needs it. Watching
/// is where a slower cadence is safe, because nothing in that state acts on a
/// sample within seconds of taking it — the consumers are the plots, the
/// record, and the detectors. The trade is honest and stated in the toggle:
/// history recorded while watching becomes coarser.
public enum WatchingSampleRate: String, CaseIterable, Sendable {
    /// Every 5 s — the rate this app has always used while watching.
    case standard
    /// Every 15 s — about a third of the sensor cost while observing.
    case batterySaver

    var interval: TimeInterval {
        switch self {
        case .standard: return 5.0
        case .batterySaver: return 15.0
        }
    }

    var label: String {
        switch self {
        case .standard:     return "Full detail (every 5 s)"
        case .batterySaver: return "Battery saver (every 15 s)"
        }
    }

    var explanation: String {
        switch self {
        case .standard:
            return "Sensors are sampled every 5 seconds while macOS controls the fans."
        case .batterySaver:
            return "Sampling slows to every 15 seconds while watching. Control still runs at "
                 + "1 Hz the moment this app takes over; history recorded while watching is coarser."
        }
    }
}
