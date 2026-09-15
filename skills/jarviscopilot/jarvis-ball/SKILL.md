---
name: jarviscopilot-jarvis-ball
description: "Drive the Jarvis Ball (round 240 px ESP32 screen + speaker + mic): show generated pages like charts and weather, make and switch home screens, update live values, change its settings."
version: 1.0.0
author: JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [JarvisCopilot, JarvisBall, ESP32, Device, Display, Design]
---

# JarvisCopilot — Jarvis Ball

The Jarvis Ball is a small round device with a **240×240 px circular screen**, speaker and
mic. The user talks to you through it (wake word "Jarvis") in the same voice session as the
phone and Mac. When a voice turn comes from the ball, the turn instructions say so.

Its tools are `device_ball_*` (device bridge skills). Use them when the user asks to:

- **See something on the ball** ("show me today's NVIDIA chart", "put the weather on the ball") → `device_ball_show`
- **Make or change a home screen** ("make me a home page with the time and my next meeting") → `device_ball_home_save`
- **Switch home** ("set the ball to the clock") → `device_ball_settings_set {home}`
- **Keep a page fresh** ("update the weather every 30 minutes") → `device_ball_data` + a Jarvis cron job
- **Settings / status** → `device_ball_settings_get|set`, `device_ball_status`, `device_ball_system_info`, `device_ball_reboot`

## Shown page vs home page

| | `device_ball_show {page}` | `device_ball_home_save {page, make_home}` |
|---|---|---|
| Lifetime | Temporary: gone when the user presses Back, when you show another page, or on reboot | Saved on the ball (max 16) |
| Use for | Anything "show me …" | "make / set / design a home page" |
| After | Nothing to clean up | Appears in the app's home picker; `make_home` (default true) switches to it |

Built-in homes `orb` (voice orb, default) and `clock` can't be replaced or deleted.
Every page gets a ≡ menu button (top-left) and, when it isn't the home page, a ‹ Back
button (top-right) from the ball itself — don't draw your own.

## Page format

```json
{"id": "nvda", "title": "NVIDIA today",
 "root": {"type": "vstack", "style": {"gap": 6, "align": "center"}, "children": [
   {"type": "text", "value": "NVDA", "style": {"size": 20, "color": "muted"}},
   {"type": "text", "value": {"$": "price"}, "style": {"size": 40, "weight": "bold"}},
   {"type": "chart", "kind": "line", "points": {"$": "series"},
    "labels": {"first": "9:30", "last": "16:00"}, "style": {"color": "accent", "height": 70}},
   {"type": "badge", "text": {"$": "change"}, "style": {"color": "success"}}]},
 "data": {"price": "$142.10", "change": "+2.3%", "series": [139.8, 140.2, 141.0, 142.1]}}
```

Every node is `{"type", …props, "style": {…}, "children": […], "onTap": {…}}`.
`id` is optional (a-z 0-9 _ -, max 20; saving with an existing id replaces that home).

**Containers:** `vstack`, `hstack` (flex; `style.gap`, `style.align` left|center|right),
`zstack` (children overlap, centred; `style.width/height`), `spacer`.

**Leaves:**

| type | props |
|---|---|
| `text` | `value`; style `size` 12–64, `color`, `align` |
| `titleSubtitle` | `title`, `subtitle` |
| `stat` | `value` (big), `label` (small) |
| `symbol` | `name` — one of the names below; style `size`, `color` |
| `image` | `source`: a direct `https://…` link to a **JPEG or PNG** (up to 1.5 MB; photos are decoded and fitted to the box), or a small `data:image/png;base64,…` / `data:image/jpeg;base64,…`; style `width`, `height` (default 96). WebP/GIF/SVG won't show. |
| `badge` | `text`; style `color` (pill background) |
| `progress` | `value` 0–1; style `color`, `width` |
| `gauge` | `value`, `min`, `max` — an arc ring, great on a round screen; style `size` (diameter), `thickness`, `color` |
| `chart` | `kind` line\|bar, `points` (≤ 200 numbers), optional `min`/`max`, `labels {first,last}`; style `color`, `width` (180), `height` (80) |
| `timer` | `to` (unix seconds), `format` clock (HH:MM:SS) \| relative ("3d 4h"); ticks on the ball |
| `clock` | `format` (strftime, e.g. `"%H:%M"`); omit for the user's 12/24 h preference |
| `divider`, `dot` | style `color` (`dot` also `size`) |

**Values** can be literals or bindings `{"$": "key"}` read from the page's `data`. Built-in
keys update themselves every second: `time`, `date`, `weekday`, `battery`, `wifi`.

**Colours:** `accent`, `success`, `warning`, `danger` (the user's app theme), `text`,
`muted`, `bg`, or `#RRGGBB`. Prefer the tokens.

**Taps (`onTap`):** `{"action": "voice"}` starts listening; `{"action": "voice", "text": "Will it rain today?"}`
sends that text as a request and speaks your reply; `{"action": "home"}` goes home.

**Symbols (`symbol.name`):** wifi, battery.100, battery.75, battery.50, battery.25, battery.0,
bolt.fill, house.fill, gearshape.fill, bell.fill, play.fill, pause.fill, stop.fill,
forward.fill, backward.fill, speaker.wave.2.fill, speaker.wave.1.fill, speaker.slash.fill,
music.note, photo, video.fill, location.fill, mappin, phone.fill, envelope.fill, trash.fill,
pencil, eye.fill, eye.slash.fill, exclamationmark.triangle.fill, plus, minus, checkmark,
xmark, arrow.clockwise, arrow.up, arrow.down, chevron.left, chevron.right, power,
list.bullet, line.3.horizontal, folder.fill, doc.fill, square.and.arrow.down,
square.and.arrow.up, repeat, shuffle, keyboard, drop.fill, sdcard, circle.fill.
There are no weather glyphs: use text ("18°", "Rain"), a `gauge`, or an `image`.

**Text:** the ball's fonts are Latin (ASCII plus °). No emoji.

## Round-screen layout rules

- The root is centred and clipped to the circle. Keep important content inside the central
  **170×170 px** square; the top-left and top-right corners hold the menu and Back buttons.
- Aim for 3–5 elements. One hero element (big `stat`, `gauge` or `chart`) plus small labels reads best.
- Limits: 60 nodes, depth 8, 16 KB of JSON. Big lists don't fit — summarise.

## Workflow

1. Build the page (fetch the data first with your other tools).
2. Call `device_ball_show` or `device_ball_home_save`.
3. If the result is an error, it lists every problem as `json.path: message`
   (e.g. `root.children[2].name: unknown symbol "cloud" (did you mean …)`). Fix exactly those and call again.
4. Say what you put on the ball in one short sentence.

For values that change (prices, weather), save the page once with bindings, then push only
the numbers: `device_ball_data {"target": "home" | "shown", "data": {"price": "$143.02"}}`.

## Showing a picture

"Show me a picture of a red panda" → find a direct JPEG/PNG image URL with your web tools
(the file itself, ending in .jpg/.jpeg/.png — not a web page or a WebP), then:

```json
{"page": {"root": {"type": "image", "source": "https://upload.wikimedia.org/…/red_panda.jpg",
                   "style": {"width": 200, "height": 200}}}}
```

The circle clips it, so a centred subject reads best. Use a caption `text` below only if it
adds something. If the result says the image didn't load, try another URL.

## Examples

**Weather home**

```json
{"id": "weather", "title": "Weather",
 "root": {"type": "vstack", "style": {"gap": 4}, "children": [
   {"type": "clock", "style": {"size": 20, "color": "muted"}},
   {"type": "text", "value": {"$": "temp"}, "style": {"size": 48}},
   {"type": "text", "value": {"$": "summary"}, "style": {"size": 16, "color": "muted"}},
   {"type": "hstack", "style": {"gap": 12}, "children": [
     {"type": "stat", "value": {"$": "high"}, "label": "High"},
     {"type": "stat", "value": {"$": "low"}, "label": "Low"}]}]},
 "data": {"temp": "18°", "summary": "Light rain", "high": "21°", "low": "12°"}}
```

**Countdown gauge (shown)**

```json
{"root": {"type": "zstack", "style": {"width": 180, "height": 180}, "children": [
   {"type": "gauge", "value": 65, "min": 0, "max": 100, "style": {"size": 170, "thickness": 12}},
   {"type": "vstack", "children": [
     {"type": "timer", "to": 1789400000, "format": "relative", "style": {"size": 28}},
     {"type": "text", "value": "until launch", "style": {"size": 14, "color": "muted"}}]}]}}
```
