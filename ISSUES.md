# Issue log — reported defects, investigation, and disposition

**Date:** 2026-08-10 · **Machine:** Mac17,8 (Apple M5 Pro, 64 GiB), macOS 27.0 (26A5388g)
**Baseline before this work:** 515 tests, 0 failures · **After:** 553 tests, 0 failures
**Roadmap update (2026-08-21):** T-1 through T-5 implemented — **614 tests, 0 failures**, three consecutive runs.
**Enhancement pass (2026-08-21):** nine UX/perf enhancements implemented — **644 tests, 0 failures**.
**Hardening audit (2026-08-22):** eleven defects fixed across four subsystems — **675 tests, 0 failures**, soak seeds 1–10 clean, release build warning-free. See §Hardening audit below.
**Power telemetry fix (2026-08-22):** "0W" readout traced to broken platform Energy Model counters (powermetrics ground truth) plus three app-side fabrication defects — per-series withdrawal, zero-is-not-data, honest formatting. See §Power telemetry below.

Two symptoms were reported. Both were real, both are fixed, and the investigation
turned up seven further defects of the same class plus one environmental hazard
this codebase cannot fix on its own. Everything found is listed, including the
items deliberately left alone.

Severity: **C**ritical (can leave hardware unmanaged) · **H**igh (wrong output the
user acts on) · **M**edium (latent, or wrong under load) · **L**ow (polish)

| # | Sev | Finding | Status |
|---|---|---|---|
| I-1 | H | Memory "used" was the wrong page classes — under-reported by 5.65–8.15 GB | **Fixed** |
| I-2 | H | Memory rendered in GB (1e9) where macOS means GiB — 64 GiB shown as "69 GB" | **Fixed** |
| I-3 | **C** | Profile/Stock switch raced the control tick: spurious failure banner, and fans left armed with nothing driving them | **Fixed** |
| I-4 | H | Ticks could overlap, corrupting the CPU-delta window behind the "Load" readout | **Fixed** |
| I-5 | M | A CPU sample that could not be computed was reported as 0% | **Fixed** |
| I-6 | M | Quit had no supersede barrier; only sleep did | **Fixed** |
| I-7 | M | `AppModel`'s control-state machine had no test seam and therefore no tests | **Fixed** |
| I-8 | L | `applyForTesting` could build a state the running app cannot reach | **Fixed** |
| I-9 | **C** | A second fan controller (Macs Fan Control) is installed and running as root on this machine | **Open — needs a decision from you** |
| I-10 | L | `SystemMetrics.swapUsage()` is public API with no caller | Open — left alone |
| I-11 | H | A refused pre-sleep release left the fans pinned and said nothing | **Fixed** (found by the new soak) |
| I-12 | **H** | macOS 27 beta maintains no Energy Model telemetry on this machine — `powermetrics` itself reports **0 mW** for CPU/GPU/ANE/DRAM/Combined — and the app turned that into a permanent fabricated "0W" readout | Platform: unfixable here, recheck each beta. App: **Fixed** (see §Power telemetry below) |

---

## Tasks & Action Items Roadmap

| Task ID | Target Area | Description | Priority | Status |
|---|---|---|---|---|
| **T-1** | System / UX | Detect concurrent root fan controllers (Macs Fan Control, etc.) and alert user (`ISSUES.md` I-9) | High | **Done** |
| **T-2** | SensorKit | Remove unreferenced public API `SystemMetrics.swapUsage()` (`ISSUES.md` I-10) | Low | **Done** |
| **T-3** | Settings / PowerKit | Surface Battery Charge Limit (80%/100%) UI controls (`DESIGN.md` §8) | Medium | **Done** — read-only surfacing + opt-in write path (see §T-3 below) |
| **T-4** | Notifications | Dispatch UserNotifications on sustained throttle / thermal pressure (`DESIGN.md` §3.4) | Medium | **Done** — see §T-4 below |
| **T-5** | Dashboard | Add CPU/GPU Package Power charting in Swift Charts (`DESIGN.md` §8) | Low | **Done** — see §T-5 below |

---

## I-1 · Memory "used" counted the wrong page classes — **High**

**Reported as:** "Memory and load reading differ from activity monitor."

**Measured, not inferred.** A probe reading the same `host_statistics64` sample two
ways, run twice on this machine several minutes apart:

```
                                          run 1      run 2
Fan_Control 'used' (active+wired+compressed)   35.80 GB   31.78 GB
Activity Monitor  (app+wired+compressed)       41.45 GB   39.93 GB
delta                                          -5.65 GB   -8.15 GB
```

**Cause.** `MemoryUsage.used` was `active_count + wire_count + compressor_page_count`.
`active_count` counts *file-backed* pages alongside anonymous ones, so it charged
the disk cache to the user while omitting the inactive anonymous pages that are
genuinely spoken for. Two errors pointing in opposite directions, which is why the
result looked like drift rather than a formula bug — the gap moves with how warm
the file cache is.

**Fix.** `Sources/SensorKit/SystemMetrics.swift` now mirrors Activity Monitor's
decomposition exactly:

```
Memory Used  = App Memory + Wired + Compressed
App Memory   = internal_page_count - purgeable_count
Cached Files = external_page_count + purgeable_count
free         = free_count - speculative_count      (read-ahead holds file data)
```

`MemoryUsage` gained `app` and `cachedFiles` and lost `active`, so the categories
now reconstruct the machine — an invariant a test asserts rather than a comment
that claims it. `pressure` was documented as "a usable stand-in for the macOS
memory-pressure indicator" and was `(wired+compressed)/total`, which is neither
that nor anything else; it now reads the same basis as `used`.

Every subtraction saturates. `0 - 1` on an unsigned page count is how a memory
readout comes to claim 18,446,744 TB, and two tests pin that shut.

**Tests.** `Tests/SensorKitTests/SystemMetricsTests.swift` — 15 tests, including
`testUsedIsNotTheOldActivePageFormula`, which computes the old formula and asserts
the difference rather than describing it.

---

## I-2 · Memory rendered with the storage convention — **High**

The second half of the same complaint, and independent of I-1. `physicalMemory`
on this Mac is 68,719,476,736 bytes — exactly 64 GiB, and exactly what Activity
Monitor and "About This Mac" both call **64 GB**. The popover divided by 1e9 and
rendered it **69 GB**, so even a perfectly correct `used` was being compared
against a total that disagreed with every other reading on the machine.

Memory is 1024-based on macOS; storage is 1000-based. `MemoryFormat` exists so
one place knows which is which, and `PopoverView` uses it.

---

## I-3 · Switching between a profile and Stock raced the control tick — **Critical**

**Reported as:** "switching between profiles and stock triggers fan failure
errors, but a second click resolves it."

**Confirmed from this machine's own helper log** (`/var/log/fancontrold.log` at
the time; the helper is now `m5bladed` logging to `/var/log/m5bladed.log`),
twice — 2026-08-08 23:41:12 and again 2026-08-10 18:55:22:

```
18:55:22.166  rejected setTarget: fan 0 is not under manual control — call setManualMode first
18:55:34.982  watchdog timeout — released 0,1
```

**Cause.** Everything in `AppModel` is main-actor, which prevents data races and
nothing else — `await` is a yield point, and both the 1 Hz sampling tick and a
user's click are full of them, across XPC to the helper. Pressing Stock ran
`releaseToStock` while a tick sat suspended inside `applyControl`. The tick
resumed after the release, wrote a target to a fan that was no longer armed, and
`DaemonCore` correctly refused it. The app read that refusal as "the daemon's
watchdog dropped us" — its documented meaning — and **re-armed manual mode**,
undoing the release the user had just asked for.

**The second log line is the severity.** The visible symptom was a banner reading
*"Fan control is failing: fan 2 — fan 1 is not under manual control"*. The
invisible one: 12.8 seconds later the fans were **still under manual control**,
while the app displayed "Watching" and had stopped sending heartbeats. Nothing in
the system was driving them, and nothing but the daemon's watchdog was left to
notice. A second click worked because by then no tick was in flight.

The daemon side never had this problem — `DaemonCore` is an actor, so its requests
serialise. The app was the outlier.

**Fix.** `Sources/M5Blade/ControlGate.swift`, a new component with two
mechanisms because the two failures are different:

* **Exclusion** — one fan-control operation at a time. A release can no longer
  land between a tick's `heartbeat` and its `setTarget`.
* **Supersession** — exclusion alone would make Stock wait for a tick that is
  mid-round-trip, so a user action bumps an epoch *synchronously* before it
  queues. The holder sees that at its next `await` and abandons without writing.
  Worst case for the panic button is one outstanding XPC request (bounded by
  `DaemonClient.requestTimeout`, 3 s), not a whole tick.

`releaseToStock` deliberately never aborts on supersede: handing the fans back is
idempotent and is the safe direction, and a release that gave up halfway would
leave exactly the half-owned state the panic button exists to eliminate. Arming
does the opposite — superseded mid-way, it releases what it took, because one fan
under this app and one under macOS is two controllers in one thermal envelope.

`start()`, `noteWillSleep()`, and the new `noteWillTerminate()` take the same
barrier.

**Tests.** `Tests/M5BladeAppTests/ControlTransitionTests.swift` — 7 tests
driving a simulated helper that refuses writes to unarmed fans exactly as
`DaemonCore` does. Verified in both directions: with the gate neutered, 6 of the 7
fail and reproduce the logged operation sequence verbatim —

```
[version, arm(0), arm(1), heartbeat, setTarget(0), releaseAll, setTarget(1) refused, arm(0), arm(1)]
```

— including the exact banner text the user saw.

---

## I-4 · Overlapping ticks corrupted the load readout — **High**

The second half of "memory and load reading differ from activity monitor".

`cpuUsage()` differences per-core tick counters against the previous call and
stores the new sample. A tick that ran long — 85 ms of sensors, plus up to three
XPC round trips of up to 3 s each — was still running when the 1 Hz timer fired
the next one, and nothing prevented the second from starting. Two concurrent
calls meant one of them differenced counters over a window of a few milliseconds
that had never elapsed as a sample interval, producing a load figure that was
noise. The same overlap gave the control loop a wrong `dt` and wrote two history
samples at nearly the same timestamp.

**Fix.** The tick takes the gate with `tryExclusive` and *skips* rather than
queues — a sampler that piled up behind a 15-second arm would afterwards run a
burst of stale ticks, each differencing a window that never happened.
`testATickCannotStartWhileAnotherIsMidWrite` holds one tick open at its first
write and asserts a second never reaches one.

---

## I-5 · An uncomputable CPU sample was reported as 0% — **Medium**

`cpuPercent = systemMetrics.cpuUsage()?.total ?? 0`. `cpuUsage()` returns nil when
it has no previous sample to difference against — the first tick, and any tick
whose window was too short to accumulate a scheduler tick. Reporting that as 0% is
not "we do not know", it is a claim that the machine is idle, and it is also what
a fan curve would act on if one were ever mapped to load. `AppModel` now holds the
previous value instead. Same treatment for `memoryUsage()`.

---

## I-6 · Quit had no supersede barrier — **Medium**

`shutdownFansAndFlush` runs deliberately *off* the main actor (that is a
deadlock fix, documented in place) and so cannot take the gate. Sleep called
`noteWillSleep` first, which stops the app claiming control; quit called nothing.
A tick suspended mid-`applyControl` could therefore resume after the quit release
had completed, see its target refused, and re-arm on an app in the act of exiting
— the same stranding as I-3, with no live app left to recover. `noteWillTerminate`
now bumps the epoch and cancels the sampler before the release.

---

## I-7 · The control-state machine had no tests — **Medium**

`DaemonClient` was constructed inline by `AppModel`, so the logic deciding when
fans are armed, when they are handed back, and what the app claims to be doing
could only be exercised against a root daemon, an installed launchd job, and real
hardware. It had no tests at all — which is why a critical defect's only evidence
was a line in a log file on a real machine.

`FanControlChannel` extracts the five operations `AppModel` uses; `DaemonClient`
conforms unchanged and is still the default. This is the same seam the config,
history, and defaults stores already had, applied to the one dependency that had
been missed.

---

## I-8 · A test fixture could build an unreachable state — **Low**

`applyForTesting(fans:)` set `fans` without building `loops`. `applyControl` skips
any fan with no loop, so a test posed against that fixture would appear to drive
two fans while silently exercising nothing. It now builds them the way
`performStart` does.

---

## I-9 · A second fan controller is installed and running — **Critical, open**

Found while confirming the helper's state, not reported:

```
system/com.crystalidea.macsfancontrol.smcwrite = { state = running }
pid 582  /Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite
```

**Macs Fan Control's privileged SMC-write helper is loaded and running as root on
this machine right now.** It writes the same SMC keys `m5bladed` does — `F0md`,
`F0Tg` and their fan-1 equivalents. Nothing in either product coordinates with the
other.

This matters for the report you filed. I-3 fully explains the failures in the log
and is fixed. But a second root writer can *independently* take a fan out of
manual mode underneath `m5bladed`, and the symptom would be indistinguishable:
`rejected setTarget: fan N is not under manual control`. The fix makes the app
stop *causing* that; it cannot stop another program causing it.

I have not touched it — unloading another vendor's privileged helper is your call,
not mine. To rule it out as a contributing factor:

```bash
sudo launchctl bootout system/com.crystalidea.macsfancontrol.smcwrite
```

If the rejections stop recurring afterwards, both causes were present. If you want
to keep both installed, the app's watchdog and daemon-side clamp will keep the
hardware safe, but the two will keep fighting over the fans.

---

## I-10 · `swapUsage()` has no caller — **Low, left alone**

`SystemMetrics.swapUsage()` is called by nothing in the app, the daemon, the probe,
or the tests. It is correct, it is public API of the `SensorKit` product, and
deleting a product's public surface is a different decision from fixing a bug —
so it is recorded here rather than removed. `MemoryUsage.pressure` was in the same
position but was also *wrong*, so it was corrected rather than left.

---

## I-11 · A refused release before sleep was silent — **High**

**Not reported, and not found by reading the code — found by the fault soak added
for I-3**, which is the point of writing one.

`noteWillSleep()` sets the app to "Watching" and `shutdownFansAndFlush()` then
performs the release. That function runs deliberately off the main actor (a
documented deadlock fix) and therefore cannot report its own failure, and both
call sites discarded its return value. So when the helper refused the release —
`refuseRelease` in the simulation, a busy or wedged helper in life — the machine
went to sleep with the fans **still pinned under manual control** while the app
displayed a calm "Watching" with nothing wrong.

Structurally identical to I-3: the app quiet about fans it could not release. The
daemon's watchdog still recovers the hardware, which is not a reason for the app
to keep it to itself.

**Fix.** `main.swift`'s sleep handler is already on the main thread waiting on
that release, so it is the one place that can both know the answer and say it. It
now carries the result back through a small box and calls the new
`AppModel.noteReleaseUnconfirmed()`, which sets a status and a banner. A timeout
is treated as unconfirmed too — "we never found out" is not "it worked".

Quit deliberately does *not* do this: there is no app left to show a banner to,
and `noteWillTerminate` (I-6) has already stopped anything from re-arming.

**Tests.** `testAnUnconfirmedReleaseBeforeSleepIsSurfaced`, plus the soak that
found it.

---

## Before you run the new build

`make app` re-signs the bundle, which changes its cdhash — and the helper pins
the cdhash of the build that installed it:

```
pinned by the installed helper : eff0d6822cb96f970a3366384de0cc9142590c16
this build                     : ab6aa935fd5a31d832b290f75adb2cb52913c8e9
```

Until the helper is re-installed it will refuse every connection from the new
app, and the app will report *"the helper could not be reached … its pinned
signature is stale"*. That is the pinning working, not a new fault. Re-run:

```bash
make install
```

---

## Verification

| What | Result |
|---|---|
| Test suite before any change | 515 tests, 0 failures |
| Test suite after | **553 tests, 0 failures**, three consecutive runs |
| I-3 regression tests against the pre-fix code | 6 of 7 fail, reproducing the logged operation sequence and banner text verbatim |
| Randomised transition soak | 150 iterations, each clicking into a window where a tick is provably mid-write |
| Control soak, healthy helper | 200 iterations |
| Control soak, faulty helper | 200 iterations with refusals, unreachability, and third-party fan grabs |
| Seed sweep | seeds 1–5 confirmed clean; a 30-seed sweep was still running when this was written — the compiled-in seeds are the ones under test by default |
| Memory formula | Fabricated kernel samples, plus a live coherence check; cross-checked against `vm_stat` and `memory_pressure` |
| CPU formula | Measured against `top` over the same window — 29.11% computed vs 26–30% reported |
| Release build | Clean, no warnings |
| Read-only hardware probe | Passes; both fans reported on auto |

Reproduce the seed sweep with:

```bash
for s in $(seq 1 30); do FANCONTROL_SOAK_SEED=$s swift test --filter "ControlSoakTests|ControlTransitionTests"; done
```

---

## Deliberately not changed

* **`DaemonCore` and the helper.** Audited alongside the app; the actor already
  serialises every request, the watchdog's clock handling is sound, and
  `DaemonSoakTests` already asserts the daemon-versus-hardware invariant this
  work needed on the app side. No changes were required.
* **The CPU percentage formula.** Suspected, then measured against `top` over the
  same window: 29.11% computed against `top`'s 26–30%. The formula is right; the
  overlap in I-4 was what made the readout wrong.
* **The `Ftst` unlock path.** Investigated because "a second click resolves it"
  matches the M3/M4 `thermalmonitord` unlock, then ruled out: this is an M5 Pro,
  `Ftst` is absent, and the helper logs `M5-style: direct mode writes, no unlock
  needed`. Left untouched.

---

## Roadmap implementation notes (2026-08-21)

### T-1 · Concurrent controller detection — **Done**

`Sources/M5Blade/ConcurrentControllerDetector.swift`. Verified unprivileged
detection is possible on this machine: `/Library/LaunchDaemons/*.plist` are
world-readable (Macs Fan Control's job confirmed present), and
`sysctl(KERN_PROC_ALL)` reports all 135 root processes with uid and the
16-byte command name — `proc_name()` returns nothing cross-user. Matching
survives kernel truncation (`com.crystalidea.macsfancontrol.smcwrite` →
`com.crystalidea`). Known signatures for Macs Fan Control, TG Pro, iStat Menus,
smcFanControl and Lubbbo plus a generic root-daemon-named-like-a-fan-tool rule;
Apple's own daemons and this app's helper are excluded by construction.
Surfaced as a banner in the popover, a section in Settings → General, and a
unified-log notice; re-scanned at most once a minute from the sampling tick.

On this machine today the detector reports *Macs Fan Control — installed*
(plist + helper binary present, not currently running). I-9's advice stands:
`sudo launchctl bootout system/com.crystalidea.macsfancontrol.smcwrite`, or
delete both files, to rule it out.

### T-2 · `swapUsage()` removed — **Done**

Deleted; no references existed outside ISSUES.md/README.

### T-3 · Battery & charge limit — **Done**, two stages

Measured first: this Mac17,8 exposes 3626 SMC keys and **neither CHWA nor BCLM
is among them**; `AppleSmartBattery` carries health data but no temperature or
permanent-failure keys. Byte semantics were verified against `zackelia/bclm`
(CHWA: `0x01`=80 %, `0x00`=full; BCLM: percent) rather than folklore.

Stage A (`Sources/PowerKit/BatteryHealth.swift`): unprivileged IORegistry read
of charge %, cycle count, Apple-smoothed and raw capacity figures — both shown
together with DESIGN §6.2's disagreement explained, never alone.

Stage B (`ChargeLimit.swift`, `ChargeLimitController.swift`,
`DaemonCore/ChargeLimitPolicy.swift`): XPC `getChargeLimit`/`setChargeLimit`,
daemon-side validation to exactly {80, 100}, capability gate, no-battery gate,
and a mandatory read-back that treats "firmware ignored it" as failure. All of
it sits behind an explicit opt-in toggle default-off, because §6.3 recommends
against third-party limiting. Two measured caveats surfaced honestly in the UI:
this Mac has no key (controls disabled with an explanation pointing at System
Settings), and macOS ≥ 15 refuses these writes to non-Apple processes even as
root.

### T-4 · Throttle notifications — **Done**

`ThrottleAlerter.swift`: pure decision engine + `UNUserNotificationCenter`
delivery behind a protocol. Rules per DESIGN §3.5 — authorization requested
lazily on the first alert-worthy event, one alert per episode after 120 s
sustained, ≥ 15 min between any two alerts, repeats coalesced into "Nth episode
in the last hour", `.critical` pressure alerts without the load gate but under
the same limiter, recovery deliberately silent. Events ride on the same
`HistoryRecorder.record` transition the recorder persists, so what history
records and what the user was told cannot drift. Ambient case handled by the
status item: orange while throttling or pressure ≥ serious, red at critical,
plus an accessibility value. A General-tab toggle turns the feature off without
touching history or detection; a denial is recorded once, never re-prompted.

### T-5 · Package power — **Done**, with one honest limitation

New `CIOReport` target wraps libIOReport (the symbols left IOKit's tbd in
macOS 27). Signatures were *measured*, not assumed: this generation takes five
arguments on `IOReportCopyChannelsInGroup`, returns a query dictionary, needs a
mutable copy passed to subscription with a **NULL task port** (a real port
faults inside libIOReport), and names channels via
`IOReportChannelGetChannelName`. Arithmetic is unit-tested directly; a physics
ceiling rejects unit mix-ups as "no data" instead of drawing megawatts.

Measured limitation: on this macOS 27 beta / M5 Pro firmware the CPU Energy
counter does not accumulate (zero delta under idle *and* four `yes` burners),
and GPU Energy deltas are ~2×10⁹/s — implausible under any sane unit. Ten
consecutive motionless samples withdraw the reading entirely. So power series
are absent here by design: a dead counter must not draw an idle-cool machine
(DESIGN §2.1's quietest-failure rule). `smcfan power` remains for verifying
channels on other machines/releases.

### Verification

| What | Result |
|---|---|
| Test suite | **614 tests, 0 failures**, three consecutive runs (baseline 553) |
| New suites | ConcurrentControllerTests 17 · ThrottleAlerterTests 17 · PowerKitTests 9 · ChargeLimitModelTests 5 · AlertAndDetectorStressTests 3 · PackagePowerTests 10 |
| Soak seeds 1–5 | ControlSoakTests + ControlTransitionTests clean |
| Randomised alert soak | 6 seeds × 3000-event streams: no alert pair closer than 15 min; none under threshold; critical-only pressure wording holds |
| Detector fuzz | 200 random plist/process worlds: own helper and Apple daemons never reported, output deduped and sorted, every report evidenced |
| Release build | Clean, no warnings; `make app` + `make verify` pass |
| Live probe | `smcfan probe`, `smcfan keys`, `smcfan power` against real hardware |

### Deliberate gaps

* Charge-limit controls are inert on hardware without CHWA/BCLM — measured true
  here, and expected to become the common case.
* Power charting is inert where the Energy Model counters are frozen or
  rescaled — currently true on this machine; `smcfan power` decides per host.

---

## Enhancement pass (2026-08-21)

Nine improvements, each verified by tests that fail against the pre-change
code where the change is logic. 614 → **644 tests**, all passing; release
build clean.

| # | Area | What changed |
|---|---|---|
| E-1 | Curve editor | Keyboard operation (UI.md §3): handles are focusable buttons — Tab walks them, arrows nudge (Option = fine step), Delete removes. Plus a point table: one editable numeric row per point. All three input paths share `clampedMove`, so the keyboard and the table cannot author a curve the drag cannot. |
| E-2 | Reduce Motion | The nudge animation honours `accessibilityDisplayShouldReduceMotion`. A grep-verified audit found no other animated surface in the app to honour it on; the constraint now has a caller so it cannot be forgotten when motion appears. |
| E-3 | Charts a11y | History and Sensors plots expose full audio-graph descriptors (`ChartAccessibility`): epoch-second x-axis with a time-rendering provider (the API has no date axis), y-range bracketing every series, points capped at 120 per series keeping both endpoints. |
| E-4 | Undo | Every curve-draft edit is ⌘Z-able via the environment undo manager through one `mutate` choke point that refuses no-op writes; one drag is one undo entry. `registerUndo(withTarget:)` needs a class, so the target is a small box reading/writing the draft's `@State` storage through closures. |
| E-5 | Stale fan readings | A failed fan read used to leave a frozen rpm on screen forever looking live (`AppModel.sample`'s `try?`). Readings now carry their last-success timestamp (`readingsUpdatedAt`); past `readingStalenessLimit` (10 s, mirroring `ControlLoop.stalenessLimit`) the popover shows a *stale* badge and VoiceOver reads "reading out of date". |
| E-6 | Diagnostics | `DiagnosticsReport` + **Copy Diagnostics** in Settings › General: status, fans (with staleness), problems, settings, platform, and the last 20 control-state transitions. All `status` writes now flow through `setStatus(_:reason:)`, which records changes only — `applyControl` restates `.controlling` every tick and would otherwise flood the log. Bounded at 100 entries. |
| E-7 | Status-item readout modes | Full / temperature-only / icon-only (`StatusDisplayMode`), persisted and re-read defensively; formatting lives in one pure function (`StatusDisplayMode.title`) that tests pin for all three modes including missing-data placeholders. |
| E-8 | Watching sampling rate | Optional 15 s cadence while macOS owns the fans (`WatchingSampleRate`), default unchanged at 5 s. Control stays 1 Hz (AUDIT A-6). The trade — coarser history while watching — is stated in the toggle, not discovered later. |
| E-9 | PackagePower dormancy | After a counter is declared frozen, IOReport queries stop entirely until a probe due 10 minutes later; waking from dormancy re-baselines rather than differencing across the gap (which would report microwatts). On this machine — dead counters since macOS 27 beta — this removes a wasted subscription+sample pair from every tick. |

Process-walk gating (the other candidate under E-9) already existed:
`needsProcessSampling` gates the pid walk on an open automation editor,
opted-in attribution above its demand gates, or live per-app rules.

### Verification

| What | Result |
|---|---|
| Test suite | **644 tests, 0 failures** (baseline 614); release build clean, no warnings |
| New suites | StatusPreferenceTests 9 · DiagnosticsReportTests 8 · ChartAccessibilityTests 6 · EnhancementRenderTests 4 · plus render coverage of the stale badge and new Settings sections |
| Descriptor data | Values round-trip through `AXDataPoint` (unpacked via KVC — the wrapper's Swift property name is ambiguous); empty input yields valid axes, not refused ranges |
| Curve-editor invariants | Drag/keyboard/table all route through `clampedMove`; render-tested at 2 and at the 12-point cap |

---

## Hardening audit (2026-08-22)

A four-subsystem audit (sensors, history, daemon, app) found eleven defects.
Every logic change ships with a test that fails against the pre-fix code.

| # | Sev | Finding | Fix |
|---|---|---|---|
| H-1 | **H** | `AppModel` held the last temperature set forever when reads came back empty — fan curves evaluated a frozen input and `ControlLoop`'s stale-data release was unreachable after the first success | `temperaturesUpdatedAt` + staleness limit; stale input feeds the loop as nil, which drives the designed hold-then-release ladder. Scripted sensor seam added so the production tick path is testable |
| H-2 | M | `SystemMetrics` minted a Mach send-right *reference* on every poll (`mach_host_self()` inline, never deallocated; ~2/tick at 1 Hz). Measured: urefs climb to the kernel's per-name ceiling of **65,535** after ~9 h of control, then pin — the kernel keeps returning the shared right, so readings do not die (an earlier draft of this row claimed they did); the defect is unbounded-by-design resource accounting, not an outage | Port acquired once through a factory seam, cached for process lifetime; a stress test asserts 800 polls move the kernel's reference counter by zero |
| H-3 | **H** | `LiveWindow` evicted a whole series when its key missed one batch — one failed fan read wiped up to 15 min of sparkline | Eviction keyed on newest-point age vs window, not batch presence |
| H-4 | **H** | `uninstall-helper.sh`'s fan restore checked `/usr/local/libexec/smcfan`, which nothing ever installs — the step never ran, and "Done." printed over possibly pinned fans | Uses the bundled tool beside the script, verifies mode read-back, honest failure text |
| H-5 | M-H | Legacy DB migration: three independent `try?` byte copies could tear a live WAL database, then latch the bad target forever | SQLite online-backup API; partial output removed on failure so next launch retries |
| H-6 | M-H | Daemon watchdog gave up permanently after ~6 s of refused releases — fans pinned until a client re-armed — while logging `.givingUp` at 1 Hz into an unrotated file (~7 MB/day) | One attempt per 60 s after the fast budget; give-up logged on transition only |
| H-7 | M | One finite garbage heartbeat (TTPD's −306783232 °C) disabled the daemon's independent hard floor | Heartbeat sanitized with `PlausibleTemperature.admits`; implausible → floor applies |
| H-8 | M | A transient SMC `open()` failure latched an empty sensor catalogue until relaunch | Failures leave the catalogue unset and retry on a 5 s cooldown; genuine no-keys answers still latch |
| H-9 | M | Counter reset across sleep produced genuine `0.0 W` instead of nil — violating PackagePower's own nil-vs-zero contract | Backwards delta → nil ("no measurement"); test re-pinned with justification |
| H-10 | M | First-run consent requested from the status-item menu was parked invisibly: the alert lives in popover/settings only | Menu actions that park consent open the panel, which hosts the dialog |
| H-11 | M | Give-up path labelled a live, answering helper "Helper not running" and offered reinstall | Release result decides: confirmed → Watching + clean; refused → Watching + explanation; unreachable → Helper-not-running |

Also fixed en route: `ChargeLimitPolicy` rejected `false` batteries but accepted *unreported* ones, contradicting its comment · `reconcileUnconfirmed` deliberately leaves the watchdog clock alone (documented — an unverified release means we hold the fan; startup adoption is the only case that grants grace) · notification denial was permanent for the process lifetime while the UI claimed System Settings would fix it — now retried on a 5 min cooldown and self-recovering · charge-limit UI stated "not supported" when the real state was "unknown" · CSV export honoured neither its own documented column contract nor formula-injection safety, and lacked a BOM · `clear()` reset recorder state before the fallible DB clear · config saves fired per keystroke/drag-tick, washing out the backup rotation during one drag (now coalesced 400 ms, flushed on quit) · export wrote silently or as a zero-byte file · installer booted out the working helper before staging its replacement and never verified process liveness; directories it relies on are now ownership-checked · `lastLoggedUnconfirmed` data race between overlapping watchdog tasks closed with scoped locking · dead `enableControl()` selector removed from StatusItemController.

### Verification

| What | Result |
|---|---|
| Test suite | **675 tests, 0 failures** (baseline 644); release build clean, no warnings |
| New suites/tests | LiveWindow eviction ×2 · SMC recovery ×2 · migration ×2 · heartbeat plausibility ×2 · charge-limit policy ×4 · temperature-staleness ×2 · give-up honesty ×1 · host-port ×1 · CSV contract ×1 · alert cooldown ×2 (one re-pinned with justification) |
| Control soak seeds 1–6 | ControlSoakTests + ControlTransitionTests clean per seed |
| Daemon/gate soak seeds 7–10 | clean per seed |
| Mach-port probe | 200k uncapped calls → urefs 1→65,535 then plateau; cached right flat across 200k polls — measured on this machine, and encoded as a permanent test |
| WarningBanner VoiceOver | fix follows Apple's combine-descriptive-content-only pattern; render tests guard layout. Headless runtime AX verification is impossible (SwiftUI builds its tree only when an assistive client attaches; the xctest runner gets AX cannotComplete −25208) — manual check with Accessibility Inspector: banner shows one static-text element "Warning. …" plus a separate focusable button. Not yet performed |
| I-9 Macs Fan Control | helper binary + LaunchDaemon plist still installed (root:wheel, Jul 11), service NOT loaded, no process running. Removal/disable requires sudo — commands left to the user below |
| `make app` + `make verify` | pass |

### Still needs you

```bash
# I-9: the plist in /Library/LaunchDaemons will be loaded at every boot until
# removed or disabled. bootout alone is moot while it isn't running:
sudo launchctl disable system/com.crystalidea.macsfancontrol.smcwrite   # survive reboots
sudo rm /Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist
sudo rm "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite"
```

---

## Power telemetry: "0W" in the panel (2026-08-22)

**Symptom.** The popover's watt readout showed `0W` permanently (or vanished).

**Investigation** — measured, not assumed:

* `smcfan power` reproduced it: CPU pinned at 0.00 W, GPU always "—".
* Raw IOReport probes: with six `yes` burners holding ~97 % CPU busy,
  `CPU Energy` and *every* cluster counter (`MCPU0/1`, `PCPU`, `PACC_*`,
  `MCPM*`, `PCPM`, `DRAM0`) sat at exactly +0 delta across 1 s, 2 s and 20 s
  windows for minutes; a single +36 M burst appeared once in ~2 min of
  probing. A brand-new subscription in a brand-new process reads the same
  frozen value byte-for-byte — the staleness is upstream of any subscription.
* The SMC's float `P*` keys move but are temperatures (36–63 under load that
  does not move them like watts), and battery amperage is 0 on AC — no
  alternative source exists on this hardware.
* **Ground truth**: Apple's own `sudo powermetrics` reports CPU Power
  **0 mW**, GPU Power **0 mW**, ANE/DRAM/Combined **0 mW** — macOS 27.0 beta
  (27A5416b), Mac17,8. The platform telemetry is broken below everything this
  app can reach.

Three app-side defects then converted a dead platform counter into a
confident lie, each now fixed with tests that fail against the old code:

| # | Defect | Fix |
|---|---|---|
| P-1 | An exact-zero delta passed the plausibility check and rendered as `0.0 W`. An idle package burns tens of millijoules per second against a one-mJ counter resolution, so zero over a real interval is firmware silence, never idleness | `watts(delta:)` maps zero to nil; the UI shows absence, not zero |
| P-2 | Frozen-counter withdrawal required *both* channels to freeze simultaneously (`cpuDelta == 0 && gpuDelta == 0`). The GPU channel ticks constantly here (with an implausible ~3×10⁹/s scale), so its motion reset the shared streak forever and CPU's zombie survived every check the class was written to enforce | Per-series state machine (`PackagePower.Series`): each channel tracks silence, implausibility and dormancy independently |
| P-3 | `%.0fW` rounded every reading below half a watt down to `0W` — on healthy machines too, indistinguishable from P-1's fabrication | `PowerText.watts`: one decimal below 10 W, integer above, `—` for absent; accessibility label uses the same text |

Hardening added while there: lazy-flush bursts are attributed across the
whole quiet span (a +36 M flush divided by one tick rendered as absurd
spikes; now averaged since the counter last moved, capped at 120 s);
implausible bursts count toward withdrawal exactly like silence; sleep-style
counter resets restart the accumulation window without counting as breakage;
both series withdrawn skips the IOReport query entirely (wake probe once per
10 min); `smcfan power` names the suspected cause when nothing measures; the
diagnostics report gained a Package power row so "why no watts?" is answerable
in-app. On healthy hardware nothing changes except honest sub-watt rendering:
counters that move every tick publish per-tick watts as before.

### Verification

| What | Result |
|---|---|
| Test suite | **697 tests, 0 failures** |
| New tests | 19 for this fix: per-series state machine ×12 (silent-run withdrawal, lazy-flush averaging, stale-window cap, same-instant resample, implausible run, single-glitch recovery, counter reset, missing channel, wake probe, steady tick, zero-delta policy, diagnostics summary) · watt formatter ×4 · report row ×1 · concurrent-sampling smoke ×1 · live plausibility re-pinned to reject zero |
| Live behaviour | `smcfan power`: `—` from tick 2 onward, withdrawal after the silent run, hint printed; matches `powermetrics`'s all-zero ground truth |

### Still needs you

Nothing actionable — but re-check `smcfan power` after each macOS beta bump.
When Apple fixes the counters, watts reappear with no code change; until then
their absence here is the designed, honest state.

---

## Panel availability readout (2026-08-22)

The popover's system row gained a second line: **available memory** and **free
disk space**. Requested for the expanded menu bar rather than the at-a-glance
title, whose width stays as it was.

* `MemoryUsage.available` is the complement of `used` on the same basis — not
  `free + cachedFiles`, an identity that fails by 4.6 GB on this very fixture,
  because the kernel's page categories do not sum to physical memory.
* Disk uses `.volumeAvailableCapacityForImportantUsageKey` — Finder's
  "available", which counts purgeable caches — formatted by the new
  `StorageFormat` (1e9-based): the storage convention `MemoryFormat`
  deliberately does not own.
* Sampled once per tick beside CPU and memory (one statfs call), published only
  on change like they are.

### Verification

| What | Result |
|---|---|
| Test suite | **704 tests, 0 failures** (baseline 697); release build clean |
| New tests | AvailabilityReadoutTests ×3 (tick wiring through the production path, render with the row, one-sided + absurd values) · SystemMetricsTests ×4 (complement definition including the identity it replaces, saturation, storage convention, live statfs) |
| Flake fixed en route | `testCPUPercentagesAreAWholeMachine` bounded `total ≤ 100` exactly; four rounded percentages were measured summing to 100.00000000000001 between two runs of the identical code — now checked with the same tolerance as the partition assertion above it |
