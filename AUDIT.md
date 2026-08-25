# Design Audit — M5Blade

**Scope:** the architecture proposed in `FEASIBILITY.md`, audited for a Mac-only (Apple Silicon M5) environment.
**Date:** 2026-08-08 · **Status:** pre-implementation review

Severity: **C**ritical (will cause damage or a security hole) · **H**igh (will cause a rewrite) · **M**edium (will cause bugs) · **L**ow (polish)

---

## Summary

The feasibility architecture is sound in outline — unprivileged app, root daemon, XPC between them, floor-only override — but it has **two critical defects** that must be resolved before any code is written, and it is silent on several Mac-specific details that are reliable sources of subtle bugs.

The most important finding: **the baseline-learning scheme I proposed for the floor-only override does not work.** It is the load-bearing safety mechanism in the design, and as specified it produces a garbage floor. Section A-1 replaces it.

| # | Severity | Finding |
|---|---|---|
| A-1 | **C** | Baseline learning is unsound; the safety floor it produces is unreliable |
| A-2 | **C** | Root XPC service has no specified authorization model |
| A-3 | H | Single-fan assumption; M5 MacBook Pro has two fans with different thermal neighbourhoods |
| A-4 | H | No concurrency model — sensor, UI, and XPC contexts are undefined |
| A-5 | H | Hardcoded page size / timebase — the classic Intel→Apple Silicon porting bug |
| A-6 | H | Polling design will produce a bad Energy Impact score |
| A-7 | M | No macOS version gate on entering manual mode |
| A-8 | M | Display sleep, clamshell, and macOS Low/High Power Mode unaddressed |
| A-9 | M | `MenuBarExtra` is likely the wrong status-item API |
| A-10 | M | `F%dMn`/`F%dMx` absence not handled |
| A-11 | M | Rosetta / architecture detection absent |
| A-12 | L | No hardware abstraction for testing |
| A-13 | L | Units, formatting, and localization unspecified |

---

## A-1 · Baseline learning is unsound — **Critical**

**What the design says.** Establish `systemBaselineRPM` by sampling `F%dAc` while in auto mode, keyed by temperature, and use `max(userCurve, systemBaseline)` as the effective target.

**Why it fails.** Four independent problems:

1. **You cannot observe the baseline while you are overriding it.** The moment you enter manual mode, the signal you need disappears. The table is frozen at whatever it was when you took control and silently rots.
2. **Fan RPM in auto mode is not a function of current temperature.** `thermalmonitord` and `AppleCLPC` run a stateful closed-loop controller over thermal history, power delivery, and workload prediction. A `temp → RPM` table is a lossy projection of a controller with hidden state. Identical temperatures produce different RPM depending on trajectory.
3. **On Apple Silicon in system mode, fans idle at 0 RPM.** Sampling `F%dAc` in mode 3 mostly yields zero, so the learned floor would be ~0 across most of the temperature range — the exact opposite of a safety floor.
4. **It fails unsafe.** A safety mechanism whose failure mode is "floor = 0" is worse than no mechanism, because the design leans on it.

**Fix.** Drop learning. Replace with a three-part floor, each part independently sufficient:

```swift
floorRPM = max(
    staticFloor(for: maxTemp),        // compiled-in conservative curve, per-fan
    thermalStateFloor(ProcessInfo.processInfo.thermalState),
    fanMin                            // F%dMn when present, else a per-model constant
)
effectiveTarget = clamp(max(userCurve(temp), floorRPM), floorRPM, ceilingRPM)
```

- `staticFloor` is a conservative, deliberately-boring curve — not learned, not adaptive, reviewed by a human, and changeable only in code or an advanced setting.
- `thermalStateFloor` maps `.nominal → 0`, `.fair → 30%`, `.serious → 60%`, `.critical → 100%` (releasing the ceiling entirely). This is a public, documented Apple signal and is the most trustworthy input in the whole system.
- If you still want empirical grounding, add an explicit, user-initiated **calibration run**: hold auto mode under a synthetic load for a few minutes, record the `(temp, RPM)` trace with timestamps, and present it to the user as a *suggested* starting curve. Never apply it automatically.

**Corollary.** The claim "structurally impossible to cool worse than stock" in `FEASIBILITY.md` is too strong and should be struck. With a static floor the honest claim is: *the app will not command below a conservative floor, and yields entirely to the system on any anomaly.*

---

## A-2 · Root XPC service has no authorization model — **Critical**

**What the design says.** "For personal use you can relax the daemon's peer code-signature validation."

**Why it fails.** A root-owned Mach service advertised in a `LaunchDaemon` plist is reachable by **every process on the machine**, including sandboxed ones. With validation relaxed, any local code can command your fans to 0 RPM. That is a local denial-of-service against your own hardware and, more generally, an unauthenticated root-privileged control channel. "Personal use" does not change the threat model; it only changes who is likely to find it.

**Fix.** Always validate, even in the manual-install path. There is a cheap option that works without a Developer ID:

```swift
// Daemon side, in listener(_:shouldAcceptNewConnection:)
newConnection.setCodeSigningRequirement(
    "identifier \"com.you.FanControl\" and certificate leaf = H\"<cdhash>\""
)
```

Pin to the **cdhash** of your ad-hoc-signed app binary. Regenerate the requirement on each rebuild (a build script step). It is mildly annoying during development and it closes the hole completely.

Additional hardening, all cheap:

- The daemon's XPC interface should expose **only** `setTarget(fan:rpm:)`, `setMode(fan:_:)`, `heartbeat()`, `releaseAll()`. No generic `writeSMCKey(_:_:)` escape hatch — that turns the daemon into an arbitrary-SMC-write primitive.
- Clamp and validate **daemon-side**. The daemon must reject any RPM below its own hard floor regardless of what the app asked for. Assume the app is compromised.
- Set `MachServices` in the plist, not a filesystem socket. Do not make the helper binary world-writable (`chown root:wheel`, `chmod 755`).

---

## A-3 · Single-fan assumption — **High**

The design speaks in terms of "the fan" and `F0*`. M5 MacBook Pro has **two** fans; Mac Studio and Mac Pro have more. Left and right fans sit near different heat sources — on a MacBook Pro the left fan is typically nearer the SoC and the right nearer the power delivery and ports.

**Fix.** Model `[Fan]` from `FNum` throughout. Each fan gets its own curve, its own ceiling, its own floor, and — critically — its own **sensor mapping**: the set of temperature sensors that drive it, and a reduction (`max` is the right default). A single global curve driving both fans will run one of them harder than it needs to for its entire life.

**Status: done.** Per-fan curves shipped first; the *sensor mapping* did not — `FanCurve.sensorIDs` and `.reduction` were persisted to `config.json` and read by nothing, so `applyControl` fed the machine-wide maximum to every fan and a mapped curve behaved exactly like an unmapped one. Now wired through `FanCurve.input(readings:globalMax:)` → `ControlLoop.step(curveTempC:floorTempC:)`. The safety floor deliberately keeps reading the machine-wide maximum: mapping is a comfort optimisation, and a fan mapped to a cool sensor must still answer to a hot SoC.

---

## A-4 · No concurrency model — **High**

Unspecified, and this is where these apps break. Four contexts are in play: a 1 Hz sensor sampler, a slower process sampler, the SwiftUI main actor, and XPC reply blocks arriving on arbitrary queues.

**Fix.** Commit to Swift 6 strict concurrency from the start (retrofitting is miserable):

- `actor SensorReader` — owns the `io_connect_t`. IOKit connections are **not** thread-safe; serialize every call through this actor. This is the single most important rule here.
- `actor MetricsStore` — owns the SQLite handle.
- `@MainActor final class AppModel: ObservableObject` — the only thing SwiftUI observes.
- `final class DaemonClient: @unchecked Sendable` wrapping `NSXPCConnection`, hopping replies to a known executor.
- All value types crossing boundaries (`SensorSample`, `FanState`, `Profile`) are `Sendable` structs.

The daemon is a separate process and should be single-threaded on a serial queue. There is no reason for it to be concurrent, and every reason for it to be trivially auditable.

---

## A-5 · Page size and timebase hardcoding — **High**

The Mac-specific porting bug that bites almost everyone, and the design doesn't mention it:

- **Page size is 16384 bytes on Apple Silicon**, not 4096. `host_statistics64` returns page *counts*. Multiplying by a hardcoded 4096 under-reports memory by exactly 4×. Use `vm_kernel_page_size` or `sysctlbyname("hw.pagesize")`.
- **`mach_timebase_info` is 1:1 on Intel and not on Apple Silicon.** Code that treats `mach_absolute_time()` deltas as nanoseconds is correct on Intel and wrong on M-series. Always apply `numer/denom`, or use `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` and sidestep it.
- CPU tick math: `proc_pidinfo` returns Mach absolute time units, not ticks. Same conversion required.

Both of these are silent — no crash, just wrong numbers — which is why they survive into shipped builds.

---

## A-6 · Energy impact of the monitor itself — **High**

A thermal app that shows up high in Activity Monitor's Energy tab is self-defeating, and 1 Hz `Timer` polling from the main run loop is the usual cause: it defeats timer coalescing and prevents the CPU from reaching deep idle.

**Fix.**

- `DispatchSourceTimer` with generous `leeway` (≥10% of interval) so the system can coalesce wakeups.
- **Tiered sampling:** fan/temp at 1 Hz *only while a curve is active*; 0.2 Hz when idle; process list at 0.2 Hz; battery at 0.1 Hz.
- **Suspend on invisibility.** When the popover is closed and no manual curve is active, drop to 0.1 Hz. When the display sleeps, suspend entirely except the safety watchdog.
- Never redraw the status item text more than once per second.
- Measure this: run `powermetrics --samplers tasks` against your own bundle ID and treat >1% CPU average as a defect.

---

## A-7 · No macOS version gate — **Medium**

Apple has changed SMC fan behavior in every Apple Silicon generation and across point releases (the M5 lowercase-`F%dmd` change is exactly this). The design says "fail open" but never says *when to refuse to start*.

**Fix.** Maintain a `KnownGoodMatrix` of `(hardware model, macOS build) → verified`. On an unverified combination, start in **monitor-only mode**, surface a one-line banner ("Fan control unverified on macOS 26.5 — monitoring only"), and require an explicit user opt-in before the first manual write. This converts a silent-breakage risk into a visible, informed choice.

---

## A-8 · Display sleep, clamshell, and macOS power modes — **Medium**

Three Mac-specific states the design doesn't handle:

- **Display sleep** (`NSWorkspace.screensDidSleepNotification`) — back off sampling; the user cannot see the UI.
- **Clamshell / lid closed with external display** — thermal behavior changes materially (no keyboard-deck dissipation, and the machine is often on a desk with blocked vents). Detect via `IOPMCopyCPUPowerStatus` / display-count change and consider a dedicated profile.
- **macOS Low Power Mode / High Power Mode** — these are Apple's own thermal-envelope controls and they *interact* with your curve. Read them (`pmset -g`), display them, and let profiles react to them. Do not silently fight Low Power Mode; if the user has asked macOS to be quiet and cool, a Performance fan profile is a contradiction worth surfacing.

Also: `NSWorkspace.willSleepNotification` should proactively release to mode `0` *before* sleep rather than relying on the firmware reset and repairing on wake.

**Status: partly done.** Sleep/wake release and re-probe ship in `AppDelegate`; display sleep and external-display count are `Condition`s the rule engine can use; Low Power Mode is read and the Performance-while-low-power contradiction is surfaced (`AppModel.powerModeContradiction`). Writing macOS power modes remains deliberately unimplemented — see DESIGN §2.6. A dedicated clamshell heuristic is still not implemented.

Recovery across wake is now bounded rather than silent: manual mode is lost over sleep, so the first post-wake write is refused by the daemon, `AppModel.noteControlFailure` re-arms manual mode, and control resumes on the following tick. Before, the refusal was discarded and the app went on reporting "Controlling" while macOS drove the fans.

---

## A-9 · `MenuBarExtra` is probably the wrong API — **Medium**

`MenuBarExtra` (SwiftUI, macOS 13+) is convenient but constrained: limited control over the status item's rendering, awkward live-updating text/graphs in the menu bar itself, and known quirks with `.window` style dismissal. Every mature app in this category (Stats, iStat Menus, TG Pro) drives `NSStatusItem` directly.

**Fix.** Use `NSStatusItem` with an `NSHostingView` for the popover content. You keep SwiftUI for the interior and get full control over the bar item — which matters here, because a live temperature/RPM readout *in the menu bar* is the app's primary surface.

---

## A-10 · Missing `F%dMn` / `F%dMx` — **Medium**

The curve formula `rpm = Mn + (pct/100) * (Mx - Mn)` assumes both keys exist. They are not guaranteed on all models, and the research notes they are advisory even when present.

**Fix.** Treat them as `Double?`. Fall back to a per-model table, and if the model is unknown, fall back to monitor-only rather than guessing a range. Additionally: since `Mx` is advisory and real hardware exceeded it in testing, the "95% ceiling" should be computed against a **measured** maximum where available (observed peak `F%dAc`), with `Mx` as the initial estimate.

---

## A-11 · Architecture detection — **Medium**

Build **arm64-only**. If a universal or x86_64 build ends up running under Rosetta, `sysctl` values, page size, and timebase all report translated values and the SMC data-format branch (FPE2 vs IEEE-754 float) can be selected wrongly.

**Fix.** Check `sysctlbyname("sysctl.proc_translated")` at launch and refuse to run translated. Select the SMC data format from the **key's reported type from `readKeyInfo` (command 9)**, never from the host architecture — that's the robust discriminator and it costs one extra call.

---

## A-12 · No hardware abstraction for testing — **Low**

Everything in this app that can be tested without hardware — curve interpolation, hysteresis, slew limiting, profile resolution, rule precedence — is also everything that determines whether it is safe.

**Fix.** `protocol FanBackend` with `LiveFanBackend` and `SimulatedFanBackend`. The simulator models a first-order thermal system (heat in from a synthetic load, heat out proportional to RPM) so you can run the entire control loop in CI and assert invariants: *target never below floor*, *ceiling released on `.critical`*, *no oscillation over a step input*, *watchdog fires on a stalled heartbeat*.

---

## A-13 · Units and formatting — **Low**

°C/°F toggle, RPM, watts, mAh. Use `Measurement<UnitTemperature>` and `MeasurementFormatter` rather than manual conversion, and respect the system locale. Menu bar width changes as text changes — use a fixed-width font variant (`.monospacedDigit`) or the status item will jitter every sample.

---

## What the design got right

Worth keeping explicitly, since the list above is all criticism:

- Splitting privileged writes from unprivileged reads is correct and matches how every serious tool in this space is built.
- Keeping curve logic in the app and the daemon dumb is the right division — but only once A-2's daemon-side clamping is added.
- The floor-only *principle* is right even though the baseline mechanism was wrong; A-1 preserves the principle with a sound mechanism.
- Runtime capability probing over compile-time assumptions is the correct posture given Apple's per-generation churn.
- Phase 1 as read-only hardware verification before any write is the right sequencing.

---

## A-14 · Deep Audit Findings & Architectural Verification (2026-08-10)

A comprehensive code-level audit was conducted across all 11 modules then present (`SMCKit`, `FanKit`, `ProfileKit`, `SensorKit`, `HistoryKit`, `DaemonProtocol`, `DaemonCore`, `SimSupport`, `m5bladed`, `smcfan`, `M5BladeApp` — named `fancontrold`/`FanControlApp` at the time; the project has since been renamed M5Blade. `PowerKit` and `CIOReport` arrived later with T-3 and T-5).

### Verified Subsystems & Guarantees:
1. **`SMCKeyData` Layout & Bounds:**
   - `SMCConnection.open()` validates `MemoryLayout<SMCKeyData>.stride == 80` before executing any IOKit transport calls.
   - `SMCKey.fan(index, suffix)` enforces strict 4-byte FourCC bounds, preventing index truncation bugs for fan indices $\ge 10$.
2. **Concurrency & Control Gate (A-4 Resolution):**
   - `ControlGate` eliminates race conditions between `releaseToStock` and in-flight control ticks via mutual exclusion (`exclusive()`) and epoch supersession (`supersede()`).
   - `tryExclusive()` skips sampling ticks when an operation is already in flight, avoiding UI thread queuing pile-ups.
3. **Memory Metrics & Underflow Protection:**
   - Memory usage mirrors Activity Monitor's decomposition (`App Memory + Wired + Compressed`) formatted in binary GiB ($1024^3$).
   - Page count arithmetic uses saturating subtractions (`saturatingDifference`), preventing unsigned 64-bit underflow crashes ($18.4 \times 10^{18}$ bytes).
4. **Data Persistence & Database Security (`HistoryKit`):**
   - SQLite uses `WAL` mode, `BEGIN IMMEDIATE` write transactions, `sqlite3_busy_timeout`, and watermarked downsampling retention tiering (raw seconds $\to$ minutes $\to$ hours).
   - Accumulators are strictly bounded (4096 trailing samples, 256 process names, 2-year event retention).
5. **Test Verification:**
   - All 553 unit and system tests across 8 test suites pass cleanly with 0 failures.

