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

## His first tries (CarPlay screen on the Mac, real iPhone) — round 2

- [ ] **7. "Could not start voice: The operation couldn't be co…" when the phone is locked / Jarvis not open**
  - Found: the 4:29 tap never reached the server (no `/api/voice/session`), so the phone refused before
    connecting — the audio session. The tap's intent returned right after starting the turn; the session was
    claimed a moment later on its own task, when iOS may no longer allow a background app to start recording.
  - Fixed: the session is claimed inside the tap, and the tap returns only once the mic is live. A refusal now
    says why in words with iOS's code ("Mic blocked: iOS won't start the mic while Jarvis is in the background
    (!rec)") instead of "The operation couldn't be completed".
- [ ] **8. The widget doesn't update — stuck on "Thinking…", never shows his words or the reply**
  - Found: the turn ran (server voice turns 21:30:12 / 21:30:37); WidgetKit redraws a backgrounded app's widget
    on its own schedule, merging/dropping updates — only the redraw right after a tap is reliable.
  - Fixed: the widget no longer claims a live state. The live words + reply are the Jarvis card on the CarPlay
    home screen (Live Activity), plus sounds.
- [ ] **9. A sound when it starts listening, and one when it stops listening and starts thinking**
  - Built: rising two-tone when listening starts, falling when it starts thinking — every car turn (the widget's
    and the CarPlay voice tab while the phone is in the car); 250 ms of mic audio ignored after each so the tone
    can't count as speech.
- [ ] **10. No mic button on the widget — just a big centred orb**
  - Built: the widget is the orb alone (a line under it only when the last tap couldn't start).

## Round 3

- [ ] **11. Still "Mic blocked: another app's audio won't let go (!int)" unless the app is in front**
  - Found: `!int` = a backgrounded app activating a session that takes the audio over. With CarPlay connected,
    the voice turn's `.videoChat` (echo-cancelling, call-style) session goes to the car's exclusive voice
    channel — refused in the background even though it asked to mix.
  - Built: car turns use their own session — `.playAndRecord`, `.default` mode (Apple's CarPlay voice-app
    mode), mixing and ducking his music. No echo cancellation there, so a car turn takes no talk-over
    (tap the orb to stop). Awaiting his test: works with Jarvis in the background?
- [ ] **12. Can the Jarvis card on the CarPlay home screen be the clickable orb?** — answered: Apple turns off
  buttons on Live Activities in CarPlay; tapping the card can only open Jarvis on the car screen (it already
  opens it listening). The widget orb is the stay-on-screen button.
- [ ] **13. Softer, more professional sounds**
  - Built: soft bell notes (C5→G5 rising for listening, G5→C5 falling for thinking), quiet, slow decay.

## For you
- Add the button: iPhone Settings → General → CarPlay → your car → Customize → add **Talk to Jarvis (car)** on
  CarPlay's Widgets page (one swipe from the home screen).
- First drive: tap it with the phone locked. Expected: the screen stays put, the Jarvis card shows "Listening…",
  you talk, Jarvis answers out loud, music comes back, the card shows the reply for 2 min. Tap again mid-turn →
  stops. If it doesn't listen, tell me — the fallback is the widget opening Jarvis's voice card already listening.
- "Take me to the nearest Costco" → Jarvis says which one, then Google Maps opens (tap Start if it shows a route).
  If Jarvis says to open it on the car screen once, tap the Jarvis icon in CarPlay one time that drive.
- Settings → More → CarPlay picks Google Maps / Apple Maps / Waze.
