import XCTest
import SwiftUI
import FanKit
import ProfileKit
import SensorKit
import HistoryKit
@testable import M5BladeApp

/// Renders for the enhancement surfaces: the curve editor's keyboard/table
/// editing, the popover's stale-reading badge, and Settings' new sections.
///
/// Same reasoning as `ViewRenderTests`: these views trap at layout time on
/// things the compiler accepts, and running them is the only way to know.
@MainActor
final class EnhancementRenderTests: XCTestCase {

    private var directory: URL!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnhancementRenderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = Fixture.model(directory: directory)

        let fans = Fixture.fans()
        model.applyForTesting(fans: fans, readings: Fixture.readings(fans),
                              temperatures: Fixture.temperatures(), cpuPercent: 20,
                              status: .watching)
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Curve editor

    /// The editor now carries the point table below the graph; both must lay
    /// out together without clipping the graph's fixed 280 pt minimum.
    func testCurveEditorWithPointTable() {
        RenderHarness.assertDraws(
            ScrollView { CurveEditorView(model: model) },
            "curve editor with point table",
            size: CGSize(width: 760, height: 980))
    }

    /// Twelve points — the cap the drag path enforces — must all get rows.
    func testPointTableWithTheMaximumNumberOfPoints() {
        var curve = FanCurve.balanced
        var points = curve.points
        while points.count < 12 {
            let last = points.last!
            points.append(CurvePoint(tempC: last.tempC + 2,
                                     percent: max(last.percent - 4, 0)))
        }
        curve.setPoints(points)
        // Give every editable profile the fat curve so the editor actually
        // renders twelve rows.
        for profile in model.profiles where !profile.releasesToSystem {
            model.updateCurve(curve, forFan: 0, inProfile: profile.id)
        }

        RenderHarness.assertDraws(
            ScrollView { CurveEditorView(model: model) },
            "curve editor with twelve points",
            size: CGSize(width: 760, height: 1100))
    }

    // MARK: - Popover staleness

    /// A fresh reading shows no badge; a frozen one says so. The popover is
    /// rendered both ways so a regression to "always stale" or "never stale"
    /// is visible as content that differs from what was asked for.
    func testPopoverRendersWithStaleFanReadings() {
        let fans = Fixture.fans()
        model.applyForTesting(
            fans: fans,
            readings: Fixture.readings(fans),
            readingsUpdatedAt: [0: Date().addingTimeInterval(-600),
                                1: Date()])
        RenderHarness.assertDraws(PopoverView(model: model,
                                              onOpenSettings: {}, onOpenDashboard: {}),
                                  "popover with one stale fan",
                                  size: CGSize(width: 340, height: 520))
    }

    // MARK: - Settings additions

    func testGeneralTabRendersNewSections() {
        RenderHarness.assertDraws(
            ScrollView { GeneralTab(model: model) },
            "general tab with menu bar and diagnostics sections",
            size: CGSize(width: 760, height: 1200))
    }
}
