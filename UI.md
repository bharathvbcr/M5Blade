# M5Blade — Interface Design

**Target:** macOS 14+ (designed against macOS 26 Tahoe), Apple Silicon · **Frameworks:** AppKit `NSStatusItem` + SwiftUI interiors + Swift Charts
Companion to `FEASIBILITY.md`, `AUDIT.md`, `DESIGN.md`.

---

## 1. Organizing Principle

This app can damage hardware. That single fact should shape every screen:

> **The safe action is always one click away and always visible. The dangerous action requires deliberate effort and shows its consequences before it takes effect.**

Concretely, four rules that override any other design consideration:

1. **"Stock" is reachable in one click from every surface.** Menu bar, popover, curve editor, settings. It writes mode `0` and hands the machine back to macOS. It is the app's panic button and it never moves.
2. **The floor is drawn, not described.** In the curve editor, the region below the safety floor is rendered as a shaded forbidden zone that control points physically cannot enter. No validation dialog — the geometry does the enforcing.
3. **State is never ambiguous.** At any moment the user can see: which profile is active, *why* it's active, and whether the app is actually controlling the fans or just watching.
4. **Degraded modes are visible, not silent.** Monitor-only, unverified macOS, daemon disconnected, stale sensors — each has a persistent, non-modal banner. An app that silently stops controlling fans is worse than one that never started.

---

## 2. Surface Inventory

| Surface | Type | Purpose |
|---|---|---|
| Status item | `NSStatusItem` | Live readout + one-click profile switch |
| Popover | `NSPopover` + `NSHostingView` | At-a-glance dashboard, profile picker |
| Curve editor | Window | Per-fan curve authoring — the core interaction |
| Rules editor | Window (tab) | Automation authoring |
| History | Window | Charts, sessions, throttle episodes, export |
| Battery | Window (tab) | Health, capacity trend, power draw |
| Settings | Window | General, sensors, safety, advanced |
| Onboarding | Sheet sequence | First-run probe → consent → daemon install |

Three windows total (Control, History, Settings), tabbed where related. Not eight separate windows.

**As built:** two windows. **Dashboard** (read-only: Insights, Sensors, History) and **Settings** (everything that changes: General, Profiles, Curves, Automation) — the read/change split replaced the Control/History split. Battery health lives in Settings › General rather than a dedicated tab (DESIGN §6.2's both-figures-together rule is kept). Onboarding collapsed into a first-control consent dialog (`AppDialogs`) plus the helper install flow of §8; the curve editor lives in Settings › Curves as a tab rather than its own window.

---

## 3. Status Item

The primary surface. Most users will interact with nothing else on most days.

```
 ┌──────────────────────┐
 │ 󰈐 62°  2140          │      ← icon · temp · RPM
 └──────────────────────┘
```

**Layout budget.** Menu bar space is scarce, and on a MacBook Pro it's scarcer. Default to **two fields** (temp + RPM), user-configurable from: package temp, GPU temp, max fan RPM, CPU load, package watts, battery %. Cap the selection at three and say why.

**Anti-jitter.** Use `.monospacedDigit()` and reserve fixed character widths. A status item that changes width every second is genuinely irritating and it's the most common defect in this app category.

**The notch problem — Mac-specific, and it matters here.** On a MacBook Pro, status items can be clipped behind the notch, and **there is no API to detect this**. `NSStatusItem.isVisible` returns `true` even when the item is hidden behind the notch or a long menu title. For a normal app that's cosmetic. For a *safety* status item it means the user's only ambient indicator can silently vanish.

Mitigations:
- Keep the item narrow by default — this is the strongest defense.
- Offer an icon-only mode explicitly labeled "for narrow menu bars."
- Never make the status item the *only* channel for an emergency. Critical thermal events also fire a notification and, optionally, bring the popover forward.
- Mention `NSStatusItemSpacing` in the help text rather than writing user defaults on their behalf.

**Click behavior.**

| Gesture | Result |
|---|---|
| Left click | Popover |
| Right click | Compact `NSMenu`: profile list, **Stock**, Open Control, Settings, Quit |
| ⌥-click | Diagnostics menu (raw SMC keys, daemon status, key-casing probe result) |

**Color coding.** Temperature tint is a *secondary* channel only — never the sole carrier of meaning (see §11). Nominal uses the standard label color; `.fair`/`.serious` shift tint *and* the icon glyph changes.

---

## 4. Popover — Dashboard

Fixed width 340 pt. Scannable in under two seconds.

```
┌────────────────────────────────────────┐
│  Balanced                        ⌄     │  ← active profile, click to switch
│  Auto · rule "Xcode build"             │  ← WHY it's active (§1 rule 3)
├────────────────────────────────────────┤
│  CPU      62°C    ▁▂▄▅▄▂▁              │  ← 60s sparkline
│  GPU      54°C    ▁▁▂▃▂▁▁              │
│  Package  18.4 W                       │
├────────────────────────────────────────┤
│  Fan 1   2140 rpm   ████████░░  42%    │
│  Fan 2   1980 rpm   ███████░░░  38%    │
├────────────────────────────────────────┤
│  Memory   18.2 / 24 GB      Load  34%  │
├────────────────────────────────────────┤
│  ⚡ Battery 78%  ·  discharging 12.1 W │
├────────────────────────────────────────┤
│  [ Settings ]  [ Dashboard ]  [ Stock ] │
└────────────────────────────────────────┘
```

Design notes:

- **Line 2 is load-bearing.** "Auto · rule 'Xcode build'" is what makes automation trustworthy. Automation the user can't explain is automation they'll disable.
- The fan bar fills to the **ceiling**, not to 100% — with a tick mark at the ceiling so 95% reads as "near my limit," not "near maximum possible."
- **Stock is a destructive-styled button** in the permanent footer row. Always present.
- Sparklines come from `HistoryKit`, which is why DESIGN §8 builds history before control.
- When controlling, a subtle "Controlling" pill appears next to the profile name. When monitoring only, the pill reads "Watching" in a muted tone. Never leave this implicit.

---

## 5. Curve Editor — The Core Interaction

The hardest screen, and the one that determines whether the app is safe to use.

```
┌──────────────────────────────────────────────────────────────┐
│  ⟨ Fan 1 ⟩  ⟨ Fan 2 ⟩                    Profile: Balanced   │
├──────────────────────────────────────────────────────────────┤
│ 100% ┤ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  max   │
│  95% ┤═══════════════════════════════════════════●══  ceiling│
│      │                                        ╱             │
│  75% ┤                                     ●╱               │
│      │                                  ╱                   │
│  55% ┤                            ●──╱                      │
│      │                        ╱                             │
│  35% ┤                 ●──╱          ┊                      │
│      │            ╱                  ┊ now: 62°C            │
│  20% ┤     ●──╱                      ┊                      │
│      │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  safety floor │
│    0 └──┬────┬────┬────┬────┬────┬────┬────┬────┬───        │
│        35   45   55   65   75   85   95  105                 │
│                                                              │
│  Sensors driving this fan:  [CPU Package ×] [GPU ×] [+]      │
│  Reduction: (•) Max  ( ) Mean       Ceiling: [ 95 ]%         │
│                                                              │
│  Preview: at 62°C → 33% → ~1,890 rpm                         │
│                                                              │
│  [ Reset to Stock ]              [ Revert ]  [ Apply ]       │
└──────────────────────────────────────────────────────────────┘
```

### Interaction

| Action | Behavior |
|---|---|
| Drag a point | Moves in both axes. Clamped: cannot cross neighbours horizontally (enforces monotonicity), cannot enter the shaded floor or exceed the ceiling. |
| Double-click on the line | Inserts a control point |
| Select + Delete | Removes (minimum two points enforced) |
| ⇧-drag | Constrains to vertical (adjust % only) |
| Arrow keys | Nudge selected point 1 unit; ⇧+arrow = 5 |
| ⌘Z / ⌘⇧Z | Undo / redo via `UndoManager` |

### Non-negotiable affordances

- **Live temperature indicator** — a vertical line at the current temperature, moving in real time, with the resulting % shown. This turns an abstract graph into a legible statement about *right now*.
- **The floor is geometry, not validation.** Shaded region, hard clamp on drag. No error dialogs — the user simply cannot author an unsafe curve.
- **Ghost of the previous curve** while dragging, so the change is visible as a delta.
- **Apply is explicit.** Live-preview as you drag, but nothing is written to hardware until Apply. Revert restores the last applied state.
- **Per-fan tabs with per-fan sensor mapping** (AUDIT A-3). One curve driving both fans runs one of them harder than necessary for its whole life.
- **Preview line in plain language.** "at 62°C → 33% → ~1,890 rpm" does more for comprehension than the entire graph.

### Implementation

Swift Charts is the right tool for *rendering* but is not built for direct manipulation. Use it for axes, gridlines, and the curve path; overlay a custom `Canvas` + `DragGesture` layer for the control points, with hit-testing in data space rather than view space so it survives resizing. Budget real time for this screen — it's the one place where "good enough" will be felt daily.

---

## 6. Rules Editor

Condition builders are notoriously easy to make hostile. Three decisions keep this one usable:

```
┌──────────────────────────────────────────────────────────────┐
│  Rules are checked top to bottom. First match wins.       [+]│
├──────────────────────────────────────────────────────────────┤
│ ⠿ ☑  Xcode build                          → Performance      │
│      when  [process ▾][swift-frontend] uses >[50]% for [15]s │
│      and   [power source ▾] is [AC ▾]                        │
│                                          ● matching now      │
├──────────────────────────────────────────────────────────────┤
│ ⠿ ☑  On battery                           → Silent           │
│      when  [power source ▾] is [Battery ▾]                   │
├──────────────────────────────────────────────────────────────┤
│ ⠿ ☐  Late night                           → Silent           │
│      when  [time ▾] between [23:00] and [07:00]              │
└──────────────────────────────────────────────────────────────┘
        Currently active:  Xcode build → Performance
```

1. **Priority is drag-to-reorder**, not a numeric field. "First match wins, top to bottom" is a rule people already understand from mail filters.
2. **Live match indicators.** Each rule shows whether it matches *right now*, and the footer shows which one is actually winning. The user can see the resolver working instead of guessing.
3. **"Create rule from what's running now"** — snapshot current top processes and pre-fill. Nobody should have to know the string `swift-frontend` to use this feature.

Emergency and manual-pin states appear in the footer too, so the precedence ladder from DESIGN §2.4 is visible rather than documented-only.

---

## 7. Dashboard → History

One window, three pages: **Insights** (§7.1), **Sensors** (§7.2, formerly a
Settings tab), **History** (below). They read the same data, so they share a
window — a finding on Insights scrubs the chart here rather than telling you
where to look, and the live value of a sensor sits one tab from its own record.

```
┌──────────────────────────────────────────────────────────────┐
│ [1h] [6h] [24h] [7d] [30d]        Sensors: [CPU][GPU][Fan][W]│
├──────────────────────────────────────────────────────────────┤
│  90°┤                    ╭─╮                                 │
│     │        ╭──╮       ╱   ╲        ▓▓▓ throttle episode    │
│  60°┤   ╭───╯   ╰──────╯     ╰────                           │
│     │──╯                                                     │
│   0 └────────────────────────────────────────────────────    │
│      │Balanced        │Performance         │Balanced         │
├──────────────────────────────────────────────────────────────┤
│  Episodes                                                    │
│  14:22  4m 18s  peak 97°C  ·  swift-frontend 71%             │
│  11:05  1m 02s  peak 94°C  ·  Compressor 88%                 │
├──────────────────────────────────────────────────────────────┤
│  [ Start Session ]                          [ Export… ]      │
└──────────────────────────────────────────────────────────────┘
```

- The **shared time axis with profile bands underneath** is the single most valuable view in the app — it answers "is my cooling policy doing anything?" directly.
- Throttle episodes are shaded regions on the chart *and* rows below; clicking a row scrubs the chart to it.
- Sessions bracket a benchmark so two runs under different profiles can be compared.
- Export via `NSSavePanel`, with a warning when the payload includes process names (DESIGN §5.4).

### 7.1 Insights

```
┌──────────────────────────────────────────────────────────────┐
│  Right now   Controlling · Balanced                          │
│  78°  78 °C · hottest: main chip · load 71% · fans 62%       │
├──────────────────────────────────────────────────────────────┤
│  4 sudden spikes in the last 24 hours    [1h][6h][24h][7d]   │
│  [↻ swift-frontend — 2 of them]  [⚙ Mostly application (2)]  │
├──────────────────────────────────────────────────────────────┤
│  14:22  [Application]  swift-frontend drove it — 71% of the  │
│         CPU work                            [Show on chart]  │
│         58 → 92 °C in 1m 10s · load 6% → 94% · fans 4200 rpm │
├──────────────────────────────────────────────────────────────┤
│  16:40  [Graphics]  Graphics or Neural Engine work, not the  │
│         CPU                                 [Show on chart]  │
│         61 → 88 °C in 40s · load 11% → 14%                   │
└──────────────────────────────────────────────────────────────┘
```

- The page answers a question rather than displaying a quantity, and it is the only one in the app that does. Everything else here shows *what* happened.
- **Every headline is followed by the measurements it was inferred from**, so the reader can disagree with it. A cause the app cannot establish is stated as "it got hot without the CPU doing more" — never guessed into the most common one.
- *Show on chart* hands the window to §7 and switches to it. This is the reason the pages share a window.
- The application-name toggle appears here as well as in the History footer, because this is the page where its absence is felt: without it a spike can be measured but not blamed on anything.

### 7.2 Sensors

Every temperature sensor grouped by subsystem, with a live plot per group. Moved out of Settings: this is something you read, not something you change, and it belongs beside the record of the same sensors.

---

## 8. Onboarding & Daemon Install

The most under-designed moment in most tools of this type, and the one where trust is won or lost.

**Step 1 — Probe (automatic, read-only).**
"Found 2 fans. Range 1,200–8,400 rpm. Mode key `F0md`. macOS 26.4 — verified." Or, on an unknown combination: "macOS 26.5 hasn't been verified with this Mac. Starting in monitor-only mode." (AUDIT A-7)

**Step 2 — Choose a mode.** Two large options:
- **Monitoring only** — "No special permissions. Nothing is written to your Mac." *(default, pre-selected)*
- **Monitoring + fan control** — "Requires an administrator password and a background helper."

Defaulting to monitoring is correct. Most people who install this want to *see* something; control is the escalation.

**Step 3 — Consent (control path only).** Plain language, not a EULA: what gets installed and where, that fan control can damage hardware if misused, that the app maintains a safety floor and hands control back on any anomaly, and exactly how to uninstall. A checkbox, not a scroll-to-bottom.

**Step 4 — Install.** Since Developer ID isn't available (FEASIBILITY §1), the daemon install is a manual `sudo` sequence. Do not make the user assemble it:

```
┌──────────────────────────────────────────────────────────────┐
│  Install the helper                                          │
│                                                              │
│  Run this in Terminal. It installs a background helper that  │
│  can adjust fan speed, and nothing else.                     │
│                                                              │
│  ┌────────────────────────────────────────────────┐ [Copy]  │
│  │ sudo /Applications/M5Blade.app/Contents/        │         │
│  │   Resources/install-helper.sh                   │         │
│  └────────────────────────────────────────────────┘         │
│                                                              │
│  ⟳ Waiting for helper…            [ What does this do? ]     │
└──────────────────────────────────────────────────────────────┘
```

Ship a readable install script rather than a wall of commands, link its source, and **poll for the helper so the sheet advances by itself** the moment it appears. Uninstall gets equal billing in Settings with a matching one-line command.

---

## 9. Degraded & Emergency States

Each is a persistent, non-modal banner at the top of the popover. Never a modal dialog — a modal that appears while the user is doing something else during a thermal event is actively harmful.

| State | Banner | Action |
|---|---|---|
| Monitor-only | "Watching only — fan control not installed" | Set Up |
| Unverified macOS | "Fan control unverified on macOS 26.5" | Enable Anyway / Learn More |
| Daemon disconnected | "Helper not responding — fans returned to automatic" | Reconnect |
| Sensors stale | "Sensor data unavailable — released to automatic" | — |
| **Emergency** | "Critical temperature — fans at maximum" | Show History |

Emergency additionally changes the status item glyph and fires a notification, because §3 establishes the status item may be invisible behind the notch.

---

## 10. Settings

Four tabs. Resist adding a fifth.

Only things you *change*. The sensor readout lives on the Dashboard (§7.2).

- **General** — launch at login (`SMAppService.loginItem`), status item fields, °C/°F, update check (opt-in, off by default)
- **Safety** — floor curve (read-only by default, "Advanced" discloses), ceiling default, watchdog timeout, emergency thresholds, **"Restore automatic control" panic button**
- **Advanced** — raw SMC key browser (read-only), key-casing probe result, daemon status and logs, uninstall, "reset everything to defaults"

The safety floor being **read-only by default with a disclosure to edit** is deliberate: it's editable for people who need it, and not something anyone changes by wandering through Settings.

**As built:** four tabs — **General** (login item, readout format, watching sample rate, notifications, diagnostics copy), **Profiles**, **Curves**, and **Automation**, matching DESIGN §2's layered model. The Safety/Advanced items distribute into these: profiles own ceilings and responsiveness; the panic path stays one click away in the menu bar; helper status and uninstall live beside the install flow rather than in a raw-advanced tab.

---

## 11. Accessibility

Not optional, and mostly cheap:

- **Never encode state in color alone.** Temperature severity carries a glyph change and a text label alongside tint. Roughly 8% of men have some color-vision deficiency, and red/green is the exact axis affected.
- **The curve editor must be keyboard-operable.** Tab between points, arrows to nudge, a table view alternative listing points as editable rows. A drag-only editor is unusable for some people and awkward for everyone doing precise work.
- **VoiceOver on charts:** set `accessibilityLabel` and `accessibilityValue` per control point ("point 3, 75 degrees, 55 percent"), and use Swift Charts' `.accessibilityChartDescriptor` for the history graphs.
- **Reduce Motion** — sparklines and crossfade animations respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- **Reduce Transparency** — required under macOS 26's Liquid Glass materials; fall back to opaque backgrounds.
- **Dynamic Type / larger text** — no fixed-height rows in the popover.
- **Full Keyboard Access** — every button reachable, visible focus rings.

---

## 12. Visual Language

- **macOS 26 Tahoe / Liquid Glass.** Use standard materials (`.regularMaterial`, `.thinMaterial`) and let the system provide the glass. Don't hand-roll translucency — it will look wrong against the new menu bar, which is fully transparent by default in Tahoe.
- **SF Symbols** throughout: `fan`, `thermometer.medium`, `bolt`, `battery.75percent`, `chart.xyaxis.line`. Variable-color symbols suit fan speed naturally.
- **System accent color** for interactive elements. Reserve a fixed semantic palette for thermal severity only, so severity never collides with the user's accent choice.
- **Typography:** `.monospacedDigit()` for every changing number — status item, popover, charts. Non-monospaced digits cause visible reflow at 1 Hz.
- **Dark Mode** is table stakes; test the curve editor's shaded floor region in both, since low-opacity fills that read clearly on light backgrounds often disappear on dark.

---

## 13. What This Adds to the Build Order

Amending DESIGN §8:

| Phase | Addition |
|---|---|
| 2 | `NSStatusItem` + popover. **Ship the "Watching" pill from day one** — the controlling/watching distinction should exist before control does. |
| 3 | History window + Swift Charts. Sparklines land in the popover here. |
| 4 | Onboarding sheets + install flow. Build this *with* the daemon, not after — the install experience is part of the daemon's design. |
| 5 | Curve editor. Budget more time than feels reasonable; it's the app's identity. |
| 6 | Rules editor with live match indicators. |
| 7 | Battery panel, episode UI, Settings polish, accessibility pass. |

**Accessibility is a pass in Phase 7 but a constraint from Phase 2.** Retrofitting keyboard operation into a drag-based curve editor is a rewrite; designing for it from the start is nearly free.
