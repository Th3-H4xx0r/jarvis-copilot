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
