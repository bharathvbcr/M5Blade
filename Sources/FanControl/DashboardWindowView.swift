import SwiftUI
import HistoryKit

/// Everything you read, in one window: why it got hot, what every sensor says,
/// and the record over time.
///
/// These used to be two places — a Sensors tab buried in Settings and a separate
/// History window — which put the live reading of a sensor and the saved record
/// of that same sensor in different windows, and left "why did it spike?"
/// unanswered in both. Settings is now only for things you change.
///
/// Both view models are owned here rather than by the pages, so switching pages
/// never resets a range, a group selection, or a chart scrubbed to a spike.
struct DashboardWindowView: View {

    enum Page: String, CaseIterable, Identifiable {
        case insights, sensors, history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .insights: return "Insights"
            case .sensors:  return "Sensors"
            case .history:  return "History"
            }
        }

        var symbolName: String {
            switch self {
            case .insights: return "lightbulb"
            case .sensors:  return "thermometer.medium"
            case .history:  return "chart.xyaxis.line"
            }
        }
    }

    @ObservedObject var model: AppModel
    @StateObject private var history: HistoryViewModel
    @StateObject private var insights: InsightsViewModel
    @State private var page: Page

    init(model: AppModel, page: Page = .insights) {
        self.model = model
        _history = StateObject(wrappedValue: HistoryViewModel(model: model))
        _insights = StateObject(wrappedValue: InsightsViewModel(model: model))
        _page = State(initialValue: page)
    }

    /// Renders against view models already in a chosen state, so the window can
    /// be exercised without waiting for a database to produce one.
    init(model: AppModel, history: HistoryViewModel, insights: InsightsViewModel,
         page: Page = .insights) {
        self.model = model
        _history = StateObject(wrappedValue: history)
        _insights = StateObject(wrappedValue: insights)
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            content
        }
        .frame(minWidth: 840, minHeight: 620)
    }

    /// `Text`, not `Label`: a macOS segmented control renders a `Label` as its
    /// icon alone, and three unlabelled glyphs is not a navigation control.
    private var picker: some View {
        Picker("", selection: $page) {
            ForEach(Page.allCases) { page in
                Text(page.title).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel("Dashboard section")
    }

    /// A `switch` rather than three views with `.opacity`: each page's `.task`
    /// polls the database, and the two that aren't on screen must not.
    @ViewBuilder
    private var content: some View {
        switch page {
        case .insights:
            InsightsPage(model: model, viewModel: insights, onShowOnChart: showOnChart)
        case .sensors:
            SensorsPage(model: model)
        case .history:
            HistoryPage(model: model, viewModel: history)
        }
    }

    /// The reason these pages share a window: a finding on Insights can put its
    /// own moment on the chart next door instead of describing where to look.
    private func showOnChart(_ window: ClosedRange<Date>) {
        history.focus(from: window.lowerBound, to: window.upperBound)
        page = .history
    }
}
