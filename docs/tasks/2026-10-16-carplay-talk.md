# 2026-10-16 — CarPlay: talk to Jarvis from the home screen

He said: "I need a button widget on the home screen itself … a button there to talk to Jarvis that'll start the
mic right away … show text through that widget … if I click the button again, it'll stop listening. It should
work like the gemini app … do the routing … without me having to interact with my phone at all, all through voice
only."

His picks: directions open in **Google Maps** by default (a setting in Jarvis's CarPlay settings picks the maps
app); **one answer per tap** (mic stops after the reply); the card shows **his words, then Jarvis's reply**;
ambiguous places → Jarvis picks the closest and says which. Route: **the widget route** (a Talk/Stop button on a
CarPlay widget), not a navigation entitlement.

Found:
- The "JarvisCopilot · Idle" card on the CarPlay Dashboard is the voice Live Activity, auto-built from the Dynamic
  Island compact views (no `.small` family declared).
- Gemini's "Go | Gemini" card is Google Maps' own dashboard shortcut buttons — navigation apps only; the
  Dashboard shows one navigation app's card (the last one used), so a navigation entitlement wouldn't keep a
  Jarvis button there.
- Apple: Live Activity buttons don't run in CarPlay (a tap only opens the app); widget `Button(intent:)` does run
  in CarPlay on touchscreen cars. Starting the mic from the background needs `AudioRecordingIntent` — unproven
  from CarPlay with the phone locked → device test first.
- `open_url` / `open_app` refuse to run unless the phone itself is in the foreground → directions need a new
  car-screen path (`CPTemplateApplicationScene.open`).

- [x] **1. Design approved** (docs/superpowers/specs/2026-10-16-carplay-talk-widget-design.md)
  - His picks after review: the reply holds the card ~2 min even over coding agents; one "Start" tap in Google
    Maps is fine.
- [ ] **2. Device test: widget button listens without leaving the screen** (phone locked, in CarPlay)
- [x] **3. Talk/Stop widget + one-shot background voice turn**
  - Built: one-shot turns (close after the reply, 10 s silence close, phone voice mode restored) cc2b686a10;
    "Talk to Jarvis (car)" widget + `CarTalkIntent` (AudioRecordingIntent, works with the phone locked) 7060ad636e.
- [x] **4. CarPlay card shows his words, then the reply** (Live Activity `.small` layout)
  - Built a3b8fc3e03: `.small` card; reply holds 2 min over coding/custom; server pushes in that window put back.
    The widget extension now needs iOS 18.
- [x] **5. Voice directions → Google Maps on the car screen** (+ maps-app setting)
  - Built 65ff3052db + 657bf92365: `car_directions` (closest MapKit match, opens after Jarvis's line, Stop
    cancels), Settings → More → CarPlay picker, server pins the tool loaded (needs a server deploy).
- [ ] **6. Installed on the iPhone + tried in the car**
  - ✅ Installed on the iPhone 21:12 UTC (66976aaa7; the auto-launch was refused only because the phone was locked).
    Waiting on his first drive for item 2.

Bug sweep (2 reviewers, parallel) — fixed 9c53862b42:
- mic left on after a cut-in (barge-in/Interrupt) or a dead zone → the 10 s close now covers every way back to
  listening, and the connect
- a hand-off ("On it — let me dig into that") closed the one-shot turn and lost the answer → the server marks
  end_turn `followup: true`; the turn waits up to 90 s for the answer, then closes
- a bump read as speech ended the turn → it listens again until the real question (or 10 s of silence)
- a refused tap (mic off) left the card saying "Listening…" → it says why
- announced directions that the car screen won't open → Apple Maps instead; "Bush airport" no longer loses to a
  nearer "Bush Park"; a failed map search is said as a failure, not "couldn't find"
- his own pinned list in config.yaml would have dropped the car pin → the default pins always stay

Deployed: server webui restarted 21:10 UTC on 66976aaa7 (end_turn followup + car_directions pinned); Mac voice
dylib rebuilt and committed. Tests: touched iOS classes 236/236; full iOS suite 4150 with 6 failures, all in areas
this change doesn't touch (Inmo keychain -34018, CarModelRender, CodeMasterSettings); server voice/rank tests pass
(the 183 server-suite failures are the same on the commit before this work).

## For you
- Add the button: iPhone Settings → General → CarPlay → your car → Customize → add **Talk to Jarvis (car)** on
  CarPlay's Widgets page (one swipe from the home screen).
- First drive: tap it with the phone locked. Expected: the screen stays put, the Jarvis card shows "Listening…",
  you talk, Jarvis answers out loud, music comes back, the card shows the reply for 2 min. Tap again mid-turn →
  stops. If it doesn't listen, tell me — the fallback is the widget opening Jarvis's voice card already listening.
- "Take me to the nearest Costco" → Jarvis says which one, then Google Maps opens (tap Start if it shows a route).
  If Jarvis says to open it on the car screen once, tap the Jarvis icon in CarPlay one time that drive.
- Settings → More → CarPlay picks Google Maps / Apple Maps / Waze.
