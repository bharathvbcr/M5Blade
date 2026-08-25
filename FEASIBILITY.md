# Native Swift macOS Fan Controller — Feasibility Assessment

**Target:** Apple Silicon M5 · **Signing:** free Apple Developer account · **Date:** 2026-08-08

> *Point-in-time study, written before implementation. The shipped project is
> **M5Blade**: the daemon binary is `m5bladed` (installed by
> `Scripts/install-helper.sh` with cdhash pinning per AUDIT A-2, not the manual
> `cp` sequence below), and the UI module is `Sources/M5Blade`. Names and
> commands below are the originals; see `README.md` for how it actually built.*

---

## 1. Verdict

**Monitoring: fully practical.** A complete system monitor (temps, per-core usage, memory, per-process tracking, power, fan RPM) is buildable in pure Swift with zero special permissions, zero TCC prompts, and no root. This is a solved problem with good open-source prior art.

**Fan control: practical on M5, but gated by one hard blocker.** The M5 generation is actually the *easiest* Apple Silicon target for fan control — easier than M3/M4 — but SMC writes require a process running as **root**, and the sanctioned install path for a root helper (`SMAppService`) wants a real signing certificate.

| Capability | Feasible? | Blocker |
|---|---|---|
| Read all sensors, fans, usage, processes | ✅ Yes | None |
| Write fan speed | ⚠️ Yes, with caveats | Needs root daemon |
| Ship a double-clickable app to others | ❌ No | Needs paid account ($99/yr) for Developer ID + notarization |
| Mac App Store distribution | ❌ Never | Sandbox forbids the `AppleSMC` IOKit user client |

**The workaround for personal use:** the Developer ID requirement applies to `SMJobBless`/`SMAppService`'s *installation* mechanism, not to the SMC write itself. The firmware only checks that the calling process is root. You can hand-install a plain `LaunchDaemon` (`sudo cp` the helper + a plist in `/Library/LaunchDaemons/`, then `launchctl bootstrap system`) with an ad-hoc-signed binary and get full fan control on your own machine today. It just isn't distributable.

**Confirm first:** M5 **MacBook Air is fanless**. Only MacBook Pro / Mac mini / Mac Studio M5 have controllable fans. If you're on an Air, this project is monitoring-only by physics.

---

## 2. Why M5 Is the Easy Case

Apple has been progressively locking down fan control across generations. The state of play, per [reverse-engineering research published Jan 2026](https://github.com/agoodkind/macos-smc-fan):

| Generation | Behavior |
|---|---|
| Intel / T2 | Direct `F0Md=1` + `F0Tg` writes. FPE2 (14.2 fixed-point, big-endian) data format. Trivial. |
| M1 | Direct `F0Md=1` works. IEEE-754 float, little-endian. |
| M2 | Undocumented; assume M1-like. |
| M3 / M4 | **Hardest.** `thermalmonitord` holds fans in mode 3 ("System Mode"); firmware rejects mode writes with SMC error `0x82`. Requires writing `Ftst=1`, waiting 3–6s for the daemon's `LifetimeServoController` to yield, then retrying. Requires a *persistent* root daemon — control reverts to mode 3 within seconds of the controlling process exiting. |
| **M5** | **Easiest of the Apple Silicon line.** The `Ftst` key **doesn't exist** (`readKeyInfo` → `SmcNotFound` `0x84`). No unlock sequence, no retry loop. Direct `F0md=1` then `F0Tg=<rpm>` succeeds immediately. |

**Critical M5 gotcha:** the mode key casing changed. It is `F%dmd` (lowercase `m`), **not** `F%dMd`. The uppercase variant returns `SmcNotFound`. Any implementation must **probe both casings at runtime** — this single detail is why several existing tools silently fail on M5.

### SMC keys you need

| Key | Type | Meaning |
|---|---|---|
| `FNum` | uint8 | Fan count |
| `F%dAc` | float | Actual RPM (read-only) |
| `F%dTg` | float | Target RPM (writable) |
| `F%dMn` / `F%dMx` | float | Recommended min/max — **guidelines, not enforced** |
| `F%dmd` (M5) / `F%dMd` | uint8 | Mode: `0`=auto, `1`=manual, `3`=system |

`Mn`/`Mx` are advisory only. Testing confirms targets below min, above max, and 0 RPM (fan fully stopped) are all accepted by firmware. **There is no hardware guardrail. Your software is the only thing standing between the user and a stopped fan under load.**

### IOKit transport

```
Service: AppleSMC · Connection type: 0 · Selector: 2 · Struct size: 80 bytes
Commands: 9 = read key info, 5 = read value, 6 = write value
```

Reads and writes use the identical `IOServiceOpen(..., 0, &conn)` + `IOConnectCallStructMethod` path. The read/write asymmetry is enforced **per-key in SMC firmware** via an attribute byte (bit `0x80` = read, bit `0x40` = write), not at the IOKit connection level. Practical consequence: **your unprivileged GUI app can read every sensor directly.** Only writes need the helper.

---

## 3. Architecture

```
┌─────────────────────────────────────────────┐
│  FanControl.app  (user, unprivileged)       │
│  ├── SwiftUI + MenuBarExtra                 │
│  ├── SMCKit (read-only) ──────► AppleSMC    │  ← no privileges needed
│  ├── HID sensor client   ──────► IOHIDEvent │
│  ├── Metrics collectors (host_*, libproc)   │
│  └── CurveEngine  ── computes target RPM    │
└──────────────┬──────────────────────────────┘
               │ XPC (NSXPCConnection, Mach service)
               ▼
┌─────────────────────────────────────────────┐
│  fancontrold  (root LaunchDaemon)           │
│  ├── validates + clamps every request       │
│  ├── independent safety watchdog            │
│  └── SMCFanKit (write) ────────► AppleSMC    │
└─────────────────────────────────────────────┘
```

**Keep the daemon dumb and paranoid.** The curve logic lives in the app; the daemon accepts only `(fanIndex, targetRPM)` and enforces its own hard floor and its own watchdog. Never let the daemon trust the app.

**Split it into SPM modules from day one:** `SMCKit` (transport, format conversion), `SensorKit` (HID + metrics), `FanKit` (mode/curve/safety), `fancontrold` (daemon), `FanControl` (UI). This is exactly how the reference implementation and Stats are organized, and it lets you unit-test the curve engine without hardware.

---

## 4. Monitoring Stack — What API for What

Everything here works **unprivileged, no entitlements, no TCC prompt**.

| Metric | API | Notes |
|---|---|---|
| Temperatures (Apple Silicon) | `IOHIDEventSystemClientCreate` + `kHIDPage_AppleVendor` / `AppleVendor_TemperatureSensor` | **Private API.** The only practical route on M-series. Sensor keys change every SoC generation — build a per-chip lookup table and degrade gracefully on unknown chips. |
| Temperatures (fallback) | SMC `T*` keys | Sparser on Apple Silicon than Intel. Use as secondary. |
| Fan RPM | SMC `F%dAc` | Read-only, unprivileged. |
| Power / voltage / current | SMC + `IOReport` | `IOReport` (private but stable) gives CPU/GPU/ANE power without root — the no-sudo alternative to `powermetrics`. |
| CPU usage (system + per-core) | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | Public. Delta two samples. |
| Memory | `host_statistics64(HOST_VM_INFO64)` + `sysctl vm.swapusage` | Public. Compute "memory pressure" as `(wired + compressed) / total`. |
| Per-process CPU/memory | `proc_listpids` → `proc_pidinfo(PROC_PIDTASKINFO)`, `proc_pid_rusage` for `phys_footprint` | Public. **Limitation: cannot read processes owned by other users or root without elevation.** Your daemon can fill this gap over XPC if you want a complete process list. Consider [Swift System Metrics](https://www.swift.org/blog/swift-system-metrics-1.0-released/) for a stable wrapper. |
| GPU utilization | IORegistry `IOAccelerator` → `PerformanceStatistics` dict | Gives "Device Utilization %", VRAM, tiler/renderer activity. |
| Thermal pressure | `ProcessInfo.processInfo.thermalState` + `NSProcessInfoThermalStateDidChangeNotification` | **Fully public and documented.** Use this as a safety trigger — it's Apple telling you the machine is in trouble. |
| Battery / power source | `IOPSCopyPowerSourcesInfo` (IOKit.ps) | Public. Needed for AC/battery curve profiles. |
| Disk / network I/O | IOKit block storage statistics; `getifaddrs` / `sysctl NET_RT_IFLIST` | Public. |

### Private API exposure — be deliberate

`IOHIDEventSystemClient` and `IOReport` are private. That means:
- **Guaranteed Mac App Store rejection** — but you're not shipping there anyway (the sandbox already rules it out).
- They can break silently in any macOS update. Every private-API call must be wrapped, failure-tolerant, and behind a feature flag that degrades to "sensor unavailable" rather than crashing.
- Resolve symbols via `dlopen`/`dlsym` rather than linking, so a missing symbol is a runtime `nil` and not a launch failure.

---

## 5. Fan Curve Design (95% ceiling)

### The core safety principle: **floor-only override**

The single most important design decision. Never command a target *lower* than what the system would have chosen on its own:

```
effectiveTarget = max(userCurve(temp), systemBaselineRPM)
```

Establish `systemBaselineRPM` by sampling `F%dAc` while in auto mode over time, keyed by temperature, and keep it updated. This makes it **structurally impossible** for your app to cool the machine worse than stock. Everything else — curves, profiles, manual sliders — becomes a strictly additive safety margin. This is the answer to "preserve system cooling."

### Curve shape

Piecewise-linear over N control points, monotonic non-decreasing, with hysteresis:

```
percent = clamp(interpolate(points, currentTemp), minPercent, 95.0)
rpm     = F0Mn + (percent / 100.0) * (F0Mx - F0Mn)
```

Anchoring to `Mn…Mx` rather than `0…Mx` is the right call — 0 RPM is a valid write, and the low end of the range is where a bad curve does real damage.

A reasonable default for an M5 MacBook Pro (tune against measured `Mn`/`Mx`):

| Temp (°C) | Fan % |
|---|---|
| ≤ 45 | 0 (system baseline) |
| 55 | 20 |
| 65 | 35 |
| 75 | 55 |
| 85 | 75 |
| ≥ 95 | **95 (ceiling)** |

### Why cap at 95%, and what it costs

95% is a sound default — the last 5% of RPM buys very little thermal headroom for a large acoustic penalty, and leaving headroom means the fan is audibly *not* maxed, which reads as "under control" to the user.

**But the cap must not be absolute.** Define an override ladder:

1. `ProcessInfo.thermalState == .critical` → release to 100%
2. Any sensor > a hard threshold (e.g. 100 °C) → release to 100%
3. Sensor read failure or stale data → **relinquish to system mode entirely** (write mode `0`)

A 95% ceiling that holds during a genuine thermal emergency is a bug, not a feature.

### Control loop hygiene

- **Sample at 1–2 Hz.** Faster gains nothing and burns battery. Ironically, an aggressive monitor is itself a heat source — sample the expensive stuff (process list) at 0.2 Hz, sensors at 1 Hz.
- **Hysteresis:** require ~3 °C of movement, or a 5s dwell, before changing target. Prevents audible fan hunting.
- **Slew limiting:** clamp RPM change to ~200 RPM/s ramping up, ~100 RPM/s down. Sudden RPM steps are the most perceptible acoustic artifact.
- **EMA smoothing** on the temperature input (α ≈ 0.3) before it hits the curve.

### Safety mechanisms (non-negotiable)

| Mechanism | Implementation |
|---|---|
| Daemon watchdog | App must heartbeat over XPC every ~5s. Two missed beats → daemon writes mode `0` and returns control to `thermalmonitord`. |
| Crash safety | `atexit` / signal handlers on the daemon that restore mode `0`. |
| Sleep/wake | SMC firmware resets manual state across sleep transitions. Observe `NSWorkspace.didWakeNotification` and re-apply — with a fresh key-casing probe, since you're re-establishing from scratch. |
| Temp staleness | If no valid reading for >10s, fail open to system mode. |
| Hard floor | Daemon-side, independent of the app: never write below a compiled-in minimum RPM while any temp > 60 °C. |
| Uninstall | Explicit "restore automatic control" that writes mode `0` before unloading the daemon. |

---

## 6. Permissions, Signing, Distribution

| Requirement | Applies to | Your situation |
|---|---|---|
| Root | SMC writes only | Needed. Via LaunchDaemon. |
| Developer ID cert | `SMAppService`/`SMJobBless` install, notarization | ❌ Not available on free account |
| Notarization | Distributing to other people | ❌ Blocked |
| App Sandbox | Mac App Store | ❌ Incompatible with `AppleSMC` user client — permanently |
| Hardened Runtime | Notarized distribution | Only relevant if you go paid |
| TCC prompts (camera/mic/files/etc.) | — | **None required.** Nothing in this app touches TCC-protected resources. |

**Worth testing before you assume the worst:** a *free* Apple Developer account does issue "Apple Development" certificates for local use, and Apple's guidance for `SMAppService` daemons says to configure a **Development** signing certificate for both app and helper ("Sign to Run Locally" is explicitly unsupported). It's plausible `SMAppService` registration works locally with a personal-team Development cert. Spend an hour testing this before committing to the manual-plist path — it's a much cleaner install/uninstall story.

**The manual path (guaranteed to work):**
```
sudo cp fancontrold /usr/local/libexec/
sudo cp com.you.fancontrold.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.you.fancontrold.plist
```
XPC via a `MachServices` entry in the plist. For personal use you can relax the daemon's peer code-signature validation; **do not ship anything with that relaxation in place** — an unvalidated root XPC endpoint is a local privilege escalation vector.

### Data collection — set the bar at zero

The established norm in this category is aggressively privacy-clean, and it's a genuine differentiator:

- **TG Pro** — all analytics removed from the codebase; no tracking code; user activity never transmitted.
- **iStat Menus** — no ads, no analytics, no tracking.
- **Stats** — fully open source, inspectable.

Match it: no telemetry, no crash reporting to a third party, no network access at all except an explicit, opt-in update check. Write config to `~/Library/Application Support/`. If you never add the `com.apple.security.network.client` capability, the claim is self-evidently true.

---

## 7. Prior Art Worth Reading

| Project | What to take from it |
|---|---|
| [agoodkind/macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) | **Start here.** MIT-licensed Swift. The M5 findings, key-casing probe, IOKit struct layout, and daemon architecture all come from this. Its `docs/research.md` is the single best public document on the subject. |
| [exelban/Stats](https://github.com/exelban/stats) (41k★, MIT) | The reference for the monitoring half. `SMC/smc.swift` for transport, `Modules/Sensors/values.swift` for the per-chip sensor key tables. Note it currently ships the broken M3/M4+ fan control path ([#2928](https://github.com/exelban/stats/issues/2928)) — read the issue, don't copy the code. |
| [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl) | The canonical Intel/FPE2 implementation. Historical reference. |
| [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) | Minimal `IOHIDEventSystemClient` temperature reader for Apple Silicon. |
| [vladkens/macmon](https://github.com/vladkens/macmon) | `IOReport`-based power/frequency metrics without sudo. |
| [alienator88/HelperToolApp](https://github.com/alienator88/HelperToolApp) · [SwiftAuthorizationSample](https://github.com/trilemma-dev/SwiftAuthorizationSample) | Working `SMAppService` privileged-helper patterns in Swift. |
| [macmade/Hot](https://github.com/macmade/Hot) | Clean, minimal thermal-throttle menu bar app. Good UI reference. |

---

## 8. Documentation Landscape

**Apple publishes nothing about the SMC.** There is no official documentation for SMC keys, fan control, or thermal management. Everything above is community reverse engineering. This is the defining constraint of the project and the reason it needs empirical validation on your specific machine rather than trust in any table.

**Apple docs that *are* relevant and current:**

- [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) — daemon/agent registration (macOS 13+)
- [`NSXPCConnection`](https://developer.apple.com/documentation/foundation/nsxpcconnection) + XPC security — peer validation via `setCodeSigningRequirement(_:)`
- [`ProcessInfo.thermalState`](https://developer.apple.com/documentation/foundation/processinfo/thermalstate) — the one public thermal API
- [`IOKit`](https://developer.apple.com/documentation/iokit) and the archived *IOKit Fundamentals* — `IOServiceOpen` / `IOConnectCallStructMethod`
- Notarization & Hardened Runtime guides — for when/if you go paid
- Developer Forums threads on [migrating from SMJobBless](https://developer.apple.com/forums/thread/725811) and [CPU usage by process](https://developer.apple.com/forums/thread/655349)

**Non-Apple, higher value for the low-level work:**

- [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/) — the best public description of the Apple Silicon SMC/RTKit protocol
- [`macsmc-hwmon`](https://github.com/torvalds/linux/blob/master/drivers/hwmon/macsmc-hwmon.c) in the Linux kernel — a real, working fan control driver for Apple Silicon
- VirtualSMC SDK — the per-key attribute-byte permission model
- [Asahi progress report on fan control](https://asahilinux.org/2025/12/progress-report-6-18/)

---

## 9. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Hardware damage from a bad curve | **High** | Floor-only override; daemon-side hard floor; watchdog; thermal-state escape hatch. This is the risk that matters. |
| macOS update changes SMC behavior | High | Runtime capability probing (never compile in assumptions); fail open to system mode; version-gate. Apple has changed this every generation since M1. |
| Private API removal | Medium | `dlsym` resolution; graceful sensor-unavailable state. |
| M5 key casing / behavior varies by Pro/Max variant | Medium | Research explicitly notes Pro/Max/base variants are unverified. Probe everything at runtime. |
| Can't distribute | Certain | Accepted — personal use, or $99/yr. |
| Monitoring overhead becomes a heat source | Low | Tiered sampling rates; no per-frame work. |
| No warranty / support implications | Low–Medium | Apple doesn't sanction this. Self-inflicted damage is on you. |

---

## 10. Suggested Sequence

**Phase 1 — Prove the hardware (1–2 days).** CLI only. Open `AppleSMC`, enumerate keys, read `FNum`/`F0Ac`/`F0Mn`/`F0Mx`, probe both `F0md` and `F0Md` casings. Confirm your machine has fans and what its real range is. **Do not write anything yet.** If this phase surprises you, everything downstream changes.

**Phase 2 — Monitoring app (1 week).** SwiftUI `MenuBarExtra`. Sensors, CPU, memory, processes, GPU. Zero privileges. This alone is a genuinely useful app and de-risks the whole project.

**Phase 3 — Root daemon (2–3 days).** Test `SMAppService` with a Development cert first; fall back to manual plist. Prove a root process can write `F0md=1` and `F0Tg` and that RPM actually changes. XPC plumbing with heartbeat.

**Phase 4 — Curve engine + safety (1 week).** Baseline learning, floor-only override, hysteresis, slew limiting, watchdog, sleep/wake re-establishment. Unit-test the curve engine against synthetic temperature traces — no hardware needed, and this is where correctness actually lives.

**Phase 5 — Extras.** Profiles (AC/battery, quiet/performance/gaming), sensor history graphs, per-app auto-profiles (fan curve switches when a named process is running), throttle detection & alerting, battery health, CSV export, `launchd` login item.

**Throughout:** keep a physical thermometer-of-last-resort habit — leave Activity Monitor open and know how to `sudo launchctl bootout system/com.you.fancontrold` from a terminal you can reach.
