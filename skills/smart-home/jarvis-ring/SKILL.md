---
name: jarvis-ring
description: "Read and control a Colmi R12 smart ring (and other QRing R-series rings) paired through the Jarvis iOS app — sleep stages, steps, heart rate, SpO₂, HRV, stress and temperature history, on-demand measurements, monitoring and touch settings — plus a Python SDK for scripts and cron jobs."
version: 1.0.0
author: pranav
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, Wearables, Bluetooth, Health, Sleep, Fitness]
---

# Jarvis Ring

The **Colmi R12** is a screenless smart ring that speaks the QRing protocol, like the rest of
the R-series. It records steps, sleep, heart rate, SpO₂, HRV, stress and skin temperature on
its own and keeps about a week of history.

The ring never talks to this server directly. The **Jarvis iOS app** holds its Bluetooth
link, runs the ring's setup on every connect, copies everything the ring records into an
on-phone history (one file per day, a year kept) and advertises the ring's commands as
`ring_*` device skills over the device bridge. You drive them like any other device skill.

Jarvis **replaces** the QRing app for this ring. If the user still has the ring bound in
QRing, both apps receive every reply on the one link and collide — ask them to unbind it
there first.

## Discovering it

```bash
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py list
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py skills
```

The phone appears once in the device list; the ring is one of the wearables behind it, and
its skills are named `ring_*`. `wearables_list` (always present on the phone) shows the ring
with model `Colmi R12`, its advertised name (e.g. `R12_7E04`), whether its link is up and
when it was last seen.

Every `ring_*` skill takes an optional `device_id` — the ring's id from `wearables_list`.
Omit it when only one ring is paired. Start with **`ring_get_status`**: it works while the
ring is away and tells you what this particular ring supports.

In a Jarvis conversation you already have these as tools — **`device_ring_get_status`**,
`device_ring_measure` and so on, with an optional `device` argument to pick the phone when more
than one offers them. Call those. `devices.py invoke` (below) is for scripts and a fallback.

```bash
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py \
  invoke <phone> ring_measure --json-args '{"metric": "heart_rate"}'
```

## Commands

| Skill | Arguments | What it does |
|---|---|---|
| `ring_get_status` | — | Connection, battery and charging, firmware/hardware, `supported_metrics`, `supported_measurements`, `touch_modes`, every current `settings` value, `last_sync`, `last_measurement`, and `today`'s summary. Works while the ring is away (cached). |
| `ring_get_day` | `date` (`YYYY-MM-DD`, default today), `metrics` (list), `detail` (bool) | One day's `summary`; `detail: true` adds series, sleep stages and step slots. Syncs from the ring first when it is connected, the day is within the last week and the data is stale. |
| `ring_get_history` | `days` (1–30, default 7), `metrics` | Per-day summaries from the phone's history, today first. Never waits on the ring. |
| `ring_sync` | `days` (0–6, default 0 = today only) | Pulls from the ring now. Returns `finished`, `updated` and per-metric `failed`; a long sync returns `finished: false` and carries on in the background. |
| `ring_measure` | `metric`, `wait_seconds` (0–25, default 25) | On-demand reading. Returns the result, `status: "not_worn"`, or `status: "measuring"`. |
| `ring_find` | — | The ring vibrates/flashes. |
| `ring_set_monitoring` | `metric`, `enabled` (bool), `interval_minutes` | Automatic background measurement: `heart_rate` (1–60 min), `hrv` (10–60), `temperature` (10, 30, 60 or 120), `spo2` and `stress` (on/off only). |
| `ring_set_touch_mode` | `control` (`touch` \| `gesture`), `mode`, `strength` (0–10, gesture only) | What a tap/swipe or a double-tap gesture controls: `off`, `music`, `video`, `page_turn`, `photo`, `game`, `heart_rate`. Only modes in `ring_get_status.touch_modes` are accepted. |
| `ring_set_goals` | `steps`, `calories` (kcal), `distance_m`, `sport_minutes`, `sleep_minutes` | Daily goals. Unspecified goals keep their values. |
| `ring_set_profile` | `sex` (`male` \| `female`), `age`, `height_cm`, `weight_kg`, `use_24h`, `metric_units` | Body profile the ring uses for calories and distance. Unspecified fields keep their values. |
| `ring_set_preferences` | `temperature_unit` (`celsius` \| `fahrenheit`), `dnd` {`enabled`, `start`, `end`}, `sedentary` {`enabled`, `start`, `end`, `interval_minutes`: 30 \| 60 \| 90} | Only what is given changes. Times are 24-hour `HH:MM`. |
| `ring_power` | `action` (`power_off` \| `factory_reset`), `confirm` | **`confirm: true` required.** See **Safety**. |
| `ring_raw_command` | `hex`, or `big_data_cmd` + `payload_hex`; `confirm` | **Protocol work only; `confirm: true` required.** Returns `replies`: `{channel, cmd, error, payload_hex}`. |

`metrics` names: `activity`, `sleep`, `heart_rate`, `spo2`, `hrv`, `stress`, `temperature`,
`blood_pressure`, `blood_sugar`. `ring_measure` metrics: `heart_rate`, `spo2`, `hrv`,
`stress`, `temperature`, `blood_pressure`, `blood_sugar`, `health_check` — only those in
`supported_measurements` work on a given ring.

Every `ring_set_*` skill writes the setting, reads it back from the ring and returns
`{"settings": …}`, so the reply shows what the ring actually holds.

## Data model and units

`ring_get_status`, abridged (values illustrative; `settings` holds one object per setting):

```json
{
  "device_id": "5C1F9A2E-0B7D-4E43-9D5A-8C2B6F1E7A40",
  "name": "R12_7E04",
  "model": "Colmi R12",
  "connected": true,
  "battery_percent": 76,
  "charging": false,
  "firmware_version": "3.10.06",
  "capabilities_known": true,
  "supported_metrics": ["activity", "sleep", "heart_rate", "spo2", "hrv", "stress", "temperature"],
  "supported_measurements": ["heart_rate", "spo2", "hrv", "stress", "temperature"],
  "touch_modes": ["off", "music", "video", "page_turn", "photo"],
  "settings": {"heart_rate": {"enabled": true, "interval_minutes": 30}},
  "last_sync": "2026-09-11T07:42:10Z",
  "last_measurement": {"metric": "heart_rate", "status": "done", "value": 61, "unit": "bpm"},
  "today": {"steps": 4210, "kilocalories": 182.4, "sleep_minutes": 431, "heart_rate_min": 54}
}
```

**Summaries** (`ring_get_day.summary`, `ring_get_history.days[].summary`, `ring_get_status.today`).
A key is absent when there is no data for it — absent is not zero.

| Metric | Keys |
|---|---|
| activity | `steps`, `kilocalories` (kcal), `distance_meters`, `active_minutes` |
| sleep | `sleep_minutes` (asleep, excluding awake), `deep_minutes`, `light_minutes`, `rem_minutes`, `awake_minutes` — the longest night that ended that day |
| heart_rate | `heart_rate_min`, `heart_rate_avg`, `heart_rate_max`, `heart_rate_latest` (bpm) |
| spo2 | `spo2_min`, `spo2_avg`, `spo2_latest` (%) |
| hrv | `hrv_avg`, `hrv_latest` (ms) |
| stress | `stress_avg`, `stress_latest` (score) |
| temperature | `temperature_avg`, `temperature_latest` (°C) |
| blood_pressure | `blood_pressure_systolic`, `blood_pressure_diastolic` — the day's latest reading (mmHg) |
| blood_sugar | `blood_sugar_min`, `blood_sugar_max` — the ring's raw value |

**Detail** (`ring_get_day` with `detail: true`): `activity`; `step_slots` (`fields`
`[slot_15min, steps, calories_small, distance_m]` + `rows`; slot 0 is 00:00–00:15, 95 is
23:45–24:00); `sleep` (`start`, `end`, `asleep_minutes`, `stages`), `sleep_stage_codes`,
`naps`; `heart_rate_series`, `heart_rate_manual`, `heart_rate_instant`; `spo2_hourly`,
`spo2_manual`, `spo2_instant`; `hrv_series`; `stress_series`; `temperature_series_c`,
`temperature_instant_c`; `blood_pressure`; `blood_sugar_hourly`; `measurements`.

Units and conventions:

- **Calories.** Summary `kilocalories` is **kcal**, and so are goals: `ring_set_goals` takes
  `calories` in kcal and `settings.goals.kilocalories` reads it back. `detail.activity.calories`
  and the step-slot `calories_small` column are **small calories** (kcal × 1000 — divide by 1000).
- **Distance** in metres; durations in minutes.
- **Temperature** is always **°C** in results (`temperature_*`, `value_celsius`), whatever
  `temperature_unit` the ring is set to. Convert for the user if they want °F.
- **Sleep stages** are `[stage, minutes]` pairs in order from bedtime. Codes: **`2` light,
  `3` deep, `4` REM, `5` awake**. A night is filed under the day it **ended**.
- **Series** (`*_series*`): `{interval_minutes, values}`; `values[i]` is the reading
  `i × interval_minutes` after local midnight, and `0` means no reading in that slot.
- **Timed values** (`*_manual`, `*_instant*`): `[minute_of_day, value]` pairs in local time.
- **Hourly min/max** (`spo2_hourly`, `blood_sugar_hourly`): `{min: [24], max: [24]}`, index =
  hour, `0` = no reading. Blood sugar is the ring's raw value.
- **Timestamps** (`start`, `end`, `last_sync`, `started_at`, `synced_at`) are ISO 8601 in UTC.
- **Touch settings.** `settings.touch.mode` / `settings.gesture.mode` are numeric app types:
  0 off, 1 music, 2 video, 3 tasbih, 4 page turn, 5 photo, 7 game, 8 heart rate, 10 couple.
- **Measurements.** `metric`, `status` (`measuring`, `done`, `not_worn`, `failed`,
  `cancelled`, `timed_out`), `value` with `unit` (`bpm`, `%`, `ms`, `score`, `raw`),
  `value_celsius` for temperature, `systolic`/`diastolic` (mmHg) for blood pressure and
  health check, `started_at`, `finished_at`, `detail`.

## Recipes

### Morning readiness summary

1. `ring_get_day` with `metrics: ["sleep", "heart_rate", "hrv", "temperature"]` — today,
   because last night is filed under the day it ended.
2. `ring_get_history` with `days: 7` and the same metrics, for a baseline.
3. Compare last night's `sleep_minutes` and `deep_minutes`, `heart_rate_min` (a resting
   proxy), `hrv_avg` and `temperature_avg` with the averages of the other days that have them.
   Report plainly — "7 h 12 min asleep (1 h 20 deep), resting HR 54 against a usual 57, HRV
   above your week". These are wellness estimates, not medical readings.

If today has no sleep keys, run `ring_sync` (`days: 0`) and read again. Still nothing means
the ring wasn't worn overnight or hasn't reached the phone yet.

### How did I sleep last night?

`ring_get_day` with `metrics: ["sleep"]` and `detail: true`. Use `detail.sleep` (take the
longest session if there are several): `start` and `end` are bedtime and wake time — convert
from UTC to the user's time zone — and `stages` is the night in order. Total the minutes per
stage code for deep/light/REM/awake. Mention `detail.naps` separately.

### Measure heart rate now

`ring_measure` with `metric: "heart_rate"` (other metrics work the same way; check
`supported_measurements` first).

- `status: "done"` → report `value` and `unit`.
- `status: "not_worn"` → the sensor can't see skin. Ask the user to wear the ring snugly with
  the sensor on the palm side, keep still, and retry. This is not a fault.
- `status: "measuring"` → the reading isn't finished (a measurement can take up to a minute,
  longer if the phone had to reconnect first). Wait 15–30 s, then read
  `ring_get_status.last_measurement`; if its `started_at` matches and `status` is `done`,
  that's the result. Don't start another meanwhile — the ring measures one thing at a time and
  answers `ring is busy`.
- `timed_out` or `failed` → retry once, then check the fit.

### Turn on 10-minute heart-rate monitoring

`ring_set_monitoring` with `{"metric": "heart_rate", "enabled": true, "interval_minutes": 10}`.
Confirm the reply's `settings.heart_rate` shows `enabled: true` and `interval_minutes: 10`.
Short intervals cost ring battery (QRing warns at 20 minutes or less), so mention it. Turn it
off with `enabled: false`.

### Automations and ESP32 scripts

Automations and board scripts should call the **exact skill names** with the argument shapes
above — a matching device skill runs directly, with no model turn:

```lua
-- Button between GPIO 27 and GND: buzz the ring so the user can find it.
gpio.mode(27, "input_pullup")
on_input(27, function(level)
  if level == 0 then
    jarvis.invoke("ring_find", {}, function(ok, text) print("ring_find:", ok, text) end)
  end
end)
```

`jarvis.invoke("ring_measure", { metric = "heart_rate", wait_seconds = 20 }, cb)` works the same
way; the callback's text is the start of the skill's JSON result. Keep such calls to a few per
hour at most and make failures harmless — the ring may be off the finger or out of range.

### Cron jobs with `ring.py`

A cron job's `script` is a file path (relative paths resolve under `$HERMES_HOME/scripts/`;
`.sh` runs with bash), so wrap the CLI. The scheduler always exports `HERMES_HOME`, but may
point `HOME` at a profile directory — so build paths from `HERMES_HOME`, not `~`:

```bash
# $HERMES_HOME/scripts/ring-morning.sh
RING="$HERMES_HOME/skills/smart-home/jarvis-ring/scripts/ring.py"
python3 "$RING" sync --days 1 > /dev/null
python3 "$RING" day --metrics sleep,heart_rate,hrv,temperature
python3 "$RING" history --days 7 --metrics sleep,heart_rate,hrv,temperature
```

Then create the job with `schedule: "0 8 * * *"`, `script: "ring-morning.sh"` and a `prompt`
such as "Write a two-line morning readiness summary from this ring data". The script's stdout
becomes the prompt's context; with `no_agent: true` the JSON is delivered verbatim instead.

## When the ring isn't responding

The `ring_*` skills stay advertised while the ring is away. Reads (`ring_get_status`,
`ring_get_day`, `ring_get_history`) fall back to the phone's stored data and say
`connected: false`. Everything that touches the ring reconnects on demand first, which can take
up to ~15 s — so the usual answer to "is it connected?" is to run the command.

If a command returns `device is not connected over Bluetooth` or
`ring is not connected over Bluetooth`, work the recovery path instead of giving up:

1. `wearables_scan` (`seconds` 3–15) — is the ring nearby, and how strong is its signal?
2. `wearables_connect` with **`wearable_id`** set to the ring's `device_id` from
   `wearables_list` or the scan. (Not `device_id`: that argument picks which device runs a
   skill.) It returns `connected: false` with a reason when the ring is off, flat or out of
   range.
3. Retry the original command.

`bluetooth_ready: false` means Bluetooth is off on the phone — tell the user that rather than
reporting the ring as missing. `wearables_connect` only works for a ring already paired in the
app; it will not adopt a new one.

## Safety

- **`ring_power` needs `confirm: true`.** `power_off` turns the ring off until it goes back on
  its charger (whether the R12 powers off or restarts is unverified); `factory_reset` erases the
  ring's settings and stored data — the phone's history is kept. Use either only when the user
  has asked for it, and confirm with them first.
- **`ring_raw_command` needs `confirm: true`.** Raw bytes can change settings or wipe the ring
  (`FF 66 66` is a factory reset). Protocol work only, with the user's go-ahead.
- **Measurements need the ring worn.** `not_worn` is the expected answer while it sits on the
  charger or the nightstand.
- **Settings writes are real.** Short monitoring intervals drain the ring's small battery, and
  a touch mode fires phone actions on every tap.
- **Readings are wellness estimates** from a consumer ring. Don't diagnose.
- **Do not gate on `bridge_connected`.** `/api/devices` reports `bridge_connected: false` for a
  phone whose app is backgrounded — iOS suspends it and the WebSocket closes. Invokes still fall
  back to a silent push and are delivered when the app wakes. Check **`invokable`**, or simply
  that the phone lists `ring_*` skills; a slow reply means "the phone is waking".

## Python SDK

`scripts/ring.py` (stdlib only, Python 3.10+) wraps the devices skill's authenticated webui
client, so scripts, cron jobs and other integrations get one call per skill and JSON back.

```bash
RING=~/.jarviscopilot/skills/smart-home/jarvis-ring/scripts/ring.py
python3 "$RING" status
python3 "$RING" day --date 2026-09-10 --metrics sleep,heart_rate --detail
python3 "$RING" history --days 14 --metrics activity
python3 "$RING" sync --days 6
python3 "$RING" measure spo2 --wait 20
python3 "$RING" find
python3 "$RING" monitoring heart_rate on --interval 10
python3 "$RING" touch gesture music --strength 5
python3 "$RING" goals --steps 9000 --sleep-minutes 480
python3 "$RING" profile --sex male --age 30 --height-cm 178 --weight-kg 72 --24h --metric
python3 "$RING" prefs --dnd-on --dnd-start 22:30 --dnd-end 07:00 --sedentary-interval 60
python3 "$RING" power power_off --confirm
python3 "$RING" raw --hex 03 --confirm
python3 "$RING" --device iphone --timeout 45 status
```

The result prints as JSON on stdout. Errors print `{"error": "..."}` on stderr with exit code 1.

```python
import os, sys
sys.path.insert(0, os.path.expanduser("~/.jarviscopilot/skills/smart-home/jarvis-ring/scripts"))
from ring import Ring, RingError

ring = Ring()  # or Ring(device="iphone", timeout=45)
try:
    night = ring.day(metrics=["sleep"])["summary"]
    reading = ring.measure("heart_rate", wait_seconds=20)
except RingError as exc:
    print("ring unavailable:", exc)
```

- **Methods** — one per skill: `status()`, `day(date, metrics, detail)`, `history(days, metrics)`,
  `sync(days)`, `measure(metric, wait_seconds)`, `find()`,
  `set_monitoring(metric, enabled, interval_minutes)`, `set_touch_mode(control, mode, strength)`,
  `set_goals(**goals)`, `set_profile(**profile)`, `set_preferences(**prefs)`,
  `power(action, confirm)`, `raw(hex, big_data_cmd, payload_hex, confirm)`. Each sends only the
  arguments given and returns the skill's result dict; `invoke(skill, args)` reaches any skill.
- **Device** — with no `device`, it finds the phone advertising `ring_get_status` via
  `GET /api/devices/skills` (preferring a connected one). `device` may be a paired device id or
  a case-insensitive name substring. The resolved id is cached on the instance.
- **Errors** raise `RingError` carrying the server's or phone's message.
- **Guards** — `power` and `raw` refuse without `confirm=True` before sending anything;
  `measure` clamps `wait_seconds` to 0–25.
- **Timeout** — every call waits up to `timeout` (default 45 s, never less for `measure`): the
  phone answers within 25 s of receiving a command, and waking a backgrounded app takes the rest.
- **devices.py** is looked up next to this skill (`skills/jarviscopilot/devices`), then under
  `$JARVISCOPILOT_DIR/skills`, `$HERMES_HOME/skills` and `~/.jarviscopilot/skills`.

## Troubleshooting

- **No `ring_*` skills.** They're advertised whether or not the ring is connected, so their
  absence means the *phone* isn't reachable or the ring was never shared: the app must be paired
  and online, the ring connected once in the app, and **Share with Jarvis** on in its settings.
- **`this ring doesn't support …` / `this ring can't measure …`.** A capability this model
  lacks — check `supported_metrics`, `supported_measurements` and `touch_modes`.
- **`ring did not answer command 0x…` / `ring rejected command 0x…`.** Retry once; the ring may
  be mid-sync or low on battery.
- **Stale numbers.** Compare `last_sync` with now and run `ring_sync`.
- **Readings stop or settings flip back.** QRing is probably still bound to the ring — unbind it.

## Protocol reference

The byte-level protocol — GATT UUIDs, both frame formats, every command the app uses with its
payload layout, capability bits, event codes, and recipes for alarms, drink reminders, message
push and vibration — is in `ios_app/RING_PROTOCOL.md` in the JarvisCopilot repo. Needed only
for `ring_raw_command`.
