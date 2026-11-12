# 2026-11-06 — E910 band battery drain

His report: "The battery drain on the e90 is massive." (the HBand/Veepoo E910). Tick only when he confirms it live.

## What the history shows

Sources: `band_get_status` (phone's battery log summary), the band's day records on the server
(`day-band-d47a07e5-*`: per-minute heart rate, HRV records, readings), the band command log.

Drain, from the levels at each sync:

| Stretch | Measuring | Drain |
|---|---|---|
| Oct 5 – Oct 16 | band-managed, sensor all day | ~15–20 %/day |
| Oct 18 – Nov 2 | phone-managed (sensor 21:00–11:00 + spot readings) | ~14.5–21 %/day |
| Nov 3 – Nov 6 | band-managed again, every auto switch on | ~23–29 %/day |

1. **Since Nov 3 07:52 CST the band is band-managed again.** The last phone-asked reading was
   13:52:23Z; band-made records (BP, glucose, components every 10 min, on :x0:00) start 14:00Z, no
   phone reading since, and the band reports every auto switch on — what `setControl(.band)` puts
   back. He was in the app then (update checks 13:31–13:33Z). No Jarvis chat changed it. Nothing
   records who flips "Managed by", so tap vs glitch can't be told.
2. **Phone-managed mode barely saved anything.** Daytime spot readings ran ~12 an hour (HR and
   stress every 15 min, glucose 30, temperature and BP hourly, components ~2 h), ~75 s each, and
   they ran **all night too** (`due(at:)` ignores the night window) on top of the band's continuous
   overnight sensing: ~350–430 readings a day ≈ 7 h of sensor time. Plus a daytime HRV record
   every hour (~10 min of sensing each) and a 14 h night window (21:00–11:00).
3. **The phone turns the band's own auto switches off only once** (taking over). A band reset or
   anything else that turns them back on is never corrected; `reconcile` only watches PPG/HRV.
4. **The battery page's "where it went" can't tell causes apart:** the sensing span is open
   almost all the time, so 96 % lands on "All-day sensing" whatever the cause.

## Plan

- [ ] A. Now (no build): switch back to Managed by Phone.
- [ ] B1. No spot readings inside the night window (the band measures every minute there).
- [ ] B2. Daytime readings — his pick (2026-11-07): heart rate + stress, blood pressure only.
      HR 60, stress 120, BP 240; glucose, components, SpO₂, temperature off; HRV 120.
- ~~B3. Night window follows his sleep~~ — dropped: he needs the overnight window (it's how the
  band tracks his sleep). It stays 21:00–11:00 with the band's every-minute sensing.
- [ ] B4. Reconcile all auto switches while phone-managed, not just PPG/HRV.
- [ ] C1. Log every "Managed by"/switch change with its source (picker, skill, restore, reset).
- [ ] C2. Switching to Band asks first, showing the measured cost a day.
- [ ] C3. Drain alert: over ~12 %/day for 24 h → a notification naming the likely cause.
- [ ] D1. `band_battery_history` skill (raw samples, spans, switch changes) for remote analysis.
- [ ] D2. Battery page: cost per mode from measured stretches instead of span sharing.
- [ ] D3. Check whether a phone-asked reading lights the band's screen (watch it once).
- [ ] Verify: 48 h on the new plan, drain read back via `band_battery_history`.

**2026-11-07 done (unconfirmed live):** A applied over the bridge at ~00:00 CST (managed by phone,
HR 60 / stress 120 / BP 240 / HRV 120, rest off, window 21:00–10:59 kept; band reported every auto
switch off). B1, B2 (defaults = his pick), B4, C1, C2, C3, D1, D2 built; tests pass. D3 is his check.

## 2026-11-08 — sleep stopped syncing (his report)

"the sleep tracking doesn't sync anymore for the band it just shows no sleep and even battery is
draining so it's tracking I think but not working"

- [ ] Find why the night of Nov 7→8 shows no sleep after build 263111440, fix, confirm with him.

**Findings (2026-11-08):**
- The band records sleep fine. Nov 7→8: 02:13–10:13, 480 min, read off the band by a manual
  `band_sync` at 18:24Z and on the server at 18:25Z. Before that, nothing had pulled it.
- **Periodic sync is set to Manual** (`sync_interval_minutes: 0`, `jc.band.syncInterval` = 0; only the
  Band page's Sync picker writes it). Manual = no timer sync, no sync on opening the app, so sleep only
  arrives on a tap of Sync. He needs it back on 30 min.
- Nov 6→7: the band kept only 08:27–10:57 (150 min, so filed as a nap: <3 h ending 10–20 h). Likely
  lost to my midnight takeover writing the band's switches mid-night. One-off; not recoverable.
- Overnight drain: 99 → 84 % from 20:47 to 10:11 (~1.1 %/h) with auto_ppg + auto_hrv on for the 14 h
  window; by day 100 → 99 % with phone readings. The night sensing is now nearly all of the cost.
- [ ] He sets Periodic sync back to 30 min; confirm sleep arrives on its own tomorrow.
- [ ] Night drain: his pick (see below).
- **His pushback (2026-11-08):** "it lasted way longer, when I first got the band" / "I had all sensors on
  with 24h on and it didn't even drain this much". The numbers agree: Oct 8→9 (every sensor 24 h)
  99→83 = 16 % the first day off the charger; Nov 7→8 after the update 100→84 = 16 % in 25 h. The
  update did not move the daily rate. The "100 % all day then a big night drop" is mostly the band's
  gauge sitting at 100 after a charge (Oct shows the same first-day shape), not the night alone.
  Factory settings (read Oct 4): auto_heart_rate + auto_bp on, auto_ppg/auto_hrv OFF. Since Jarvis:
  per-minute sensing on (24 h in Oct, 14 h now) and the link held for long stretches (since Sat 08:18
  almost continuously; 13 h straight Sat 23:16 → Sun 12:22). Next: factory-settings test (band
  managed, no ppg/hrv, link not held) to split sensor vs link.
- **Factory test started 2026-11-08 12:50 CST at 83 %** (his yes): managed by Band (bandManaged/jarvis
  logged), auto_heart_rate ON, auto_ppg/auto_hrv/BP/stress/temp/glucose/components OFF, night SpO₂ off,
  Keep Alive for the band OFF. Periodic sync still Manual — I pull with `band_sync` myself so the link
  stays mostly closed. Read back ~24 h later: drain (vs 15–16 %/day), whether sleep recorded tonight.
- [ ] Factory test result → build the fix around whichever part drains (sensor vs held link).
