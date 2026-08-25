import Foundation
import os
import SwiftUI
import SMCKit
import FanKit
import PowerKit
import ProfileKit
import SensorKit
import HistoryKit
import DaemonProtocol

/// Whether the app is actually driving the fans or only observing.
/// Surfaced in the UI at all times — never left implicit (UI.md §1 rule 3).
enum ControlStatus: Equatable {
    case watching
    case controlling
    case emergency
    case daemonUnavailable
    case unverifiedOS(String)

    var label: String {
        switch self {
        case .watching:            return "Watching"
        case .controlling:         return "Controlling"
        case .emergency:           return "Emergency"
        case .daemonUnavailable:   return "Helper not running"
        case .unverifiedOS:        return "Unverified"
        }
    }

    var isDegraded: Bool {
        if case .controlling = self { return false }
        if case .watching = self { return false }
        return true
    }
}

/// The temperature input, as `AppModel` consumes it. `TemperatureSources`
/// conforms; the seam exists for the same reason `FanControlChannel` does —
/// the control path must be exercisable against a scripted sensor layer, not
/// only against whatever this machine's HID hub happens to report today.
protocol TemperatureReadingSource: Actor, Sendable {
    func readAll() async -> [TemperatureSensors.Reading]
    func setIncludeSMC(_ enabled: Bool) async
}

extension TemperatureSources: TemperatureReadingSource {}

@MainActor
final class AppModel: ObservableObject {    @Published private(set) var fans: [FanDescriptor] = []
    @Published private(set) var readings: [Int: FanReading] = [:]
    /// When each fan's reading was last *received*. A read that fails leaves
    /// the old value standing, which is the right thing to keep displaying and
    /// the wrong thing to keep implying: without this, a wedged SMC read shows
    /// a frozen rpm forever as if it were live. The popover marks anything
    /// past `readingStalenessLimit` as stale.
    @Published private(set) var readingsUpdatedAt: [Int: Date] = [:]
    /// Same reasoning as `ControlLoop.stalenessLimit` on the temperature side:
    /// ten seconds without a fresh sample is no longer a gap, it is missing.
    nonisolated static let readingStalenessLimit: TimeInterval = 10
    /// Same reasoning as `ControlLoop.stalenessLimit` on the temperature side:
    /// ten seconds without a fresh sample is no longer a gap, it is missing.
    nonisolated static let temperatureStalenessLimit: TimeInterval = 10
    @Published private(set) var temperatures: [TemperatureSensors.Reading] = []
    /// When the temperature set was last *received*. A read that comes back
    /// empty leaves the old array standing — right for display, wrong to keep
    /// implying: without this timestamp, a sensor layer that dies mid-run
    /// leaves every fan curve evaluating a permanently frozen temperature while
    /// the loop's own stale-data protection sits unreachable (it can only fire
    /// on samples that arrive as nil, and `maxTempC` never became nil again).
    @Published private(set) var temperaturesUpdatedAt: Date?
    @Published private(set) var maxTempC: Double?
    /// `SensorCategory` raw value of the hottest measured sensor, or "" when
    /// nothing reported. Recorded with every spike so the record can say which
    /// part of the machine got hot, not only how hot.
    @Published private(set) var hottestGroup: String = ""
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var memory: MemoryUsage?
    /// Free space on the startup volume, Finder's "available" basis. Sampled
    /// with the other host metrics and shown in the panel's system row.
    @Published private(set) var availableDiskBytes: UInt64?
    /// Live package power, when this machine's IOReport counters are alive.
    /// Surfaced beside the load readout and charted on the History page.
    @Published private(set) var cpuWattsReading: Double?
    @Published private(set) var gpuWattsReading: Double?
    @Published private(set) var thermalPressure: ThermalPressure = .nominal
    /// A throttle episode is open, as far as this launch has observed. Drives
    /// the menu bar's ambient colour change (DESIGN §3.5): notifications are
    /// reserved for sustained episodes, so the quiet signal for "it is
    /// happening right now" lives on the status item.
    @Published private(set) var isThrottling = false
    @Published private(set) var status: ControlStatus = .watching
    @Published private(set) var resolution: Resolution?

    @Published var profiles: [Profile] = []
    @Published var rules: [Rule] = []
    @Published var activeProfileID: UUID = Profile.balancedID
    @Published var manualPin: ManualPin?
    /// The profile used when no rule matches and nothing is pinned.
    @Published var defaultProfileID: UUID = Profile.balancedID
    /// Live per-process CPU, for the automation editor's app picker.
    @Published private(set) var topProcesses: [ProcessInfoSample] = []
    /// The in-memory tier: a short rolling window backing the live plots and
    /// the popover sparklines. Written from the same batch as the database, so
    /// the two can't drift apart.
    @Published private(set) var liveHistory = LiveWindow()
    /// True when macOS owns the fans. The inverse of "we are driving them", kept
    /// as explicit user intent so it survives a tick that happens to release.
    @Published private(set) var autoMode: Bool = true
    @Published private(set) var environment = EnvironmentMetrics.Snapshot()
    /// Surfaced rather than swallowed — a config that silently resets to
    /// defaults is indistinguishable from one that was never saved.
    @Published private(set) var configProblem: String?
    /// Why control is degraded right now: a refused write, a release that did
    /// not take, a curve whose sensors have vanished. Distinct from
    /// `configProblem`, which is about the file rather than the hardware.
    @Published private(set) var controlProblem: String?

    /// Other privileged fan controllers found on this machine (ISSUES I-9 /
    /// roadmap T-1). Two root writers of the same SMC keys do not coordinate;
    /// the app cannot stop them, so it refuses to stay quiet about them.
    @Published private(set) var concurrentControllers: [ThirdPartyFanController] = []
    private var lastControllerScan = Date.distantPast
    /// Detection reads a dozen plists and one sysctl walk — cheap, but not
    /// worth paying at the sampling rate.
    private static let controllerScanInterval: TimeInterval = 60

    /// Battery health and the firmware charge limit (T-3). Health reads
    /// unprivileged; charge-limit state comes from the helper because only it
    /// may touch the SMC key.
    @Published private(set) var batteryHealth: BatteryHealth?
    @Published private(set) var chargeLimit: ChargeLimitStatus?
    /// Why the last charge-limit change did not take, when one was attempted.
    /// Kept apart from `controlProblem`: a refused firmware write says nothing
    /// about fan control, and one banner must not blame the other.
    @Published private(set) var chargeLimitProblem: String?
    /// The user's explicit opt-in for charge-limit *control* (T-3b). Off by
    /// default — DESIGN §6.3 recommends against third-party limiting, and this
    /// switch is what makes enabling it an informed act rather than a silent one.
    @Published private(set) var chargeLimitControlOptedIn: Bool
    private static let chargeLimitOptInKey = "battery.chargeLimit.optIn"

    /// Consecutive ticks whose fan writes failed. One is a reconnect; a run of
    /// them means we are not in control and must stop saying we are.
    private var controlFailureStreak = 0
    /// Consecutive refused operations after which the app stops claiming
    /// control and hands the fans back. Internal so tests drive the real
    /// threshold rather than guessing at it.
    static let maxControlFailures = 3

    /// Control-state transitions, kept for the diagnostics report. The unified
    /// log answers "why did it stop driving the fans" only to someone willing
    /// to run `log stream`; this ring buffer puts the same answer on the
    /// clipboard of anyone who presses Copy Diagnostics.
    ///
    /// Only *changes* are recorded: `applyControl` restates `.controlling`
    /// every tick, and an unbounded per-second log would be both useless and
    /// unbounded by construction.
    struct StatusTransition {
        let date: Date
        let from: ControlStatus
        let to: ControlStatus
        let reason: String
    }
    private var transitions: [StatusTransition] = []
    /// Bounded like every other accumulator here. A hundred transitions cover
    /// any session worth diagnosing without growing with uptime.
    static let transitionLogLimit = 100

    /// The one writer of `status`. Every assignment goes through this, so the
    /// state on screen and the trail in the report cannot disagree about what
    /// happened or why.
    ///
    /// Losing control mid-drive also leaves here, and only here: a transition
    /// into a bad state from an actively-driving one is what deserves a
    /// notification, because with every window closed it was previously
    /// invisible — the glyph changed and nothing else said so. Deliberate
    /// handovers (Stock, quit) start from `.watching`-adjacent intent and never
    /// alert; `.unverifiedOS` is a machine that cannot drive fans at all, not a
    /// fault to chase.
    private func setStatus(_ new: ControlStatus, _ reason: String) {
        guard new != status else { return }
        let wasDriving = status == .controlling || status == .emergency
        transitions.append(StatusTransition(date: Date(), from: status, to: new,
                                            reason: reason))
        if transitions.count > Self.transitionLogLimit {
            transitions.removeFirst(transitions.count - Self.transitionLogLimit)
        }
        status = new

        guard wasDriving else { return }
        switch new {
        case .daemonUnavailable:
            Task { await alerter.controlLost(.helperLost, reason: reason) }
        case .emergency:
            Task { await alerter.controlLost(.emergencyCooling, reason: reason) }
        default:
            break
        }
    }

    var recentTransitions: [StatusTransition] { transitions }

    /// Whether throttle episodes may record which applications were responsible.
    /// Off unless the user turns it on: it is otherwise a timestamped record of
    /// what they run (DESIGN §5.4).
    ///
    /// The recorder keeps its own copy because it is an actor and this is the
    /// main thread's; `setRecordsProcessNames` is the only writer of either, so
    /// they cannot drift. Every reader observes this one.
    @Published private(set) var recordsProcessNames: Bool

    /// How much of the live readout the status item shows. The full "42° 3120"
    /// pair is the right default, but on a notched MacBook the item is the
    /// first thing clipped, and a clipped readout is worse than a chosen one —
    /// there is no API to detect the clipping (`StatusItemController`), so the
    /// escape hatch is a setting.
    @Published private(set) var statusDisplayMode: StatusDisplayMode

    /// Sampling interval while watching. The default matches the historical
    /// behaviour exactly; the slower option exists because reading every HID
    /// sensor costs ~85 ms per tick (AppModel `sample`) and macOS is driving
    /// the fans in this state anyway — the only consumer of that cadence is
    /// the record and the plots, which is why choosing it is explicit rather
    /// than automatic.
    @Published private(set) var watchingSampleRate: WatchingSampleRate

    /// Whether the SMC's own temperature keys are read alongside the HID hub.
    ///
    /// Off unless the user turns it on. It is not a display preference: it takes
    /// this Mac from 22 sensors to 292, adds ~57 ms to every sample, and widens
    /// what the history store writes. Each of those is defensible when asked for
    /// and none is acceptable as a silent consequence of an update.
    @Published private(set) var includesSMCSensors: Bool

    /// The persistent time series (DESIGN §5). An actor, so no SQLite work ever
    /// happens on the main thread; the Dashboard reads through it too, so
    /// there is only ever one connection.
    /// `nonisolated` because termination has to reach it *without* the main
    /// actor. See `releaseAndFlushForTermination`. Safe by type: it is an actor.
    nonisolated let historyRecorder: HistoryRecorder

    private let backend = SMCFanBackend()
    /// Both temperature sources behind one reader. The SMC half is off unless
    /// `includesSMCSensors` says otherwise, in which case this is byte-for-byte
    /// the HID behaviour the app has always had. A protocol rather than the
    /// concrete actor so a test can script sensor dropout — the frozen-input
    /// defect was untestable while the reader was hardwired, and untestable is
    /// where it hid.
    private let sources: any TemperatureReadingSource
    private let systemMetrics = SystemMetrics()
    private let processMetrics = ProcessMetrics()
    private let environmentMetrics = EnvironmentMetrics()
    /// Package power (DESIGN §6.5). Nil readings — no subscription, dead
    /// counters, nonsense scale — simply record nothing; they never become a
    /// zero-watt sample that would draw an idle machine over a hot one.
    private let packagePower = PackagePower()
    /// Also `nonisolated`, for the same reason: the panic path on quit must be
    /// able to talk to the helper from a thread that is not the main one.
    private nonisolated let daemon: any FanControlChannel
    private var thermalMonitor: ThermalMonitor?
    /// Sustained-throttle, thermal-pressure, and control-loss notifications
    /// (T-4). The center is touched only when an alert actually fires; until
    /// then the feature costs nothing and asks for nothing. Injectable for the
    /// same reason the daemon is — the decision to alert is consequential logic
    /// and must be testable without UserNotifications.
    let alerter: ThrottleAlerter

    /// The connection generation this app armed its fans on. A drop reported for
    /// an older generation is stale news about a connection already replaced,
    /// and acting on it would mark a healthy control session as helper-not-running.
    private var armedGeneration: Int?

    private let store: ConfigStore
    /// Where the two persisted toggles live. Injectable for the same reason the
    /// config and history stores are: a test must not write to the real one.
    private let defaults: UserDefaults
    /// Serialises every operation that talks to the helper about fan state, and
    /// lets a user action supersede a tick that is mid-flight. See `ControlGate`
    /// for the failure this exists to prevent.
    let controlGate = ControlGate()
    private var resolver = ProfileResolver(defaultProfileID: Profile.balancedID)
    private var loops: [Int: ControlLoop] = [:]
    private let safetyFloor = SafetyFloor()
    /// Clocks for every "sustained for N seconds" condition.
    private var sustain = SustainTracker()

    /// Control-state transitions, so "why did it stop driving the fans" can be
    /// answered after the fact:
    ///
    ///     log stream --predicate 'subsystem == "com.m5blade.app"' --level debug
    /// `nonisolated` so the quit path, which deliberately runs off the main
    /// actor, can log. A main-actor-isolated logger would be a hard error in
    /// Swift 6 and is a warning today.
    private nonisolated static let log = Logger(subsystem: "com.m5blade.app", category: "control")

    private var timer: DispatchSourceTimer?
    private var lastTick = Date()
    private var lastEnvironmentSample = Date.distantPast
    /// Tiered sampling — 1 Hz only while controlling (AUDIT A-6). While
    /// watching, the rate is the user's choice: the default is what this app
    /// has always done, and the slower tier trades record resolution for less
    /// than a third of the sensor cost in a state where macOS owns the fans.
    private var sampleInterval: TimeInterval {
        isControlling ? 1.0 : watchingSampleRate.interval
    }
    private var isControlling: Bool { status == .controlling || status == .emergency }

    /// All three stores are injectable so a test can point them somewhere
    /// disposable. The defaults are the real locations, so nothing at the call
    /// site changes — but without the seam, running the test suite would write
    /// into the developer's own configuration, history, and preferences.
    ///
    /// `UserDefaults.standard` is the shared one people forget: not merely
    /// process-wide but *machine*-wide, so two test processes running at once
    /// read and write each other's settings. A test that set a toggle and checked
    /// it came back failed whenever a second run cleared the key in between.
    /// - Parameter daemon: the helper channel. Injectable for the same reason the
    ///   stores are — the control-state machine is the most consequential logic in
    ///   the app and must be testable without root, hardware, or an XPC listener.
    init(configStore: ConfigStore = .default(),
         historyURL: URL = HistoryRecorder.defaultURL(),
         defaults: UserDefaults = .standard,
         daemon: any FanControlChannel = DaemonClient(),
         alerter: ThrottleAlerter? = nil,
         sources: (any TemperatureReadingSource)? = nil) {
        self.alerter = alerter ?? ThrottleAlerter()
        self.daemon = daemon
        // Read once, before anything derived from them: three separate reads of
        // a store another process can write between them is how they come to
        // disagree with each other.
        let recordsNames = defaults.bool(forKey: Self.processNamesKey)
        let includesSMC = defaults.bool(forKey: Self.smcSensorsKey)
        let chargeOptIn = defaults.bool(forKey: Self.chargeLimitOptInKey)
        self.defaults = defaults
        self.recordsProcessNames = recordsNames
        self.includesSMCSensors = includesSMC
        self.chargeLimitControlOptedIn = chargeOptIn
        // `rawValue` round-trips through the stored string; an unrecognised or
        // absent value falls back to the defaults rather than crashing.
        let displayMode = StatusDisplayMode(rawValue:
            defaults.string(forKey: Self.displayModeKey) ?? "") ?? .full
        let watchingRate = WatchingSampleRate(rawValue:
            defaults.string(forKey: Self.watchingRateKey) ?? "") ?? .standard
        self.statusDisplayMode = displayMode
        self.watchingSampleRate = watchingRate
        self.sources = sources ?? TemperatureSources(includeSMC: includesSMC)
        self.store = configStore
        self.historyRecorder = HistoryRecorder(url: historyURL,
                                               recordsProcessNames: recordsNames)
        applyConfiguration(store.loadOrDefault(fanCount: 2))
        thermalMonitor = ThermalMonitor { [weak self] pressure in
            Task { @MainActor [weak self] in self?.noteThermalPressure(pressure) }
        }
        daemon.onDisconnect = { [weak self] generation in
            Task { @MainActor [weak self] in self?.noteConnectionDropped(generation: generation) }
        }
    }

    /// Thermal pressure changed. Published for the UI, and the escalation to
    /// `.critical` is the one thing that alerts without a sustained-load gate —
    /// Apple saying so directly outranks every detector this app runs.
    private func noteThermalPressure(_ pressure: ThermalPressure) {
        thermalPressure = pressure
        Task { await alerter.observe(pressure: pressure) }
    }

    /// A dropped XPC connection, filtered for relevance.
    ///
    /// Drops are delivered asynchronously on an XPC queue, so the notification
    /// for a connection we already replaced can land *after* the replacement has
    /// been established and armed. Unconditionally setting `.daemonUnavailable`
    /// on it marked a working control session as broken one tick after it
    /// started, and the banner then blamed the helper for a connection that was
    /// fine. Only the generation we are actually driving on counts.
    private func noteConnectionDropped(generation: Int) {
        guard let armed = armedGeneration else { return }
        guard generation >= armed else {
            Self.log.debug("ignoring stale drop of connection \(generation, privacy: .public); armed on \(armed, privacy: .public)")
            return
        }
        armedGeneration = nil
        setStatus(.daemonUnavailable, "connection to the helper dropped")
        controlProblem = "The connection to the helper dropped. Fan control has stopped; macOS is driving the fans."
        Self.log.error("armed connection \(generation, privacy: .public) dropped — control lost")
        rescheduleTimerIfNeeded()
    }

    /// Probes the hardware and builds the per-fan loops.
    ///
    /// Gated like the transitions are, because on wake it runs with the sampling
    /// timer already live: re-discovering fans and rebuilding `loops` underneath a
    /// tick that is partway through driving the old set is the same interleaving
    /// hazard, just with a rarer trigger.
    func start() async {
        controlGate.supersede()
        await controlGate.exclusive { await self.performStart() }
    }

    private func performStart() async {
        guard !SystemMetrics.isTranslated else {
            setStatus(.unverifiedOS("running under Rosetta"), "process is translated")
            return
        }
        // Before any user action, so a profile pinned on battery records the real
        // power source rather than the default.
        environment = environmentMetrics.snapshot()
        do {
            try await backend.connect()
            fans = try await backend.discoverFans()
            // Re-read now that the real fan count is known, so per-fan curves
            // exist for every fan this machine actually has.
            applyConfiguration(store.loadOrDefault(fanCount: max(1, fans.count)))
            // First run: write the defaults out so the file exists and can be
            // inspected or backed up before any edit is made.
            if !FileManager.default.fileExists(atPath: store.url.path) { persist() }
            let caps = await backend.capabilities()
            if caps.modeKeySuffix == nil {
                setStatus(.unverifiedOS("no fan mode key found"), "SMC has no fan mode key")
            }
            for fan in fans {
                loops[fan.index] = ControlLoop(fan: fan,
                                               curve: activeProfile.curve(forFan: fan.index),
                                               settings: activeProfile.settings,
                                               floor: safetyFloor)
            }
        } catch {
            if fans.isEmpty {
                setStatus(.unverifiedOS("SMC unavailable"), "fan discovery failed")
            }
        }
        refreshConcurrentControllers()
        refreshBattery()
        scheduleTimer()
    }

    // MARK: - Battery & charge limit (T-3)

    /// Re-reads battery health and charge-limit state.
    ///
    /// Health comes from IORegistry directly; the charge limit from the
    /// helper. A helper failure leaves the previous state in place — a stale
    /// reading is still labelled as such by its age in the UI — while an
    /// unsupported machine gets `.unsupported` so the UI can explain rather
    /// than show an empty control.
    func refreshBattery() {
        batteryHealth = BatteryReader.read()

        let previous = chargeLimit
        Task { [weak self] in
            guard let self else { return }
            switch await self.daemon.chargeLimitStatus() {
            case .success(let status):
                if status != self.chargeLimit { self.chargeLimit = status }
            case .failure:
                // Keep whatever we last knew. Overwriting with nil would make
                // every helper hiccup look like "this Mac has no battery".
                if self.chargeLimit == nil { self.chargeLimit = previous }
            }
        }
    }

    /// Opts into (or out of) charge-limit control. Opting out never writes
    /// anything: it only removes the controls, leaving the firmware exactly
    /// where it was.
    func setChargeLimitControlOptedIn(_ optedIn: Bool) {
        chargeLimitControlOptedIn = optedIn
        defaults.set(optedIn, forKey: Self.chargeLimitOptInKey)
    }

    /// Requests a firmware charge-limit change through the helper, then
    /// re-reads the state so what's displayed is what took effect — not what
    /// was asked for.
    func setChargeLimit(percent: Int) async {
        guard [80, 100].contains(percent) else { return }
        switch await daemon.setChargeLimit(percent: percent) {
        case .success:
            chargeLimitProblem = nil
            Self.log.notice("charge limit set to \(percent, privacy: .public)")
        case .failure(let failure):
            Self.log.error("charge limit change refused: \(failure.message, privacy: .public)")
            chargeLimitProblem = failure.message
        }
        refreshBattery()
    }

    /// Re-scans for third-party fan controllers when the last scan has aged out.
    ///
    /// Called from every tick rather than on its own timer: a second timer is a
    /// second thing to keep alive across sleep/wake, and a tick already proves
    /// this process is awake. The scan itself is off-main-thread work kept short
    /// — a directory read plus one sysctl walk — and runs synchronously at the
    /// 60 s cadence, which is far below anything the user can perceive.
    private func maybeRefreshConcurrentControllers(now: Date) {
        guard now.timeIntervalSince(lastControllerScan) >= Self.controllerScanInterval else { return }
        refreshConcurrentControllers(at: now)
    }

    private func refreshConcurrentControllers(at now: Date = Date()) {
        lastControllerScan = now
        let detected = ConcurrentControllerDetector.scanNow()
        // Only publish on change: a `@Published` write per scan would wake
        // every SwiftUI view twice a minute for no visible reason.
        if detected != concurrentControllers { concurrentControllers = detected }
        if let running = detected.first(where: { $0.runningAsRoot }) {
            Self.log.notice("third-party fan controller \(running.identifier, privacy: .public) is running as root")
        } else if let installed = detected.first {
            Self.log.notice("third-party fan controller \(installed.identifier, privacy: .public) is installed (not running)")
        }
    }

    /// Whether another fan controller is installed or running. Drives the
    /// popover banner; the General tab lists them individually.
    var concurrentControllerWarning: String? {
        guard !concurrentControllers.isEmpty else { return nil }
        let names = concurrentControllers.map(\.productName).sorted()
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ")
            + " and " + names.last!
        if concurrentControllers.contains(where: \.runningAsRoot) {
            return "\(list) is running as root and writes the same fan keys this app writes. "
                + "The two will fight over the fans; quit or uninstall it to use fan control here."
        }
        return "\(list)'s privileged helper is installed and will start with macOS, writing "
            + "the same fan keys this app writes. Quit or uninstall it to avoid two controllers fighting."
    }

    /// The profile currently driving the fans.
    ///
    /// The fallback chain matters more than it looks. It used to end at
    /// `profiles.first`, which is *Silent* in a factory config and *Stock* in
    /// several plausible hand-edited ones — so a resolver returning an id that
    /// no longer existed during an emergency could quietly hand the fans back to
    /// macOS or cap them at 60%. Fall back to Max cooling, then Balanced: the
    /// only safe direction to be wrong in is "too much airflow".
    var activeProfile: Profile {
        if let exact = profiles.first(where: { $0.id == activeProfileID }) { return exact }
        if let maxCooling = profiles.first(where: { $0.id == Profile.maxCoolingID }) { return maxCooling }
        if let balanced = profiles.first(where: { $0.id == Profile.balancedID }) { return balanced }
        return Profile.builtIns(fanCount: max(1, fans.count))
            .first { $0.id == Profile.maxCoolingID } ?? .init(name: "Balanced")
    }

    // MARK: - Sampling

    /// Re-arms the timer only when the tier actually changed.
    ///
    /// Tiered sampling (AUDIT A-6) is 1 Hz while controlling and 0.2 Hz while
    /// watching, but `status` also changes *inside* a tick — a release, a failed
    /// write, an emergency — and nothing re-armed the timer on those paths. The
    /// app went on sampling every sensor at 1 Hz after handing the fans back,
    /// which is the exact cost the tiering exists to avoid.
    private func rescheduleTimerIfNeeded() {
        guard scheduledInterval != sampleInterval else { return }
        scheduleTimer()
    }

    private var scheduledInterval: TimeInterval?

    private func scheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        let interval = sampleInterval
        scheduledInterval = interval
        t.schedule(deadline: .now() + interval,
                   repeating: interval,
                   leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        t.resume()
        timer = t
    }

    /// Whether a fan's displayed reading has aged out. Pure so the views and
    /// the tests ask the same question the same way.
    func readingIsStale(_ fan: Int, now: Date = Date()) -> Bool {
        guard let updated = readingsUpdatedAt[fan] else { return true }
        return now.timeIntervalSince(updated) >= Self.readingStalenessLimit
    }

    /// Whether the temperature set is fresh enough for the control path to
    /// trust. Pure for the same reason `readingIsStale` is: views, tests, and
    /// the tick must ask one question one way.
    static func temperatureInputIsFresh(updatedAt: Date?, isNow now: Date) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) < temperatureStalenessLimit
    }

    /// One sampling tick, or nothing if a fan-control operation holds the gate.
    ///
    /// Skipping rather than queueing. A tick is a *sample*: one taken after
    /// waiting behind a 15-second arm describes a machine that has since moved
    /// on, and running the backlog afterwards would difference the CPU counters
    /// over windows that never elapsed and stamp several samples into the history
    /// database at almost the same instant.
    private func tick() async {
        _ = await controlGate.tryExclusive { await self.sample() }
    }

    private func sample() async {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        // Reading all 52 HID sensors costs ~85ms — measured, and by far the most
        // expensive thing in a tick; the SMC's 285 keys add ~57ms on top when
        // that source is on. Doing either on the main actor blocked the UI for
        // that long on every sample, so it runs off it. `TemperatureSources` is
        // an actor, so awaiting it already hops off the main actor — no detached
        // task is needed to get the work off this thread.
        let readTemps = await sources.readAll()
        // Publish on change: an identical 292-element array reassigned every
        // second wakes every SwiftUI view watching this model for no visible
        // difference. Same rule `concurrentControllers` already follows.
        if readTemps != temperatures && (!readTemps.isEmpty || temperatures.isEmpty) {
            temperatures = readTemps
        }
        // Only a non-empty read proves the sensor layer is alive. An empty one
        // leaves the old array displayed but *timestamps* it as aging — which
        // is what lets `applyControl` stop trusting it once the staleness
        // limit passes, instead of driving fans from a frozen input forever.
        if !readTemps.isEmpty { temperaturesUpdatedAt = now }
        // Only sensors whose subsystem is established may set this — the number
        // every fan curve reads. That excludes calibration references, which is
        // the rule this had before (`PMU tcal` reports a constant 51.8 °C that
        // sits *above* every real sensor at idle, pinning the input to something
        // that never moved), and now also excludes SMC keys nobody can attribute,
        // several of which are constants or not temperatures at all. With the SMC
        // source off the set is unchanged.
        //
        // Computed once per tick: history records exactly this set too, and
        // recomputing it there doubled the filter for nothing.
        let attributed = TemperatureSources.attributed(temperatures)
        let hottest = attributed
            .max { $0.celsius < $1.celsius }
        if hottest?.celsius != maxTempC {
            maxTempC = hottest?.celsius ?? maxTempC
        }
        // Which part of the machine is hottest, not just how hot. Without it a
        // spike record cannot tell "the graphics cores got hot" from "the SSD
        // did", and those have completely different answers.
        let hottestName = hottest.map { SensorCategory.classify($0.name).rawValue } ?? hottestGroup
        if hottestName != hottestGroup { hottestGroup = hottestName }
        // Hold the previous value rather than falling to zero. `cpuUsage` returns
        // nil when it has no previous sample to difference against — the first
        // tick, and any tick whose window was too short to accumulate a scheduler
        // tick — and reporting that as 0% is not "we do not know", it is a claim
        // that the machine is idle. It is also the reading a fan curve would act
        // on if one were ever mapped to load.
        if let usage = systemMetrics.cpuUsage(), usage.total != cpuPercent { cpuPercent = usage.total }
        if let usage = systemMetrics.memoryUsage(), usage != memory { memory = usage }
        // Same publish-on-change rule as the two above it.
        if let bytes = systemMetrics.availableDiskSpace(), bytes != availableDiskBytes {
            availableDiskBytes = bytes
        }
        noteTemperatureForAttribution(maxTempC, at: now)

        for fan in fans {
            if let r = try? await backend.readFan(fan.index) {
                if readings[fan.index] != r { readings[fan.index] = r }
                // Only success refreshes this. A failed read leaves the old
                // value *and* the old timestamp, which is what makes it
                // visibly stale rather than quietly frozen.
                readingsUpdatedAt[fan.index] = now
            }
        }

        let state = buildSystemState(now: now)
        maybeRefreshConcurrentControllers(now: now)
        let decision = resolver.resolve(state: state, rules: rules, pin: manualPin,
                                        floor: safetyFloor, now: now)
        if decision != resolution { resolution = decision }
        if decision.profileID != activeProfileID { activeProfileID = decision.profileID }

        // Before the status check below: history records what the machine is
        // doing whether or not this app is driving the fans. That is the whole
        // point of building it first — the first fan write becomes a measurable
        // experiment rather than a guess (DESIGN §8).
        await recordHistory(now: now, attributed: attributed)

        guard status == .controlling || status == .emergency else {
            rescheduleTimerIfNeeded()
            return
        }
        await applyControl(dt: dt, now: now, releaseCeiling: decision.releaseCeiling,
                           epoch: controlGate.epoch)
        rescheduleTimerIfNeeded()
    }

    /// - Parameter epoch: the intent this tick is acting on. Re-checked after
    ///   every suspension point: a user action taken while this was mid-round-trip
    ///   has already decided what the fans should be doing, and a superseded tick
    ///   writing one more target — or worse, re-arming manual mode on the strength
    ///   of that target being refused — is the whole bug.
    private func applyControl(dt: TimeInterval, now: Date, releaseCeiling: Bool,
                              epoch: Int) async {
        let profile = activeProfile

        if profile.releasesToSystem {
            await releaseAndReport(reason: "profile “\(profile.name)” hands control back to macOS")
            return
        }

        // The safety input has an expiry. A sensor layer that stopped reporting
        // must not keep feeding its last value to the loops: past the limit the
        // temperature is treated as missing, which is exactly what
        // `ControlLoop.step`'s stale-data path exists for — hold at the
        // unknown-temperature floor briefly, then release to system mode. This
        // used to be unreachable after the first successful read, because a
        // failed read left `maxTempC` standing as a finite number forever.
        let temperatureInputIsStale = !Self.temperatureInputIsFresh(
            updatedAt: temperaturesUpdatedAt, isNow: now)

        // `.nan` rather than 0 when no sensor reported. The daemon's clamp reads
        // this to decide whether its hard floor applies, and "we have no idea how
        // hot this machine is" must not arrive there looking like 0 °C — that is
        // the reading that switches the floor *off*.
        let beat = await daemon.heartbeat(maxTempC: (temperatureInputIsStale ? nil : maxTempC) ?? .nan)
        guard controlGate.isCurrent(epoch) else { return abandon(epoch) }
        if case .failure(let failure) = beat {
            // The helper is unreachable, not merely unhappy. Re-arming manual
            // mode would be several more blocking round trips per tick against
            // something that is not answering, on the main actor.
            await noteControlFailure(failure.message, reArm: false, epoch: epoch)
            return
        }

        // Curve inputs are per fan: each curve reads the sensors it is mapped to
        // (AUDIT A-3). The safety floor keeps reading the machine-wide maximum —
        // a fan mapped only to the SSD must still respond to a hot SoC.
        let sensorValues = temperatureInputIsStale ? [:] : sensorReadingsByID()
        let staleFloorInput: Double? = temperatureInputIsStale ? nil : maxTempC
        var missingSensors: [String] = []
        var lostSensorIDs = Set<String>()
        var anyEmergency = false

        for fan in fans {
            guard var loop = loops[fan.index] else { continue }
            let curve = profile.curve(forFan: fan.index)
            loop.curve = curve
            loop.settings = profile.settings
            if releaseCeiling { loop.settings.ceilingPercent = 100 }

            let input = curve.input(readings: sensorValues, globalMax: staleFloorInput)
            if input.usedGlobalFallback {
                missingSensors.append("fan \(fan.index + 1)")
                lostSensorIDs.formUnion(input.missingSensorIDs)
            }

            let decision = loop.step(curveTempC: input.celsius,
                                     floorTempC: staleFloorInput,
                                     pressure: thermalPressure,
                                     now: now, dt: dt)
            loops[fan.index] = loop

            if decision.releaseToSystem {
                await releaseAndReport(reason: decision.reason)
                return
            }
            anyEmergency = anyEmergency || decision.isEmergency

            let write = await daemon.setTarget(fan: fan.index, rpm: decision.targetRPM)
            guard controlGate.isCurrent(epoch) else { return abandon(epoch) }
            if case .failure(let failure) = write {
                // The helper is alive (it answered the heartbeat) but refused the
                // write. Overwhelmingly the cause is that its watchdog dropped us
                // out of manual mode while this app was stalled or asleep, so
                // re-arming is the documented way back. Its own reason is carried
                // through rather than replaced: "fan 0 is not under manual
                // control" tells the user which of those it was.
                await noteControlFailure("fan \(fan.index + 1) — \(failure.message)",
                                         reArm: failure.helperIsUnreachable == false,
                                         epoch: epoch)
                return
            }
        }

        controlFailureStreak = 0
        setStatus(anyEmergency ? .emergency : .controlling,
                  anyEmergency ? "critical temperature — emergency cooling" : "driving fans from “\(profile.name)”")

        if !missingSensors.isEmpty {
            // Name the sensors, not just the fans. "Fan 2 is using a fallback" is
            // a symptom; "PMU tdie7#0 is not reporting" is the thing to go and
            // remove from the curve.
            let names = lostSensorIDs.sorted().joined(separator: ", ")
            controlProblem = "The curve for \(missingSensors.joined(separator: ", ")) names sensors that are not reporting (\(names)); using the hottest sensor instead."
        } else {
            controlProblem = powerModeContradiction(profile)
        }
    }

    /// DESIGN §5: read macOS power modes and reflect them; never write them.
    ///
    /// If the user has told macOS to keep the machine quiet and cool and then
    /// selects a profile that runs the fans hard, both are happening at once and
    /// neither is wrong — but the combination is worth saying out loud rather
    /// than leaving them to wonder why Performance feels slow.
    private func powerModeContradiction(_ profile: Profile) -> String? {
        guard environment.lowPowerMode else { return nil }
        guard profile.settings.ceilingPercent > 95 || profile.id == Profile.performanceID
                || profile.id == Profile.maxCoolingID else { return nil }
        return "macOS Low Power Mode is on while “\(profile.name)” is active. The fans follow this profile, but macOS is still capping performance."
    }

    /// Hand the fans back and say so. Used for Stock, for stale sensors, and as
    /// the endpoint of every failure path — one place, so "we stopped driving"
    /// is always accompanied by a reason the user can read.
    private func releaseAndReport(reason: String) async {
        Self.log.notice("releasing fans: \(reason, privacy: .public)")
        switch await daemon.releaseAll() {
        case .success:
            setStatus(.watching, reason)
            controlProblem = nil
        case .failure(let failure):
            // A helper that never answered has not put the fans anywhere. Saying
            // "Watching" would claim macOS is driving them, which is exactly the
            // thing that could not be confirmed.
            setStatus(failure.helperIsUnreachable ? .daemonUnavailable : .watching,
                      "\(reason) — handover unconfirmed")
            controlProblem = "Stopped driving the fans (\(reason)), but the handover to macOS was not confirmed: \(failure.message.trimmedSentence)."
        }
        rescheduleTimerIfNeeded()
    }

    /// Drop a tick whose intent has been overtaken.
    ///
    /// Deliberately silent in the UI: nothing went wrong. The user changed their
    /// mind mid-round-trip, the transition they asked for owns the fans now, and
    /// a banner here would report their own click back to them as a fault — which
    /// is exactly what the old code did.
    private func abandon(_ epoch: Int) {
        Self.log.debug("tick superseded (epoch \(epoch, privacy: .public) → \(self.controlGate.epoch, privacy: .public)) — abandoning its writes")
    }

    /// A failed write means we are not controlling, whatever the last tick said.
    ///
    /// One or two failures are recoverable — XPC reconnects, and the daemon's
    /// watchdog legitimately drops manual control after a stall or a sleep. A run
    /// of them means the helper is gone, so stop claiming otherwise and hand back.
    ///
    /// - Parameter reArm: whether to retake manual mode before the next tick.
    ///   Only worth doing when the helper is known to be answering; against a
    ///   dead helper it is one blocking round trip per fan per tick, on the main
    ///   actor, for nothing.
    private func noteControlFailure(_ reason: String, reArm: Bool, epoch: Int) async {
        // Checked again here, and not only at the call sites, because this is the
        // one path that can *take* the fans back. A re-arm issued on behalf of a
        // superseded tick is how "hand the fans to macOS" turned into "the fans
        // are still manual and nothing is driving them".
        guard controlGate.isCurrent(epoch) else { return abandon(epoch) }
        controlFailureStreak += 1
        controlProblem = "Fan control is failing: \(reason)."
        Self.log.error("control failure \(self.controlFailureStreak, privacy: .public)/\(Self.maxControlFailures, privacy: .public): \(reason, privacy: .public)")
        guard controlFailureStreak < Self.maxControlFailures else {
            controlFailureStreak = 0
            var releaseConfirmed = false
            var releaseUnreachable = false
            if case .failure(let failure) = await daemon.releaseAll() {
                releaseUnreachable = failure.helperIsUnreachable
                Self.log.error("giving up on control, and the release was not confirmed: \(failure.message, privacy: .public)")
            } else {
                releaseConfirmed = true
            }
            for key in Array(loops.keys) { loops[key]?.reset() }
            autoMode = true
            // The release result decides the story. A *confirmed* handover
            // proves the helper answered — calling that "helper not running"
            // sent users to the reinstall sheet for a live daemon, while the
            // real message ("control kept failing, so the fans were handed
            // back") is actionable in a different way.
            setStatus(releaseConfirmed ? .watching
                          : (releaseUnreachable ? .daemonUnavailable : .watching),
                      "control failed \(Self.maxControlFailures) times in a row — "
                          + (releaseConfirmed ? "fans handed back to macOS"
                                              : "handover unconfirmed"))
            controlProblem = releaseConfirmed
                ? nil
                : "Fan control kept failing, and handing the fans back could not be confirmed."
            rescheduleTimerIfNeeded()
            return
        }
        guard reArm else { return }
        for fan in fans {
            guard controlGate.isCurrent(epoch) else { return abandon(epoch) }
            _ = await daemon.setManual(fan: fan.index, enabled: true)
        }
    }

    /// Sensor id -> °C for this tick, the keying `FanCurve.sensorIDs` uses.
    private func sensorReadingsByID() -> [String: Double] {
        var map: [String: Double] = [:]
        map.reserveCapacity(temperatures.count)
        // References are left out for the same reason they are left out of
        // `maxTempC`: a constant cannot be a control input. A curve pinned to
        // one resolves to nothing and reports it as a missing sensor, which is
        // visible, rather than holding the fan at a fixed percent forever.
        for reading in temperatures where reading.celsius.isFinite && !reading.isReference {
            map[reading.id] = reading.celsius
        }
        return map
    }

    // MARK: - System state

    /// Assembles the full state the rule engine needs.
    ///
    /// Previously this filled in four of twelve fields and let the rest default,
    /// which left seven of the nine `Condition` cases permanently unsatisfiable —
    /// the automation layer could be authored but could never fire.
    private func buildSystemState(now: Date) -> SystemState {
        // Power, displays, and the frontmost app move on human timescales. Reading
        // IOKit power sources at the 1 Hz control rate is pure overhead.
        if now.timeIntervalSince(lastEnvironmentSample) >= Self.environmentInterval {
            environment = environmentMetrics.snapshot()
            lastEnvironmentSample = now
        }
        let env = environment

        // Walking every pid costs real CPU — proc_pidinfo plus proc_name across
        // ~4000 pids. Only pay it when something actually consumes the result:
        // an enabled per-app rule, or the automation editor's picker being open.
        let samples: [ProcessInfoSample]
        if needsProcessSampling {
            samples = processMetrics.sample()
            topProcesses = samples
        } else {
            samples = []
            if !topProcesses.isEmpty { topProcesses = [] }
        }

        // Sustain clocks. A key drops out of the active set the moment it falls
        // below its threshold, which resets that clock — "continuously", not
        // "cumulatively".
        var active = Set<String>()
        if cpuPercent >= SystemState.loadActivityThresholdPercent { active.insert(Self.loadKey) }
        for sample in samples where sample.cpuPercent >= ProcessSnapshot.activityThresholdPercent {
            active.insert(Self.processKey(sample.name))
        }
        sustain.update(activeKeys: active, now: now)

        let processes = samples.map { sample in
            ProcessSnapshot(pid: sample.pid,
                            executableName: sample.name,
                            bundleID: nil,
                            cpuPercent: sample.cpuPercent,
                            memoryBytes: sample.memoryBytes,
                            activeFor: sustain.duration(Self.processKey(sample.name), now: now))
        }

        return SystemState(timestamp: now,
                           maxTempC: maxTempC,
                           thermalPressure: thermalPressure,
                           cpuPercent: cpuPercent,
                           loadSustainedFor: sustain.duration(Self.loadKey, now: now),
                           powerSource: env.onACPower ? .ac : .battery,
                           batteryPercent: env.batteryPercent,
                           displaysAsleep: env.displaysAsleep,
                           externalDisplayCount: env.externalDisplayCount,
                           macOSPowerMode: env.lowPowerMode ? .low : .automatic,
                           foregroundBundleID: env.frontmostBundleID,
                           processes: processes)
    }

    private static let loadKey = "@load"
    private static func processKey(_ name: String) -> String { "proc:\(name)" }

    /// How often the non-thermal environment is re-read.
    private static let environmentInterval: TimeInterval = 5

    /// Set while the automation editor is visible so its process picker is live.
    /// Balanced rather than boolean so overlapping views can't switch it off for
    /// each other.
    private var processObservers = 0

    func beginObservingProcesses() { processObservers += 1 }
    func endObservingProcesses() { processObservers = max(0, processObservers - 1) }

    private var needsProcessSampling: Bool {
        if processObservers > 0 { return true }
        // Episode attribution is a consumer too — but only above the detector's
        // own demand gate, since no episode can be declared below it and the
        // names would be collected for nothing.
        if recordsProcessNames && cpuPercent >= Self.attributionGate { return true }
        // Spike attribution has a lower bar than throttling does, because the
        // event it explains does. Walking every pid is expensive, so it is armed
        // by the same signal a spike is made of — the temperature climbing —
        // rather than paid for continuously.
        if recordsProcessNames && isTemperatureClimbing { return true }
        return rules.contains { rule in
            rule.enabled && rule.conditions.contains { condition in
                if case .processActive = condition { return true }
                return false
            }
        }
    }

    // MARK: - Spike attribution gate

    /// Recent maximum temperatures, only as far back as the arming window needs.
    /// Bounded by time *and* by count, so a pathological sample rate cannot grow
    /// it between trims.
    private var recentTemperatures: [(date: Date, celsius: Double)] = []

    private func noteTemperatureForAttribution(_ celsius: Double?, at now: Date) {
        // A clock corrected backwards would otherwise leave entries in the
        // future, and every rise measured against them would read as a fall.
        if let newest = recentTemperatures.last?.date, newest > now { recentTemperatures.removeAll() }
        // A tick with no reading still ages the window. Returning early instead
        // left readings from before a sensor dropout sitting in it indefinitely,
        // so the arming decision could be made against a baseline older than the
        // window it is supposed to cover.
        if let celsius, PlausibleTemperature.admits(celsius) {
            recentTemperatures.append((date: now, celsius: celsius))
        }
        let cutoff = now.addingTimeInterval(-SpikeDetector.Attribution.armWindow)
        if let firstFresh = recentTemperatures.firstIndex(where: { $0.date >= cutoff }), firstFresh > 0 {
            recentTemperatures.removeFirst(firstFresh)
        }
        if recentTemperatures.count > 240 {
            recentTemperatures.removeFirst(recentTemperatures.count - 240)
        }
    }

    /// Whether a spike may be forming. Deliberately more sensitive than the
    /// detector's declaration threshold: this decides only whether application
    /// names are *collected*, never whether a spike happened. The numbers belong
    /// to `SpikeDetector`, so the two cannot drift apart.
    private var isTemperatureClimbing: Bool {
        if cpuPercent >= SpikeDetector.Attribution.armCPUPercent { return true }
        guard let current = recentTemperatures.last?.celsius,
              let coolest = recentTemperatures.map(\.celsius).min() else { return false }
        return current - coolest >= SpikeDetector.Attribution.armRiseC
    }

    /// A manual pin records the power source it was set under, and clears when
    /// that changes. It must therefore record the *real* one — pinning `.ac`
    /// while on battery makes the pin invalid the instant it is created.
    private var currentPowerSource: PowerSource {
        environment.onACPower ? .ac : .battery
    }

    // MARK: - Configuration

    private func applyConfiguration(_ loaded: (configuration: Configuration, problem: String?)) {
        profiles = loaded.configuration.profiles
        rules = loaded.configuration.rules
        defaultProfileID = loaded.configuration.defaultProfileID
        configProblem = loaded.problem
        resolver.defaultProfileID = loaded.configuration.defaultProfileID
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = loaded.configuration.defaultProfileID
        }
    }

    var currentConfiguration: Configuration {
        Configuration(profiles: profiles, rules: rules, defaultProfileID: defaultProfileID)
    }

    /// Persist and re-arm. Called after every edit — there is no separate save
    /// step for the user to forget.
    func persist() {
        resolver.defaultProfileID = defaultProfileID
        persistNeedsFlush = false
        do {
            try store.save(currentConfiguration)
            configProblem = nil
        } catch {
            configProblem = error.localizedDescription
        }
    }

    /// Coalesces edit-driven saves.
    ///
    /// Slider drags and text fields used to call `persist()` on every tick and
    /// every keystroke: dozens of full save cycles (backup rotation, copy,
    /// atomic write) per gesture, and the "last good versions" backup set
    /// reduced to intermediate states of a single drag — the pre-edit config
    /// gone exactly when an editor mistake makes backups matter. Edits now
    /// land here; important transitions (import, load, first run) keep calling
    /// `persist()` directly because their result must be durable immediately.
    func persistCoalesced() {
        persistNeedsFlush = true
        persistTask?.cancel()
        let interval = Self.persistDebounceNanoseconds
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Flushes any coalesced save synchronously — quit must not drop the last
    /// keystrokes' worth of edits waiting out the debounce.
    func flushPendingPersist() {
        guard persistNeedsFlush else { return }
        persistTask?.cancel()
        persistTask = nil
        persist()
    }

    nonisolated static let persistDebounceNanoseconds: UInt64 = 400_000_000
    private var persistTask: Task<Void, Never>?
    private var persistNeedsFlush = false

    var configFileURL: URL { store.url }

    // MARK: - Configuration import / export

    /// What an import file contains, decoded far enough for the confirmation
    /// dialog to say what will change — without applying anything.
    struct ImportSummary: Equatable {
        let profiles: Int
        let rules: Int
        let isValid: Bool
        /// The reconcile messages the import would carry, shown before the user
        /// agrees rather than discovered after.
        let notices: [String]
    }

    func importSummary(_ data: Data) -> ImportSummary? {
        guard var imported = try? ConfigStore.decode(data) else { return nil }
        let report = imported.reconcile(fanCount: max(2, fans.count))
        return ImportSummary(profiles: imported.profiles.count,
                             rules: imported.rules.count,
                             isValid: true,
                             notices: report.messages)
    }

    /// The working configuration as it would be written to disk. Nil when
    /// encoding fails — an empty `Data` would be written out as a "successful"
    /// zero-byte export, which is the one outcome worse than an error message.
    func configurationExportData() -> Data? {
        try? ConfigStore.encode(currentConfiguration)
    }

    /// Replaces the working configuration with the imported document. The file
    /// is reconciled against *this* machine's fan count on the way in, so a
    /// config exported from two fans lands sanely on four — missing built-ins
    /// restored, rules pointing at vanished profiles removed, and every
    /// correction reported back rather than swallowed.
    ///
    /// Returns the reconciliation text, or nil when the import applied clean.
    @discardableResult
    func importConfiguration(_ data: Data) -> String? {
        do {
            var imported = try ConfigStore.decode(data)
            // Supersede any in-flight control work first: swapping the profile
            // table underneath a tick that is mid-apply is the I-3 race again,
            // wearing an import button.
            controlGate.supersede()
            if let pin = manualPin, !imported.profiles.contains(where: { $0.id == pin.profileID }) {
                manualPin = nil
            }
            let report = imported.reconcile(fanCount: max(2, fans.count))
            applyConfiguration((imported, nil))
            persist()
            return report.corrections.isEmpty ? nil : report.corrections.joined(separator: "\n")
        } catch {
            Self.log.error("configuration import failed: \(error.localizedDescription, privacy: .public)")
            return "Could not read the file as a Fan Control configuration: \(error.localizedDescription)"
        }
    }

    // MARK: - Diagnostics

    /// The text "Copy Diagnostics" puts on the clipboard. Assembled entirely
    /// from published state, so what it reports is exactly what the UI shows —
    /// a report that read private state could contradict the screen.
    func makeDiagnosticsReport() -> String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                       as? String) ?? "(development build)"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return DiagnosticsReport.build(.init(
            appVersion: version,
            osVersion: os,
            hardwareModel: DiagnosticsReport.hardwareModel(),
            isTranslated: SystemMetrics.isTranslated,
            status: status,
            autoMode: autoMode,
            activeProfileName: activeProfile.name,
            resolutionReason: resolution?.source.displayReason ?? "Default",
            fans: fans,
            readings: readings,
            readingsUpdatedAt: readingsUpdatedAt,
            maxTempC: maxTempC,
            hottestGroup: hottestGroup,
            cpuPercent: cpuPercent,
            packagePowerSummary: packagePower.diagnosticSummary(),
            thermalPressure: thermalPressure,
            isThrottling: isThrottling,
            concurrentControllers: concurrentControllers,
            configProblem: configProblem,
            controlProblem: controlProblem,
            chargeLimitProblem: chargeLimitProblem,
            recordsProcessNames: recordsProcessNames,
            includesSMCSensors: includesSMCSensors,
            watchingSampleRate: watchingSampleRate,
            configFileURL: store.url,
            transitions: transitions.map { ($0.date, $0.from, $0.to, $0.reason) },
            now: Date()))
    }

    // MARK: - Consent to leave auto mode

    /// What asked to take over the fans, so an acknowledgement can resume
    /// exactly what was deferred — a profile click, a toggle, or a menu command.
    enum ControlConsentIntent: Equatable {
        case enableControl
        case turnAutoOff
        case selectProfile(UUID)
    }

    /// Non-nil while the first-ever handover is waiting for an explicit yes.
    ///
    /// Selecting "Performance" used to arm the fans through a root helper on
    /// the first click with no explanation of what that means. The README says
    /// plainly that this software can damage hardware; the app owes the same
    /// sentence to the person actually holding the mouse.
    @Published private(set) var pendingControlConsent: ControlConsentIntent?

    /// Set once the person at the keyboard has agreed, in plain language, to
    /// what taking control means. Internal so the test fixtures can start from
    /// "already agreed" and exercise the machinery behind it.
    nonisolated static let controlRiskAcknowledgedKey = "hasAcknowledgedFanControlRisk"

    private var hasAcknowledgedControlRisk: Bool {
        defaults.bool(forKey: Self.controlRiskAcknowledgedKey)
    }

    /// Returns true when control may proceed; otherwise records what to resume
    /// and returns false, and the UI presents the acknowledgement.
    private func deferForConsentUnlessAcknowledged(_ intent: ControlConsentIntent) -> Bool {
        guard !hasAcknowledgedControlRisk else { return true }
        pendingControlConsent = intent
        Self.log.notice("first fan-control request deferred until acknowledged")
        return false
    }

    /// The user said yes. Persists the answer so it is asked once per machine,
    /// then resumes the exact request that opened the sheet.
    func confirmControlConsent() {
        guard let intent = pendingControlConsent else { return }
        defaults.set(true, forKey: Self.controlRiskAcknowledgedKey)
        pendingControlConsent = nil
        switch intent {
        case .enableControl:
            pendingConsentTask = Task { await self.enableControl() }
        case .turnAutoOff:
            pendingConsentTask = Task { await self.setAutoMode(false) }
        case .selectProfile(let id):
            selectProfile(id)
        }
    }

    func cancelControlConsent() {
        pendingControlConsent = nil
    }

    // MARK: - Helper setup

    /// The privileged helper is missing or refuses this build's signature.
    @Published private(set) var showsHelperSetup = false

    func openHelperSetup() { showsHelperSetup = true }
    func closeHelperSetup() { showsHelperSetup = false }

    /// The one command a user has to run, derived from where this bundle
    /// actually is rather than from where the Makefile assumes it will be.
    var helperInstallCommand: String {
        let appPath = Bundle.main.bundleURL.path
        let script = appPath + "/Contents/Resources/install-helper.sh"
        return "sudo '\(script)' '\(appPath)'"
    }

    // MARK: - Profile editing

    @discardableResult
    func addProfile(basedOn source: Profile?) -> Profile {
        let base = source ?? activeProfile
        var copy = base
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = uniqueName(base.name == "" ? "New profile" : "\(base.name) copy")
        profiles.append(copy)
        persist()
        return copy
    }

    private func uniqueName(_ wanted: String) -> String {
        var name = wanted
        var n = 2
        while profiles.contains(where: { $0.name == name }) {
            name = "\(wanted) \(n)"
            n += 1
        }
        return name
    }

    /// Built-ins cannot be deleted — every fallback path leads to one, and the
    /// panic path leads to Stock specifically.
    func canDelete(_ profile: Profile) -> Bool { !profile.isBuiltIn }

    func deleteProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), canDelete(profile) else { return }
        profiles.removeAll { $0.id == id }
        // Rules pointing at a deleted profile would silently never resolve.
        rules.removeAll { $0.targetProfileID == id }
        if defaultProfileID == id { defaultProfileID = Profile.balancedID }
        if activeProfileID == id { activeProfileID = defaultProfileID }
        if manualPin?.profileID == id { manualPin = nil }
        persist()
    }

    func updateProfile(_ profile: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        if profile.id == activeProfileID {
            for fan in fans { loops[fan.index]?.curve = profile.curve(forFan: fan.index) }
        }
        // This is the path slider drags and text fields hammer; the save is
        // coalesced so one gesture is one disk write and one backup.
        persistCoalesced()
    }

    /// How many rules would stop working if this profile went away.
    func ruleCount(targeting id: UUID) -> Int {
        rules.filter { $0.targetProfileID == id }.count
    }

    // MARK: - Rule editing

    func addRule(_ rule: Rule) {
        rules.append(rule)
        persist()
    }

    func updateRule(_ rule: Rule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
        // Same reasoning as `updateProfile`: rule fields are edited per keystroke.
        persistCoalesced()
    }

    func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    /// Order is priority — first match wins — so moving a rule is a real edit.
    func moveRules(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Which rule the resolver would pick right now, for the editor's live badge.
    var matchingRuleID: UUID? {
        if case .rule(let id, _) = resolution?.source { return id }
        return nil
    }

    // MARK: - Commands

    /// Pin a profile, and actually start using it.
    ///
    /// Picking "Performance" from the menu bar used to set `activeProfileID` and
    /// stop there. If the app was watching — which it is on launch, after Stock,
    /// and after any release — the status check in `sample()` then skipped
    /// `applyControl` forever, so the popover said Performance while macOS ran
    /// the fans. Choosing a profile that drives the fans *is* the request to
    /// drive the fans; if the helper is missing, `enableControl` surfaces that
    /// instead of failing silently.
    func selectProfile(_ id: UUID) {
        // Stock hands the fans back — the safe direction, never gated. A
        // profile that drives the fans is a request to leave auto mode, and
        // that request is deferred behind acknowledgement exactly once.
        if let profile = profiles.first(where: { $0.id == id }),
           !profile.releasesToSystem,
           !deferForConsentUnlessAcknowledged(.selectProfile(id)) {
            return
        }
        // Superseded synchronously, before anything suspends: a tick already
        // mid-round-trip must learn that this click happened at its next `await`,
        // not after it has written one more target on the old profile's behalf.
        let epoch = controlGate.supersede()
        manualPin = ManualPin(profileID: id, setAt: Date(), powerSourceAtPin: currentPowerSource)
        activeProfileID = id
        pendingSelection = Task {
            await controlGate.exclusive { await self.activateSelection(id, epoch: epoch) }
        }
    }

    /// The most recent `selectProfile` activation, held so it can be awaited.
    /// Nothing in the running app reads it — a menu click is fire-and-forget —
    /// but a test that clicks and then inspects the result needs a handle on the
    /// work its click started, and inferring one from timing is how a suite comes
    /// to fail once a week on a loaded machine.
    private var pendingSelection: Task<Void, Never>?

    /// Same idea for the follow-up a consent confirmation resumes.
    private var pendingConsentTask: Task<Void, Never>?

    /// Waits until every fan-control operation started so far has finished.
    func settleForTesting() async {
        await pendingConsentTask?.value
        await pendingSelection?.value
        await controlGate.exclusive { }
    }

    /// Runs holding the gate. Everything it calls is the `perform…` form for that
    /// reason — re-acquiring from in here would wait on a gate this call already
    /// holds, which is a deadlock rather than a delay.
    private func activateSelection(_ id: UUID, epoch: Int) async {
        if id == Profile.stockID {
            await performReleaseToStock()
            return
        }
        guard let profile = profiles.first(where: { $0.id == id }), !profile.releasesToSystem else {
            await performReleaseToStock()
            return
        }
        guard canLeaveAutoMode else { return }
        if status != .controlling && status != .emergency {
            await performEnableControl(epoch: epoch)
        }
    }

    func enableControl() async {
        guard deferForConsentUnlessAcknowledged(.enableControl) else { return }
        let epoch = controlGate.supersede()
        await controlGate.exclusive { await self.performEnableControl(epoch: epoch) }
    }

    private func performEnableControl(epoch: Int) async {
        guard canLeaveAutoMode else { return }

        // Both of these used to set `.daemonUnavailable` and nothing else, which
        // left whatever `controlProblem` was already showing — typically the
        // release message from the last attempt — as the banner text. Selecting a
        // profile then appeared to fail for the wrong reason.
        let probe = await daemon.version()
        guard controlGate.isCurrent(epoch) else { return abandon(epoch) }
        if case .failure(let failure) = probe {
            // Failure messages are now whole sentences of their own, so the
            // trailing period is added here rather than carried in each one.
            let reason = failure.message.hasSuffix(".") ? String(failure.message.dropLast()) : failure.message
            controlProblem = "Cannot take control of the fans: \(reason)."
            setStatus(.daemonUnavailable, "helper did not answer the version probe")
            Self.log.error("enableControl aborted: \(failure.message, privacy: .public)")
            return
        }

        // Captured before arming, not after: a drop that happens *during* arming
        // belongs to this generation and must not be filtered out as stale.
        let generation = daemon.currentGeneration

        // Every fan, or none. A machine driving fan 0 while macOS drives fan 1 is
        // two controllers fighting over one thermal envelope.
        var armed: [Int] = []
        for fan in fans {
            let result = await daemon.setManual(fan: fan.index, enabled: true)
            // Arming is the slow operation — up to `armTimeout` per fan — so it is
            // also the one most likely to still be running when the user changes
            // their mind. Half-armed is the state that must not survive: hand back
            // whatever was taken and let the newer intent decide from a clean slate.
            guard controlGate.isCurrent(epoch) else {
                await daemon.releaseAll()
                armedGeneration = nil
                return abandon(epoch)
            }
            switch result {
            case .success:
                armed.append(fan.index)
            case .failure(let failure):
                _ = await daemon.releaseAll()
                armedGeneration = nil
                controlProblem = "The helper would not take manual control of fan \(fan.index + 1): \(failure.message.trimmedSentence). Fans remain on macOS control."
                setStatus(.daemonUnavailable, "arming fan \(fan.index) refused")
                Self.log.error("enableControl aborted arming fan \(fan.index, privacy: .public): \(failure.message, privacy: .public)")
                return
            }
        }
        guard !armed.isEmpty else {
            controlProblem = "No controllable fans were found."
            setStatus(.daemonUnavailable, "no fans armed")
            armedGeneration = nil
            return
        }
        Self.log.notice("controlling \(armed.count, privacy: .public) fan(s) on connection \(generation, privacy: .public) under profile “\(self.activeProfile.name, privacy: .public)”")

        armedGeneration = generation
        controlProblem = nil
        controlFailureStreak = 0
        for key in Array(loops.keys) { loops[key]?.reset() }
        autoMode = false
        setStatus(.controlling, "manual control taken — profile “\(self.activeProfile.name)”")
        scheduleTimer()
    }

    /// The single switch between "macOS decides" and "this app decides".
    ///
    /// Auto mode is the safe state and the default, so turning it *on* always
    /// succeeds — it releases the fans and stops driving them. Turning it off
    /// needs the helper, and reports failure rather than silently staying auto.
    func setAutoMode(_ enabled: Bool) async {
        if !enabled, deferForConsentUnlessAcknowledged(.turnAutoOff) == false { return }
        let epoch = controlGate.supersede()
        await controlGate.exclusive {
            if enabled {
                self.autoMode = true
                await self.performReleaseToStock()
            } else {
                await self.performEnableControl(epoch: epoch)
            }
        }
    }

    /// Whether leaving auto mode is possible at all on this machine.
    var canLeaveAutoMode: Bool {
        if case .unverifiedOS = status { return false }
        return !fans.isEmpty
    }

    /// The panic button. Reachable from every surface.
    ///
    /// Always leaves the app in the watching state — refusing to keep driving is
    /// the point — but says so when the helper could not confirm the handover,
    /// because "we asked" and "the fans are back on macOS" are different facts.
    func releaseToStock() async {
        controlGate.supersede()
        await controlGate.exclusive { await self.performReleaseToStock() }
    }

    /// Runs holding the gate.
    ///
    /// Unlike arming, this never gives up partway on being superseded. Handing
    /// the fans back is idempotent and is the safe direction; a release that
    /// aborted halfway because another action arrived would leave exactly the
    /// half-owned state the panic button exists to eliminate.
    private func performReleaseToStock() async {
        autoMode = true
        armedGeneration = nil
        let result = await daemon.releaseAll()
        manualPin = ManualPin(profileID: Profile.stockID, setAt: Date(), powerSourceAtPin: currentPowerSource)
        activeProfileID = Profile.stockID
        controlFailureStreak = 0
        switch result {
        case .success:
            setStatus(.watching, "handed back to macOS (Stock)")
            controlProblem = nil
        case .failure(let failure):
            // Same distinction as `releaseAndReport`: an unreachable helper never
            // touched the fans, so the honest status is "helper not running", not
            // "watching macOS drive them".
            setStatus(failure.helperIsUnreachable ? .daemonUnavailable : .watching,
                      "handover to macOS unconfirmed")
            controlProblem = "The fans were not confirmed back on macOS control: \(failure.message.trimmedSentence)."
            Self.log.error("releaseToStock unconfirmed: \(failure.message, privacy: .public)")
        }
        for key in Array(loops.keys) { loops[key]?.reset() }
        scheduleTimer()
    }

    // MARK: - History

    /// The detector's own gate, so "when is attribution worth collecting?" has
    /// one answer rather than a copy that can drift.
    private static let attributionGate = ThrottleDetector.Configuration().gateCPUPercent

    /// Absent means off, which is the default we want, for both of these.
    private static let processNamesKey = "history.recordsProcessNames"

    func setRecordsProcessNames(_ enabled: Bool) async {
        recordsProcessNames = enabled
        defaults.set(enabled, forKey: Self.processNamesKey)
        await historyRecorder.setRecordsProcessNames(enabled)
    }

    // MARK: - Display preferences

    private static let displayModeKey = "status.displayMode"
    private static let watchingRateKey = "sampling.watchingRate"

    func setStatusDisplayMode(_ mode: StatusDisplayMode) {
        statusDisplayMode = mode
        defaults.set(mode.rawValue, forKey: Self.displayModeKey)
    }

    /// Takes effect on the next `rescheduleTimerIfNeeded` — which the next tick
    /// itself performs — rather than tearing the timer down mid-flight.
    func setWatchingSampleRate(_ rate: WatchingSampleRate) {
        watchingSampleRate = rate
        defaults.set(rate.rawValue, forKey: Self.watchingRateKey)
        rescheduleTimerIfNeeded()
    }

    // MARK: - Sensor sources

    private static let smcSensorsKey = "sensors.includesSMC"

    /// Add or remove the SMC's own temperature keys.
    ///
    /// Takes effect on the next tick rather than sampling immediately: a toggle
    /// that triggers its own out-of-band read would put a sample into the live
    /// window off the tick cadence, and the plots assume that cadence.
    ///
    /// Turning it off does not delete anything already recorded. Those series
    /// simply stop growing, which is why the toggle's own copy says so — a
    /// setting that silently drops data you have collected is worse than one
    /// that keeps it.
    func setIncludesSMCSensors(_ enabled: Bool) async {
        includesSMCSensors = enabled
        defaults.set(enabled, forKey: Self.smcSensorsKey)
        await sources.setIncludeSMC(enabled)
    }

    var historyFileURL: URL { historyRecorder.url }

    /// One tick's worth of samples, built once and given to both tiers — the
    /// live window for the plots, the recorder for the database. Two builders
    /// would be two chances for the plots and the saved record to disagree.
    ///
    /// `attributed` arrives precomputed by the tick that read the sensors —
    /// it is the same set that picked `maxTempC`, and recomputing it here per
    /// tick was a second full filter over every reading for an identical answer.
    private func recordHistory(now: Date,
                               attributed: [TemperatureSensors.Reading]) async {
        var samples: [RecordedSample] = []
        samples.reserveCapacity(temperatures.count + fans.count * 2 + 1)

        let ambiguous = TemperatureSensors.ambiguousNames(in: temperatures)
        // The same set the fan curve is allowed to read, for the same reason:
        // this is what the app can say it measured. A calibration reference is a
        // constant, not a measurement, and storing it would add a dead flat line
        // to every chart and a row per tick for a number that never changes; an
        // SMC key whose subsystem is unestablished is worth showing live and not
        // worth two years of the hour tier. On this Mac that is 87 sensors with
        // the SMC source on, against 292 shown and 22 with it off.
        for reading in attributed {
            samples.append(RecordedSample(
                sensor: HistorySensors.temperature(reading,
                                                   isAmbiguous: ambiguous.contains(reading.name)),
                value: reading.celsius))
        }

        var fanRPM: [Int: Double] = [:]
        var peakDuty: Double = 0
        var peakRPM: Double = 0
        for fan in fans {
            guard let reading = readings[fan.index] else { continue }
            let duty = fan.dutyPercent(forRPM: reading.actualRPM)
            fanRPM[fan.index] = reading.actualRPM
            peakDuty = max(peakDuty, duty)
            peakRPM = max(peakRPM, reading.actualRPM)
            samples.append(RecordedSample(sensor: HistorySensors.fanRPM(fan.index),
                                          value: reading.actualRPM))
            samples.append(RecordedSample(sensor: HistorySensors.fanDuty(fan.index),
                                          value: duty))
        }

        samples.append(RecordedSample(sensor: HistorySensors.cpuLoad, value: cpuPercent))

        // Package power rides the same tick. The first call only sets the
        // reader's baseline; its unavailability is silent by design.
        let power = packagePower.sample()
        if let cpuWatts = power.cpuWatts {
            samples.append(RecordedSample(sensor: HistorySensors.cpuPower,
                                          value: cpuWatts))
            cpuWattsReading = cpuWatts
        } else {
            cpuWattsReading = nil
        }
        if let gpuWatts = power.gpuWatts {
            samples.append(RecordedSample(sensor: HistorySensors.gpuPower,
                                          value: gpuWatts))
            gpuWattsReading = gpuWatts
        } else {
            gpuWattsReading = nil
        }

        liveHistory.record(samples, at: now)

        // `topProcesses` is empty unless something is consuming it; the recorder
        // discards names again if attribution is off, so this can't leak.
        let processes = topProcesses.map {
            ThrottleDetector.ProcessLoad(name: $0.name, cpuPercent: $0.cpuPercent)
        }

        let input = ThrottleDetector.Input(
            date: now,
            cpuPercent: cpuPercent,
            pressure: thermalPressure,
            maxTempC: maxTempC,
            fanRPM: fanRPM,
            fanNearCeiling: peakDuty >= ThrottleDetector.Configuration().fanCeilingFraction * 100,
            profileName: activeProfile.name,
            onBattery: !environment.onACPower,
            externalDisplayCount: environment.externalDisplayCount,
            processes: processes)

        // The sudden-rise record, which answers a question the throttle record
        // cannot: most spikes people notice never reach a throttle's sustained-
        // load bar, so without this they left no trace at all.
        let spike = SpikeDetector.Input(
            date: now,
            maxTempC: maxTempC,
            cpuPercent: cpuPercent,
            hottestGroup: hottestGroup,
            fanRPM: peakRPM,
            fanDutyPercent: peakDuty,
            profileName: activeProfile.name,
            onBattery: !environment.onACPower,
            processes: processes)

        // The alerting layer rides on the same event the recorder just handled,
        // so detection cannot drift between "what history recorded" and "what
        // the user was told about".
        let throttleEvent = await historyRecorder.record(
            samples: samples, at: now, throttle: input, spike: spike,
            profile: HistoryRecorder.ProfileState(
                id: activeProfileID.uuidString,
                name: activeProfile.name,
                reason: resolution?.source.displayReason ?? "Default"))
        switch throttleEvent {
        case .opened: isThrottling = true
        case .closed: isThrottling = false
        case .none, .updated: break
        }
        await alerter.observe(throttleEvent, at: now)
    }

    /// Runs exactly one sampling tick, synchronously awaitable.
    ///
    /// The real driver is a `DispatchSourceTimer`, which a test cannot step. This
    /// is the same entry point the timer's handler calls — gate and all — so a
    /// test exercises the production path rather than a parallel one written to
    /// be convenient.
    func tickForTesting() async { await tick() }

    /// Puts the model into a state a running Mac would produce, so views can be
    /// rendered against it. Internal, and it writes only to the published
    /// readouts — nothing here touches hardware, the daemon, or either store.
    func applyForTesting(fans: [FanDescriptor]? = nil,
                         readings: [Int: FanReading]? = nil,
                         readingsUpdatedAt: [Int: Date]? = nil,
                         temperatures: [TemperatureSensors.Reading]? = nil,
                         temperaturesUpdatedAt: Date? = nil,
                         cpuPercent: Double? = nil,
                         memory: MemoryUsage? = nil,
                         availableDiskBytes: UInt64? = nil,
                         thermalPressure: ThermalPressure? = nil,
                         status: ControlStatus? = nil,
                         resolution: Resolution? = nil,
                         environment: EnvironmentMetrics.Snapshot? = nil,
                         configProblem: String? = nil) {
        if let fans {
            self.fans = fans
            // Built the same way `performStart` builds them. Without this a model
            // could be given fans and still have no control loops, which is a
            // state the running app never reaches — and `applyControl` skips any
            // fan with no loop, so a test posed against it would silently exercise
            // nothing while appearing to drive two fans.
            loops = Dictionary(uniqueKeysWithValues: fans.map { fan in
                (fan.index, ControlLoop(fan: fan,
                                        curve: activeProfile.curve(forFan: fan.index),
                                        settings: activeProfile.settings,
                                        floor: safetyFloor))
            })
        }
        if let readings { self.readings = readings }
        if let readingsUpdatedAt { self.readingsUpdatedAt = readingsUpdatedAt }
        if let temperatures {
            self.temperatures = temperatures
            // A live sensor set, exactly as `sample` records one. Without this a
            // fixture would look identical to "the sensors died" the moment the
            // staleness check existed — and every control test would silently
            // exercise the release path instead of the loop.
            self.temperaturesUpdatedAt = Date()
            // Derived exactly as `tick` and `recordHistory` derive them. A
            // fixture that computed these its own way would let a view be tested
            // against a state the running app cannot produce — and it did: this
            // used to take the maximum over every reading including calibration
            // references, which production has excluded since before the SMC
            // source existed.
            let attributed = TemperatureSources.attributed(temperatures)
            self.maxTempC = attributed.map(\.celsius).max()
            self.hottestGroup = attributed.max { $0.celsius < $1.celsius }
                .map { SensorCategory.classify($0.name).rawValue } ?? ""
            liveHistory.record(attributed.map {
                RecordedSample(sensor: HistorySensors.temperature($0, isAmbiguous: false),
                               value: $0.celsius)
            }, at: Date())
        }
        if let temperaturesUpdatedAt { self.temperaturesUpdatedAt = temperaturesUpdatedAt }
        if let cpuPercent { self.cpuPercent = cpuPercent }
        if let memory { self.memory = memory }
        if let availableDiskBytes { self.availableDiskBytes = availableDiskBytes }
        if let thermalPressure { self.thermalPressure = thermalPressure }
        if let status { self.status = status }
        if let resolution { self.resolution = resolution }
        if let environment { self.environment = environment }
        if let configProblem { self.configProblem = configProblem }
    }

    /// Called on quit, so the last few seconds aren't lost to the write buffer.
    func flushHistory() async {
        await historyRecorder.flush()
        await historyRecorder.optimizeOnClose()
    }

    /// Whether control should be retaken once the machine wakes.
    ///
    /// Manual control does not survive sleep on Apple Silicon, so the fans are
    /// handed back on the way down. Without recording that the user *wanted*
    /// control, waking left the app watching — fan control silently stopped at
    /// the first sleep and only a manual profile re-selection brought it back.
    private var resumeControlAfterWake = false

    /// Called on `NSWorkspace.willSleepNotification`, before the hardware release.
    /// Synchronous and main-actor, so the intent is recorded even if the release
    /// that follows it times out.
    func noteWillSleep() {
        resumeControlAfterWake = isControlling
        beginTerminalTransition()
        Self.log.notice("sleeping — releasing fans (resume on wake: \(self.resumeControlAfterWake, privacy: .public))")
    }

    /// Called from `applicationWillTerminate`, before the detached release.
    ///
    /// Quit takes the same protection sleep already needed. `shutdownFansAndFlush`
    /// deliberately runs *off* the main actor and so cannot take the gate; without
    /// this, a tick suspended mid-`applyControl` could resume after that release
    /// had completed, see its target refused, and re-arm manual mode on an app
    /// that is in the act of exiting — leaving the fans pinned with nothing alive
    /// to release them but the daemon's watchdog.
    func noteWillTerminate() {
        beginTerminalTransition()
        timer?.cancel()
        timer = nil
        scheduledInterval = nil
        // A coalesced save waiting out its debounce would be dropped here.
        flushPendingPersist()
        Self.log.notice("quitting — releasing fans")
    }

    /// The state changes shared by sleep and quit: stop claiming control, drop
    /// the loops' history, and supersede anything in flight so it cannot write.
    private func beginTerminalTransition() {
        controlGate.supersede()
        armedGeneration = nil
        autoMode = true
        setStatus(.watching, "sleep or quit — releasing fans")
        for key in Array(loops.keys) { loops[key]?.reset() }
    }

    /// The pre-sleep release came back unconfirmed.
    ///
    /// `shutdownFansAndFlush` runs off the main actor and cannot say this itself,
    /// so the caller — which is already on the main thread, waiting on it — says
    /// it here. Without this the app went to sleep having failed to hand the fans
    /// back, showing "Watching", with nothing on screen to say the handover had
    /// not happened: the same silence as `ISSUES.md` I-3, entered by a different
    /// door. The daemon's watchdog still recovers the hardware; that is not a
    /// reason for the app to keep it to itself.
    func noteReleaseUnconfirmed() {
        setStatus(.daemonUnavailable, "pre-sleep release unconfirmed")
        controlProblem = "The fans were not confirmed back on macOS control before sleep. "
            + "The helper's watchdog will release them; if this repeats, check that the helper is running."
        Self.log.error("sleep: release unconfirmed — fans may still be under manual control")
    }

    /// Called on `NSWorkspace.didWakeNotification`. Re-probes the hardware, then
    /// retakes control if that is what the user had before the machine slept.
    func resumeAfterWake() async {
        await start()
        guard resumeControlAfterWake else { return }
        resumeControlAfterWake = false
        Self.log.notice("woke — retaking fan control")
        await enableControl()
    }

    /// Sleep and quit path: hand the fans back and flush the write buffer,
    /// *without* the main actor.
    ///
    /// `applicationWillTerminate` runs on the main thread and AppKit will not
    /// return from it until we do, so the shutdown had to block there — and it
    /// blocked on a `Task { @MainActor in … }`, which cannot start until the main
    /// actor is free. That is a deadlock with a timeout on it: the semaphore
    /// always expired, and the app quit having released nothing, every time. The
    /// fans were only rescued afterwards by the daemon's watchdog, twelve seconds
    /// later, which is twelve seconds of a quit app driving the hardware.
    ///
    /// So this touches nothing main-actor-isolated. Both collaborators are
    /// actors reached through `nonisolated` stored properties, and the caller
    /// runs it on a detached task.
    nonisolated func shutdownFansAndFlush() async -> Bool {
        let released: Bool
        switch await daemon.releaseAll() {
        case .success:
            released = true
        case .failure(let failure):
            released = false
            Self.log.error("quit: fans not confirmed back on macOS control: \(failure.message, privacy: .public)")
        }
        await historyRecorder.flush()
        return released
    }

    func updateCurve(_ curve: FanCurve, forFan index: Int, inProfile profileID: UUID? = nil) {
        let target = profileID ?? activeProfileID
        guard let i = profiles.firstIndex(where: { $0.id == target }) else { return }
        profiles[i].fanCurves[index] = curve
        if target == activeProfileID { loops[index]?.curve = curve }
        persist()
    }
}
