# Issue log — reported defects, investigation, and disposition

**Date:** 2026-08-10 · **Machine:** Mac17,8 (Apple M5 Pro, 64 GiB), macOS 27.0 (26A5388g)
**Baseline before this work:** 515 tests, 0 failures · **After:** 553 tests, 0 failures

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

---

## Tasks & Action Items Roadmap

| Task ID | Target Area | Description | Priority | Status |
|---|---|---|---|---|
| **T-1** | System / UX | Detect concurrent root fan controllers (Macs Fan Control, etc.) and alert user (`ISSUES.md` I-9) | High | **Planned** |
| **T-2** | SensorKit | Remove unreferenced public API `SystemMetrics.swapUsage()` (`ISSUES.md` I-10) | Low | **Planned** |
| **T-3** | Settings / PowerKit | Surface Battery Charge Limit (80%/100%) UI controls (`DESIGN.md` §8) | Medium | **Planned (Phase 7)** |
| **T-4** | Notifications | Dispatch UserNotifications on sustained throttle / thermal pressure (`DESIGN.md` §3.4) | Medium | **Planned (Phase 7)** |
| **T-5** | Dashboard | Add CPU/GPU Package Power charting in Swift Charts (`DESIGN.md` §8) | Low | **Planned (Phase 7)** |

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

**Confirmed from this machine's own helper log** (`/var/log/fancontrold.log`),
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

**Fix.** `Sources/FanControl/ControlGate.swift`, a new component with two
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

**Tests.** `Tests/FanControlAppTests/ControlTransitionTests.swift` — 7 tests
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
this machine right now.** It writes the same SMC keys `fancontrold` does — `F0md`,
`F0Tg` and their fan-1 equivalents. Nothing in either product coordinates with the
other.

This matters for the report you filed. I-3 fully explains the failures in the log
and is fixed. But a second root writer can *independently* take a fan out of
manual mode underneath `fancontrold`, and the symptom would be indistinguishable:
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
