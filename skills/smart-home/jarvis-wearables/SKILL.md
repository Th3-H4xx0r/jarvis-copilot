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

The `wearables_*` skills below are always present, whether or not any bottle is
connected. `wearables_list` is the cheapest way to see what exists and what state
it's in.

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

## When a device isn't responding

**A paired device's skills are always advertised, connected or not.** The app
reconnects on demand: invoking `bottle_get_status` on a bottle whose link is down
brings the link up first, so the usual answer to "is it connected?" is just to run
the command. Give it a few seconds.

If that returns `device is not connected over Bluetooth`, work the recovery path
instead of giving up — the bottle is out of range, off, or asleep:

| Skill | Arguments | What it does |
|---|---|---|
| `wearables_list` | — | Every paired wearable: connected state, signal, when last seen, and the commands each offers. |
| `wearables_scan` | `seconds` (3–15, default 6) | Bluetooth scan; returns what's nearby with signal strength. |
| `wearables_connect` | `wearable_id` | Brings one paired device's link up. Returns `connected: false` with a reason when it can't. |

The sequence is **`wearables_scan` → `wearables_connect` → retry the command**.

Two things to note. `wearables_connect` takes **`wearable_id`**, not `device_id` —
`device_id` is the argument that picks *which* device a command runs on, and using
it here would mean "run this on the bottle". And `wearables_connect` only works for
devices already paired in the app; it will not adopt a new one, so an unrecognised
id is a genuine dead end that needs the user to pair it on their phone.

If `bluetooth_ready` comes back `false`, Bluetooth is off on the phone — tell the
user that rather than reporting the device as missing.

Invoke one:

```bash
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py \
  invoke <device_id> bottle_sterilise --json-args '{"on": true, "confirm": true}'
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

## Do not gate on `bridge_connected`

`/api/devices` reports `bridge_connected: false` for a phone whose app is
backgrounded — iOS suspends it and the WebSocket closes. **That does not mean the
device is unreachable.** `invoke_skill` falls back to a silent push, so the command is
queued and delivered when the app wakes.

Check **`invokable`** instead, or simply that the device lists `bottle_*` skills. If it
does, call the skill; a slow response means "the phone is waking", not "it failed".

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

**No `bottle_*` skills in the list.** These are advertised whether or not the
bottle is connected, so their absence means the *phone* isn't reachable, not the
bottle. In order:
1. The app must be paired (Settings → Jarvis Copilot shows "Online").
2. The bottle must have been paired in the app at least once — a device that has
   never been shared has no catalogue to advertise.
3. **Bridge mode** must be on, or the app drops its Bluetooth link when backgrounded.

**`device is not connected over Bluetooth`.** The app is reachable but the bottle
isn't. Run `wearables_scan`, then `wearables_connect`, then retry — see **When a
device isn't responding**.

**Skills listed but invokes time out.** The phone is likely backgrounded past its runtime
allowance. iOS grants background execution while the app holds a Bluetooth connection, but
not indefinitely. Invokes are queued server-side and delivered when the app next wakes, so
a slow response usually means "the phone will get to it", not "it failed".


## Protocol reference

The full byte-level protocol, reverse-engineered from the stock VSITOO app, lives in
`PROTOCOL.md` in the JarvisWearables repo: GATT UUIDs, every opcode, and the layout of the
18-byte status frame. Needed only for `bottle_raw_command`.

## Smart ring

The Colmi R12 smart ring has its own skill, **`jarvis-ring`** — its `ring_*` commands,
data model, recipes and Python SDK are documented there. `wearables_list`,
`wearables_scan` and `wearables_connect` cover the ring as well: when a `ring_*` command
reports the ring isn't connected, use the same scan → connect → retry path.
