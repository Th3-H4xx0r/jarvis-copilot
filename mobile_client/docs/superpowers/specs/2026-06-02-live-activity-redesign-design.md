# Live Activity / Dynamic Island redesign — design

## Goal
Replace the current messy, unanimated, occasionally-stale JARVIS Live Activity with a
polished, professional, on-brand design that uses the real app-icon orb, has genuine
motion, and always matches the app's voice state.

## Approved visual design (from the brainstorm mockups)

**Orb (top-left):** the real app-icon orb, bundled into the widget extension and
circle-clipped, wrapped in a **breathing glow halo** whose colour = the state colour.
The halo animates (pulse). The orb image itself is static brand art.

**Header:** orb + `JARVIS` (heavy weight) with `● Connected` (green dot) directly
beneath it. The **state** sits as a coloured **pill** on the far right
(e.g. a cyan-tinted `LISTENING`), recolouring per state.

**Signature graphic — waveform:** a state-coloured audio waveform under the header. It
animates with voice activity on-device (SF Symbol `waveform` + `.variableColor`
repeating); flat/dim when idle.

**Conversation panel:** a state-tinted glass panel (`color@8–14% bg`, `color@~18% border`)
with `YOU <transcript>` and `JARVIS <reply/tool>` rows.

**Devices strip (bottom):** small phone / watch icons — online ones lit with a green
glow, offline dimmed — plus a count (`2 of 2 online`). Separated by a hairline divider.

**States & colours:** Idle `#6f8bd6` (resting, "Tap to talk"), Listening `#2fb8ff`,
Thinking `#8a7cff`, Speaking `#ff6fd8`. Each recolours the orb halo, waveform, state
pill, and panel tint.

**Compact Dynamic Island:** orb (small, halo) leading + state word (coloured) trailing.
**Minimal:** orb only. **Lock Screen:** the full expanded layout.

**Tap anywhere → Voice screen** (`jarviscopilot://voice`).

## Animation strategy (the hard part — honestly scoped)
A Live Activity is a restricted canvas; most continuous SwiftUI animations don't run.
Only these animate reliably, so the design leans on them:
- **Halo pulse:** an SF Symbol `circle.fill` glow behind the orb with
  `.symbolEffect(.pulse, options: .repeating)` (iOS 17+); static glow on 16.2.
- **Waveform:** `Image(systemName:"waveform").symbolEffect(.variableColor.iterative.repeating)`
  for active states; static symbol when idle/thinking.
- **State transitions:** colour/content changes cross-fade when we push an update.
No amplitude-reactive or custom-path animation (not feasible on-device).

## Data model — `JarvisActivityAttributes.ContentState`
- `state: String` — idle | listening | thinking | speaking | error
- `transcript: String` — what the user said
- `activity: String` — JARVIS's reply snippet / tool status
- `connected: Bool` — server link
- `watchPresent: Bool`, `watchOnline: Bool` — for the devices strip (phone is implicit
  and always online)

Device data is computed **natively** in `LiveActivityManager` from `WCSession`
(`isPaired && isWatchAppInstalled` → present; `isReachable` → online) and merged into the
content on every update, so Dart doesn't need watch state. Phone = 1 always-online device;
watch adds a second when paired. (A desktop/3rd device is out of scope unless the server
later reports one.)

## State-sync fix (idle stuck on "Listening")
Root cause: pushing on every `_set` floods iOS's Live Activity update budget, so the final
`idle` update gets dropped. Already mitigated by **dedupe + 450 ms trailing throttle** in
`voice_controller._pushLiveActivity`. Harden: when entering a **terminal/idle** state,
flush immediately (bypass the throttle) so idle/stop always lands. Connection changes push
via the existing `ws.connected` listener.

## Persist behaviour
Created on first active state; on stop we push `idle` (not `end`) so it lingers as a
tap-to-talk launcher until dismissed.

## Tap → Voice
Keep `widgetURL(jarviscopilot://voice)` on the lock-screen + Dynamic Island. (If the
compact-pill tap proves unreliable for the custom scheme on-device, a follow-up universal
link is the bulletproof fix — out of scope for this pass.)

## Implementation units
1. **Bundle the orb image** — add `Assets.xcassets` with `JarvisOrb` imageset (the app
   icon) to the `JarvisWidget` extension; wire into the target's Resources build phase
   (pbxproj). Riskiest step → verify with a widget build.
2. **ContentState** — add `watchPresent`, `watchOnline`.
3. **Native `LiveActivityManager`** — compute device flags from `WCSession` and merge into
   content; terminal-state immediate flush hook (Dart side).
4. **Widget UI** (`JarvisWidget.swift`) — orb (image + pulsing halo), header (JARVIS /
   Connected + state pill), waveform (variableColor), conversation panel, devices strip;
   compact/minimal/lock variants; `widgetURL`.
5. **Dart** (`voice_controller`) — terminal-state immediate flush; keep dedupe/throttle.
6. **Verify** — `flutter analyze` + full `flutter build ios --release`.

## Out of scope
Inter font in the extension (system font is fine); desktop/3rd device counts; universal
link; amplitude-reactive animation.
