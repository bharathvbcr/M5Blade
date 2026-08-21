import Foundation
import CoreGraphics
import HistoryKit

/// Turns a stretch of samples into the points of a sparkline.
///
/// Pulled out of the view because it is the only part that can be *wrong* — a
/// drawing routine either draws or it doesn't, but a scale can divide by zero,
/// invent a NaN, or make half a degree of drift look like a mountain range. As a
/// pure function it can be tested against those cases directly instead of being
/// squinted at in a 64-point-wide box.
enum SparklineGeometry {

    /// Newest 60 seconds only (UI.md §4).
    static let window: TimeInterval = 60

    /// The vertical scale never shrinks below this, so a sensor sitting still
    /// draws a flat line rather than amplified noise.
    static let minimumSpanC: Double = 10

    /// Nil when there is nothing meaningful to draw: no samples, one sample, or
    /// a size with no area. A caller that gets nil should draw nothing, not a
    /// degenerate line at the top of the box.
    static func path(for points: [SeriesPoint], in size: CGSize) -> [CGPoint]? {
        guard size.width > 0, size.height > 0,
              let latest = points.last?.date else { return nil }

        let visible = points.filter {
            $0.date >= latest.addingTimeInterval(-window) && $0.average.isFinite
        }
        guard visible.count >= 2, let first = visible.first?.date else { return nil }

        // Samples can share an instant — two ticks inside one second — which
        // would divide by zero here and put every point at x = NaN.
        let span = max(1, latest.timeIntervalSince(first))

        let values = visible.map(\.average)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let centre = (low + high) / 2
        let range = max(high - low, minimumSpanC)
        let bottom = centre - range / 2

        return visible.map { point in
            let x = point.date.timeIntervalSince(first) / span * size.width
            let y = size.height - (point.average - bottom) / range * size.height
            // Clamped, not trusted: a value far outside the window's own range
            // — a sensor that jumps 300° for one sample — would otherwise draw
            // outside the box and over the text beside it.
            return CGPoint(x: min(max(x, 0), size.width),
                           y: min(max(y, 0), size.height))
        }
    }
}
