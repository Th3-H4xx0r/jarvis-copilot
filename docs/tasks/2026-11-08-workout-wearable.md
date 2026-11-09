# 2026-11-08 — strength workout loses the ring/band; cancel leaves the band busy

His reports: "it doesn't reconnect to the band or ring once I close app and come back. It should have
a option to reconnect or change" (screenshot: "No ring — logging sets only.") and "when I cancel a
workout, it doesn't seem to stop usage of the band … it says that band is busy … when I close the
app … then I came back, it started working". Tick only when he confirms it live.

## Causes

1. Heart rate was tried once. Right after a relaunch the Bluetooth radio hasn't reported in, so
   `ensureConnected` failed at once, and nothing ever tried again.
2. A workout restored at launch on the band or X5 asked the R12 for heart rate: that wearable
   registers after the controller is built, and vitals started before it did.
3. The band's stop raced its own status poll: a poll answered mid-stop read "not started" and its
   keep-running nudge started the session again (test: start, stop, start). The band stayed in sport
   mode and refused spot readings as busy until a relaunch's setup stopped the stray session.
4. Cancel/finish only stopped a wearable whose start had landed in this run of the app.

## Fixes

- [ ] `ensureConnected` gives the radio up to 3 s after launch.
- [ ] Vitals start again when the app comes forward, when the link comes back, and from a new
      **Reconnect** button; **Change** (or tapping the heart rate) opens the wearable picker
      mid-workout (switch wearable or "No wearable").
- [ ] A restored workout waits for its own wearable.
- [ ] The band stops its polls before the stop and retries an unanswered stop; cancel/finish always
      tell the workout's wearable to stop; a start that lands after a cancel is stopped.
