import Foundation

/// The in-memory tier: a short rolling window per series, forgotten on quit.
///
/// It exists because a popover must not wait on a database — the live plots and
/// sparklines need the last few minutes instantly, at full resolution, with no
/// round trip. `HistoryStore` is the durable tier behind the History page.
///
/// Both tiers are fed from the same `[RecordedSample]` batch and are keyed the
/// same way, so a series drawn live and the same series drawn from disk are the
/// same series — there is no second definition of what a sensor is called.
public struct LiveWindow: Sendable {

    /// Oldest sample kept. At the 1 Hz controlling rate this is 15 minutes.
    public let window: TimeInterval
    /// Hard cap per series, so a pathological sample rate can't grow this
    /// without bound between trims.
    public let capacity: Int

    private var series: [String: [SeriesPoint]] = [:]

    public init(window: TimeInterval = 900, capacity: Int = 1200) {
        self.window = window
        self.capacity = capacity
    }

    public mutating func record(_ samples: [RecordedSample], at date: Date) {
        for sample in samples where sample.value.isFinite {
            var points = series[sample.sensor.key] ?? []

            // A clock corrected backwards leaves points dated in the future. Kept,
            // they draw a line that doubles back on itself; dropped, the series
            // stays monotonic and heals itself within one window. The store makes
            // the same choice by winding its rollup watermark back.
            if let newest = points.last?.date, newest > date {
                points.removeAll { $0.date > date }
            }

            points.append(SeriesPoint(date: date, value: sample.value))

            let cutoff = date.addingTimeInterval(-window)
            if let firstFresh = points.firstIndex(where: { $0.date >= cutoff }), firstFresh > 0 {
                points.removeFirst(firstFresh)
            }
            if points.count > capacity {
                points.removeFirst(points.count - capacity)
            }
            series[sample.sensor.key] = points
        }

        // Forget series whose newest point has aged out of the window, so a
        // chart does not keep a frozen line for a sensor that has gone away.
        //
        // Keyed on staleness rather than on presence in this batch: a single
        // failed read used to erase up to fifteen minutes of history for that
        // series (one skipped fan reading or an empty power sample is routine),
        // and the plot refilled only as fast as new samples arrived. A sensor
        // that stops reporting now fades out exactly when its last point leaves
        // the window — which is also what "gone away" looks like in time.
        let cutoff = date.addingTimeInterval(-window)
        series = series.filter { points in
            guard let newest = points.value.last?.date else { return false }
            // Future-dated points survive a backwards clock step until they are
            // trimmed by the normal path above, so keep them here too.
            return newest >= cutoff || newest > date
        }
    }

    public func points(for key: String) -> [SeriesPoint] { series[key] ?? [] }

    public var isEmpty: Bool { series.isEmpty }

    /// Span actually covered, for a chart's subtitle — honest about how much
    /// history exists rather than always claiming the full window.
    public func span(now: Date) -> TimeInterval {
        guard let earliest = series.values.compactMap(\.first?.date).min() else { return 0 }
        return max(0, now.timeIntervalSince(earliest))
    }

    public mutating func reset() { series.removeAll() }
}
