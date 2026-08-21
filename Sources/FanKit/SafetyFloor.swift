import Foundation

/// The static safety floor that replaced the unsound baseline-learning scheme
/// (AUDIT A-1). Deliberately boring, not adaptive, and reviewable by a human.
///
/// Three independent sources; the highest wins. Each is sufficient on its own,
/// so a failure in any one cannot drop the floor to zero.
public struct SafetyFloor: Sendable, Codable, Equatable {

    /// Conservative temperature -> minimum percent. Never learned.
    public var staticCurve: FanCurve

    /// Floor implied by Apple's own thermal pressure signal.
    public var thermalFloors: [Int: Double]

    /// Absolute hard minimum percent whenever any sensor exceeds `hardFloorTempC`.
    public var hardFloorPercent: Double
    public var hardFloorTempC: Double

    /// Above this, the ceiling is released entirely.
    public var emergencyTempC: Double

    public init(staticCurve: FanCurve = SafetyFloor.defaultStaticCurve,
                thermalFloors: [Int: Double] = SafetyFloor.defaultThermalFloors,
                hardFloorPercent: Double = 25,
                hardFloorTempC: Double = 60,
                emergencyTempC: Double = 100) {
        self.staticCurve = staticCurve
        self.thermalFloors = thermalFloors
        self.hardFloorPercent = hardFloorPercent
        self.hardFloorTempC = hardFloorTempC
        self.emergencyTempC = emergencyTempC
    }

    public static let defaultStaticCurve = FanCurve(points: [
        CurvePoint(tempC: 50, percent: 0),
        CurvePoint(tempC: 65, percent: 20),
        CurvePoint(tempC: 75, percent: 40),
        CurvePoint(tempC: 85, percent: 60),
        CurvePoint(tempC: 95, percent: 85),
        CurvePoint(tempC: 100, percent: 100),
    ])

    public static let defaultThermalFloors: [Int: Double] = [
        ThermalPressure.nominal.rawValue: 0,
        ThermalPressure.fair.rawValue: 30,
        ThermalPressure.serious.rawValue: 60,
        ThermalPressure.critical.rawValue: 100,
    ]

    /// Minimum permitted fan percent for the given conditions.
    ///
    /// A non-finite temperature is treated as *unknown, assume hot* rather than
    /// as 0 °C. A sensor that starts reporting NaN must not be able to lower the
    /// floor — "the check could not run" and "the check ran and passed" have to
    /// produce different answers.
    public func floorPercent(tempC: Double, pressure: ThermalPressure) -> Double {
        var floor = thermalFloors[pressure.rawValue] ?? 0
        if tempC.isFinite {
            floor = max(floor, staticCurve.percent(at: tempC))
            if tempC >= hardFloorTempC { floor = max(floor, hardFloorPercent) }
        } else {
            floor = max(floor, hardFloorPercent)
        }
        return min(100, max(0, floor))
    }

    /// True when the ceiling must be released regardless of user preference.
    ///
    /// An unreadable temperature is not by itself an emergency — the caller's
    /// staleness path handles lost sensors — but it must never read as *below*
    /// the emergency threshold either, so it is excluded rather than compared.
    public func requiresEmergency(tempC: Double, pressure: ThermalPressure) -> Bool {
        if pressure == .critical { return true }
        return tempC.isFinite && tempC >= emergencyTempC
    }
}
