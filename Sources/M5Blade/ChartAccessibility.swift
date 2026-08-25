import Foundation
import Accessibility
import SwiftUI
import HistoryKit

/// VoiceOver's ears for this app's Swift Charts plots.
///
/// Charts render nothing VoiceOver can read on their own; a summary string
/// tells someone *that* something happened but not its shape. A descriptor
/// gives them the Chart Detail view and an audio graph: axes they can scrub,
/// series they can walk point by point, pitch that follows the temperature.
///
/// The x-axis is numeric epoch seconds because that is what the API offers —
/// there is no date axis (`AXNumericDataAxisDescriptor` and the categorical
/// one are the only two) — so the value-description provider renders the time
/// back into words for the reader.
///
/// Points are downsampled before they reach the descriptor. The audio graph
/// plays one tone per point; handing it two hours of raw seconds would turn
/// scrubbing into a ten-minute ordeal without telling the listener anything a
/// hundred-and-twenty tones would not.
struct ChartAccessibility: AXChartDescriptorRepresentable {

    struct SeriesInput {
        var name: String
        var points: [SeriesPoint]
        /// Which of the three stored aggregates to speak — `average` for live
        /// plots, or whatever the page is actually drawing.
        var value: (SeriesPoint) -> Double
    }

    var title: String
    /// One or two sentences of take-aways; spoken before any axis is read.
    var summary: String
    /// Spoken after each y-value — "degrees", "percent", "watts".
    var unit: String
    var series: [SeriesInput]
    /// Renders an x position back into words. Injected rather than built in
    /// because the History page wants absolute times and the Sensors page is
    /// happy with minutes-ago.
    var xDescription: (Date) -> String

    static let maximumPointsPerSeries = 120

    func makeChartDescriptor() -> AXChartDescriptor {
        let all = series.flatMap { input in
            input.points.map { point in (point.date, input.value(point)) }
        }
        // Empty data still needs a valid descriptor: degenerate ranges would
        // make the audio graph refuse to play rather than play silence.
        let times = all.map { $0.0.timeIntervalSince1970 }
        let values = all.map(\.1)
        let xRange = (times.min().map { $0 - 1 } ?? 0)...(times.max().map { $0 + 1 } ?? 1)
        let yLow = (values.min() ?? 0) - 0.5
        let yHigh = max((values.max() ?? 1) + 0.5, yLow + 1)

        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: xRange,
            gridlinePositions: [],
            valueDescriptionProvider: { [xDescription] seconds in
                xDescription(Date(timeIntervalSince1970: seconds))
            })

        let yAxis = AXNumericDataAxisDescriptor(
            title: title,
            range: yLow...yHigh,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                String(format: "%.1f %@", value, unit)
            })

        let descriptors = series.map { series -> AXDataSeriesDescriptor in
            let points = Self.downsample(series.points, to: Self.maximumPointsPerSeries)
                .map { point in
                    AXDataPoint(x: point.date.timeIntervalSince1970,
                                y: series.value(point))
                }
            return AXDataSeriesDescriptor(name: series.name,
                                          isContinuous: true,
                                          dataPoints: points)
        }

        return AXChartDescriptor(title: title,
                                 summary: summary,
                                 xAxis: xAxis,
                                 yAxis: yAxis,
                                 additionalAxes: [],
                                 series: descriptors)
    }

    /// Evenly spaced subset keeping the first and last point, so the shape the
    /// audio traces matches the shape drawn at the edges.
    static func downsample(_ points: [SeriesPoint], to limit: Int) -> [SeriesPoint] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            points[Int((Double(index) * step).rounded())]
        }
    }
}
