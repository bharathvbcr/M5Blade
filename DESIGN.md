# M5Blade — Power Profiles & Feature Design

**Target:** Apple Silicon (M-series), macOS 14+ · **Reads:** unprivileged · **Writes:** root daemon
Companion to `FEASIBILITY.md` (viability) and `AUDIT.md` (design review — **read A-1 and A-2 first**).

---

## 1. Module Layout

```
Fan_Control/
├── Sources/
│   ├── SMCKit/          IOKit transport, key info, FPE2 ⇄ IEEE-754, actor-serialized
│   ├── CIOReport/       C shim over libIOReport — Energy Model power counters
│   ├── SensorKit/       IOHIDEventSystem temps, IOReport power, host_* metrics, libproc
│   ├── PowerKit/        AppleSmartBattery, IOPowerSources, adapter, charge limit
│   ├── FanKit/          Fan model, curves, hysteresis, slew, safety floor, ceiling
│   ├── ProfileKit/      Profiles, rules, resolver, precedence, dwell
│   ├── HistoryKit/      SQLite time series, downsampling, spikes, throttle episodes, export
│   ├── DaemonProtocol/  Shared XPC interface — deliberately minimal
│   ├── DaemonCore/      Daemon policy — write-only validation, clamps, watchdog;
│   │                    a separate target so it tests without root or hardware
│   ├── SimSupport/      Test-only thermal simulator + seeded trace generators
│   ├── m5bladed/        Root LaunchDaemon — write-only, clamps, watchdog
│   ├── smcfan/          Read-only probe/status CLI
│   └── M5Blade/         NSStatusItem UI, SwiftUI panels, Swift Charts
└── Tests/               704 tests across 9 test targets (control loop invariants,
                         resolver precedence, retention, daemon policy, app view models)
```

`SMCKit`, `SensorKit`, `PowerKit`, `HistoryKit` have **no dependency on the daemon** — the entire monitoring app builds and runs without it.

---

## 2. Power Profiles — Layered Model

Two layers: **profiles** define behavior, **rules** select which profile is active. Manual selection and automation coexist rather than competing.

### 2.1 Profile

As shipped (`Sources/ProfileKit/Profile.swift`, `Sources/FanKit/ControlLoop.swift`):

```swift
struct Profile: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isBuiltIn: Bool

    // Per-fan, keyed by fan index — see AUDIT A-3
    var fanCurves: [Int: FanCurve]

    // Control loop parameters, one set per profile (ControlSettings):
    // ceilingPercent 95 · hysteresisC 3.0 · slewUpRPMPerSec 200 ·
    // slewDownRPMPerSec 100 · smoothingAlpha 0.3 (EMA on temperature)
    var settings: ControlSettings

    var releasesToSystem: Bool      // Stock: write mode 0 and hand control back
}

struct FanCurve: Codable, Sendable {
    var points: [CurvePoint]        // tempC + percent; monotonic non-decreasing,
                                    // re-normalized on every write
    var sensorIDs: [String]         // which sensors drive this fan
    var reduction: SensorReduction  // .max (default), .mean
}
```

Three fields from the original sketch were dropped rather than left unread: `floorPercent` (the floor is `SafetyFloor`'s, computed per tick — never user-authored per profile), `sampleHz` (control is 1 Hz, fixed; the only cadence choice is the watching-mode sample rate), and `chargeLimitPercent` (charge limiting is a machine-level setting behind the daemon, not a property of a fan profile — §6.3).

`sensorIDs` empty means "the machine's hottest sensor", which is what every
built-in ships with. A mapped curve reads only its own sensors; if every one of
them stops reporting, the curve falls back to the machine-wide maximum and the
UI says so — reading a vanished mapping as 0 °C would stop the fan on a hot
machine, which is the quietest possible way to fail.

The **safety floor never uses the mapping**. It reads the machine-wide maximum
regardless of which sensors a curve names, so a fan mapped to the SSD still
answers to a hot SoC.

`desiredMacOSPowerMode` was specified here and never implemented. It has been
removed rather than left as a field nothing reads — see §2.6, where the
"read and reflect" half of that design is what actually ships.

### 2.2 Built-in profiles

| Profile | Ceiling | Character |
|---|---|---|
| **Silent** | 60% | Fans stay near floor until 75 °C. Accepts throttling in exchange for silence. |
| **Balanced** *(default)* | 95% | Tracks stock behavior with a modest head start on the ramp. |
| **Performance** | 95% | Ramps early and hard — fans lead the heat rather than chasing it. |
| **Max Cooling** | 100% | Ceiling released. For sustained exports/compiles where noise is irrelevant. |
| **Stock** | — | Writes mode `0` and gets out of the way. Monitoring continues. |

**Stock is not a cosmetic entry.** It is the target of every fallback path in the app, and it must be reachable in one click from the menu bar at all times.

### 2.3 Rules

As shipped (`Sources/ProfileKit/Rule.swift`):

```swift
struct Rule: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var enabled: Bool
    // No priority field: order in the list IS the priority — first match wins.
    var conditions: [Condition]    // ALL must hold (AND)
    var targetProfileID: UUID
    var minDwell: TimeInterval = 30
    var debounce: TimeInterval = 5
}

enum Condition: Codable, Sendable {
    case powerSource(PowerSource)             // .ac / .battery
    case batteryBelow(percent: Int)
    case thermalAtLeast(ThermalPressure)      // .fair / .serious / .critical
    case processActive(match: ProcessMatch, sustainedCPU: Double?, forSeconds: TimeInterval?)
    case foregroundApp(bundleID: String)
    case displaysAsleep(Bool)
    case externalDisplayCount(atLeast: Int)
    case macOSPowerMode(MacOSPowerMode)
    case sustainedLoad(cpuPercent: Double, forSeconds: TimeInterval)
}
```

`clamshell` and `timeOfDay` were specified here and never implemented; they are
recorded as absent rather than listed among the conditions a rule can use.
External-display count and display sleep ship, which covers most of the
clamshell signal's practical ground (§A-8 of the audit tracks the remainder).

### 2.4 Resolution order — strict precedence

```
1. EMERGENCY      thermalState == .critical, or any sensor > hardMaxC,
                  or sensor data stale > 10s
                  → ceiling released to 100%, or full release to Stock on stale data.
                  Cannot be overridden by anything below.

2. MANUAL PIN     User picked a profile from the menu bar.
                  Pinned until: explicitly cleared, its expiry elapses, or
                  a pin-breaking condition fires (default: unplugging from AC).

3. RULES          Highest-priority rule whose conditions all hold.
                  Ties broken by rule order in the list.

4. DEFAULT        The profile marked default (Balanced out of the box).
```

The resolver is a pure function — `(SystemState, [Rule], [Profile], PinState) -> Profile` — with **no I/O and no side effects**, which makes the entire precedence system unit-testable without hardware. Given A-1 and A-2, this is the second-most safety-relevant code in the project and it should be tested exhaustively.

### 2.5 Anti-flapping

Rule evaluation is a state machine, not a per-tick lookup:

- **Minimum dwell** (default 30s): once a rule wins, it holds for at least `minDwellSeconds` even if its conditions stop matching.
- **Debounce on entry** (default 5s): conditions must hold continuously before a rule activates.
- **Ramp, not jump**: an abrupt RPM step on profile switch is the most audible thing this app can do. This is delivered by the control loop's existing **slew limiter** rather than by a separate crossfade between curves: the incoming curve takes effect immediately and the *rpm* is rate-limited toward it, which reaches the same place in about the same time with one mechanism instead of two. Silent → Max cooling on a 1350–5349 rpm fan takes roughly five seconds at the default 600 rpm/s.
- **Emergency bypasses all of it.** Emergency ramps immediately and ignores dwell, debounce, and the slew limiter.

### 2.6 macOS power-mode coupling

macOS has its own Low Power / High Power modes. Default posture is **read and reflect, do not write**:

- Read via `ProcessInfo.isLowPowerModeEnabled` and expose as a `Condition`. **Shipped.**
- Surface the contradiction: if the user is in macOS Low Power Mode and selects an aggressive profile, say so in the UI rather than silently doing both. **Shipped** — `AppModel.powerModeContradiction`.
- Writing the power mode is **not implemented and not planned**. It requires root, it fights a setting the user chose deliberately, and the profile field that once anticipated it has been removed. If it is ever added it must be gated behind an explicit opt-in that is off by default.

---

## 3. Feature: Thermal Throttle Detection & Alerts

### 3.1 The trap

Naive frequency-based throttle detection produces constant false positives on Apple Silicon. macOS routinely runs P-cores below maximum frequency for scheduling and efficiency reasons **with no thermal cause whatsoever** — conventional "clock is below max ⇒ throttling" logic is simply wrong here.

### 3.2 Signal fusion

Require corroboration across independent signals before declaring an episode:

| Signal | Source | Weight |
|---|---|---|
| `ProcessInfo.thermalState` ≥ `.serious` | Foundation — **public, documented** | Primary |
| P-cluster DVFS residency concentrated in low states while demand is high | `IOReport` (private) | Supporting |
| Sustained CPU demand > 70% for > 20s | `host_processor_info` | Gate |
| Package temp above a per-model threshold | HID sensors | Supporting |
| Fan already at/near its ceiling | SMC `F%dAc` vs `F%dMx` | Supporting |
| `CPU_Speed_Limit` < 100 | `pmset -g therm` (Intel only) | Primary where present |

**Declare an episode when the gate holds AND `thermalState ≥ .serious`, OR when the gate holds AND ≥2 supporting signals agree.** `thermalState` alone is authoritative — it is Apple telling you directly — so it deserves a fast path.

### 3.3 Episode model

As shipped (`Sources/HistoryKit/HistoryModels.swift`):

```swift
struct ThrottleEpisode: Identifiable, Sendable {
    var id: Int64                       // database row id
    var start: Date
    var end: Date?                      // nil while the episode is still open
    var peakTempC: Double?
    var peakPressure: Int               // thermal pressure at the peak
    var meanCPUPercent: Double
    var profileName: String
    var onBattery: Bool
    var externalDisplayCount: Int
    var fanRPMAtPeak: [Int: Double]
    var processes: [ProcessShare]       // top 3 by CPU-seconds during the window
}
```

`processes` is the feature's real value — "your Mac throttled" is noise; "your Mac throttled for 4 minutes and `swift-frontend` accounted for 71% of it" is actionable. It is opt-in (§5.4).

### 3.4 Sudden spikes — a different question

Throttle detection asks "did the machine run out of cooling headroom?" and needs a **sustained demand gate** before it will say anything. That is correct for what it measures, and it means the event users actually report — *"my Mac suddenly spikes"*, the fans audibly ramping for ninety seconds — leaves no record at all. Most such rises never reach 70% CPU for 20 seconds with two corroborating signals.

So there is a second detector, watching the **shape** of the temperature trace rather than its level:

| | |
|---|---|
| Declare | a climb of ≥ 12 °C inside a 2-minute trailing window, peaking ≥ 70 °C |
| Baseline | the *coolest* sample in that window, so the record starts where the climb began rather than where it crossed a threshold |
| Close | when half the climb has been given back for 30 seconds, ending at the last instant it was still elevated |
| Give up | after 30 minutes still elevated — that is a workload, which is §3.2's subject, not this one's |

Two rules keep this from becoming noise. A gap longer than a minute (sleep, a stall, a clock correction) discards the baseline, so a wake never reads as an instant 40-degree rise. And closing a spike **empties the trailing window**, so a machine that stays hot produces one record rather than a chain of them each measured from a temperature it left ten minutes ago.

The record stores **evidence, not a verdict**: start/peak/end, temperature at both ends, load at both ends, which sensor group was hottest, fan rpm and duty at the peak, the profile and whether it changed mid-rise, and the per-application CPU-seconds. `SpikeExplanation` derives the cause from that. Keeping the two apart means the wording can be improved without a schema migration and a wait for the next spike — and that an exported record carries the reasoning *and* the numbers it rests on, so a reader can disagree with it.

Attribution is only allowed to **name** an application when load actually rose. It measures CPU-seconds, so during a graphics or SSD spike whatever happened to be using the processor would otherwise take the blame for heat it had nothing to do with.

### 3.5 Alerting

- `UserNotifications` (`UNUserNotificationCenter`) — **requires user authorization**, and it's the only permission prompt in the entire app. Request it lazily, on first alert-rule creation, not at launch.
- Rate limit: at most one notification per 15 minutes; coalesce repeats into "3rd episode in the last hour."
- **Suppression list**: per-app mute ("don't alert me while Blender is running") — otherwise the feature trains the user to ignore it within a day.
- Menu bar affordance: a subtle color change on the status item is better than a notification for the ambient case. Reserve notifications for episodes exceeding a duration threshold.
- Every episode is written to history regardless of whether it alerted.

---

## 4. Feature: Per-App Auto-Profiles

### 4.1 Detection

Two populations, two mechanisms:

- **GUI apps** — `NSWorkspace.shared.runningApplications`, plus `didLaunchApplicationNotification` / `didTerminateApplicationNotification`. Event-driven, essentially free. Match on `bundleIdentifier`.
- **CLI processes and daemons** — `proc_listpids` + `proc_pidpath`, polled at 0.2 Hz. Necessary for the workloads that actually generate heat: `swift-frontend`, `clang`, `ffmpeg`, `node`, `com.docker.backend`, `Xcode`'s build subprocesses. Match on executable name.

Note the A-4 constraint: `proc_pidinfo` cannot read processes owned by other users or root without elevation. Match on the names you *can* see and don't pretend the list is complete. If completeness matters, the daemon can supply it over XPC — but that widens the daemon's interface, which A-2 argues against. Recommendation: **don't**.

### 4.2 Trigger on load, not on existence

The important design decision. "Xcode is running" is true all day and is a useless trigger. The condition should be:

```swift
.processRunning(
    match: .executableName("swift-frontend"),
    sustainedCPU: 50.0,      // % of one core, summed across matching PIDs
    forSeconds: 15
)
```

CPU is attributed by summing `proc_pidinfo(PROC_PIDTASKINFO)` CPU-time deltas across all PIDs matching the pattern — build systems spawn and reap short-lived processes constantly, so per-PID tracking must be tolerant of churn.

**Deactivation asymmetry:** activate after 15s sustained, deactivate after 60s below threshold. Compiles come in bursts; dropping the profile between two files and re-ramping is worse than holding it.

### 4.3 UX

- **"Create rule from what's running now"** — snapshot the current top processes and pre-fill a rule. Far better than asking a user to type `swift-frontend`.
- Suggested presets shipped disabled: Xcode/compilers, Final Cut/Compressor, Blender, Docker, games (match on `/Applications/*.app` with sustained GPU).
- Show *which* rule is active and *why* in the menu bar popover — "Performance · rule: Xcode build". Automation the user can't see is automation they won't trust.

---

## 5. Feature: Sensor History & Logging

### 5.1 Storage — SQLite, not SwiftData

SwiftData is the wrong tool for high-frequency time series: no efficient bulk insert, no control over indexing, and object-graph overhead on every sample. Use SQLite directly (or GRDB).

```sql
CREATE TABLE sensors (
    id       INTEGER PRIMARY KEY,
    key      TEXT NOT NULL UNIQUE,   -- 'TC0P', 'F0Ac', 'gpu_power'
    kind     TEXT NOT NULL,          -- temperature | rpm | power | percent | mah
    unit     TEXT NOT NULL
);

CREATE TABLE samples (
    sensor_id INTEGER NOT NULL REFERENCES sensors(id),
    ts        INTEGER NOT NULL,      -- unix seconds
    value     REAL    NOT NULL,
    PRIMARY KEY (sensor_id, ts)
) WITHOUT ROWID;

CREATE TABLE episodes (...);          -- throttle episodes
CREATE TABLE spikes (...);            -- sudden-rise records (§3.4)
CREATE TABLE sessions (...);          -- user-marked benchmark windows
CREATE TABLE profile_changes (ts, profile_id, reason);
```

`WITHOUT ROWID` with a `(sensor_id, ts)` primary key gives clustered storage in exactly the order you query. Batch inserts in a transaction once per 10s, not per sample. `PRAGMA journal_mode=WAL`.

### 5.2 Retention — tiered downsampling

| Tier | Resolution | Window | Rows (20 sensors) |
|---|---|---|---|
| Raw | 1 s | 2 hours | ~144k |
| Minute | 1 min avg/min/max | 14 days | ~403k |
| Hour | 1 h avg/min/max | 2 years | ~350k |

Roll up in a background task hourly, then delete the superseded tier. Steady-state database stays well under 100 MB indefinitely. Expose the number and a "clear history" button — an app that quietly grows a database on someone's SSD forever is bad manners.

Event rows — episodes, spikes, sessions, profile changes — age out with the hour tier rather than being kept forever. They are small, and "small × unbounded" is still unbounded; more to the point, an event row that outlives every sample in its own window is one the chart can never draw, so the list would offer a throttle from two years ago over an empty plot. Two exceptions, both because the row means something other than "this happened then": a record still **open** is never pruned at any age (it is the record of something unfinished — `finalizeDanglingRecords` closes those), and the **newest** profile change is never pruned (it is the statement "this profile from here on", so deleting it unlabels the chart's first band and makes the recorder write a duplicate transition on next launch).

### 5.3 Presentation & export

- **Swift Charts** (public, macOS 13+) for the graphs. Overlay temperature, RPM, and package watts on a shared time axis with profile-change and throttle-episode annotations — that combined view is the single most useful screen in the app.
- **Sessions**: "Start recording" marks a window, so a user can compare two runs of the same benchmark under different profiles side by side.
- **Export**: CSV (wide, one column per sensor) and JSON (tall, with full metadata). Write to a user-chosen location via `NSSavePanel`.

### 5.4 Privacy

The history database contains a timestamped record of which applications the user runs. That is meaningfully sensitive.

- Process-name capture in episodes **and spikes** (§3.4) is **opt-in**, with the toggle explained in plain language, and the recorder discards names when it is off rather than trusting callers to have filtered them.
- **Switching it off means forget, not stop adding.** An event in progress is still being collected, so both detectors discard what they already hold and the open rows are rewritten without names. A *completed* record keeps its names: destroying data the user already has is `clear()`'s job, and that asks first. Getting this wrong is silent — the toggle reads as off while the file keeps the names and an export carries them.
- Each record stores whether capture was on **at the time**, so an empty attribution list reads as "not recorded" years later rather than "nothing was responsible" — and the setting can be changed without rewriting the past.
- Sampling per-process CPU means walking every pid, so it is armed by the signal a spike is made of (a 5 °C climb inside a minute) rather than paid for continuously. That is a cost decision, not a privacy one: nothing is collected while the toggle is off.
- Store in `~/Library/Application Support/M5Blade/`, not a shared location.
- CSV/JSON export must warn when the payload includes process names — from a spike as well as from an episode.
- No network egress. Ever. Don't add the `com.apple.security.network.client` capability and the claim verifies itself.

---

## 6. Feature: Battery Health & Power Analytics

### 6.1 Sources

| Data | Source | Privilege |
|---|---|---|
| Charge %, time remaining, AC/battery, adapter watts | `IOPSCopyPowerSourcesInfo` | None |
| `DesignCapacity`, `AppleRawMaxCapacity`, `CycleCount`, `Temperature`, `Voltage`, `Amperage`, `PermanentFailureStatus` | `AppleSmartBattery` IORegistry node | None |
| CPU / GPU / ANE / DRAM wattage | `IOReport` (private) | None |
| System total power | SMC power keys | None |
| Charge limit (read/write) | SMC `CHWA` (Apple Silicon), `BCLM` (Intel) | **Write needs root** |

### 6.2 Health, honestly

```
healthPercent = AppleRawMaxCapacity / DesignCapacity × 100
```

**Expect this to disagree with System Settings.** Apple's "Maximum Capacity" figure is smoothed and recalibrated over time; the raw ratio is noisier and often reads lower. Show both, label the difference, and don't let the user conclude their battery degraded overnight because your app is more literal than Apple's.

Useful derived views: cycles vs. Apple's 1000-cycle rating; capacity trend over months (you have the history database — this is where it pays off); charge/discharge wattage in real time; time-at-high-temperature, which is a better predictor of degradation than cycle count alone.

### 6.3 Charge limiting — recommend deferring to Apple

`CHWA` on Apple Silicon accepts only **80** or **100**, and requires firmware ≥ 13.0. Meanwhile macOS ships a native Charge Limit in System Settings.

**Recommendation: don't implement charge limiting.** Read `CHWA` and display the current state, link to System Settings, and stop there. Rationale:

- Apple's implementation survives sleep, reboots, and firmware updates; yours needs a daemon running to hold state.
- Two independent controllers writing the same SMC key is a genuine conflict, and the loser is the user's battery.
- It doubles the daemon's write surface for a feature the OS already provides — directly against A-2.

If you implement it anyway: detect Apple's setting first and refuse to engage when it is active.

**Status.** Shipped, per the "if you implement it anyway" branch — read-only surfacing always, plus a write path behind an explicit opt-in that defaults **off** (ISSUES §T-3). The daemon validates requests to exactly {80, 100}, gates on the key's presence and a battery being present, and treats a read-back that disagrees with the request as failure. Measured on this machine: no `CHWA`/`BCLM` key exists (3626 SMC keys enumerated), so the controls are inert here with an explanation pointing at System Settings — expected to become the common case as Apple tightens these writes.

### 6.4 Per-process energy attribution

macOS's own "Energy Impact" is a proprietary composite. You can approximate:

```
energyScore(pid) ≈ Σ (cpuTimeDelta × coreTypeWeight) + gpuTimeDelta × gpuWeight + wakeups × wakeupCost
```

P-cores cost roughly 3–5× E-cores per unit time on M-series. **Label it "estimated" in the UI.** Presenting a hand-rolled approximation next to Activity Monitor's number, with no caveat, is how you get bug reports you can't close.

### 6.5 The view that justifies the feature

One chart: **package watts, fan RPM, and package temperature on a shared axis, with the active profile shaded behind.** It answers the question the whole app exists to answer — *is my cooling policy actually doing anything?* — and nothing else in the feature set answers it as directly.

---

## 7. Permissions Summary

| Permission | Needed? |
|---|---|
| TCC (camera, mic, files, Full Disk Access, Accessibility, Screen Recording) | **None** |
| Notifications | Only if throttle alerts are enabled — request lazily |
| Root | Fan writes only, via the daemon |
| App Sandbox | Incompatible — `AppleSMC` user client is not permitted |
| Network | None. Not requested. |

Zero telemetry, zero analytics, zero crash reporting to third parties. This matches the category norm (TG Pro removed all analytics; iStat Menus ships none) and is cheap to hold to from day one.

---

## 8. Revised Build Order

Amended from `FEASIBILITY.md` to front-load the audit fixes:

| Phase | Work | Gate |
|---|---|---|
| **0** | `FanBackend` protocol + thermal simulator + resolver tests | Control loop provably correct with no hardware (A-12) |
| **1** | `SMCKit` read-only CLI. Probe `F0md`/`F0Md`, enumerate fans, log ranges | Hardware behavior confirmed on *your* M5 |
| **2** | Monitoring app: sensors, CPU, memory, processes, GPU, battery. `NSStatusItem` | Useful standalone; zero privileges |
| **3** | `HistoryKit` + Swift Charts | History exists *before* control, so you can measure what control changes |
| **4** | Daemon + XPC with cdhash pinning and daemon-side clamping (A-2) | Root write proven; safety enforced daemon-side |
| **5** | `FanKit`: static floor (A-1), hysteresis, slew, watchdog, sleep/wake | First manual curve, in Balanced only |
| **6** | `ProfileKit`: profiles, rules, resolver, dwell, crossfade | Layered profiles live |
| **7** | Throttle detection, per-app rules, battery analytics | Feature complete |

Phase 3 before Phase 4 is deliberate: with history already recording, the first fan write becomes a measurable experiment instead of a guess.

**Status: all phases shipped.** The roadmap items that came after (T-1 through T-5 — concurrent-controller detection, battery/charge-limit surfacing, notifications, package power charting) are tracked and closed in `ISSUES.md`.
