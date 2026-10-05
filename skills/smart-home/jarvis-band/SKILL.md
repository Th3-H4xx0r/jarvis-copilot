---
name: jarvis-band
description: Read and control the HBand smart band through the phone.
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Wearables, Bluetooth, Health, Sleep, Fitness, Blood-Pressure]
    category: smart-home
    related_skills: [jarvis-ring, jarvis-x5-ring]
---

# Smart Band Skill

The **HBand smart band** (Veepoo) is a screenless band that records steps, sleep, heart rate,
blood pressure, SpO₂, HRV and skin temperature, and vibrates for calls, messages, alarms and
sedentary reminders. The Jarvis iOS app holds its Bluetooth link and advertises its commands as
`band_*` device skills; their day, history and status JSON is the same shape as the Colmi R12's
`ring_*` skills (see `jarvis-ring`). In Jarvis Health it counts as much as a ring: it can be the
primary source. This skill does not flash firmware, send raw bytes or factory-reset the band.

## When to Use

- The user asks about sleep, steps, heart rate, blood pressure, SpO₂, HRV or temperature and the
  band is what they wear (or the device chosen as the Jarvis Health source in Health settings).
- They want a spot reading (including blood pressure), a workout started or ended, or the band
  found.
- They want call, message or app alerts, an alarm, a sit-too-long reminder or automatic
  measurements changed on the band.

## Prerequisites

- The Jarvis iOS app paired with this server and reachable, with the band connected once in the
  app and **Share with Jarvis** on. The skills stay advertised while the band is away.
- In a Jarvis conversation the skills are already agent tools named `device_band_<skill>`:
  `device_band_get_status`, `device_band_measure` and so on, with an optional `device` argument
  to pick the phone. Call them directly.
- For scripts: the bundled `jarviscopilot/devices` skill (its `devices.py` signs requests to the
  web UI). `scripts/band.py` finds it next to this skill, then under `$JARVISCOPILOT_DIR/skills`,
  `$HERMES_HOME/skills` and `~/.jarviscopilot/skills`.

## How to Run

Call the device tools directly. From a script or cron job, run `scripts/band.py` with
`terminal` (stdlib only, Python 3.10+); it prints the skill's JSON, or `{"error": ...}` on
stderr with exit code 1:

```bash
BAND="$HERMES_HOME/skills/smart-home/jarvis-band/scripts/band.py"
python3 "$BAND" status
python3 "$BAND" day --metrics sleep,heart_rate,blood_pressure --detail
python3 "$BAND" measure blood_pressure
python3 "$BAND" workout start --sport walk
python3 "$BAND" alerts --calls on --messages on --apps WhatsApp,Telegram
python3 "$BAND" alarm add --time 06:45 --days mon,tue,wed,thu,fri
python3 "$BAND" sedentary on --interval 60 --start 09:00 --end 18:00
python3 "$BAND" log --limit 20
python3 "$BAND" --device iphone history --days 14
```

In Python: `from band import Band, BandError` — one method per skill (`status`, `day`,
`health_day`, `history`, `sync`, `measure`, `workout`, `find`, `set_alerts`, `set_alarm`,
`set_sedentary`, `set_profile`, `set_monitoring`, `log`); each raises `BandError` with the
phone's message.

## Quick Reference

| Skill | Arguments | What it does |
|---|---|---|
| `band_get_status` | — | `name`, `model`, `firmware_version`, `battery_percent`, `charging`, `connected`, `last_sync`, `last_measurement`, `today` — the R12's keys — plus `wear` when the band knows it. Works while the band is away. |
| `band_get_day` | `date`, `metrics`, `detail` | One day's `summary`; `detail: true` adds series, sleep stages and readings. Blood pressure is the `blood_pressure` metric (`blood_pressure_systolic`, `blood_pressure_diastolic` in the summary). |
| `band_get_health_day` | `date` | One day in the Jarvis Health wire shape, `source: "band"`. |
| `band_get_history` | `days` (1–30), `metrics` | Per-day summaries, today first. Never waits on the band. |
| `band_sync` | `days` (0 = today) | Pulls from the band now. |
| `band_measure` | `type`: `heart_rate` \| `spo2` \| `blood_pressure` \| `temperature` \| `stress` \| `blood_glucose` \| `blood_component` \| `body_composition` \| `ecg` | Spot reading. Ends `done` with the value(s), or `failed` / `busy` / `not_worn` with `failure` (why); a reading longer than the phone's answer comes back `still_measuring` with `check_again_in_seconds`. Blood pressure answers `systolic` and `diastolic` in mmHg; ECG `heart_rate`, `hrv`, `respiratory_rate`; body composition `bmi`, `body_fat_percent` and the rest; `lead_off` while no finger is on the electrode. The E910 has no HRV or MET spot command (HRV comes from history). |
| `band_set_heart_rate_alarm` | `enabled`, `high`, `low` (bpm) | Vibrate when heart rate leaves the range. |
| `band_set_raise_to_wake` | `enabled` | Raise-the-wrist wake. |
| `band_set_skin_tone` | `level` 1–6 | Calibrates the optical sensor. |
| `band_camera` | `on` | Camera-remote mode. |
| `band_clear_data` | `confirm: true` | **Factory reset** — erases the band's history and settings. Only on an explicit request. |
| `band_workout` | `action`: `start` \| `pause` \| `resume` \| `end` \| `status`; `sport` (start only) | Opens the phone's live workout screen with the band as its sensor (3-second countdown, live sheet) and saves the workout to Jarvis Health at the end; `sport` is a name such as `run`, `walk`, `cycling`. `status` returns `phase`, `elapsed_seconds`, `heart_rate`, `steps`, `distance_m`. |
| `band_find` | `stop` (boolean) | The band vibrates until it is found (pressed), stopped (`stop: true`) or times out; answers `finding`. |
| `band_set_alerts` | `calls`, `messages` (booleans), `apps` (names) | Which notifications vibrate the band; `apps: []` turns every app alert off. Unspecified fields keep their values. |
| `band_set_alarm` | `action`: `list` \| `add` \| `delete`; `time` (`HH:MM`), `days` (`mon`…`sun`), `id`, `enabled` | Vibrating alarms on the band: `list` returns each with its `id`; `add` needs `time` (no `days` = once); `delete` needs `id`. |
| `band_set_sedentary` | `enabled`; `interval_minutes`, `start`, `end` (`HH:MM`) | The sit-too-long reminder and the hours it covers. |
| `band_set_profile` | `sex`, `age`, `height_cm`, `weight_kg` | Body profile for calories, distance and blood pressure; unspecified fields keep their values. |
| `band_set_monitoring` | `metric`: `heart_rate` \| `spo2` \| `blood_pressure` \| `temperature`; `enabled`; `interval_minutes` | Automatic background readings. |
| `band_get_log` | `limit` | Recent commands and replies, decoded, newest first. |

Units and codes match the R12: sleep stages `2` light, `3` deep, `4` REM, `5` awake, a night
filed under the day it ended; temperature in °C; blood pressure in mmHg; summary calories in
kcal; timestamps in UTC.

## Procedure

1. **Start with `band_get_status`.** It answers from the phone's cache even when the band is off
   the wrist, and shows whether it is `connected`, its battery and (when known) `wear`.
2. **Sleep or readiness:** `band_get_day` with `metrics: ["sleep", "heart_rate", "hrv"]` for
   today (last night is filed under today), then `band_get_history` with `days: 7` for a
   baseline. No sleep keys → `band_sync` (`days: 0`) and read again.
3. **Blood pressure:** a trend is `band_get_day` / `band_get_history` with
   `metrics: ["blood_pressure"]`; a reading now is `band_measure` with `type: "blood_pressure"`.
4. **Spot reading:** `band_measure` with `type`. `done` → report the value (`systolic` /
   `diastolic` for blood pressure); `failed` / `busy` / `not_worn` → tell the user `failure`
   (it says why: not on a wrist, charging, finger off the electrode, keep still…);
   `still_measuring: true` → wait `check_again_in_seconds`, then read
   `band_get_status.last_measurement` (`band_get_status.measuring` names one still running).
   ECG and body composition need a finger on the band's metal top for the whole reading.
5. **Workouts:** `band_workout` `start` with a `sport` opens the live workout screen on the
   phone; `status` reads the running one; `pause`, `resume` and `end` act on it, and `end` saves
   it to Jarvis Health.
6. **Alarms:** `band_set_alarm` `list` first, then `add` or `delete` by the listed `id`.
7. **Alerts and reminders:** `band_set_alerts` for calls, messages and apps;
   `band_set_sedentary` for the sit-too-long reminder; `band_set_monitoring` for automatic
   readings.
8. **Not responding:** `wearables_scan`, then `wearables_connect` with **`wearable_id`** set to the
   band's id from `wearables_list` (not `device_id`, which picks the phone), then retry.

## Pitfalls

- **Long readings outlast the phone's answer.** Heart rate and SpO₂ take 10–30 s, blood
  pressure about 55 s, temperature / stress / glucose up to 90 s, ECG and body composition up
  to 2 min. `band_measure` then answers `still_measuring`; the reading carries on and lands in
  `band_get_status.last_measurement` (`scripts/band.py measure` waits for it). Don't start a
  second measurement meanwhile — the band answers `busy`.
- **Blood pressure from a wrist band is an optical estimate, not a cuff reading**, and it is only
  as good as the body profile — set `band_set_profile` first. Readings are wellness estimates.
  Don't diagnose.
- **No screen.** The band can only vibrate, so the user sees nothing when a setting changes;
  confirm by reading it back (`band_set_alarm` `list`, `band_get_log`).
- **Alerts come from the phone's own notifications.** `band_set_alerts` chooses which ones
  vibrate the band; an app whose notifications are off on the phone never vibrates it.
- **Don't gate on `bridge_connected`.** A backgrounded phone shows it false but still runs skills
  after a silent push; a slow reply means the phone is waking.

## Verification

- `band_get_status` returns `model` and `battery_percent`, and `connected: true` when the band is
  near the phone.
- After `band_set_alarm` `add`, `band_set_alarm` `list` shows the alarm with its `id`.
- `band_get_health_day` carries `source: "band"`; when the band is the Health source, its days
  appear in Jarvis Health under a device key starting `band-`.
- `python3 scripts/band.py status` exits 0 and prints JSON.
