import Foundation

public struct CurvePoint: Sendable, Codable, Equatable {
    public var tempC: Double
    public var percent: Double

    public init(tempC: Double, percent: Double) {
        self.tempC = tempC
        self.percent = percent
    }
}

public enum SensorReduction: String, Sendable, Codable {
    case max, mean

    public func reduce(_ values: [Double]) -> Double? {
        let usable = values.filter { $0.isFinite }
        guard !usable.isEmpty else { return nil }
        switch self {
        case .max:  return usable.max()
        case .mean: return usable.reduce(0, +) / Double(usable.count)
        }
    }
}

/// The temperature a curve should be evaluated at this tick, plus what was lost
/// getting there.
///
/// A curve that names sensors and finds none of them must not be read as 0 °C —
/// that is the quietest possible failure and it stops the fan. It falls back to
/// the machine-wide maximum and says so, so the UI can tell the user their
/// mapping is broken instead of silently running a different curve than the one
/// on screen.
public struct CurveInput: Sendable, Equatable {
    /// nil only when the machine reported no usable temperature at all.
    public let celsius: Double?
    /// Named sensors that did not report. Empty for an unmapped curve.
    public let missingSensorIDs: [String]
    /// True when every named sensor was missing and `celsius` is the global max.
    public let usedGlobalFallback: Bool

    public init(celsius: Double?, missingSensorIDs: [String] = [], usedGlobalFallback: Bool = false) {
        self.celsius = celsius
        self.missingSensorIDs = missingSensorIDs
        self.usedGlobalFallback = usedGlobalFallback
    }
}

/// Piecewise-linear, monotonic non-decreasing temperature -> fan percent.
public struct FanCurve: Sendable, Codable, Equatable {
    public private(set) var points: [CurvePoint]
    public var sensorIDs: [String]
    public var reduction: SensorReduction

    public init(points: [CurvePoint],
                sensorIDs: [String] = [],
                reduction: SensorReduction = .max) {
        self.points = FanCurve.normalize(points)
        self.sensorIDs = sensorIDs
        self.reduction = reduction
    }

    /// Drops unusable points, sorts by temperature, clamps percent into range,
    /// and enforces monotonic non-decreasing percent. A curve that dips as
    /// temperature rises is always a mistake, and a point at NaN °C is a curve
    /// that evaluates to nonsense at every temperature.
    static func normalize(_ input: [CurvePoint]) -> [CurvePoint] {
        var sorted = input
            .filter { $0.tempC.isFinite && $0.percent.isFinite }
            .map { CurvePoint(tempC: $0.tempC, percent: Swift.max(0, Swift.min(100, $0.percent))) }
            .sorted { $0.tempC < $1.tempC }
        guard sorted.count > 1 else { return sorted }
        for i in 1..<sorted.count where sorted[i].percent < sorted[i - 1].percent {
            sorted[i].percent = sorted[i - 1].percent
        }
        return sorted
    }

    /// False for a curve that cannot produce a target — an empty point list.
    /// Such a curve reads as 0% at every temperature, which looks like a working
    /// silent profile and is actually a profile with no curve at all.
    public var isUsable: Bool { !points.isEmpty }

    public mutating func setPoints(_ newPoints: [CurvePoint]) {
        points = FanCurve.normalize(newPoints)
    }

    /// Which temperature drives this curve, given the sensors that reported.
    ///
    /// An empty `sensorIDs` means "the machine's hottest sensor" — the default
    /// every built-in ships with, and not a fallback. Naming sensors is the
    /// per-fan mapping from AUDIT A-3: the exhaust fan over the SSD should not
    /// be chasing the SoC package temperature.
    ///
    /// - Parameters:
    ///   - readings: sensor id -> °C for everything that reported this tick.
    ///   - globalMax: the hottest sensor on the machine, used when a mapping
    ///     resolves to nothing.
    public func input(readings: [String: Double], globalMax: Double?) -> CurveInput {
        let usableGlobalMax = (globalMax?.isFinite ?? false) ? globalMax : nil

        guard !sensorIDs.isEmpty else {
            return CurveInput(celsius: usableGlobalMax)
        }

        var values: [Double] = []
        var missing: [String] = []
        for id in sensorIDs {
            if let value = readings[id], value.isFinite { values.append(value) } else { missing.append(id) }
        }

        guard let reduced = reduction.reduce(values) else {
            // Every named sensor vanished — renamed by a macOS update, or the
            // curve was authored on another Mac.
            return CurveInput(celsius: usableGlobalMax,
                              missingSensorIDs: missing,
                              usedGlobalFallback: usableGlobalMax != nil)
        }
        return CurveInput(celsius: reduced, missingSensorIDs: missing)
    }

    /// Linear interpolation with flat extrapolation at both ends.
    public func percent(at tempC: Double) -> Double {
        guard tempC.isFinite else { return 0 }
        guard let first = points.first, let last = points.last else { return 0 }
        if tempC <= first.tempC { return first.percent }
        if tempC >= last.tempC { return last.percent }

        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if tempC <= b.tempC {
                let span = b.tempC - a.tempC
                guard span > 0 else { return b.percent }
                let t = (tempC - a.tempC) / span
                return a.percent + t * (b.percent - a.percent)
            }
        }
        return last.percent
    }

    public static let balanced = FanCurve(points: [
        CurvePoint(tempC: 45, percent: 0),
        CurvePoint(tempC: 55, percent: 20),
        CurvePoint(tempC: 65, percent: 35),
        CurvePoint(tempC: 75, percent: 55),
        CurvePoint(tempC: 85, percent: 75),
        CurvePoint(tempC: 95, percent: 95),
    ])

    public static let silent = FanCurve(points: [
        CurvePoint(tempC: 55, percent: 0),
        CurvePoint(tempC: 70, percent: 15),
        CurvePoint(tempC: 80, percent: 30),
        CurvePoint(tempC: 90, percent: 45),
        CurvePoint(tempC: 98, percent: 60),
    ])

    public static let performance = FanCurve(points: [
        CurvePoint(tempC: 35, percent: 15),
        CurvePoint(tempC: 45, percent: 35),
        CurvePoint(tempC: 55, percent: 55),
        CurvePoint(tempC: 65, percent: 75),
        CurvePoint(tempC: 75, percent: 95),
    ])

    public static let maxCooling = FanCurve(points: [
        CurvePoint(tempC: 30, percent: 60),
        CurvePoint(tempC: 50, percent: 85),
        CurvePoint(tempC: 65, percent: 100),
    ])
}
