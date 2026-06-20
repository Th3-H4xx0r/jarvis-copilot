---
name: jarviscopilot-dynamic-island
description: "Author & manage iOS Dynamic Island / Live Activity designs: compose data-driven layout trees, push live data, pin or auto-select them — all without an app rebuild."
version: 1.0.0
author: JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [JarvisCopilot, iOS, DynamicIsland, LiveActivity, Widget, Design]
---

# JarvisCopilot — Dynamic Island Designs

Compose **new iOS Dynamic Island / Live Activity layouts on the fly** and bind them to
live data — no app rebuild. Use this skill when the user asks to:

- **Make a new island** ("put a deploy bar on my Dynamic Island", "show my next meeting countdown", "give me a battery + steps glance")
- **Update / push data to one** ("set the deploy to 80%", "the build is done")
- **Pick which island shows** ("show the deploy one", "go back to auto")
- **Tune when an island auto-appears** ("only show the deploy island while a build is running")

> **iOS only.** The Dynamic Island and Live Activity are iPhone features (iOS 17+).
> There is nothing to render on Android, the watch, or desktop — this skill is a no-op
> there. If the user is on another platform, say so instead of authoring a design.

## How it works (the load-bearing constraint)

iOS renders the Dynamic Island / Live Activity from a **WidgetKit extension compiled into
the signed app binary**. You cannot ship new SwiftUI over the wire. So a "design" is **not
code** — it's a declarative **layout tree (JSON)** that a single generic renderer baked into
the app (`JCDesignView`) interprets. You compose from a fixed, comprehensive element palette;
the app draws it.

Consequences you must design around:

- **Designs are cached on-device by `id`.** The `ContentState` ActivityKit pushes (~4 KB)
  carries only `{designId, version, data}` — never the layout. So a design must be created
  (`create`) before any data push to it lands.
- **Only a few things truly animate live:** native countdown/up timers (`timer`),
  progress/timer-driven `ProgressView`, and SF-Symbol effects. Every other value updates
  **only when you push new data** (or a server source resolves a new value).
- **One active design at a time** (single shared Live Activity, like today's voice/coding).
- The native **voice** and **coding-fleet** islands stay built in and non-editable — they
  show up in the catalog as `builtin` rows you can pin or include in Auto, but not delete.

## The design object (top level)

```jsonc
{
  "schema": 1,                  // schema version int — leave at 1
  "id": "deploy-status",        // stable kebab id; re-using it = update (upsert)
  "version": 7,                 // bump on every meaningful edit (renderer caches by id+version)
  "name": "Deploy status",      // shown in the settings tab
  "icon": "shippingbox.fill",   // SF Symbol name for the catalog row
  "tint": "#0a84ff",            // accent hex
  "presentations": {
    "expanded":       <Node>,   // big island (long-press) + lock-screen if no lockScreen
    "lockScreen":     <Node>,   // optional — separate lock-screen layout
    "compactLeading": <Node>,   // tiny pill, left  of the camera
    "compactTrailing":<Node>,   // tiny pill, right of the camera
    "minimal":        <Node>    // single glyph when another activity shares the island
  }
}
```

Always provide at least `expanded`, `compactLeading`, `compactTrailing`, and `minimal`.
`lockScreen` is optional (falls back to `expanded`). Keep compact/minimal **tiny** — a symbol
or one short value; iOS gives them almost no room.

A **`Node`** is `{ "type": "...", ...props, "style"?: {...}, "when"?: <expr> }`.

### Layout & safe margins (rounded corners + the camera) — READ THIS

The Dynamic Island and Lock-Screen banner have **rounded corners**, and the expanded island
wraps around the **front camera** at top-center. Content flush to the edges gets clipped and
anything centered at the very top collides with the camera. The renderer does **not** add
insets for you, so design with breathing room:

- **The expanded island is CAPPED at ~144pt by iOS — fill it, don't exceed it.** This is a hard
  system limit (even Spotify/Apple Music hit it). The goal is to FILL ~144pt cleanly, not to add
  endless rows: **overstuffing clips the lower rows** (they get cut off, like our first demo did).
  Aim for ~3–4 well-sized rows total.
- **To fill the cap (Spotify/Apple-Music style), use the `regions` container + balance.** The
  expanded height = the top row (`leading`/`trailing`/`center`, beside the camera) **plus**
  `bottom`. Put a **moderate album-art-style `image` (~50pt) in `leading`**, the title in `center`,
  an accent in `trailing`, and progress + a control row in `bottom`. Add `"style":{"minHeight":~86}`
  to the `bottom` container to nudge it to fill the cap. A bottom-only tree leaves the top row
  collapsed (short); too much content clips. (See the built-in "UI Example (max size)" design.)
- **Don't over-pad — especially the top.** The renderer ALREADY adds safe margins (it insets the
  expanded island horizontally and the lock screen on all sides), so your design should add little
  or NO root padding. `style.padding` is **uniform (all edges)**, so a big value adds an unwanted
  top/bottom gap and pushes content down. Use **0–4 at most** on the root; rely on the renderer's
  margins + a `spacer` for spacing.
- **Put content BESIDE the camera with `regions` — don't dump everything below it.** A
  non-`regions` `expanded` tree lands ENTIRELY in the **bottom** (full-width, below the camera),
  leaving the space beside the camera empty — that's why a stack/grid root renders only below the
  pill. To use the sides, make `expanded` a **`regions`** node:
  - `leading` and `trailing` **flank the camera** — they are **narrow**, so put *compact* content
    there: a logo `image` (~16–24pt), a short code/flight #, a status `badge`, a `dot`, or a
    `timer`. **Not** wide text or a 3-airport route.
  - `center` sits just under the camera — a small title or single glyph (or leave it empty).
  - `bottom` is **full-width** — put the wide stuff here: routes (`SFO → LHR → BLR`), progress
    bars, times, lists. Give it `"style":{"minHeight":~80}` to fill toward the cap.
  - e.g. a **flight**: logo + flight # in `leading`, status / "Leg 1 of 2" in `trailing`, the
    route + progress + times in `bottom` (see the "Flight VS20" example below).
  You **cannot** render *above* the camera (it's the physical lens) — only beside (`leading`/
  `trailing`) and below (`center`/`bottom`).
- **Stop rows from running together.** Put a `spacer` between a leading label and a trailing
  value; set `lineLimit` on `text`; keep `grid` / `list` to **≤ 3 columns**.
- **Don't pin widths near the screen edge.** Let elements size to content and use `spacer` for
  distribution; avoid large fixed `style.width`.
- **Compact pills are ~30 pt each, beside the camera** — one symbol or a ≤ 4-char value;
  `minimal` is a single glyph/dot. Never put long text there.

### Containers

| type | props | notes |
|---|---|---|
| `hstack` | `children[]`, `spacing?`, `align?` | horizontal row |
| `vstack` | `children[]`, `spacing?`, `align?` | vertical column |
| `zstack` | `children[]`, `align?` | layered (back→front) |
| `grid` | `columns`, `children[]`, `spacing?` | fixed-column grid |
| `list` | `data:<ValueRef array>`, `row:<Node>`, `columns?`, `max?`, `empty?:<Node>` | repeats `row` per item; inside `row` use `{"$row":"field"}` |
| `spacer` | `minLength?` | flexible gap |
| `regions` | `leading?`, `trailing?`, `center?`, `bottom?` | **only as the root of `expanded`** → maps to native DI regions |

`align`: `"leading" \| "center" \| "trailing" \| "top" \| "bottom"`. `spacing`/`minLength`: numbers (pt).

### Leaf elements

| type | props |
|---|---|
| `text` | `value`, `lineLimit?` |
| `titleSubtitle` | `title`, `subtitle` |
| `stat` | `value`, `unit?`, `caption?` |
| `symbol` | `name` (SF Symbol), `effect?` (e.g. `"pulse"`, `"bounce"`, `"variableColor"`) |
| `symbolValue` | `symbol`, `value` |
| `image` | `source` (SF Symbol name, the reserved `"orb"`, **or an `http(s)` image URL** — also accepts a `{"$":k}`/`{"src":k}` binding resolving to one of those), `fallback?` (SF Symbol shown until a remote image is cached), `shape?` (`"circle"`/`"rounded"`/`"rect"`), `style.width/height` |
| `dot` | `color` |
| `badge` | `text`, `color?` |
| `progress` | `value` (0–1), `tint?` |
| `segbar` | `segments:<ValueRef → array of {weight,color}>` |
| `gauge` | `style:"single"\|"concentric"`, `rings:[{value,tint}]`, `label?` |
| `timer` | `to` (date ValueRef — ISO string / epoch), `mode?` (`"countdown"`/`"countup"`), `format?` (`"relative"` = "5 days, 18 hr" → "23 min", best for **multi-day**; omit = clock `HH:MM:SS` that ticks every second). **Both tick on-device offline** — give a real future/past `to`, never pre-format the countdown as static `text`. |
| `keyValue` | `pairs:[{label,value}]` |
| `sparkline` | `points` (ValueRef → number array), `kind?` (`"line"`/`"bar"`), `tint?` |
| `iconStrip` | `items` (ValueRef → array of SF Symbol names), `max?` |
| `waveform` | `active?` (bool) |
| `divider` | — |
| `accent` | `color` |

**Remote images (`image.source` = an `http(s)` URL):** the widget extension cannot
fetch at render time, so the app **pre-downloads** referenced URLs into the App
Group cache and the widget renders them **from disk** — which means they also
display **offline** once cached (e.g. an airline logo during a flight). The first
render after a new URL appears may briefly show the `fallback` SF Symbol (or a
placeholder dot) until the download lands, then it sticks. Use a small size
(logos look right at ~14–22 pt) and always set a `fallback` so the leaf is never
blank. Prefer a stable, hotlink-friendly image URL.

Any prop above that takes a value can be a **literal or a ValueRef** (next section).
`timer` is the one truly-live, server-independent element — it keeps ticking while the phone
is asleep because iOS drives it natively. Prefer it for any countdown/elapsed display.

### `style` object (all keys optional)

`color`, `font`, `size`, `weight`, `opacity`, `padding`, `align`, `tint`, `width`, `height`.

Colors are hex strings (`"#34c759"`) or named system colors. `weight`: `"regular"`/`"medium"`/
`"semibold"`/`"bold"`. The renderer **skips unknown node types and props gracefully** (omit or
placeholder), so forward-compat is safe — but don't rely on that to author garbage.

## ValueRef — the binding mini-language (safe, no eval)

Anywhere a value is expected, use one of:

| form | meaning |
|---|---|
| **literal** | `"Live"`, `42`, `true` — used as-is |
| **data binding** `{"$":"key"}` | path into the pushed `data` object (dotted paths ok: `{"$":"deploy.pct"}`) |
| **source binding** `{"src":"battery.level"}` | a **known live source** the client/server resolves into `data` upstream |
| **row field** `{"$row":"name"}` | a field of the current item — **only inside a `list` `row`** |

Add transforms to any binding:

- **`"fmt"`** — Python-style `{}` template applied to the resolved value: `{"$":"pct","fmt":"{}%"}` → `42%`.
- **`"map"`** — value→value lookup: `{"$":"phase","map":{"working":"#34c759","failed":"#ff3b30"}}`.

You can combine them: resolve → `map` → `fmt`.

### v1 source registry (`{"src":"..."}`)

| source | type | resolved by | live while phone asleep |
|---|---|---|---|
| `jarvis.*` (any key you choose) | any | **server** (you set it via `set-data`) | ✅ |
| `coding.usage5` / `coding.usageWeek` | number | client/server | ✅ (server) |
| `coding.fleet` | array | client/server | ✅ (server) |
| `calendar.next` → `{title,start}` | object | client EventKit / server | ✅ if server-backed |
| `weather.*` | num/str | server | ✅ |
| `time.now`, timer dates | date | native | ✅ |
| `device.online` | array | client `/api/devices` | ✅ (server) |
| `battery.level` / `battery.state` | num/str | client | ⚠️ **frozen** when asleep |
| `location.place` | str | client | ⚠️ frozen |
| `health.heartRate` / `health.steps` | num | client HealthKit | ⚠️ frozen |

**Resolution model:** the widget only ever reads `data` + `$row`. Sources are resolved
*upstream* into `data` keys — by the **coordinator** while the app is awake, by the **server**
while the phone is suspended. So:

- For an island that must **stay live while the phone is asleep**, lean on **server-resolvable
  sources**: `jarvis.*` (you push), `coding.*`, `weather.*`, server-backed `calendar.*`, plus
  native `timer`.
- **Device-only sources freeze** at their last value while suspended: `battery.*`, `location.*`,
  `health.*`. Fine for glanceable islands the user opens; don't build a sleep-critical island
  on them.
- The **`jarvis.*` path is the main one for Jarvis-driven islands**: design once with
  `{"$":"..."}` bindings, then `set-data` to push fresh values (which also triggers the push).

## `when` conditions & auto-rule expressions

Both per-node visibility (`"when"` on any Node) and auto-selection rules use the same safe
JSON expression form:

```jsonc
{ "op": "<operator>", ...operands }
```

| op | operands | true when |
|---|---|---|
| `and` | `{"op":"and","items":[<expr>,...]}` | all items true |
| `or` | `{"op":"or","items":[<expr>,...]}` | any item true |
| `not` | `{"op":"not","item":<expr>}` | item false |
| `eq` / `ne` | `a`, `b` | a == b / a != b |
| `gt` / `lt` | `a`, `b` | a > b / a < b |
| `exists` | `a` | a is present / non-null |
| `between` | `a`, `lo`, `hi` | lo ≤ a ≤ hi |

Operands are themselves ValueRefs or literals, e.g.
`{"op":"gt","a":{"src":"battery.level"},"b":20}` or
`{"op":"eq","a":{"$":"phase"},"b":"failed"}`.

- **Node `when`:** hide/show a sub-tree. e.g. a "build failed" banner with
  `"when":{"op":"eq","a":{"$":"phase"},"b":"failed"}`.
- **Auto rules** (`island.py rules`): `conditions` is one such expr; the design joins the Auto
  pool when its `conditions` match **and** its `schedule` window includes now, ranked by
  `priority` (higher wins).

### Auto-selection in one line

Selection is `{mode:"pinned",pinnedId?}` or `{mode:"auto"}`. In **auto**: a live voice turn
always wins (and restores after); otherwise among **enabled** designs whose `conditions` +
`schedule` match now, the highest `priority` wins; nothing matches → resting/clear. Built-in
coding's condition is "live sessions > 0".

`schedule` shape: `{"days":[1,2,3,4,5],"from":"09:00","to":"18:00"}` (days = 1=Mon … 7=Sun;
omit `days` for every day; omit the whole schedule for always-eligible).

## Authoring rules (must follow)

- **Depth ≤ 12, total nodes ≤ 160.** The validator rejects oversize trees at create time and the
  renderer clamps defensively. Keep compact/minimal presentations to 1–3 nodes.
- **Create before you push.** `set-data` to an unknown `id` has nothing to render. Order:
  `create` → (`pin` or rely on `auto`) → `set-data` as values change.
- **Bump `version`** whenever you change the layout, so the device re-caches it. Same `id`,
  higher `version`.
- **Sleep-critical → server sources + `timer`.** If the island must update while the phone is
  in the user's pocket, bind to `jarvis.*` / `coding.*` / `weather.*` / server `calendar.*`,
  or use a native `timer`. Don't depend on `battery.*` / `location.*` / `health.*` for that.
- **Respect the rounded corners + camera, but don't over-pad.** The renderer already adds safe
  margins, so keep root `style.padding` to **0–4** (it's uniform/all-edges — big values add an
  unwanted top/bottom gap). Avoid the top-center, and put a `spacer` between leading/trailing
  items. See **Layout & safe margins** above.
- **NEVER compute a countdown/clock string into a `text` value — this is the #1 mistake.** A
  `text` like `"BLR in 5d 18h"`, `"4:18"`, or `"-0:09"` is **frozen**: it only changes when you
  push new data, so it reads stale within seconds and dies offline. For ANY remaining / elapsed /
  clock time, use a **`timer`** node bound to the absolute target date (`"to"`); for a progress
  fill use **`timeProgress {from,to}`** — both tick on-device with **no network**. For a
  **multi-day** countdown set `"format":"relative"` (→ `"5 days, 18 hr"` → `"23 min"`); omit it for
  a per-second clock `HH:MM:SS`. Do **not** pre-format the time yourself — let the node do it.
- **Keep `data` small** (it rides in a ~4 KB push). Push only the keys your bindings read.
- **SF Symbols only** for `symbol`/`icon`/`iconStrip` (e.g. `bolt.fill`, `checkmark.seal.fill`).
- **Don't author for non-iOS users.** Check the platform first.

---

## Offline plans (no service — e.g. on a flight)

When the phone loses service, the server can't push, so an island normally goes
stale. To keep it updating OFFLINE, build the design with **time-aware** pieces
that the device runs locally — set this up BEFORE the user loses service. Three
offline-capable tools:

1. **Time-driven elements (continuous, 100% offline, system-rendered):**
   - `timer {to, mode}` — auto-ticking countdown/up.
   - **`timeProgress {from, to}`** — a bar that fills from `from`→`to` (epoch
     seconds or ISO) **on its own, no network** — the flight-progress bar.
   Bind these to ABSOLUTE dates (departure/arrival), not server values.
2. **`timeline: [{at, data}]`** (top-level design field) — discrete keyframes
   applied by the clock. The device overlays the data of the entry with the
   greatest `at` (epoch s) ≤ now. Use for phases (boarding → in-flight → landed).
   Best-effort while the phone is fully suspended; advances whenever the user
   glances / a notification reopens the app; the time-driven bar covers the gap.
3. **`notifications: [{at, title, body}]`** (top-level) — pre-scheduled LOCAL
   notifications that fire offline at exact times (boarding call, "landing soon").

**Install flow:** while online, `create`/`update` the design with these fields and
`pin` it. The device caches it; the island then runs offline. (Keep the design's
visible text values in `timeline` keyframes or as literals — `{"src":...}` device
sources freeze offline; `timeProgress`/`timer` are the live offline elements.)

```jsonc
// Flight VS20 — keeps progressing offline
{ "id":"flight-vs20","version":1,"name":"Flight VS20","icon":"airplane","tint":"#0a84ff",
  "presentations": { "expanded": { "type":"regions",
    // logo + flight # flank the camera on the LEFT (leading is narrow — keep it compact):
    "leading": {"type":"hstack","spacing":6,"children":[
      {"type":"image","source":"https://pics.avs.io/200/200/VS.png","fallback":"airplane","shape":"rounded","style":{"width":20,"height":20}},
      {"type":"text","value":"VS20","style":{"size":20,"weight":"bold"}}]},
    // status flanks the camera on the RIGHT:
    "trailing": {"type":"vstack","spacing":1,"style":{"align":"trailing"},"children":[
      {"type":"badge","text":{"$":"phase"},"color":"#34c759"},
      {"type":"timer","to":{"$":"arriveAt"},"format":"relative","style":{"size":13}}]},
    // wide content (route + progress) goes full-width BELOW the camera:
    "bottom": {"type":"vstack","spacing":10,"style":{"minHeight":80},"children":[
      {"type":"timeProgress","from":{"$":"departAt"},"to":{"$":"arriveAt"},"tint":"#0a84ff"},
      {"type":"hstack","children":[
        {"type":"text","value":"SFO"},{"type":"spacer"},{"type":"text","value":"LHR"}]}
    ]}}},
  // departAt/arriveAt are epoch seconds; phase advances by the clock offline:
  "timeline":[
    {"at":1718000000,"data":{"phase":"Boarding","departAt":1718003600,"arriveAt":1718039600}},
    {"at":1718003600,"data":{"phase":"In flight"}},
    {"at":1718039600,"data":{"phase":"Landed"}}],
  "notifications":[
    {"at":1718002800,"title":"Boarding soon","body":"VS20 gate A12"},
    {"at":1718038000,"title":"Landing soon","body":"VS20 → LHR"}]
}
```

---

## Worked examples

### 1. Deploy status (server-pushed `jarvis.*`, lives while asleep)

```json
{
  "schema": 1,
  "id": "deploy-status",
  "version": 1,
  "name": "Deploy status",
  "icon": "shippingbox.fill",
  "tint": "#0a84ff",
  "presentations": {
    "expanded": {
      "type": "regions",
      "leading":  { "type": "symbol", "name": "shippingbox.fill",
                    "style": { "tint": { "$": "phase", "map": { "build": "#0a84ff", "deploy": "#5e5ce6", "done": "#34c759", "failed": "#ff3b30" } } } },
      "trailing": { "type": "badge", "text": { "$": "phase" } },
      "center":   { "type": "titleSubtitle", "title": { "$": "service" }, "subtitle": { "$": "commit" } },
      "bottom":   { "type": "vstack", "spacing": 6, "children": [
        { "type": "progress", "value": { "$": "frac" }, "tint": "#0a84ff" },
        { "type": "hstack", "children": [
          { "type": "text", "value": { "$": "pct", "fmt": "{}%" } },
          { "type": "spacer" },
          { "type": "text", "value": { "$": "eta" } },
          { "type": "badge", "text": "FAILED", "color": "#ff3b30",
            "when": { "op": "eq", "a": { "$": "phase" }, "b": "failed" } }
        ] }
      ] }
    },
    "compactLeading":  { "type": "symbol", "name": "shippingbox.fill" },
    "compactTrailing": { "type": "text", "value": { "$": "pct", "fmt": "{}%" } },
    "minimal":         { "type": "symbol", "name": "shippingbox.fill" }
  }
}
```

Push data as the deploy progresses:

```bash
# frac drives the 0-1 progress bar; pct is the 0-100 integer the "{}%" text shows.
python3 "$SCRIPT" set-data deploy-status --json '{"service":"api","commit":"a1b2c3d","phase":"build","frac":0.4,"pct":40,"eta":"~3m"}'
python3 "$SCRIPT" set-data deploy-status --json '{"service":"api","commit":"a1b2c3d","phase":"done","frac":1.0,"pct":100,"eta":"done"}'
```

### 2. Countdown to next meeting (native `timer` + server calendar — ticks while asleep)

```json
{
  "schema": 1,
  "id": "next-meeting",
  "version": 1,
  "name": "Next meeting",
  "icon": "calendar.badge.clock",
  "tint": "#5e5ce6",
  "presentations": {
    "expanded": {
      "type": "vstack", "spacing": 4, "align": "leading",
      "children": [
        { "type": "hstack", "spacing": 6, "children": [
          { "type": "symbol", "name": "calendar.badge.clock" },
          { "type": "text", "value": { "src": "calendar.next.title" },
            "style": { "weight": "semibold" }, "lineLimit": 1 }
        ] },
        { "type": "timer", "mode": "countdown", "to": { "src": "calendar.next.start" },
          "style": { "size": 22, "weight": "bold", "tint": "#5e5ce6" } }
      ]
    },
    "compactLeading":  { "type": "symbol", "name": "calendar" },
    "compactTrailing": { "type": "timer", "mode": "countdown", "to": { "src": "calendar.next.start" } },
    "minimal":         { "type": "symbol", "name": "calendar" }
  }
}
```

Make it auto-appear on weekdays during work hours:

```bash
python3 "$SCRIPT" rules next-meeting --enabled true --priority 40 \
  --when '{"op":"exists","a":{"src":"calendar.next.start"}}' \
  --schedule '{"days":[1,2,3,4,5],"from":"08:30","to":"18:00"}'
python3 "$SCRIPT" auto
```

### 3. Simple stat glance (battery + steps — device sources, opened by the user)

```json
{
  "schema": 1,
  "id": "body-glance",
  "version": 1,
  "name": "Glance",
  "icon": "heart.fill",
  "tint": "#ff375f",
  "presentations": {
    "expanded": {
      "type": "hstack", "spacing": 16,
      "children": [
        { "type": "stat", "value": { "src": "battery.level", "fmt": "{}%" }, "caption": "battery" },
        { "type": "divider" },
        { "type": "stat", "value": { "src": "health.steps" }, "caption": "steps" },
        { "type": "divider" },
        { "type": "symbolValue", "symbol": "heart.fill", "value": { "src": "health.heartRate" } }
      ]
    },
    "compactLeading":  { "type": "symbolValue", "symbol": "battery.100", "value": { "src": "battery.level", "fmt": "{}%" } },
    "compactTrailing": { "type": "symbolValue", "symbol": "heart.fill", "value": { "src": "health.heartRate" } },
    "minimal":         { "type": "symbol", "name": "heart.fill" }
  }
}
```

> Note: `battery.*` / `health.*` are **device sources** — they freeze at their last value while
> the phone is asleep. That's fine for a glance the user opens, but don't pin this one expecting
> live updates in-pocket.

---

## Helper script — subcommand reference

All operations go through one stdlib-only Python helper that talks to the running webui's REST
API over localhost, authenticating with the host signing-key carve-out (no cookies needed — same
mechanism as the `devices` skill). Resolve it once:

```bash
SCRIPT="$(find ~/.jarviscopilot /root /home -path '*skills/jarviscopilot/dynamic-island/scripts/island.py' 2>/dev/null | head -1)"
[ -z "$SCRIPT" ] && SCRIPT="$(find / -path '*skills/jarviscopilot/dynamic-island/scripts/island.py' 2>/dev/null | head -1)"
python3 "$SCRIPT" <subcommand> [args...]
```

| subcommand | endpoint | purpose |
|---|---|---|
| `list` | `GET /api/island/designs` | print `{designs, catalog, selection}` |
| `create --json '{...}'` / `--file path.json` | `POST /api/island/designs` | validate + upsert a design → `{ok, id}` |
| `update --json '{...}'` / `--file path.json` | `POST /api/island/designs` | same upsert (alias of create) |
| `delete <id>` | `DELETE /api/island/designs/<id>` | remove a custom design |
| `set-data <id> --json '{...}'` / `--file path.json` | `POST /api/island/designs/<id>/data` | push `jarvis.*` values + trigger push |
| `pin <id>` | `POST /api/island/selection` `{mode:"pinned",pinnedId:<id>}` | make `<id>` the active island |
| `auto` | `POST /api/island/selection` `{mode:"auto"}` | hand selection to the rules engine |
| `rules <id> [--enabled b] [--priority N] [--when JSON] [--schedule JSON]` | `POST /api/island/designs/<id>/rules` | tune auto-selection for `<id>` |

```bash
python3 "$SCRIPT" list
python3 "$SCRIPT" create --file deploy.json
python3 "$SCRIPT" create --json '{"schema":1,"id":"x","version":1,"name":"X","presentations":{...}}'
python3 "$SCRIPT" update --file deploy.json          # same upsert, bump version inside
python3 "$SCRIPT" delete deploy-status
python3 "$SCRIPT" set-data deploy-status --json '{"frac":0.8,"pct":80,"phase":"deploy"}'
python3 "$SCRIPT" pin deploy-status
python3 "$SCRIPT" auto
python3 "$SCRIPT" rules deploy-status --enabled true --priority 50 \
  --when '{"op":"eq","a":{"$":"phase"},"b":"build"}'
```

**Output & errors.** Every command prints JSON to stdout on success (exit 0). On bad input or an
HTTP error it prints a JSON error object to stderr and exits 1, e.g.
`{"error":"input isn't valid JSON: ..."}` or `{"error":"webui returned 400","detail":{...}}`.
The server validator is the source of truth for design validity — a malformed tree comes back as a
400 with validator detail; read it and fix the design rather than guessing.

## Important rules (recap)

- **iOS only** — check the platform before authoring; otherwise tell the user it's not available.
- **Create before set-data**; **bump `version`** on every layout edit.
- **Depth ≤ 12 / ≤ 160 nodes** (fill the expanded space when you have a lot); tiny compact + minimal presentations.
- **Sleep-critical islands → server sources (`jarvis.*`/`coding.*`/`weather.*`/server calendar) +
  native `timer`.** Device sources (`battery`/`location`/`health`) freeze when suspended.
- **Persona styling:** if the user has set a personality (e.g. JARVIS), keep the persona voice
  when reporting what you built — don't drop into a generic CLI tone.
