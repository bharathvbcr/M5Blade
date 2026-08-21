# Fan_Control

A native Swift fan controller and system monitor for Apple Silicon Macs.

Design docs: [`FEASIBILITY.md`](FEASIBILITY.md) · [`AUDIT.md`](AUDIT.md) · [`DESIGN.md`](DESIGN.md) · [`UI.md`](UI.md) · [`ISSUES.md`](ISSUES.md)

> **This software can damage hardware.** It writes fan speeds directly to the
> SMC. Read `AUDIT.md` A-1 and A-2 before enabling control. No warranty.

---

## Status: Tested & Verified

The codebase is compiled, verified, and backed by a comprehensive test suite of 553 pure-logic and app unit tests (0 failures). Tested on Apple Silicon Macs (including M5 Pro on macOS 27.0).

Verified subsystems and safety guarantees:

1. **`SMCKeyData` struct layout** — verified 80-byte memory layout matching SMC driver requirements (`SMCConnection.open()`).
2. **HID sensor symbols** — resolved dynamically via `dlsym`; missing symbols degrade gracefully without crashing.
3. **SwiftUI/AppKit & Control Gate** — state machine validated with zero race conditions between user profile switches and the control tick (`ISSUES.md` I-3).
4. **Memory Metrics** — memory usage rendered in 1024-based GiB matching Activity Monitor (`App Memory + Wired + Compressed`) (`ISSUES.md` I-1, I-2).

## Requirements

- Apple Silicon Mac **with fans**. (MacBook Air is fanless — monitoring only).
- macOS 14+, Xcode command line tools.
- No Apple Developer account needed. Ad-hoc signing throughout.

## Build and probe — start here

```bash
make test     # pure-logic & system unit tests (553 tests, 0 failures)
make probe    # read-only hardware probe
```

`make probe` writes nothing. It reports your fan count, ranges, the mode key casing (`F0md` vs `F0Md`), whether `Ftst` exists, and your temperature sensors.

Expected on M5:

```
Mode key   : F0md
Ftst key   : absent — direct mode writes (M1 or M5 path)
Generation : M5-style — easiest case, no unlock needed
```

**If the mode key is not found, stop.** Fan control is unavailable on your hardware/OS combination; the monitoring half still works.

## Enable fan control

```bash
make app       # assemble and ad-hoc sign FanControl.app
make install   # installs the root helper — asks for sudo
```

`install-helper.sh` derives your app's cdhash and pins the helper's XPC listener to it. **Rebuilding the app changes the cdhash — re-run `make install`.** A helper with no requirement file refuses every connection by design.

Then open `Products/FanControl.app` and use the menu bar item.

## Menu bar

The status item shows a live temperature and rpm readout. **Left-click** opens the panel; **right-click** opens the control menu:

| Item | |
|---|---|
| Status + readout | Current mode, temperature, per-fan rpm. Non-interactive. |
| Profile | Silent · Balanced · Performance · Max Cooling · Stock, with the active one checked |
| Enable / Turn Off Fan Control | Reflects the current state rather than always offering "Enable". Disabled, with the reason shown, when the hardware doesn't support control. |
| Restore Automatic Control (`r`) | The panic path — hands the fans back to macOS |
| Show Panel | The live readout popover |
| Dashboard… (`d`) | Insights · Sensors · History — everything you read |
| Settings… (`,`) | Profiles, curves, automation — everything you change |
| Quit (`q`) | |

Two windows, split by what you do in them: **Dashboard** is read-only, **Settings** is where things change.

The app icon is generated from code by `Scripts/make-icon.swift`; run `make icon` to regenerate `Resources/AppIcon.icns` after editing it. `make app` does this automatically when the script changes.

## Auto mode

The menu bar's **Automatic — macOS Controls Fans** item (`a`) is the master switch, mirrored in Settings › General.

- **On** — macOS owns the fans; this app only watches. This is the default and the safe state, so turning it on always succeeds and takes effect immediately.
- **Off** — this app drives the fans from the active profile. Requires the privileged helper, and reports why if it can't.

The safety floor, thermal-pressure floor, and emergency release all remain in force whenever auto mode is off.

## Startup

Settings › General › **Open Fan Control at login** (`SMAppService`, per UI.md §10). macOS ties the registration to the app's *location and signature*, so moving the bundle or rebuilding it can silently invalidate it — the toggle reads its state back from the system rather than trusting a stored preference, and **Re-check** forces a refresh. This is only the menu bar app; the privileged helper is a LaunchDaemon that already starts at boot once installed.

## Profiles, curves, and automation

**Settings** (menu bar → *Settings…*, or `,`) has four tabs: General, Profiles, Curves, and Automation.

**Profiles** — a profile is a set of per-fan curves plus a ceiling and the responsiveness settings (hysteresis, ramp up/down, smoothing). The five built-ins are editable but not deletable; every fallback path resolves to one, and the panic path resolves to Stock. Add your own with `+`, or duplicate a built-in as a starting point. *Make Default* sets the profile used when no rule matches.

**Curves** — drag a point to move it, click empty space to add one, *Remove Point* to delete. The shaded red band is the safety floor: points are clamped out of it during the drag, so an unsafe curve cannot be authored at all. The dashed orange line is the profile's ceiling; the green line is the current temperature. Nothing reaches the fans until *Apply*.

**Automation** — rules switch profiles for you. Conditions available:

| | |
|---|---|
| Thermal pressure ≥ *level* | macOS's own signal — the most trustworthy input available |
| An app is running and busy | Pick from live processes; matches on ≥ N% CPU sustained for N seconds |
| Frontmost app is *bundle id* | |
| CPU under sustained load | |
| Power source / battery below N% | |
| External displays / displays asleep | |
| macOS Low Power Mode | |

Rules are checked top to bottom and **the first match wins**, so drag to reorder. *Wait before switching* (debounce) stops a brief spike changing profiles; *Hold after switching* (dwell) stops rapid flapping. A rule that can never match — no conditions, or an empty app name — is flagged inline, and the rule that is winning right now is badged `NOW`.

Per-app CPU only covers processes your own user account owns; the app does not elevate to see root's.

## Dashboard

Menu bar → *Dashboard…* (`d`). Three pages over one set of data.

**Insights** — why it got hot. Leads with what the machine is doing right now, then lists the sudden rises it has recorded, each with a named cause and the measurements that cause was inferred from. *Show on chart* scrubs the History page to that moment, which is the reason these are one window rather than three.

**Sensors** — every temperature sensor the machine exposes, grouped by subsystem (CPU, GPU, SoC, Memory, Storage, Battery, Power, Display, Ambient, Other) with a live Swift Charts plot per group. Expand a group for per-sensor rows and an explanation of what it covers.

**History** — the recorded chart, throttle episodes, sessions, and export.

Two things worth knowing about Apple Silicon sensors:

- Apple's HID hub reports **die temperatures without saying which block each one sits on**, so on an M-series Mac most sensors land under **SoC** rather than CPU or GPU. Groups with no sensors are hidden rather than shown empty — an empty "GPU" heading would imply a reading exists and is broken. Macs that do expose `eACC`/`pACC`/`GPU` sensors get those groups populated.
- **Names are not unique.** This Mac reports three sensors called `PMU tdie1` and six called `gas gauge battery`. They're distinct physical sensors, numbered in the UI only where the name is ambiguous.

### History

Two separate things, deliberately:

- `LiveWindow` is a rolling 15-minute in-memory tier, forgotten on quit, behind the popover sparklines and the Sensors page plots. A popover should never wait on a database.
- `HistoryStore` persists to `~/Library/Application Support/FanControl/history.sqlite` and backs the History page. Three tiers, each a downsample of the one before: raw seconds for 2 hours, minute aggregates for 14 days, hour aggregates for 2 years. Rollup is watermarked, so it costs the same whether the database is a day or a year old. The History page shows the size and can clear it.

Both tiers live in `HistoryKit`, are written from the same batch each tick, and share one key space — so a series drawn live and the same series read back from disk are the same series, not two things that happen to look alike.

The retention scheme rests on one invariant: **nothing is deleted that has not been folded into the next tier.** Pruning is gated on the rollup watermark rather than on the clock, so a rollup that stalls makes a table grow — visible and recoverable — instead of quietly destroying data. A clock corrected backwards winds the watermark back rather than stranding it in the future, and a sample that lands behind the watermark (a write buffered while the disk was unavailable) winds it back far enough to catch that sample too.

Writes that fail are retried rather than dropped, up to an hour's worth. Past that the oldest ticks *are* dropped — and counted, and shown on the History page, because a gap in a chart should be explainable by something the app tells you rather than by memory it quietly threw away.

Recording runs whether or not fan control is on — that is the point of building history before control, since it makes the first fan write a measurable experiment rather than a guess.

Throttle episodes are declared by signal fusion, never by "clock below max": sustained demand must gate, and then either `thermalState ≥ serious` or two supporting signals (package temperature, a fan already at its ceiling). Episode **attribution to applications is off by default** — turning it on stores a timestamped record of what you run, and exports say so before writing it.

### Spikes

A throttle episode answers "did the machine run out of cooling headroom?", which needs sustained heavy load. That deliberately misses the event people actually notice — the fans ramping hard out of nowhere for ninety seconds — so those left no trace at all.

`SpikeDetector` watches the *shape* of the temperature trace instead of its level: a climb of ≥ 12 °C inside a 2-minute trailing window, peaking at ≥ 70 °C. It closes when the temperature gives half the climb back for 30 seconds, at the last instant it was still elevated — and after half an hour it closes regardless, because a machine that stays hot is a workload, not a spike.

Each spike stores **evidence, not a verdict**: where it started and peaked, load at both ends, which sensor group was hottest, fan rpm and duty at the peak, the profile (and whether it changed mid-rise), and the applications that owned the CPU-seconds. `SpikeExplanation` turns that into a sentence, so improving the wording is a change to one pure function rather than a schema migration and a wait for the next spike. Attribution measures CPU-seconds, so an application is only *blamed* when load actually rose — otherwise whatever happened to be running during a graphics spike would take the credit.

Application names follow the same opt-in as episodes. Because collecting them means walking every pid, sampling is armed by the signal a spike is made of — the temperature climbing 5 °C inside a minute — rather than paid for continuously. Each spike records whether names were being collected at the time, so an empty list reads as "not recorded" years later rather than "nothing was responsible".

**Turning attribution off means forget, not stop adding.** Both detectors discard what they have already collected for the event in progress, and the open rows are rewritten without their names — otherwise the applications gathered before you said stop would keep being written and would travel into every later export. Completed records keep their names: a toggle that silently destroyed data you already had would be a delete button wearing a switch's clothes. Removing them is what *Clear History* is for, and it asks first.

### Bounds

Every accumulator in the pipeline is bounded by configuration rather than by what arrives, because "small × unbounded" is still unbounded:

| | bound | why |
|---|---|---|
| Trailing sample window | 4096 entries | time trims it, but a pathological sample rate outruns the trim between trims — the same cap `LiveWindow` keeps |
| Process attribution | 256 distinct names | a build system spawns a great many short-lived processes under different names; the accumulator would otherwise grow with the *variety* of what ran |
| Event rows | 2 years | episodes, spikes and sessions used to be kept forever. An event that outlives every sample in its own window is one the chart can never draw |
| Detector configuration | clamped at construction | a zero rise threshold declares a spike on every sample; a detector configured into nonsense fails closed, not loud |

A record still **open** is never pruned however old it is — it is the record of something that has not finished, and closing those is `finalizeDanglingRecords`'s job. The newest profile change is never pruned either: it is not an event with a duration but the statement "this profile from here on", so deleting it would leave the chart's first band unlabelled.

`FanKit.PlausibleTemperature` is the one definition of what counts as a reading (−50 … 200 °C, NaN and both infinities rejected). It exists because more than one module needs the rule and only one of them can see the sensor layer that used to own it privately: a sensor reporting `1e9` is finite, and it landed in the trailing window as a baseline no real reading could be measured against.

### Fan percentages

A fan has two different percentages and they are not interchangeable:

| | |
|---|---|
| **Duty** — `rpm / maxRPM` | What the dashboard shows. A fan idling at its 1350 rpm minimum reads ~25%. |
| **Control percent** — `(rpm − min) / (max − min)` | What curves are authored in. The same idling fan reads 0%, because 0% *means* "the fan's minimum". |

The dashboard previously showed the control percent, so a fan spinning at 1357 rpm displayed **0.2%** right next to its own rpm reading.

### Where it's stored

`~/Library/Application Support/FanControl/config.json`, written atomically on every edit. If it can't be parsed it is moved aside as `config.invalid-*.json` rather than deleted, defaults are loaded, and the reason is shown in Settings.

## Undo

```bash
make uninstall           # removes the helper, restores automatic control
sudo .build/release/smcfan auto    # immediate release, no uninstall
```

## CLI

```
smcfan probe            Verify hardware support (read-only)
smcfan fans             Fan rpm, target, mode
smcfan sensors          Temperature sensors
smcfan keys F0          Dump SMC keys with types and permissions
smcfan watch 60         Live readout
smcfan set 0 3000       Set fan 0 target        (root)
smcfan auto             Release all fans        (root)
```

`smcfan set` does **not** supervise the fan afterwards. It's a diagnostic, not a control mode. Use the app for anything sustained.

## Safety model

| Layer | Enforcement |
|---|---|
| Static safety floor | `SafetyFloor` — conservative curve, never learned (AUDIT A-1) |
| Thermal pressure floor | `ProcessInfo.thermalState` raises the floor independently of temperature |
| Emergency release | `.critical` or >100 °C releases the ceiling to 100% |
| Stale sensors | No valid reading for 10s → release to system mode |
| Daemon-side clamp | Helper re-clamps every request; assumes the app is compromised |
| Watchdog | Two missed heartbeats (12s) → helper releases all fans |
| Signals | SIGTERM/SIGINT/SIGHUP → release before exit |
| Sleep | Fans released before sleep, re-probed on wake |
| Quit | Sampler stopped and in-flight work superseded before the release |
| Transition exclusion | `ControlGate` — one fan-control operation at a time; a user action supersedes an in-flight tick (`ISSUES.md` I-3) |
| Curve editor | Points are geometrically clamped out of the floor region |

The curve ceiling defaults to **95%**, released to 100% only in an emergency.

## Layout

```
Sources/
  SMCKit/        IOKit transport — actor-serialized, no IOKit call outside it
  FanKit/        Curves, safety floor, control loop, SMC + simulated backends
  ProfileKit/    Profiles, rules, pure precedence resolver
  SensorKit/     HID temps, host metrics, process metrics, thermal state
  HistoryKit/    SQLite time series, retention tiers, throttle detection, export
  DaemonProtocol/ Shared XPC interface — deliberately minimal
  DaemonCore/    Daemon policy, write-only validation, hard floor & watchdog logic
  SimSupport/    Test-only thermal simulator, seeded trace generators, invariant checkers
  fancontrold/   Root LaunchDaemon
  smcfan/        Read-only probe CLI
  FanControl/    NSStatusItem app, popover, curve editor, history window,
                 ControlGate — exclusion + supersession for fan-control operations
Tests/           553 tests across 8 test suites (DaemonCoreTests, DaemonProtocolTests,
                 FanControlAppTests, FanKitTests, HistoryKitTests, ProfileKitTests,
                 SensorKitTests, smcfanTests)
```

Memory readouts follow Activity Monitor exactly: `used` is App Memory + Wired + Compressed, rendered in GiB — which is what macOS means by "GB" for memory (`ISSUES.md` I-1 and I-2).

## Task Roadmap & Future Work

Actionable tasks and open items tracked in [`ISSUES.md`](ISSUES.md):

- **T-1 (System / UX)**: Detect concurrent root fan controllers (e.g. Macs Fan Control) and display a warning banner (`ISSUES.md` I-9).
- **T-2 (SensorKit)**: Remove unreferenced public API `SystemMetrics.swapUsage()` (`ISSUES.md` I-10).
- **T-3 (Settings / PowerKit)**: Surface Battery Charge Limit (80%/100%) UI controls (`DESIGN.md` §8).
- **T-4 (Notifications)**: Dispatch UserNotifications on sustained throttle / thermal pressure (`DESIGN.md` §3.4).
- **T-5 (Dashboard)**: Add CPU/GPU Package Power charting in Swift Charts (`DESIGN.md` §8).

## Privacy

No network code. No telemetry, analytics, or crash reporting. The app requests no TCC permissions. SMC and sensor reads need no privileges; only fan writes use the root helper.
