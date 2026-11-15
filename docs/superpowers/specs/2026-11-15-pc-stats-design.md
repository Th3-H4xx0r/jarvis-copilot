# PC Stats: live dashboard, history and watts for the gaming PC — design

Date: 2026-11-15 · Status: draft for Pranav's review

## 1. Intent

Pranav games on his Windows PC (pranav-computer: i7-14700F, NVIDIA RTX, 32 GB, three
2560×1440 monitors). He wants an **always-on stats dashboard on one of his side monitors**,
in the spirit of MSI Afterburner / HWiNFO but in the Jarvis look, that shows everything
the PC is doing: CPU, GPU, frames, memory, disks, network, fans, temperatures and
**whole-PC power** (the WattSeal idea). He wants **a lot of freedom to edit it** himself,
and to be able to **ask Jarvis to edit it** for him. The same data is **live on the
iPhone and web** (the PC's card in Agents gets live numbers and a **View stats** button
that opens a detailed page), and it's **stored on the server** so he can look back at how
a game session went, what the PC cost to run, when something went wrong, and how its
health trends over months.

Success: he leaves it running on the side monitor while he plays and finds it beautiful
and useful; he can rearrange it to taste in minutes or just tell Jarvis; he can open the
same dashboard on his phone; and it never costs him frames or trips anti-cheat.

## 2. Goals, non-goals, anti-goals

**Goals**
- Everything, equally: no metric family is second-class (his answer: "all of it").
- One saved layout model drawn natively on three platforms: Windows (WPF, in the existing
  Windows app), web (the Jarvis web app) and iPhone (SwiftUI).
- Fully editable: grid edit mode (drag, resize, add from a widget library, remove);
  per-widget settings (reading, chart type, colours, amber/red thresholds); several
  dashboards, switched by hand or automatically (e.g. a gaming dashboard when a game
  starts); and Jarvis edits the same layouts through tools.
- A **Power integration** (`jarvis_power/`): one on/off switch and a settings form on
  iPhone, web and Mac. Off means nothing is collected, sent, stored or drawn.
- History on the server: game sessions, energy/cost, marked problem moments, long-term
  health trends.
- Whole-PC watts with WattSeal's approach, honestly labelled measured vs estimated.

**Non-goals**
- An overlay drawn *inside* games (an in-game corner OSD). The dashboard lives on a side
  monitor (his answer: "side monitor, always-on").
- Notifications or alerts (his answer: problems are **only marked on the history graphs**).
- Overclocking, fan control or any writing to hardware. Read-only.
- The Mac as a stats source. This is for the PC (the model shouldn't make a Mac source
  impossible later, but nothing is built for it).

**Anti-goals (failure even if it "works")**
- **Costing frames.** Collection and drawing must be negligible while a game runs (the
  Windows client's four gaming rules apply: no surface over a fullscreen game, no focus
  stealing, no FPS cost, no anti-cheat triggering).
- **Injection or hooks**: nothing is injected into game processes and no global hooks are
  installed. (A sensor driver *is* used — his call, §3 — but never WinRing0.)
- Looking unprofessional. He rejected rough mockups; the bar is the polished "B · Jarvis"
  mockup (`.superpowers/brainstorm/49305-1794784049/content/dashboard-style-v2.html`,
  option B).
- Fake precision: an estimated watt figure must never be shown as measured.

## 3. What he decided

| Topic | His decision |
|---|---|
| Where | A side monitor he chooses, always on. |
| What | Everything equally. |
| Look | **B · Jarvis**: near-black with a faint cool radial glow, the Jarvis orb in the header, soft glass panels (white ≈3.5% fill, ≈7% hairline, 18 px radius), one large hero number per panel with a glowing area chart (cool blue gradient), compact meta rows, thin horizontal bars for breakdowns, pill controls (Live / 1 h / 24 h / Edit). |
| Editing | All four: grid edit mode, per-widget restyle, several dashboards (manual + automatic), and "just tell Jarvis". |
| Platform model | Built on the **Power integration** architecture (on/off + settings). |
| PC renderer | **Native** in the Windows app (WPF), not the web page in a window. |
| PC window | A **normal borderless window** on the chosen monitor: he can move, minimise or cover it; it doesn't stay on top and isn't a wallpaper. |
| History | All four uses: game sessions, energy & cost over time, spotting problems, long-term health. |
| Problems | **Only marked in history.** No phone notifications, no Jarvis interruptions. |
| Phone page | **His dashboard, phone-sized**: the same layout reflowed into one column, editable on the phone too, with a dashboard switcher; history underneath. |
| Sensor driver | **On by default.** The PawnIO sensor driver (what LibreHardwareMonitor and WattSeal use) is installed during setup so CPU temperature, motherboard temps, every fan and real CPU package watts are available. He accepts that some anti-cheat may flag kernel drivers. A PC Stats setting can switch the driver off (and uninstall it) if a game ever complains; then those tiles say "needs the sensor driver". Never WinRing0. |
| Active dashboard | **Each device picks its own.** The PC window, the phone and the web each remember which dashboard they show; auto-switch rules (e.g. Gaming when a game starts) apply only to the PC window. Jarvis's "current dashboard" means the PC window's unless he names one. |

## 4. My calls (he can overturn any of these)

1. **Sensors through LibreHardwareMonitorLib on PawnIO** (driver installed during setup
   through the existing Face ID + UAC admin path). CPU package watts: RAPL via the driver;
   if the driver is switched off, Windows' `Energy Meter` counters when present, else
   WattSeal's estimate. NVIDIA GPU readings via NVML (works with or without the driver).
   Any reading that's unavailable says why ("needs the sensor driver") instead of silently
   missing.
2. **FPS via PresentMon's method** (ETW `Microsoft-Windows-DxgKrnl`/`DXGI` present events —
   no injection). Reading those events needs the user in "Performance Log Users" (or
   admin); granting it is a one-time admin action through the existing Face ID + UAC
   path. FPS, 1% low and frame time are for the foreground fullscreen/game process.
3. **Live rate 1 Hz**; the PC sends samples to the server at 1 Hz only while someone is
   watching live (a dashboard open on web/phone), otherwise batched (every 10 s, 10-s
   averages). The side-monitor window reads locally, never via the server.
4. **Retention:** 10-second points for 7 days, 1-minute for 90 days, hourly forever;
   game-session summaries and marked moments forever.
5. **The Agents card** shows four live numbers: CPU %, GPU %, hottest temperature, whole-PC
   watts, plus **View stats**.
6. **Jarvis** gets tools to read/edit dashboards and to query history ("how hot did the GPU
   get last night", "what did gaming cost this week").
7. **Settings** (in the Power integration form): which monitor the dashboard window opens
   on (or off), open at sign-in, electricity price + currency, PSU efficiency (default
   90%), history on/off, sampling interval, CPU/GPU TDP overrides for the estimators, and
   which dashboard is the default / auto-switch rules.

## 5. The pieces

### 5.1 Collector (on the PC)
Reads the sensors, measures FPS, computes watts, detects game sessions and problem
moments. Read-only, no driver, no injection.

Readings (each tagged `measured` or `estimated`, with a unit):
- **CPU**: total + per-core load (PDH `% Processor Utility`), clock (effective MHz),
  package watts (Energy Meter → else estimate), temperature (where available without a
  driver), throttling flag (where Windows reports it).
- **GPU (NVIDIA, NVML)**: load, core/memory clock, temperature (+ hotspot if exposed),
  board power (measured), fan %, VRAM used/total, encoder/decoder load.
- **Frames**: FPS, 1% low, frame time (ms), the game exe it applies to.
- **Memory**: RAM used/total, commit, page file.
- **Disks**: per drive used %, read/write MB/s, active %.
- **Network**: up/down MB/s per active adapter.
- **Fans**: whatever is readable without a driver (GPU fan via NVML; others usually not).
- **Power**: per component (CPU, GPU, RAM, disks, network) and **whole-PC wall watts** =
  Σ components ÷ PSU efficiency; kWh and cost today / this month.
- **Context**: uptime, foreground game, game mode (from the existing game-mode detector).

WattSeal's estimator formulas, reimplemented (the code is GPL-3.0; formulas and constants
are facts and may be reused, the code may not be copied):
- CPU (no meter): `P = 0.2·TDP + (1.25·TDP − 0.2·TDP)·u^1.6` (TDP from a model table,
  default 65 W, overridable in settings).
- GPU without a power reading: `idle 0.1·TDP + (TDP − idle)·u^1.6`.
- RAM: RAPL DRAM domain if the Energy Meter exposes it, else a flat 5 W.
- Disk: SSD `0.05 W + 0.015 W/MB`, HDD `3 W + 0.035 W/MB`.
- Network: `0.2 W + 0.01 W/MB`, capped at 3 W.
- Intel RAPL counters are 32-bit and wrap: diff with wraparound.
- Whole-PC excludes fans, motherboard and monitors (as WattSeal does) — the UI labels it
  "PC (est.)" so it isn't mistaken for a wall meter.

**Game sessions**: start when game mode turns on for an exe (existing detector), end when
it turns off; summary = exe/title, start/end, duration, avg FPS, 1% low, peak CPU/GPU
temps, energy (Wh), avg/peak watts, throttling seconds.

**Marked moments** (history only): a reading over its threshold for ≥ N seconds (defaults:
GPU ≥ 85 °C, CPU ≥ 95 °C, throttling, whole-PC watts > 1.3× the 1-hour average, FPS drop
> 40% for 3 s while in a game). Thresholds are editable in settings.

### 5.2 Server
- Stores samples with the retention in §4, session summaries and marked moments; serves
  live (subscription/fan-out to open dashboards) and history queries.
- Stores **dashboards** (layouts) and their auto-switch rules; one source of truth for
  every platform and for Jarvis.
- The Power integration manifest (id `pc-stats`, name "PC Stats"), its settings, its
  route prefixes (409 while off), its toolset (refused while off), its surfaces (the
  Agents card numbers, the View stats button, the stats page, the PC window — all hidden
  while off).
- Jarvis tools: list/get/update dashboards (with a widget-schema-validated patch), query
  history (range + metric + aggregation), list sessions, list marked moments.

### 5.3 Dashboard model (shared by all renderers and Jarvis)
A dashboard is a named grid of widgets. Each widget: id, position/size on the grid,
**kind**, the **reading(s)** it binds to, and **style** (chart type, colours, thresholds,
title, unit, decimals, time window). Kinds must cover at least: hero number (+ meta row
+ area chart, as in look B), number tile, line/area chart (multi-series), bar list
(breakdowns like power by component, fans, memory), ring/gauge, sparkline, text/label,
game-session card, and a "marked moments" strip. Widgets must be able to show an
**estimated** badge and "unavailable on this PC" state.

Several dashboards; one is default; auto-switch rules (at least: "when a game is running →
dashboard X"). Phone reflows the grid to one column by widget order; web and PC use the
grid. The library of widget kinds and the reading catalog (what readings exist, units,
measured/estimated) come from the server so every renderer offers the same choices.

### 5.4 Windows app (WPF)
- **Dashboard window**: native renderer of the layout model in look B; a normal borderless
  window opened on the monitor chosen in settings (and at sign-in if set); can be
  moved/minimised/covered; never activates itself, never goes over a fullscreen game on
  its own monitor; draws at ≤ 1 Hz data with smooth (but cheap) transitions; stops
  animating when hidden/minimised/covered.
- **Edit mode** in the window (grid drag/resize, widget library, per-widget settings,
  dashboard switcher) — writes back to the server.
- The **collector** (§5.1). Placement between the C# app and jc-client is left to the
  builder (§8), but it must obey the gaming rules and work while the dashboard window is
  closed (history keeps recording while the integration is on).

### 5.5 Web app
- PC card in Agents: four live numbers + **View stats**.
- **Stats page**: his dashboard (grid, full editing), dashboard switcher, history below:
  sessions list (tap → session detail with its graphs), energy & cost (day/week/month),
  marked moments (on the graphs and as a list), long-term health (temps/fans trend).

### 5.6 iPhone app
- PC card in Agents: four live numbers + **View stats**.
- **Stats page**: his dashboard reflowed into one column, editable (reorder, add/remove,
  restyle — drag on a 2-D grid isn't required on the phone), dashboard switcher, history
  underneath (same sections as web).
- Follows the app's unified design (JcUnified) while matching look B's feel.

## 6. Constraints

- Windows client gaming rules (no surface over a fullscreen game, no focus stealing, no FPS
  cost). Budget: collector + dashboard window together ≲ 1% of one CPU core.
- **GPU cost on the side monitor (my call):** look B is drawn faithfully but cheaply —
  static effects (background glow, glass, gradients) rendered once and cached, only the
  changing numbers/charts redrawn once a second, no continuous animation; the window
  stops drawing when minimised or covered. The plan measures a game's FPS with the window
  open vs closed; any measurable drop is a bug.
- No DLL injection, no global hooks. The only kernel component is the PawnIO sensor driver
  (his call); never WinRing0.
- Read-only access to hardware.
- Power integration rules (`docs/power-integrations/README.md`): off really stops every
  process; never change an open chat's tools; one on/off switch only.
- AGENTS.md dependency pinning (`>=floor,<next_major`); Windows packages pinned in
  `windows_app/Directory.Packages.props`.
- GPL: reimplement WattSeal's formulas; don't copy its code.
- Builds/OTA as today: iPhone via `ios_app/scripts/release.sh`; Windows app via the
  existing package/OTA path; server deploy as usual.
- Prompt caching (AGENTS.md): new Jarvis tools live in the integration's toolset; switching
  it on/off affects only new chats.

## 7. Reference

- Mockup chosen: option B in
  `.superpowers/brainstorm/49305-1794784049/content/dashboard-style-v2.html`.
- WattSeal: github.com/Daminoup88/WattSeal (GPL-3.0) — register map, estimators,
  PSU-efficiency/kWh/cost maths, per-app split.
- Existing pieces to build on: Power integrations (`jarvis_power/`, guide above); the
  Windows app's game-mode detection, PresentationGate and NoActivateWindow; the Agents PC
  card (iOS `AgentsMacPowerCard.swift`, web Agents page); data-driven UI elsewhere
  (widget creator / island designs) as prior art for a cross-platform layout schema.

## 8. Testing on the real PC (answered)

The builder has SSH and desktop-session access to pranav-computer (the Windows client's
`windows_app/scripts/pc-*.sh`), so the plan starts by probing the real hardware (which
sensors LibreHardwareMonitor sees with PawnIO, NVML, Energy Meter counters, ETW present
events and whether the Performance Log Users grant needs a sign-out) and measures the CPU
and FPS budgets on the machine itself.

## 9. Left to the builder

- Where the collector runs (C# app vs jc-client vs split), and the transport of samples to
  the server (existing device bridge events vs HTTPS batches).
- Storage engine and schema for samples/history on the server.
- The exact layout/widget JSON schema and grid size, as long as all three renderers and
  Jarvis share it and it covers §5.3.
- Whether the dashboard model reuses the widget-creator/island-design block schema or is
  new (reuse preferred if it fits without contortion).
- Exact list of widget kinds beyond the minimum in §5.3, default dashboards shipped
  (suggest: "Overview" in look B, "Gaming", "Power"), default thresholds tuning.
- How PresentMon-style ETW capture is implemented (library vs own consumer).
