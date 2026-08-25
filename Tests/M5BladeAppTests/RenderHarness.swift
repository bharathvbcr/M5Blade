import AppKit
import SwiftUI
import XCTest
import FanKit
import ProfileKit
import SensorKit
import HistoryKit
@testable import M5BladeApp

/// Renders a SwiftUI view offscreen and hands back the bitmap.
///
/// This is the only way to make assertions about view code that actually *runs*
/// it. A view that compiles can still trap at runtime — an inverted
/// `ClosedRange`, a NaN in a chart scale, a `ForEach` over duplicate ids — and
/// none of that is visible until something lays it out.
///
/// `cacheDisplay` rather than a screen capture: it needs no permissions, the
/// window never has to be visible, and it works in a headless test run.
@MainActor
enum RenderHarness {

    /// Long enough for SwiftUI to lay out and for Charts to build its plot.
    private static let settleSeconds: TimeInterval = 0.35

    @discardableResult
    static func render<V: View>(_ view: V,
                                size: CGSize = CGSize(width: 900, height: 700),
                                appearance: NSAppearance.Name = .darkAqua,
                                file: StaticString = #filePath,
                                line: UInt = #line) -> NSBitmapImageRep? {
        _ = NSApplication.shared

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: appearance)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        // Far offscreen: a test run must not throw windows at whoever is watching.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        RunLoop.current.run(until: Date().addingTimeInterval(settleSeconds))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("could not create a bitmap", file: file, line: line)
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// Renders and asserts something was actually drawn.
    ///
    /// "Did not crash" is a weak assertion on its own — a view that silently
    /// renders nothing passes it. A view that drew content has more than one
    /// distinct pixel colour.
    static func assertDraws<V: View>(_ view: V,
                                     _ what: String,
                                     size: CGSize = CGSize(width: 900, height: 700),
                                     appearance: NSAppearance.Name = .darkAqua,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        guard let rep = render(view, size: size, appearance: appearance,
                               file: file, line: line) else { return }
        XCTAssertEqual(rep.size.width, size.width, "\(what): unexpected width", file: file, line: line)
        XCTAssertGreaterThan(distinctColours(in: rep), 1,
                             "\(what): rendered a blank rectangle", file: file, line: line)
    }

    /// Sampled rather than exhaustive — reading every pixel of two dozen renders
    /// costs more than it proves.
    static func distinctColours(in rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let step = max(1, Int(rep.pixelsWide) / 60)
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let packed = UInt32(colour.redComponent * 255) << 16
                    | UInt32(colour.greenComponent * 255) << 8
                    | UInt32(colour.blueComponent * 255)
                seen.insert(packed)
            }
        }
        return seen.count
    }
}

// MARK: - Fixtures

@MainActor
enum Fixture {

    static func model(directory: URL,
                      defaults: UserDefaults = InMemoryDefaults()) -> AppModel {
        AppModel(configStore: ConfigStore(url: directory.appendingPathComponent("config.json")),
                 historyURL: directory.appendingPathComponent("history.sqlite"),
                 defaults: defaults)
    }


    static func fans(_ count: Int = 2) -> [FanDescriptor] {
        (0..<count).map {
            FanDescriptor(index: $0, minRPM: 1_350, maxRPM: 4_800, modeKeyName: "F\($0)md")
        }
    }

    static func readings(_ fans: [FanDescriptor], rpm: Double = 2_140) -> [Int: FanReading] {
        Dictionary(uniqueKeysWithValues: fans.map {
            ($0.index, FanReading(index: $0.index, actualRPM: rpm, targetRPM: rpm, mode: .auto))
        })
    }

    /// Names drawn from what this Mac actually reports, repeats and all.
    static func temperatures(_ count: Int = 6) -> [TemperatureSensors.Reading] {
        let names = ["Chip zone 1", "Chip zone 2", "PMU tdie1", "PMU tdie1",
                     "gas gauge battery", "NAND CH0 temp"]
        return (0..<count).map { index in
            TemperatureSensors.Reading(name: names[index % names.count],
                                       celsius: Double(45 + (index * 7) % 50),
                                       ordinal: index / names.count)
        }
    }

    /// A closed spike, hot enough and fast enough to be one. `app` names the
    /// process that dominated it; without one, nothing was attributed.
    static func spike(id: Int64, at date: Date, app: String? = nil,
                      group: String = "SoC",
                      cpuFrom: Double = 6, cpuTo: Double = 92,
                      namesRecorded: Bool = true) -> Spike {
        Spike(id: id,
              start: date,
              peak: date.addingTimeInterval(70),
              end: date.addingTimeInterval(300),
              fromTempC: 58,
              peakTempC: 92,
              cpuAtStartPercent: cpuFrom,
              peakCPUPercent: cpuTo,
              hottestGroup: group,
              peakFanRPM: 4_200,
              peakFanDutyPercent: 88,
              profileName: "Balanced",
              recordedProcessNames: namesRecorded,
              processes: app.map { [ProcessShare(name: $0, percent: 74)] } ?? [])
    }

    /// Drives the recorder with the tick sequence a real spike produces: a flat
    /// baseline, a jump, and a settle. Public API only — the app has no test
    /// seam into the database and should not grow one.
    static func recordSpike(into recorder: HistoryRecorder,
                            endingAt end: Date,
                            app: String) async {
        func tick(_ offset: TimeInterval, temp: Double, cpu: Double,
                  processes: [ThrottleDetector.ProcessLoad] = []) async {
            let date = end.addingTimeInterval(offset - 200)
            await recorder.record(
                samples: [],
                at: date,
                throttle: .init(date: date, cpuPercent: cpu, pressure: .nominal, maxTempC: temp),
                spike: .init(date: date, maxTempC: temp, cpuPercent: cpu,
                             hottestGroup: "CPU", fanRPM: 4_000, fanDutyPercent: 90,
                             profileName: "Balanced", processes: processes))
        }
        for offset in stride(from: 0.0, through: 10.0, by: 5) { await tick(offset, temp: 58, cpu: 6) }
        await tick(15, temp: 90, cpu: 95)
        for offset in stride(from: 20.0, through: 90.0, by: 5) {
            await tick(offset, temp: 92, cpu: 95,
                       processes: [.init(name: app, cpuPercent: 380)])
        }
        for offset in stride(from: 95.0, through: 200.0, by: 5) { await tick(offset, temp: 61, cpu: 6) }
    }

    static func series(_ id: String, kind: SensorKind, count: Int,
                       from base: Date, value: (Int) -> Double) -> Series {
        Series(id: id, name: id, kind: kind,
               points: (0..<count).map { index in
                   SeriesPoint(date: base.addingTimeInterval(Double(index) * 60),
                               value: value(index))
               })
    }
}

/// Checks the checker.
///
/// Every render assertion in this target rests on "more than one colour means
/// something was drawn". If that measure were broken — if it counted a blank
/// rectangle as content — twenty passing render tests would prove nothing at
/// all. So it is tested against a view that is definitely blank and one that is
/// definitely not.
@MainActor
final class RenderHarnessSelfTest: XCTestCase {

    func testABlankViewIsRecognisedAsBlank() throws {
        let rep = try XCTUnwrap(RenderHarness.render(Color.clear,
                                                     size: CGSize(width: 200, height: 120)))
        XCTAssertEqual(RenderHarness.distinctColours(in: rep), 1)
    }

    func testAViewWithContentIsNot() throws {
        let view = VStack {
            Text("Fan 1").font(.headline)
            Rectangle().fill(Color.orange).frame(height: 20)
        }
        .frame(width: 200, height: 120)
        .background(Color.black)

        let rep = try XCTUnwrap(RenderHarness.render(view, size: CGSize(width: 200, height: 120)))
        XCTAssertGreaterThan(RenderHarness.distinctColours(in: rep), 1)
    }
}


/// Defaults that exist only for the length of a test.
///
/// `UserDefaults.standard` is shared by every process on the machine, so tests
/// that wrote a setting there raced each other: one run cleared the key in
/// `setUp` while another was between writing it and reading it back. They wrote
/// into the developer's own preferences on the way past, too.
///
/// A private `UserDefaults(suiteName:)` fixes the sharing but not the mess: a
/// suite is a plist in `~/Library/Preferences`, `cfprefsd` writes it back
/// asynchronously, and a domain removed in `tearDown` races that write — the
/// file comes back, one per run, and they accumulate in the hundreds. Overriding
/// the storage instead keeps it all in memory, which is the only cleanup that
/// cannot be forgotten or lose a race.
///
/// `object(forKey:)`, `set(_:forKey:)` and `removeObject(forKey:)` are the
/// documented primitives to override; `bool(forKey:)` is derived from the first,
/// and overridden anyway rather than relying on that.
/// An in-memory `UserDefaults` stand-alone, so tests never write into the
/// developer's own machine-wide preferences.
final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { storage[key] }
    override func set(_ value: Any?, forKey key: String) { storage[key] = value }
    override func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
    override func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }

    /// Pre-acknowledged control risk. Most suites exercise the machinery that
    /// runs *after* the user says yes; the consent gate itself has its own
    /// suite, and starting these fixtures from "already agreed" keeps that
    /// split honest.
    static func acknowledgingControlRisk() -> InMemoryDefaults {
        let defaults = InMemoryDefaults()
        defaults.set(true, forKey: AppModel.controlRiskAcknowledgedKey)
        return defaults
    }
}
