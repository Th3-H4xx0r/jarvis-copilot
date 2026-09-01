---
name: jarvis-wearables
description: "Discover and control smart drinkware paired through the JarvisWearables iOS app — read water temperature, battery and sterilisation state, and run UV-C cleaning cycles."
version: 1.0.0
author: pranav
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Wearables, Bluetooth, IoT, Hydration]
---

# Jarvis Wearables

The **JarvisWearables** iOS app pairs to this server as a device and advertises each
bottle it is connected to over Bluetooth. Its commands arrive as ordinary device skills,
so you drive them exactly like any other paired device — no special endpoint.

## Discovering what's available

The app registers one set of `bottle_*` skills per connected product. To see them:

```bash
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py list
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py skills
```

A paired bottle looks like `JarvisWearables (iPhone)` in the device list, with skills
named `bottle_*`. If none appear, the app isn't connected — see **Troubleshooting**.

Start with `bottle_get_status`: it returns the full state and confirms the link is live.

## Commands

Every command takes an optional `device_id`; omit it when only one bottle is connected.

| Skill | Arguments | What it does |
|---|---|---|
| `bottle_get_status` | — | Full state snapshot. Always safe. |
| `bottle_sterilise` | `on` (bool), `confirm` (bool) | Starts/stops a UV-C cycle. **Starting requires `confirm: true`.** |
| `bottle_set_uv_intensity` | `level`: `normal` \| `strong` | Lamp power. `strong` costs noticeably more battery. |
| `bottle_auto_clean` | `on` (bool) | Scheduled daily auto-sterilise. |
| `bottle_touch_lock` | `on` (bool) | Locks the lid's touchscreen. |
| `bottle_reminders` | `on` (bool) | Drink-reminder alerts on the bottle. |
| `bottle_set_screen_seconds` | `seconds` (3–15) | Lid display timeout. |
| `bottle_daily_reset` | `on` (bool) | Bottle clears its own stats at 24:00 daily. |
| `bottle_sync_clock` | — | Sets the bottle's clock from the phone. |
| `bottle_raw_command` | `hex`, `confirm` (bool) | Raw bytes to characteristic A301. Protocol work only. |

Invoke one:

```bash
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py \
  invoke <device_id> bottle_sterilise '{"on": true, "confirm": true}'
```

## What the status snapshot contains

```json
{
  "device_id": "A4:C1:38:99:2D:08",
  "model": "VSITOO S1 Pro",
  "connected": true,
  "water_temperature_c": 31,
  "water_temperature_f": 88,
  "battery_percent": 99,
  "charging": true,
  "sterilising": false,
  "sterilise_percent_complete": 0,
  "sterilise_cycles_total": 3,
  "uv_intensity": "normal",
  "auto_sterilise_enabled": false,
  "touch_locked": false,
  "reminders_enabled": true,
  "screen_seconds": 5,
  "daily_auto_reset": false,
  "firmware_version": "1.0.4",
  "hardware_version": "1.0.3",
  "raw_status_frame": "07031F630500640000010001FFFFF357FFFF"
}
```

`sterilise_percent_complete` is derived: the bottle reports a **countdown**, so the app
returns its complement. `raw_status_frame` is the undecoded 18-byte `07` response, useful
when a field looks wrong.

## Behaviour worth knowing

- **Starting a UV cycle is a real-world action.** It runs a lamp inside the bottle and
  measurably drains its battery — roughly 14% for one cycle on `strong`. Ask the user
  before starting one unless they've clearly just asked for it. `confirm: true` is
  required by the schema so this can't happen accidentally.
- **Commands return the state *after* the change.** Each one is followed by a status read,
  so the response reflects the result rather than the state beforehand. There's about a
  second of settling built in.
- **`bottle_touch_lock` disables the lid's touchscreen**, which means the bottle stops
  waking to show its own temperature. Users read that as "it's broken". Turn it back off.
- Temperature is always reported in **both** units; the app's °C/°F setting is display-only
  and doesn't affect this.

## Troubleshooting

**No `bottle_*` skills in the list.** The phone must be connected. In order:
1. The app must be paired (Settings → Jarvis Copilot shows "Online").
2. **Bridge mode** must be on, or the app drops its Bluetooth link when backgrounded.
3. The bottle must be in Bluetooth range of the phone and connected in the app.

**Skills listed but invokes time out.** The phone is likely backgrounded past its runtime
allowance. iOS grants background execution while the app holds a Bluetooth connection, but
not indefinitely. Invokes are queued server-side and delivered when the app next wakes, so
a slow response usually means "the phone will get to it", not "it failed".

**`device is not connected over Bluetooth`.** The app is reachable but the bottle isn't —
it's out of range, or off.

## Protocol reference

The full byte-level protocol, reverse-engineered from the stock VSITOO app, lives in
`PROTOCOL.md` in the JarvisWearables repo: GATT UUIDs, every opcode, and the layout of the
18-byte status frame. Needed only for `bottle_raw_command`.
