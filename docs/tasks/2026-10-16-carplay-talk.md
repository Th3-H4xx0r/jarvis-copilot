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
  - Evidence 18:44 CDT: the widget turn worked once (18:44:19, just after using Jarvis's own car screen), then
    two taps at 18:44:36/38 were refused with `!int` again — the mixing session alone did not fix it.
- [ ] **12. Can the Jarvis card on the CarPlay home screen be the clickable orb?** — answered: Apple turns off
  buttons on Live Activities in CarPlay; tapping the card can only open Jarvis on the car screen (it already
  opens it listening). The widget orb is the stay-on-screen button.
- [ ] **13. Softer, more professional sounds**
  - Built: soft bell notes (C5→G5 rising for listening, G5→C5 falling for thinking), quiet, slow decay.

## Round 4 — the Jarvis voice screen in CarPlay

- [ ] **14. The voice card covers the text; two X buttons** — his pick: text above the card
  - Found (phone console, cp-diag): the header WAS set to nil when the card opened (`listHeader -> nil`,
    `didAppear … header=false`) but CarPlay never redraws a removed list header, so it stayed and pushed the
    conversation under the card.
  - Built: no list header at all — idle is a "Talk to Jarvis" row with the orb and the state; with the card
    open the top is just "You: …" and "Jarvis: …". The card has Mute (or Send) and Stop; the separate Done/X
    is gone.
- [ ] **15. Mic startup painfully slow / stuck "Connecting…" / "bad response from the server"**
  - Found (phone console, JC_VOICE_CONSOLE): audio session 0.4 s, mic live 0.6 s after the tap; the voice
    socket opened and never answered. The server dropped off at ~18:20 CDT: Cloudflare 530 (tunnel can't
    reach it), Tailscale offline, ping and both ssh routes time out. Not the app. → he restarts the server.
- [ ] **16. Didn't stop listening after he stopped talking**
  - Found (phone console 18:34–18:45 CDT, his CarPlay turns): (a) "speech detected" 260–420 ms into EVERY
    listen — the new listening chime (390 ms + the car's output delay) outlasted its 250 ms mic mute, so the
    chime opened the turn; at 18:44:10 the chime alone was sent as a turn ("no speech"), back to listening,
    chime, again. (b) After his last word the car's noise sat at 0.005–0.0096, above the 0.006 silence level:
    18:43:34–39 had no speech yet the turn stayed open ~5 s (18:36 turn: 20 s). (c) The server's speech engine
    sent no live words and no "done talking" on those turns (no error logged); a probe from the server now
    gets both, right as the clip ends, in silence and in noise — transient, after the outage.
  - Built: the chime mutes the mic for as long as it is really heard (its length + the route's output/input
    delay + 100 ms). The phone's end-of-speech also ends a turn when the last 1.1 s stayed flat and under 35%
    of how loud he spoke — steady noise, not him; a quiet room ends sooner the old way, so nothing changes
    there. The mic log line now prints the quietest frame (floor=) next to the loudest.

## Round 5 — "CarPlay needs some very big fixes" (2026-10-17)

- [ ] **17. "Could not start recording: … audio session does not permit microphone capture"** (phone Voice, 13:12)
  - Found: the shared voice engine is built once and cached. A reply stream whose engine start fails leaves
    `streamInUse` set forever, so the engine is never released; built while the session was playback-only
    (the glasses path), it has no mic node, and every mic start fails (all retries, hence the doubled prefix)
    until Jarvis is killed.
  - Built: asked for the mic, an engine with no mic is rebuilt (a playing reply carried over); a stream or mic
    whose engine start fails no longer stays "in use". Test fails with his exact error without the fix.
- [x] **18. Tap → talking takes up to 5 s; target < 1 s**
  - Found (18:34–18:45 log): serial start ≈ 1.5 s — CarPlay waits for the voice card to present (~0.6 s) before
    starting voice, the audio session switch to the car mic (~0.5 s), the engine (~0.25 s), plus a
    `/api/session` round trip ("clear a stale stream") before `begin_turn` — that one took 4.2 s at 18:36.
  - Built: CarPlay starts voice beside the card's animation; "Listening" + the chime (Live Activity too) the
    moment the mic is live, words held until the connection is up; the server clears a stale stream on
    `begin_turn` (`ready: clears_stale_stream`), so the phone skips its round trip.
- [ ] **19. Widget with Jarvis in the background: `!int`, mic can't start**
  - Found: iOS refuses a backgrounded app a recording session; Apple's CarPlay voice-app session (play and
    record, default mode, no mixing) is exactly what it refuses. His pick: every orb tap opens Jarvis's car
    screen already listening (no in-place attempt).
  - Built: the orb is a `widgetURL` (`jarviscopilot://voice?once=1`, Apple's way for a CarPlay app's widget);
    the car screen starts listening for one answer — if its own "voice first" start got there first, that
    conversation becomes the one answer. The background intent, its toggle and snapshot are gone.
- [x] **20. Directions say "sent to your phone"; Maps only after unlock → notification → Jarvis → Maps**
  - Found (server log 18:14 UTC): the voice model followed the server skill `directions-from-current-location`
    (get location → web search → `device_open_url` Apple Maps link) and never called `device_car_directions`;
    a link opened on a backgrounded phone becomes a tap-to-open notification.
  - Built: the skill now calls `device_car_directions` first (backup `SKILL.md.bak-2026-10-17` on the
    server); any map link `open_url` gets while CarPlay is up opens on the car's screen after the reply.
- [x] **21. Voice log survives a disconnected cable** — the console capture dies when the phone drops; the
  phone keeps its own rolling voice log file to pull afterwards.
  - Built: `Library/Caches/voice.log` (+ `voice.1.log`, 1 MB each), voice + CarPlay lines with the date;
    pull with `xcrun devicectl device copy from … --domain-type appDataContainer --source Library/Caches/voice.log`.

- [ ] **22. A one-shot reply that asks ("Unlock the car?") listens for his answer** (asked by the car-confirm
  session: car commands now wait for a plain yes as the next message). Built: `VoiceTurnMachine.replyAsks`,
  set on `end_turn` when the reply ends in "?"; listens once more, then closes as usual.
- Bug sweep (round 5): fixed — server clears only when `begin_turn` asks (`clear_stale_stream`; the web and the
  Pod open voice on chats running long agent turns); a widget tap mid-reply or in hold-to-talk restarts as one
  answer instead of closing unheard; the words held while connecting cover the whole one-shot connect (10 s);
  stale one-answer flag; a failed reply resume no longer drops the rebuilt mic engine; car tab + island follow
  `shownState`; the log skips per-frame audio; the card re-states itself once presented. Deferred (minor):
  a Google/Waze map link with that app missing opens nothing (no Apple Maps fallback yet); after a server
  rollback the remembered "server clears stale streams" costs one failed turn.

- [x] **23. Directions sometimes open the route, sometimes just the maps app** (2026-10-18 00:10–00:13) — he: "it seems to work now"
  - Found (phone voice.log + the voice session's tool calls): the route opened when Jarvis called
    `device_car_directions` (coordinates); when it opened a link itself — `http://maps.apple.com/?…&daddr=<text
    address>`, `https://www.google.com/maps/dir/?…`, `comgooglemaps://?saddr=&daddr=…` — the car screen opened
    the app with no route, and a link sent after car_directions replaced its working route. Jarvis's own memory
    on the server (MEMORY.md:137, USER.md:155) teaches the open_url Apple/Google link habit.
  - Built: with CarPlay up, any map link's destination (daddr / destination / q / a Google path) goes through
    car_directions' path — found near him, opened by coordinates in his maps app; the raw link opens only when
    it names no place or the place can't be found.

## For you
- Add the button: iPhone Settings → General → CarPlay → your car → Customize → add **Talk to Jarvis (car)** on
  CarPlay's Widgets page (one swipe from the home screen).
- First drive: tap it with the phone locked. Expected: the screen stays put, the Jarvis card shows "Listening…",
  you talk, Jarvis answers out loud, music comes back, the card shows the reply for 2 min. Tap again mid-turn →
  stops. If it doesn't listen, tell me — the fallback is the widget opening Jarvis's voice card already listening.
- "Take me to the nearest Costco" → Jarvis says which one, then Google Maps opens (tap Start if it shows a route).
  If Jarvis says to open it on the car screen once, tap the Jarvis icon in CarPlay one time that drive.
- Settings → More → CarPlay picks Google Maps / Apple Maps / Waze.
