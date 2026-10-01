---
name: jarvis-x5-ring
description: Read and control the X5 touch ring through the phone.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Wearables, Bluetooth, Health, Sleep, Fitness, Gestures]
    category: smart-home
    related_skills: [jarvis-ring]
---

# X5 Ring Skill

The **X5 smart ring** is a touch ring that records steps, sleep, heart rate, HRV, stress, SpO₂
and skin temperature, and reads nine touch gestures. The Jarvis iOS app holds its Bluetooth
link and advertises its commands as `x5_*` device skills; their day, history and status JSON
is the same shape as the Colmi R12's `ring_*` skills (see `jarvis-ring`). This skill does not
flash firmware, send raw bytes or factory-reset the ring.

## When to Use

- The user asks about sleep, steps, heart rate, SpO₂, HRV, stress or temperature and the X5 is
  the ring they wear (or the one chosen in Health settings → "Ring for Jarvis Health").
- They want a spot reading, a workout started or ended, or the ring found.
- They want to change what a gesture on the ring does, or switch the ring into a keyboard mode
  (short videos, music, camera).

## Prerequisites

- The Jarvis iOS app paired with this server and reachable, with the X5 connected once in the
  app and **Share with Jarvis** on. The skills stay advertised while the ring is away.
- In a Jarvis conversation the skills are already tools: `device_x5_get_status`,
  `device_x5_measure` and so on, with an optional `device` argument to pick the phone.
- For scripts: the bundled `jarviscopilot/devices` skill (its `devices.py` signs requests to the
  web UI). `scripts/x5.py` finds it next to this skill, then under `$JARVISCOPILOT_DIR/skills`,
  `$HERMES_HOME/skills` and `~/.jarviscopilot/skills`.

## How to Run

Call the device tools directly. From a script or cron job, run `scripts/x5.py` with
`terminal` (stdlib only, Python 3.10+); it prints the skill's JSON, or `{"error": ...}` on
stderr with exit code 1:

```bash
X5="$HERMES_HOME/skills/smart-home/jarvis-x5-ring/scripts/x5.py"
python3 "$X5" status
python3 "$X5" day --metrics sleep,heart_rate,hrv --detail
python3 "$X5" measure spo2
python3 "$X5" workout start --sport walk
python3 "$X5" gesture-mode jarvis --touch-awake always
python3 "$X5" gesture-action swipe_up --prompt "What's next on my calendar?"
python3 "$X5" gesture-action double_tap --skill x5_measure --arg type=heart_rate
python3 "$X5" --device iphone history --days 14
```

In Python: `from x5 import X5Ring, X5Error` — one method per skill (`status`, `day`,
`health_day`, `history`, `sync`, `measure`, `workout`, `set_monitoring`, `set_gesture_mode`,
`set_gesture_action`, `find`, `set_profile`, `restart`, `log`); each raises `X5Error` with the
phone's message.

## Quick Reference

| Skill | Arguments | What it does |
|---|---|---|
| `x5_get_status` | — | `name`, `model`, `firmware_version`, `battery_percent`, `charging`, `connected`, `last_sync`, `last_measurement`, `today` — the R12's keys. Works while the ring is away. |
| `x5_get_day` | `date`, `metrics`, `detail` | One day's `summary`; `detail: true` adds series, sleep stages and step slots. |
| `x5_get_health_day` | `date` | One day in the Jarvis Health wire shape, `source: "x5ring"`. |
| `x5_get_history` | `days` (1–30), `metrics` | Per-day summaries, today first. Never waits on the ring. |
| `x5_sync` | `days` (0 = today) | Pulls from the ring now. |
| `x5_measure` | `type`: `heart_rate` \| `spo2` \| `temperature` | Spot reading; may answer `status: "measuring"`. |
| `x5_workout` | `action`: `start` \| `pause` \| `resume` \| `end` \| `status`; `sport` (start only) | Runs a workout on the ring; `sport` is a name such as `run`, `walk`, `cycling`. |
| `x5_set_monitoring` | `metric`: `heart_rate` \| `hrv` \| `spo2`; `enabled`; `interval_minutes` | Automatic background readings (`hrv` brings stress with it). |
| `x5_set_gesture_mode` | `mode`: `jarvis` \| `short_videos` \| `music` \| `camera` \| `off`; `touch_awake`: `1` \| `5` \| `30` \| `always` | What the touch panel does and how many minutes it stays awake. |
| `x5_set_gesture_action` | `gesture`; one of `prompt`, `skill` + `arguments`, or `none: true` | What one gesture runs in `jarvis` mode. |
| `x5_find` | — | The ring vibrates. |
| `x5_set_profile` | `sex`, `age`, `height_cm`, `weight_kg`, `stride_cm` | Body profile for calories and distance; unspecified fields keep their values. |
| `x5_restart` | — | Restarts the ring; its data is kept. |
| `x5_get_log` | `limit` | Recent commands, replies and gestures, decoded, newest first. |

Gestures: `swipe_up`, `swipe_down`, `swipe_left`, `swipe_right`, `tap` (single click),
`double_tap` (double click), `long_press`, `hold_5s`, `hold_10s`.

Units and codes match the R12: sleep stages `2` light, `3` deep, `4` REM, `5` awake, a night
filed under the day it ended; temperature in °C; summary calories in kcal; timestamps in UTC.

## Procedure

1. **Start with `x5_get_status`.** It answers from the phone's cache even when the ring is off
   the finger, and shows whether it is `connected` and its battery.
2. **Sleep or readiness:** `x5_get_day` with `metrics: ["sleep", "heart_rate", "hrv"]` for today
   (last night is filed under today), then `x5_get_history` with `days: 7` for a baseline.
   No sleep keys → `x5_sync` (`days: 0`) and read again.
3. **Spot reading:** `x5_measure` with `type`. `done` → report `value` and `unit`; `not_worn` →
   ask the user to wear it snugly and keep still; `measuring` → wait 30–40 s and read
   `x5_get_status.last_measurement`.
4. **Gestures:** set the mode with `x5_set_gesture_mode` (`jarvis` for Jarvis actions), then map
   each gesture with `x5_set_gesture_action`. Confirm the change by asking the user to try the
   gesture and reading `x5_get_log`.
5. **Workouts:** `x5_workout` `start` with a `sport`; `status` reads the running one; `pause`,
   `resume` and `end` act on it.
6. **Not responding:** `wearables_scan`, then `wearables_connect` with **`wearable_id`** set to the
   ring's id from `wearables_list` (not `device_id`, which picks the phone), then retry.

## Pitfalls

- **Gestures only reach Jarvis in `jarvis` mode.** In `short_videos`, `music` or `camera` the
  ring is a Bluetooth keyboard and iOS handles every touch directly — Jarvis never sees them and
  `x5_set_gesture_action` has no effect until the mode is `jarvis` again. Keyboard modes need the
  ring paired once in iOS Settings → Bluetooth.
- **`x5_measure` often answers `{"status": "measuring"}`.** The ring needs about 30 s for a
  reading and the phone answers within 25 s; the result lands later in
  `x5_get_status.last_measurement`. Don't start a second measurement meanwhile.
- **`touch_awake` trades battery for reach.** `always` keeps the panel listening while the ring
  is connected; with 1, 5 or 30 minutes, gestures stop registering once the panel times out.
- **`x5_restart` drops the link** for a few seconds; use it only when the user asks.
- **Readings are wellness estimates** from a consumer ring. Don't diagnose.
- **Don't gate on `bridge_connected`.** A backgrounded phone shows it false but still runs skills
  after a silent push; a slow reply means the phone is waking.

## Verification

- `x5_get_status` returns `model` and `battery_percent`, and `connected: true` when the ring is
  near the phone.
- After `x5_set_gesture_action`, a real gesture shows up in `x5_get_log` and runs the action.
- `x5_get_health_day` carries `source: "x5ring"`; when the X5 is the Health ring, its days appear
  in Jarvis Health under a device key starting `x5ring-`.
- `python3 scripts/x5.py status` exits 0 and prints JSON.
