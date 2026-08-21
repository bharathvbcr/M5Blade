import SwiftUI
import Charts

/// Axis marks shared by every temperature-over-time chart in the app.
///
/// The Sensors and History pages had the same axis decisions written
/// out twice — whole degrees, leading position, a gridline per mark. Two copies
/// of a formatting decision is how one of them ends up reading "62.4°" while the
/// other reads "62°".
///
/// Two overloads rather than one parameter because Swift Charts models automatic
/// and explicit tick values as different argument types.

/// Degrees, as whole numbers, with the chart choosing its own ticks.
@AxisContentBuilder
func celsiusAxisMarks() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisGridLine()
        AxisValueLabel { celsiusLabel(value) }
    }
}

/// Degrees at fixed ticks — for a chart whose scale is shared with a second axis
/// and so cannot let either side pick its own.
@AxisContentBuilder
func celsiusAxisMarks(values: [Double]) -> some AxisContent {
    AxisMarks(position: .leading, values: values) { value in
        AxisGridLine()
        AxisValueLabel { celsiusLabel(value) }
    }
}

@AxisContentBuilder
func timeAxisMarks(desiredCount: Int = 4) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: desiredCount)) { _ in
        AxisGridLine()
        AxisValueLabel(format: .dateTime.hour().minute())
    }
}

@ViewBuilder
private func celsiusLabel(_ value: AxisValue) -> some View {
    if let celsius = value.as(Double.self) { Text("\(Int(celsius))°") }
}
