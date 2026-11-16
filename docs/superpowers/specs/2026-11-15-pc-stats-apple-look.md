# PC Stats — Apple look (revision of look B, 2026-11-15)

He said look B "doesn't look too professional" and asked for a very professional, Apple feel (refs:
Apple Health / Fitness / Stocks, macOS & iOS widgets, iStat Menus 7). This replaces look B's
glow/glass on every platform (Windows window, web stats page, iPhone stats page).

## Surfaces
- Page background: pure black `#000000` (no radial glow).
- Card: `#1C1C1E` (Apple secondarySystemBackground, dark), **no border**, continuous corner radius 22
  (web: 22px; iOS: `RoundedRectangle(cornerRadius: 22, style: .continuous)`), padding 18–20.
- Gap between cards: 12. Elevated controls (pills, segmented): `#2C2C2E`.

## Text (dark mode label colours)
- Primary `#FFFFFF`; secondary `rgba(235,235,245,0.6)`; tertiary `rgba(235,235,245,0.3)`; separator `rgba(84,84,88,0.6)`.
- Page title: the PC name, 28 bold; subtitle secondary 15 ("Gaming · cod", "Live", "Offline · last seen …").
- Card header: tinted icon (16) + label in the tint, 15 semibold, left; right side: secondary 13 context ("Now", "Peak 72°", "10 min").
- Value: very large, semibold, **rounded** numerals with tabular digits (SF Pro Rounded on iOS `.rounded`; web `ui-rounded, "SF Pro Rounded", system-ui`; Windows "Segoe UI Variable Display" semibold), letter-spacing -0.02em; unit in secondary at ~35% of the value size, baseline-aligned.
- Temperature beside a load: "96% · 67°" — the temperature the same size as the usage (his ask), tinted only when past warn/crit.

## Category tints (Apple system colours, dark)
| group | tint | icon idea |
|---|---|---|
| GPU (gpu.*) | systemGreen `#30D158` | graphics card / display chip |
| CPU (cpu.*) | systemBlue `#0A84FF` | cpu |
| Frames (fps, fps.low1, frametime) | systemPurple `#BF5AF2` | speedometer / film |
| Power (power.*) | systemYellow `#FFD60A` | bolt |
| Memory/disk (ram.*, gpu.vram*, disk.*) | systemTeal `#64D2FF` | memory chip / drive |
| Network (net.*) | systemIndigo `#5E5CE6` | arrows |
| Cooling (fan.*, gpu.fan) | systemCyan `#5AC8FA` | fan |
| Temperatures (*.temp, temp.*) | systemOrange `#FF9F0A` | thermometer |
- Warn = systemOrange `#FF9F0A`, crit = systemRed `#FF453A` (applied to the value text only).
- A widget's `style.color` overrides the tint.

## Charts
- Smoothed: plot a centred moving average (≈ 5 samples at 1 Hz, wider for long windows) — never raw spikes.
- Y range: 0–100 for % readings; otherwise 0 (or a floor) to the 98th percentile × 1.15 so a single spike can't flatten the line.
- Line 2.5 px in the tint, round joins; area fill tint gradient 35% → 0% opacity top→bottom.
- 3 faint horizontal gridlines (separator colour, 1 px) with the value labels at the right edge (tertiary 11).
- Under the chart, a stat row in secondary 13: "Min 58 · Avg 66 · Max 72" (tabular), for the chart's window.
- The chart occupies the lower ~55% of a hero card and the bottom ~40% of a number card; it spans the card's inner width (no bleeding past the padding).

## Rings (Apple Activity style)
- Stroke = 13% of the ring diameter, round caps; track = the tint at 20% opacity; arc = the tint (subtle angular gradient from tint to a lighter tint where possible).
- Value centred (rounded numerals), label under it in secondary.

## Bars
- Rows: label (secondary 14) left, value right (primary 14 semibold, tabular), the bar under them: 8 px tall, radius 4, track `#2C2C2E`, fill the tint.

## Default dashboards (server defaults, re-seeded for dashboards never edited)
- Overview: GPU hero (x0 y0 w6 h4, meta temp/clock/power/VRAM) · CPU hero (x6 y0 w6 h4) · Frames number (x0 y4 w4 h3) · Power bars (x4 y4 w4 h3) · Memory bars (x8 y4 w4 h3) · Cooling bars (x0 y7 w6 h2) · Network chart (x6 y7 w6 h2).
- Gaming (auto game): FPS hero (x0 y0 w8 h4, meta 1% low, frame time) · GPU ring (x8 y0 w4 h2) · CPU ring (x8 y2 w4 h2) · GPU temp (x0 y4 w3 h3) · CPU temp (x3 y4 w3 h3) · PC power (x6 y4 w3 h3) · Frame time (x9 y4 w3 h3).
- Power: unchanged structure.
