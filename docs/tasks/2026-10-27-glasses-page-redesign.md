# 2026-10-27 — GO3 page redesign + truer 3D model

Spec: docs/superpowers/specs/2026-10-27-glasses-page-redesign-design.md (local) · Plan: docs/superpowers/plans/2026-10-27-glasses-page-redesign.md (local)

- [x] 1. One "Connected" rule (control link) for the Devices card, page hero and lens glow (ca58c1b77d)
- [x] 2. AirPods-style main page: hero + status/battery/audio chips, Connect / Finish setup, quick actions, gallery, Settings/Features/About rows (ca58c1b77d)
- [x] 3. Sub-pages: Display & sound, Controls, Talking to Jarvis, Notifications, Teleprompter, About, Advanced, Pairing key, Get started — nothing removed (ca58c1b77d)
- [x] 4. Page bug sweep fixes (2663479d21)
- [x] 5. Model matched to the real GO3 photos: rounded wayfarer lenses, keyhole bridge, flush corner cameras, red hinges + rings, black arms with battery sticks (da9406d893, fdc0fecbc8)
- [x] 6. Model sweep (saddle mesh, end-piece block, floating nose wires, arch tabs fixed), push, install on the phone
- [ ] 7. His look on the phone: page + model next to his real glasses

## Door alarm (same day)
- [x] Live Activity Disarm/Silence disarms right away: card uses an unlock-only intent (iOS asks Face ID/passcode to unlock), signed with the button key — no "Tap to approve" notification. His call: phone unlock = approval.
- [ ] Live check: alarm in entry delay → tap Disarm on the Lock Screen card → disarms after unlock. (First time only: if the button key isn't registered yet, one Face ID approval in Jarvis registers it.)

## Voice Live Activity (same day)
- [x] Animated Voice orb (`JarvisLiveOrb`: glass bubble, rocking blue liquid, orange glint, twinkling stars, breathing glow — SF Symbol effects) replaces the static ringed icon in the collapsed island, minimal, expanded view, lock screen, CarPlay card, and designs' "orb" inside Live Activities
- [x] Voice Live Activity redesigned (his pick: clean Apple style): orb + "Listening…" + live waveform, the latest words in large type; no boxes, labels or device icons; collapsed island = orb left, state waveform right
- [ ] Live check on the phone: orb animates in the island (liquid rocks, stars twinkle, glow breathes)

## Action button: talk to Jarvis without opening it (same day)
He: "when I press the action button it starts listening and the dynamic island expands and shows that it's listening, without having me need to redirect to the app at all". His picks: Siri-style (one question, one answer; a reply that asks listens once more; press again stops); if iOS refuses the mic in the background → open Jarvis listening (today's shortcut behaviour).
- [x] `TalkToJarvisHereIntent` (AudioRecordingIntent + LiveActivityIntent, unlock first) runs the one-shot turn in the background and returns once the mic is live; "Talk to JARVIS here" Control (Action button → Controls) + Shortcuts action
- [x] Island pops open (silent alert) on "Listening…" and again on the reply
- [x] Refused / mic never live → Jarvis opens listening (iOS 26 continueInForeground)
- [ ] Live check: Settings → Action Button → Controls → "Talk to JARVIS here"; press on the Home Screen with Jarvis in the background → island opens on Listening, reply shows, no app switch. If it opened Jarvis instead, pull voice.log ("one-shot refused: …" says why).
- [x] Mic starts in the background: armed keepalive holds a recordable session (51af68c078) — he: "It worked now"
- [x] Island: Music Recognition-style pulse (timer-font trick; symbol effects never run in a Live Activity), ✕ stop button, stays open for the talk, states go out at once (eba592a0ce) — checked in the iOS 27 simulator
- [ ] His look on the phone: pulse moves, states change, ✕ stops, island stays open until the reply ends

## Island redesign: "3 · Centered" (same day, from the mockups canvas)
He found the island unprofessional; two rounds of mockups (research: Apple HIG Live Activities, call/Voice Memos/Siri islands). Round 1 (4 colourful directions) rejected; round 2 he picked "3 · Centered".
- [x] Centered layout: pulsing orb (app icon art) leading, glass stop trailing, "Listening 0:04" (system-ticked timer) under the camera, words + answer centred below; thinking shows what Jarvis is doing in a chip; one colour (the accent) for every state; compact = orb + running timer — checked in the iOS 27 simulator
- [ ] His look on the phone: centred layout, timer ticks, answer fits two lines, stop works
- [x] Island reads the reply along (teleprompter): the page Jarvis is saying (≤72 chars, two lines), turning with the spoken-word count; each turn re-alerts (gap 1.2 s) so it stays open (669945d14f)
- [ ] His look on the phone: long answers turn pages in step with the voice, island stays open to the end
