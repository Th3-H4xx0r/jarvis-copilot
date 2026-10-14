---
name: health
description: Read Jarvis Health and track quit-habit relapses.
---

# Jarvis Health Skill

Reads Jarvis Health, the one integration every linked wearable feeds (the R12
and X5 rings, the HBand smart band, the scale): the day's scores and written
analysis, each metric's history, and the band's spot readings — blood pressure,
blood glucose, blood components, body composition and ECG — with reference
ranges and trends. It also keeps the habits Pranav is quitting: time since
the last relapse, relapses per day, a streak target and a daily or monthly
relapse limit — chat can read, log and edit those. It never changes settings.

## When to Use

- "How did I sleep", recovery, Body Battery, HRV, resting heart rate, stress.
- Blood pressure, glucose, cholesterol / triglycerides / HDL / LDL, uric acid,
  BMI, body fat, muscle, water, bone, protein, BMR, ECG heart rate / HRV /
  QTc, breathing rate — latest values, trends, "is this normal", health insights.
- Habits he is quitting: "how long since I last vaped", "log a relapse",
  "how many this month", set a streak target or a daily / monthly limit.

## Prerequisites

The local webui serves the API; the helper signs its loopback calls. Run it with
`terminal` from this skill's directory.

## How to Run

```bash
python3 scripts/health.py now                              # today: bedtime to now, battery, workouts
python3 scripts/health.py day --date 2026-09-16            # a day with its scores + analysis
python3 scripts/health.py vitals --days 30                 # spot readings: insights, ranges, trends
python3 scripts/health.py history --metric blood_glucose --range M   # D / W / M / 6M / Y (D: that day's readings)
python3 scripts/health.py devices | runs | alerts | settings
python3 scripts/health.py run                              # score again now (reaches the wearables)

python3 scripts/health.py habits                           # every habit with its summary
python3 scripts/health.py habit-days --habit vaping --days 30            # relapses per day
python3 scripts/health.py habit-relapse --habit vaping [--at 2026-10-14T03:00:00Z] [--note "..."]
python3 scripts/health.py habit-undo --habit vaping        # remove the latest relapse
python3 scripts/health.py habit-create --name "Vaping" [--started ISO] [--streak-days 30] [--limit 1 --per day|month]
python3 scripts/health.py habit-update --habit vaping [--name] [--started] [--streak-days N|0] [--limit N --per day|month | --no-limit]
python3 scripts/health.py habit-delete --habit vaping      # the habit and all its relapses
```

## Quick Reference

`history --metric` takes: battery, steps, sleep, sleep_debt, heart_rate, spo2,
hrv, stress, temperature, exercise, weight, body_fat, blood_pressure,
blood_glucose, uric_acid, cholesterol, triglycerides, hdl, ldl, bmi,
muscle_mass, skeletal_muscle, body_water, bone_mass, protein, bmr, ecg (ECG
heart rate), ecg_hrv, ecg_qtc, respiratory_rate.

Canonical units everywhere: mmHg; glucose, cholesterol, triglycerides, HDL and
LDL in mmol/L; uric acid in µmol/L; kg; %; kcal; ms. The `*_text` fields of
`vitals` are already in the units Pranav chose — quote those.

`--habit` takes a habit's id or its name (a unique part of it is enough). A
habit's `summary`: `since` (the last relapse, or the quit date),
`current_streak_seconds`, `longest_streak_seconds`, `today`, `last_7_days`,
`this_month`, `last_month`, `total`, and `goal` — `streak_days` with
`streak_progress` (0–1), and `limit` (`per` day or month, `count`, `used`,
`within`). Days and months are his local ones.

## Procedure

1. For insights on the spot readings run `vitals` first. Per metric it gives
   `latest` (with `text`), `average`, `lowest`/`highest`, `count`,
   `last_7_days_average` vs `before_average`, `trend` (rising / falling /
   steady), `status` (low / normal / elevated / high) and `reference` (the
   usual adult range, by sex where it differs). `insights` holds ready
   sentences; `readings` every value with its time.
2. For a longer view of one metric, `history`: `buckets` (one per day, week or
   month; `days: 0` is a gap, never a zero), `stats`, `highlight` and, for
   spot readings, `readings` newest first. Blood pressure buckets carry
   systolic in `value` and diastolic in `low`.
3. For sleep / recovery questions, `day` or `now`: `health` is the Body
   Battery, made of `sleep`, `recovery`, `body` and `activity`; each score's
   `points` say what every contributor earned. Explain a score with them.
4. For a habit, run `habits`; say the streak as a duration ("4 days 6 hours")
   and how the goal stands. `habit-days` gives the per-day counts.
5. Answer with the figures and their units, say what changed over time, and
   say plainly where a value sits against its usual range.

## Pitfalls

- These spot readings are optical estimates from a wrist band. Always say so
  when you report them: wellness estimates, not medical measurements and not a
  diagnosis. Don't diagnose; for a value repeatedly in the high range you may
  say it is worth checking with a proper measurement.
- Glucose: fasting 3.9–5.5 mmol/L normal, 5.6–6.9 elevated, 7.0 or more high;
  an hour after a meal up to 9.4 is normal, two hours after up to 7.8 (11.1 or
  more high). A band reading isn't tagged with meals, so say which one applies.
- Blood pressure: under 120/80 normal, 120–129 systolic elevated, 130/80 or
  more high.
- `stale: true` on a score means the wearable could not be reached for that
  run. `baseline_days` under 4 means recovery reports nothing yet.
- Log a relapse only when Pranav says one happened, at the time he gives
  (`--at`, converted to UTC). Confirm before `habit-delete` — it removes every
  relapse too. If you logged one by mistake, `habit-undo`.
- Never quote raw seconds for a streak; turn them into days and hours.
- Don't change settings. They are edited in the Health tab's settings on the
  phone (the write endpoint refuses anything else); tell Pranav where they live.

## Verification

`python3 scripts/health.py vitals --days 7` prints JSON with `disclaimer`,
`metrics` and `insights`; an empty `metrics` means no spot reading in that span.
`python3 scripts/health.py habits` prints `{"habits": [...]}`, each habit with
its `summary`; an empty list means none has been created yet.
