---
name: widgets
description: Design Jarvis Home Screen and Lock Screen widgets.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [JarvisCopilot, iOS, Widgets, WidgetKit, Design]
    category: jarviscopilot
    related_skills: [jarviscopilot-dynamic-island, jarviscopilot-devices]
---

# Widgets Skill

Creates, edits and deletes the designs the Jarvis iOS app shows in its Home Screen and Lock Screen
widgets. A design is a JSON layout tree (the same one Dynamic Island designs use) with one layout
per widget size, bound to live data the phone publishes: health, wearables, chat, coding, server,
phone. It does not make Control Center buttons (the user makes those in the app) or Dynamic Island
designs (see `jarviscopilot-dynamic-island`).

## When to Use

- "Make me a widget with my steps / sleep / X5 battery / last reply…"
- "Add a chart of this week's steps to my health widget", "make the ring card bigger".
- "Put a button for my Lights-off control on a widget", "delete the coding widget".
- The user designed one in Settings → Widget creator and wants Jarvis to change it.

## Prerequisites

- The Jarvis iOS app paired with this server. iPhone only: on Android, the watch or a desktop,
  say widgets aren't available there instead of writing one.
- The web UI running on this host (the designs live in its state directory).
- The bundled `jarviscopilot/devices` skill: `scripts/widgets.py` signs its requests with that
  skill's `devices.py`, found next to this skill, then under `$JARVISCOPILOT_DIR/skills`,
  `$HERMES_HOME/skills` and `~/.jarviscopilot/skills`.

## How to Run

Run the helper with `terminal` (stdlib only, Python 3.10+). It prints JSON, or `{"error": ...}`
(plus `"errors"` from the validator) on stderr with exit code 1:

```bash
W="$HERMES_HOME/skills/jarviscopilot/widgets/scripts/widgets.py"
python3 "$W" catalog                  # the data keys the phone publishes
python3 "$W" list                     # id, name, version, sizes of every design
python3 "$W" show steps-today         # one design's full JSON
python3 "$W" upsert steps-today.json  # create or replace (or: upsert - < file)
python3 "$W" delete steps-today
```

After `upsert` and `delete` the helper asks every phone offering the `widgets_refresh` device skill
to pull the designs now and reports it under `"phone"`; an unreachable phone is a note, not a
failure (it syncs when Jarvis next opens). `--no-refresh` skips that.

## Quick Reference

**Design:** `{"schema": 1, "id", "name", "icon"?, "tint"?, "presentations": {<size>: <node>}}`.
`id` is a lowercase slug (`a-z 0-9 - _`); the same id replaces the design. The server sets
`version` (previous + 1). `icon` is an SF Symbol; `tint` a hex or named colour. Designs made in
the app also carry `builder` (its block layout).

| size | where | room |
|---|---|---|
| `small` | Home Screen 2×2 | one stat or gauge + a label |
| `medium` | Home Screen 4×2 | two columns, or a stat beside a chart |
| `large` | Home Screen 4×4 | a header, a chart and a few rows |
| `extraLarge` | iPad Home Screen | a dashboard |
| `circular` | Lock Screen circle | a symbol + a short number, or a `gauge` |
| `rectangular` | Lock Screen, under the clock | two or three short lines |
| `inline` | Lock Screen, above the clock | one line of text and a symbol |

A missing size borrows the next smaller layout: `extraLarge` → `large` → `medium` → `small`, and
`rectangular` → `inline`. `small`, `circular` and `inline` borrow nothing, so give `small` always.

**Node:** `{"type", ...props, "style"?: {color, font, size, weight, opacity, padding, align, tint,
width, height}, "when"?: <condition>}`. At most 160 nodes per size, 12 deep.

| type | props |
|---|---|
| `hstack` / `vstack` | `children[]`, `spacing?`, `align?` (`leading` `center` `trailing` `top` `bottom`) |
| `zstack` | `children[]`, `align?` (back to front) |
| `grid` | `columns`, `children[]`, `spacing?` |
| `list` | `data` (a series binding), `row` (node using `{"$row": "field"}`), `columns?`, `max?` |
| `spacer` / `divider` | `minLength?` / — |
| `text` | `value`, `lineLimit?` |
| `titleSubtitle` | `title`, `subtitle` |
| `stat` | `value`, `unit?`, `caption?` |
| `symbol` | `name` (SF Symbol) |
| `symbolValue` | `symbol`, `value` |
| `image` | `source` (SF Symbol or https URL), `fallback?` |
| `dot` / `accent` | `color` |
| `badge` | `text`, `color?` |
| `progress` | `value` (0–1), `tint?` |
| `segbar` | `segments` (`[{weight, color}]`), `progress?` |
| `gauge` | `rings: [{value 0–1, tint}]`, `label?` |
| `timer` | `to` (date), `mode?` (`countdown`/`countup`), `format?` (`relative`) — ticks on its own |
| `timeProgress` | `from`, `to` (dates) — fills on its own |
| `keyValue` | `pairs: [{label, value}]` |
| `sparkline` | `points` (number series), `kind?` (`line`/`bar`), `tint?` |
| `iconStrip` | `items` (SF Symbol names), `max?` |
| `waveform` | `active?` |
| `chart` | `series` (series binding or list of numbers / `{x, y}`), `style?`: `line` \| `bar` \| `area`, `color?`, `min?`, `max?` |
| `model` | `device`: `ring` \| `x5ring` \| `glasses` \| `bottle` \| `scale` \| `esp32` \| `pod` — the wearable's 3D model as a picture |
| `button` | `button` (Control Center button id), `label?`, `symbol?` — runs that button's action |
| `toggle` | `button` (id of a button that keeps state), `label?` — flips it |

`regions` is island-only and isn't allowed here.

**Bindings** (any value): a literal, `{"src": "health.steps"}` (a data key from `catalog`; `{"$":
key}` reads the same snapshot), `{"$row": "field"}` inside a `list` row, or a `{"clock": …}`
binding. Add `"fmt": "{} steps"` to template the value and `"map": {"low": "#ff3b30"}` to swap it
(map, then fmt). A key with no value yet renders "—".

**`when`** hides a node unless it holds: `{"op": "gt", "a": {"src": "x5ring.battery"}, "b": 20}`;
ops `and` `or` (`items`), `not` (`item`), `eq` `ne` `gt` `lt` (`a`, `b`), `exists` (`a`),
`between` (`a`, `lo`, `hi`), `after` `before` (`at`, a date).

**Data keys** are `area.key`. Run `catalog` for the real list with label, kind (number, text,
bool, series) and unit. Typical: `health.score`, `health.band`, `health.sleep_score`,
`health.steps`, `health.hr_latest`, `health.hrv`, series `health.steps_week` /
`health.sleep_week` / `health.hr_today`; per wearable `<device>.connected`, `.battery`, `.name`
(`x5ring.battery`); `chat.last_reply`, `coding.working`, `server.connected`, `phone.battery`,
`alarm.next`.

### Example: steps, every glance size

```json
{
  "schema": 1, "id": "steps-today", "name": "Steps today", "icon": "figure.walk", "tint": "#34c759",
  "presentations": {
    "small": {"type": "vstack", "spacing": 4, "align": "leading", "children": [
      {"type": "symbol", "name": "figure.walk", "style": {"size": 22, "tint": "#34c759"}},
      {"type": "spacer"},
      {"type": "stat", "value": {"src": "health.steps"}, "caption": "steps today"}
    ]},
    "circular": {"type": "vstack", "spacing": 0, "children": [
      {"type": "symbol", "name": "figure.walk"},
      {"type": "text", "value": {"src": "health.steps"}, "style": {"size": 12, "weight": "semibold"}}
    ]},
    "rectangular": {"type": "symbolValue", "symbol": "figure.walk",
                    "value": {"src": "health.steps", "fmt": "{} steps"}},
    "inline": {"type": "text", "value": {"src": "health.steps", "fmt": "{} steps"}}
  }
}
```

### Example: health card with a week chart

```json
{
  "schema": 1, "id": "health-week", "name": "Health this week", "icon": "heart.text.square",
  "tint": "#ff375f",
  "presentations": {
    "small": {"type": "vstack", "spacing": 6, "align": "leading", "children": [
      {"type": "stat", "value": {"src": "health.score"}, "caption": {"src": "health.band"}},
      {"type": "chart", "series": {"src": "health.steps_week"}, "style": "bar", "color": "#34c759"}
    ]},
    "medium": {"type": "hstack", "spacing": 14, "children": [
      {"type": "vstack", "spacing": 6, "align": "leading", "children": [
        {"type": "text", "value": "Health score", "style": {"size": 12, "color": "secondary"}},
        {"type": "stat", "value": {"src": "health.score"}, "caption": {"src": "health.band"}},
        {"type": "symbolValue", "symbol": "bed.double.fill",
         "value": {"src": "health.sleep_score", "fmt": "sleep {}"}},
        {"type": "symbolValue", "symbol": "heart.fill",
         "value": {"src": "health.hr_latest", "fmt": "{} bpm"}}
      ]},
      {"type": "vstack", "spacing": 4, "align": "leading", "children": [
        {"type": "text", "value": "Steps, last 7 days", "style": {"size": 12, "color": "secondary"}},
        {"type": "chart", "series": {"src": "health.steps_week"}, "style": "bar",
         "color": "#34c759", "min": 0}
      ]}
    ]}
  }
}
```

### Example: X5 ring card with a button

`<button id>` and `<switch id>` stand for real ids (see Pitfalls).

```json
{
  "schema": 1, "id": "x5-card", "name": "X5 ring", "icon": "circle.circle", "tint": "#0a84ff",
  "presentations": {
    "small": {"type": "vstack", "spacing": 6, "children": [
      {"type": "model", "device": "x5ring", "style": {"height": 72}},
      {"type": "symbolValue", "symbol": "battery.75percent",
       "value": {"src": "x5ring.battery", "fmt": "{}%"}}
    ]},
    "medium": {"type": "hstack", "spacing": 12, "children": [
      {"type": "model", "device": "x5ring", "style": {"width": 110, "height": 110}},
      {"type": "vstack", "spacing": 6, "align": "leading", "children": [
        {"type": "text", "value": "X5 ring", "style": {"size": 15, "weight": "semibold"}},
        {"type": "badge", "text": "Connected", "color": "#34c759",
         "when": {"op": "eq", "a": {"src": "x5ring.connected"}, "b": true}},
        {"type": "symbolValue", "symbol": "battery.75percent",
         "value": {"src": "x5ring.battery", "fmt": "{}%"}},
        {"type": "symbolValue", "symbol": "heart.fill",
         "value": {"src": "x5ring.hr_latest", "fmt": "{} bpm"}},
        {"type": "button", "button": "<button id>", "label": "Find ring",
         "symbol": "dot.radiowaves.left.and.right"},
        {"type": "toggle", "button": "<switch id>", "label": "Keep alive"}
      ]}
    ]}
  }
}
```

## Procedure

1. **Read the catalog** (`catalog`) and bind only keys it lists. Empty catalog: the phone hasn't
   synced yet; the typical keys above still work once it does.
2. **Pick sizes.** Always `small`; `medium`/`large` for more; `circular`, `rectangular`, `inline`
   when the user wants it on the Lock Screen. Keep each size to what fits the table above.
3. **Write the design** to a JSON file and `upsert` it. On `"errors"`, fix the paths they name and
   upsert again. Each `"warnings"` entry is a key the phone doesn't publish: it will show "—".
4. **Report** the `"phone"` note. A new design: the user adds the Jarvis widget (long-press the
   Home Screen or Lock Screen → +, or Edit Widget on one already placed) and picks it by name.
5. **To change one**, `show` it, edit, `upsert` with the same `id`; `delete` removes it.

## Pitfalls

- **Never invent a `button`/`toggle` id.** They are the ids of Control Center buttons the user
  made in the app (Settings → Widget creator → Control Center); `toggle` needs one that keeps
  state. Use an id the user gives you or one the phone lists in `catalog`; otherwise build the
  rest and tell the user to add the button in the creator. An unknown id draws a dimmed label.
- **Widgets are snapshots.** Values refresh when the phone publishes (opening Jarvis, syncs, about
  every 15 minutes), never per second. For a countdown use `timer`, which ticks on its own.
- **Lock Screen sizes are monochrome.** Don't let colour carry meaning there; `inline` keeps only
  text and one symbol.
- **`chart.style` is the chart kind** (`line`, `bar`, `area`), not a style object.
- **Hand-editing a builder design:** drop its `builder` field, or the app's builder keeps showing
  (and re-saves) the old layout. Without `builder` the app shows the design read-only.
- **Island keys don't belong here:** `expanded`, `lockScreen`, compact/minimal and `regions` are
  for `jarviscopilot-dynamic-island`.

## Verification

- `upsert` exits 0 with `"ok": true`, a `"version"`, the `"sizes"` you wrote and a `"phone"` note
  starting "Refreshed widgets on".
- `list` shows the design; `show <id>` returns what you wrote.
- On the phone it appears in Settings → Widget creator and renders in a placed widget.
