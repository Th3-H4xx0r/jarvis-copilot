# 2026-11-03 — E910 band battery drain

## Baseline (phone-managed, Oct 27 – Nov 2, from server-stored readings)
- Drain 23.2 %/day (~4 days/charge); charged 98→100 % at 2026-11-03 00:02 local.
- ~360 phone spot readings/day (HR + stress /15 min, glucose /30, BP + temp /60, SpO₂ /240,
  components /480), round the clock incl. the 9 PM–11 AM night window where auto_ppg+auto_hrv
  already sense every minute. ~30 % fail (not_worn/failed/busy) and retry after 3 min.
- Battery page blames "All-day sensing" for 91 % — time-weighted attribution, likely under-counts
  short spot readings.

## Test (Pranav running it)
- [ ] Switch band to "Managed by Band" for 1–2 days, then compare battery_drain_per_day_percent
      (`band.py status` on the server) against 23.2 %/day.

## Candidate fixes (decide after the test)
- [ ] No phone spot readings inside the night window.
- [ ] After a not_worn, pause all scheduled readings for a while instead of per-type 3-min retries.
- [ ] Longer default/his intervals (HR/stress 30–60, glucose ≥60).
- [ ] Night window → his real sleep hours.
- [ ] Battery page attribution weighted by power, not just time.
