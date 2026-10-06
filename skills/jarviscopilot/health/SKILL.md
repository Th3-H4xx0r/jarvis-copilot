---
name: health
description: Read Jarvis Health: scores, vitals, history, insights.
---

# Jarvis Health Skill

Reads Jarvis Health, the one integration every linked wearable feeds (the R12
and X5 rings, the HBand smart band, the scale): the day's scores and written
analysis, each metric's history, and the band's spot readings — blood pressure,
blood glucose, blood components, body composition and ECG — with reference
ranges and trends. It never changes settings.

## When to Use

- "How did I sleep", recovery, Body Battery, HRV, resting heart rate, stress.
- Blood pressure, glucose, cholesterol / triglycerides / HDL / LDL, uric acid,
  BMI, body fat, muscle, water, bone, protein, BMR, ECG heart rate / HRV /
  QTc, breathing rate — latest values, trends, "is this normal", health insights.

## Prerequisites

The local webui serves the API; the helper signs its loopback calls. Run it with
`terminal` from this skill's directory.

## How to Run

```bash
python3 scripts/health.py now                              # today: bedtime to now, battery, workouts
python3 scripts/health.py day --date 2026-09-16            # a day with its scores + analysis
python3 scripts/health.py vitals --days 30                 # spot readings: insights, ranges, trends
python3 scripts/health.py history --metric blood_glucose --range M   # W / M / 6M / Y
python3 scripts/health.py devices | runs | alerts | settings
python3 scripts/health.py run                              # score again now (reaches the wearables)
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
4. Answer with the figures and their units, say what changed over time, and
   say plainly where a value sits against its usual range.

## Pitfalls

- These spot readings are optical estimates from a wrist band. Always say so
  when you report them: wellness estimates, not medical measurements and not a
  diagnosis. Don't diagnose; for a value repeatedly in the high range you may
  say it is worth checking with a proper measurement.
- Glucose ranges are fasting ranges (3.9–5.5 mmol/L normal, 5.6–6.9 elevated,
  7.0 or more high); a reading soon after a meal is expected to be higher.
- Blood pressure: under 120/80 normal, 120–129 systolic elevated, 130/80 or
  more high.
- `stale: true` on a score means the wearable could not be reached for that
  run. `baseline_days` under 4 means recovery reports nothing yet.
- Don't change settings. They are edited in the Health tab's settings on the
  phone (the write endpoint refuses anything else); tell Pranav where they live.

## Verification

`python3 scripts/health.py vitals --days 7` prints JSON with `disclaimer`,
`metrics` and `insights`; an empty `metrics` means no spot reading in that span.
