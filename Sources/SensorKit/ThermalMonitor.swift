import Foundation
import FanKit

/// Bridges Apple's public thermal signal into FanKit's `ThermalPressure`.
/// This is the single most trustworthy input in the system, so it is deliberately
/// thin — no interpretation, no smoothing.
public final class ThermalMonitor: @unchecked Sendable {
    public private(set) var pressure: ThermalPressure = .nominal
    private var observer: NSObjectProtocol?
    private let onChange: (@Sendable (ThermalPressure) -> Void)?

    public init(onChange: (@Sendable (ThermalPressure) -> Void)? = nil) {
        self.onChange = onChange
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func refresh() {
        let mapped: ThermalPressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  mapped = .nominal
        case .fair:     mapped = .fair
        case .serious:  mapped = .serious
        case .critical: mapped = .critical
        @unknown default: mapped = .serious   // unknown means assume trouble
        }
        pressure = mapped
        onChange?(mapped)
    }
}
