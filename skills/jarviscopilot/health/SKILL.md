---
name: health
description: Read Pranav's wearable health scores, the day's written analysis, recent runs and alerts, or run the analysis now. Use for questions about sleep quality, recovery, HRV, resting heart rate, stress load, a health score, or "how did I sleep".
---

# Wearable health

The server scores each day of wearable data and writes a short analysis. Scores
are computed here, deterministically — a model only ever writes the prose.

Run everything through the helper:

```bash
python3 scripts/health.py devices                        # which wearables have analysis
python3 scripts/health.py day                            # today's scores + analysis
python3 scripts/health.py day --date 2026-09-16          # a past day
python3 scripts/health.py run                            # re-run now (reaches the ring via the phone)
python3 scripts/health.py runs                           # recent runs
python3 scripts/health.py alerts                         # what fired, and when
python3 scripts/health.py settings                       # model, frequency, rules
```

## Reading the answer

- `health` is the day's overall score with a band (Excellent 85+, Good 70–84,
  Fair 55–69, Low under 55), composed of `sleep`, `recovery`, `body` and
  `activity`. A part with `"value": null` was not measurable; the health score
  renormalises over the rest and lists it in `missing`.
- Every score carries `points`: what each contributor earned out of what it
  could. That is how to explain a score rather than just quote it.
- `stale: true` means the ring could not be reached for that run, so the scores
  describe older data. Say so if you report them.
- `baseline_days` is how many days the comparisons rest on. Under 4, recovery
  reports nothing rather than guess.

## Changing settings

Don't. Health settings — the model, the frequency, alert thresholds and quiet
hours — are edited in the ring's wearable settings screen on the phone, and the
write endpoint refuses anything else. If Pranav wants a change, tell him where
it lives.
