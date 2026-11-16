# PC Stats — Jarvis look (2026-11-15, replaces the Apple multi-colour tints)

His ask: "make the mobile + web + windows overlay be more jarvis themed and match it with the app UI we
have right now". Layouts, widgets, behaviour and the dense v4 dashboards stay; only the styling changes.
Every colour comes from the platform's existing app tokens, so the stats re-colour with the app:

| | iPhone | web | Windows |
|---|---|---|---|
| accent (the one variable) | `JcAccent.color` (white) | `var(--jc-accent)` | `JcAccent` / `JcAccentColor` (white) |
| page | black (`jcPageChrome`) | `--jc-bg` | `JcSurface` / black |
| card | `JcCard` look (radius 20, padding 16) | `--jc-surface`, `--jc-r-card`, `--jc-hair` border | card = `JcButton`-grey-on-black like the island cards, radius 16, hairline `JcHairline` |
| text / muted | `JcTheme.text` / muted | `--jc-text` / `--jc-muted` | `JcText` / `JcTextDim`, `JcTextFaint` |
| warn / crit | amber / red app tokens | `--jc-warn` / `--jc-danger` | `JcAmber` / `JcRed` |
| buttons, segmented | `JcSegmentedPicker`, `JcSmallAction`, `JcButton` greys | the app's grey capsule segmented + grey controls | `JcButton` 0.09 / `JcButtonSelected` 0.24 greys, radius 12 |

## Rules
- **No per-category hues.** Drop green/blue/purple/yellow/teal/indigo/cyan/orange tints entirely.
- **Card header:** small muted UPPERCASE label with letter-spacing (the app's section-label style, e.g.
  "GPU", "FRAME RATE", "TEMPERATURES"), an optional small icon in muted; the right side context ("NOW",
  "10 MIN", "LIVE", "EST.") in the same small muted caps.
- **Values:** big, bold, white; units small muted; temperatures inline "65°". Load heroes keep "98% · 65°"
  (temperature the same size). Only a value past warn turns amber, past crit red.
- **Charts:** series 1 = accent line 2 px with an accent area fill fading 16% → 0%; series 2 = accent at
  55%; series 3 = accent at 30%. Legends use the same shades (dot + muted label + white value). Gridlines =
  hairline (accent ≈ 7%); axis labels faint. Min · Avg · Max row in muted. A warn/crit threshold, when set,
  is a faint dashed amber/red line.
- **Rings:** accent arc (round caps), track accent ≈ 12%; amber/red arc only past warn/crit.
- **Bars:** fill accent at 85%, track accent ≈ 10%; a temperature/power bar past its warn turns amber, crit red.
- **Sparklines (details tile):** accent at 70%, area 10% → 0%.
- **Header:** the Jarvis orb (as on the island / Windows window) beside the PC name where the platform has
  it; status in muted with a small live dot (white when live, faint when offline — not green).
- **Segmented / switchers / Edit:** the app's grey controls — selected = the 0.24 grey, never a white fill;
  white fill only for the one main action (e.g. Save in the editor).
- Edit-mode chrome (grips, outlines, library) uses the same greys and hairlines.

## Done when
Screenshots of Overview and Gaming on each platform read as the same Jarvis app (black/white/grey with
amber/red only for warnings), nothing hard-codes a hue outside the token files, and tests pass.
