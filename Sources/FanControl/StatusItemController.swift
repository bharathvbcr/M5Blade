import AppKit
import SwiftUI
import Combine
import FanKit

/// NSStatusItem rather than MenuBarExtra (AUDIT A-9): full control over the bar
/// item matters here because a live readout is the app's primary surface.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient

        // The popover must size itself from the SwiftUI content, not from a
        // hardcoded guess. With a fixed `contentSize`, AppKit anchors the popover
        // using that height and then draws a window of the content's *real*
        // height — the difference appears as a gap between the menu bar and the
        // popover (460 declared vs 258 actual put it 200pt too low). The content
        // height also changes at runtime as sensors and fans populate, so no
        // constant could be right for long.
        let hosting = NSHostingController(
            rootView: PopoverView(model: model,
                                  onOpenSettings: { [weak self] in self?.openSettings() },
                                  onOpenDashboard: { [weak self] in self?.openDashboard() })
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.image = NSImage(systemSymbolName: "fan", accessibilityDescription: "Fan control")
                ?? NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Fan control")
            button.imagePosition = .imageLeading
        }

        // Redraw at most once per second regardless of model churn.
        Publishers.CombineLatest3(model.$maxTempC, model.$readings, model.$status)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _, _, _ in self?.refreshTitle() }
            .store(in: &cancellables)

        refreshTitle()
    }

    /// Narrow by default. On a MacBook Pro there is no API to detect that the
    /// item has been clipped behind the notch, so width is the only defense.
    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        let temp = model.maxTempC.map { String(format: "%.0f°", $0) } ?? "--°"
        let rpm = model.readings.values.map(\.actualRPM).max().map { String(format: "%.0f", $0) } ?? "----"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ]
        button.attributedTitle = NSAttributedString(string: " \(temp) \(rpm)", attributes: attributes)

        let symbol: String
        switch model.status {
        case .emergency:                       symbol = "exclamationmark.triangle.fill"
        case .daemonUnavailable, .unverifiedOS: symbol = "fan.slash"
        case .controlling:                     symbol = "fan.fill"
        case .watching:                        symbol = "fan"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.status.label)
            ?? NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: model.status.label)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private var isDrivingFans: Bool {
        model.status == .controlling || model.status == .emergency
    }

    /// Whether the hardware/OS combination supports control at all. When it
    /// doesn't, the control items are shown disabled with the reason rather than
    /// hidden — an item that silently does nothing is worse than one greyed out.
    private var controlUnavailableReason: String? {
        if case .unverifiedOS(let why) = model.status { return why }
        return nil
    }

    private func showMenu() {
        let menu = NSMenu()
        // Explicit enablement: the readout rows must stay greyed out, and Quit
        // must stay live, regardless of responder-chain guesswork.
        menu.autoenablesItems = false

        menu.addItem(infoItem(model.status.label, primary: true))
        menu.addItem(infoItem(readoutLine()))
        if let reason = controlUnavailableReason {
            menu.addItem(infoItem("Unavailable: \(reason)"))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Profile"))
        for profile in model.profiles {
            let item = NSMenuItem(title: profile.name,
                                  action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = profile.id
            item.state = profile.id == model.activeProfileID ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // One switch, checked when macOS owns the fans, so the current mode is
        // legible without reading the label.
        let auto = NSMenuItem(title: "Automatic — macOS Controls Fans",
                              action: #selector(toggleAutoMode), keyEquivalent: "a")
        auto.target = self
        auto.state = model.autoMode ? .on : .off
        auto.isEnabled = model.autoMode ? model.canLeaveAutoMode : true
        menu.addItem(auto)

        // The panic path. Always present, always enabled, never moves.
        let stock = NSMenuItem(title: "Restore Automatic Control",
                               action: #selector(restoreStock), keyEquivalent: "r")
        stock.target = self
        stock.isEnabled = true
        menu.addItem(stock)

        menu.addItem(.separator())

        // The panel is the live readout this menu is attached to; the Dashboard
        // is where you go to read the record and find out why something
        // happened; Settings is where you change things. One item each — the
        // menu used to offer four doors into three of them.
        let panel = NSMenuItem(title: "Show Panel",
                               action: #selector(showPanel), keyEquivalent: "")
        panel.target = self
        panel.isEnabled = true
        menu.addItem(panel)

        let dashboard = NSMenuItem(title: "Dashboard…",
                                   action: #selector(showDashboard), keyEquivalent: "d")
        dashboard.target = self
        dashboard.isEnabled = true
        menu.addItem(dashboard)

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = true
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Fan Control",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// A non-interactive readout row.
    private func infoItem(_ text: String, primary: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = primary ? NSFont.menuFont(ofSize: 0)
                           : NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: primary ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func readoutLine() -> String {
        let temp = model.maxTempC.map { String(format: "%.0f°C", $0) } ?? "--°C"
        guard !model.fans.isEmpty else { return "\(temp) · no fans" }
        let fans = model.fans.map { fan -> String in
            let rpm = model.readings[fan.index]?.actualRPM ?? 0
            return String(format: "Fan %d %.0f rpm (%.0f%%)",
                          fan.index + 1, rpm, fan.dutyPercent(forRPM: rpm))
        }
        return ([temp] + fans).joined(separator: " · ")
    }

    @objc private func showPanel() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func showDashboard() {
        openDashboard()
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.selectProfile(id)
    }

    @objc private func restoreStock() {
        Task { await model.releaseToStock() }
    }

    @objc private func enableControl() {
        Task { await model.enableControl() }
    }

    @objc private func toggleAutoMode() {
        Task { await model.setAutoMode(!model.autoMode) }
    }

    /// Insights, Sensors and History. Kept rather than released, so reopening
    /// restores the page the user was on along with its scroll and selection
    /// state — a fresh window would drop them back on Insights every time.
    private func openDashboard() {
        dashboardWindow = present(dashboardWindow, title: "Fan Control Dashboard",
                                  size: NSSize(width: 940, height: 700)) {
            DashboardWindowView(model: self.model)
        }
    }

    private func openSettings() {
        settingsWindow = present(settingsWindow, title: "Fan Control Settings",
                                 size: NSSize(width: 760, height: 600)) {
            SettingsView(model: self.model)
        }
    }

    /// Shows a kept window, building it on first use. Both windows had this
    /// written out separately and had already drifted apart in style mask and
    /// activation; one of them is enough.
    private func present<Content: View>(_ existing: NSWindow?, title: String, size: NSSize,
                                        content: () -> Content) -> NSWindow {
        if let existing {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
}
