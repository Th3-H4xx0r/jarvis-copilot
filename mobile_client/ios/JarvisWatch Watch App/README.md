# JarvisCopilot Watch (voice-only companion)

A minimal native watchOS app: **tap → dictate → JARVIS answers** (reply text +
spoken in your configured JARVIS voice). It is a tethered companion to the
iPhone (Flutter) app and holds **no credentials of its own** — it relays
through the phone over `WCSession`.

- Design spec: `docs/superpowers/specs/2026-05-28-watchos-voice-app-design.md`
- Implementation plan: `docs/superpowers/plans/2026-05-28-watchos-voice-app.md`

## How it works (relay architecture)

```
Watch (SwiftUI)            iPhone (Runner)                    Backend
  dictation → text  ──WCSession sendMessage──▶  WatchBridge (native relay)
                                                  /api/session/new
                                                  /api/chat/start → SSE
                                                  /api/voice/synthesize
  text  ◀────────── replyHandler ─────────────  {ok, replyText}
  audio ◀────────── transferFile ─────────────  (mp3 clip, out-of-band)
```

The relay runs **natively in Swift** (`Runner/WatchBridge.swift`), cert-pinned,
reading creds from `UserDefaults` that Dart syncs via the `jarviscopilot/watch`
channel (`lib/services/watch_sync.dart`). No Flutter engine is required, so the
watch works even when the iOS app is backgrounded/background-launched —
`sendMessage` from the watch wakes the iOS app. The watch does **not** pre-gate
on `isReachable` (that's false exactly when the app is backgrounded); it calls
`sendMessage` and lets the errorHandler classify a genuine unreachable phone.

The assistant **text** comes back in the sendMessage reply; the **spoken clip**
is delivered out-of-band via `transferFile` (so the reply payload stays under
WCSession's size limit) and played by `WatchConnector` on receipt.

SSE note: the server (`webui/api/streaming.py`) emits assistant text as `token`
events and ends the stream with `stream_end` (errors as `apperror`) — the relay
parses those, not `delta`/`done`/`error`.

## Files

Watch target (`JarvisWatch Watch App/`):
- `JarvisWatchApp.swift` — `@main` SwiftUI app.
- `ContentView.swift` — single screen + dictation sheet + setup banner.
- `WatchViewModel.swift` — state machine (idle/listening/thinking/answer/error).
- `WatchConnector.swift` — `WCSession` client (`ask(text:)`, reachability, login-state).
- `AskResult.swift` — reply model + `AskError`.
- `AudioPlayer.swift` — `AVAudioPlayer` MP3 playback.

iOS Runner:
- `Runner/WatchBridge.swift` — `WCSession` delegate + native relay + `WatchRelay` pure helpers.
- `Runner/AppDelegate.swift` — activates `WatchBridge`; registers `jarviscopilot/watch`.

Tests:
- `RunnerTests/WatchBridgeTests.swift` — SSE accumulator + session-id extraction.
- `JarvisWatch Watch AppTests/WatchViewModelTests.swift` — state-machine transitions.

## ⚠️ Setup required in Xcode (one-time — cannot be scripted)

These `.swift` files are written and ready, but the watchOS **target** must be
created in Xcode (hand-editing `project.pbxproj` for a Flutter+CocoaPods
workspace is fragile):

1. Open `mobile_client/ios/Runner.xcworkspace`.
2. File → New → Target → watchOS → **App**. Name `JarvisWatch`, **SwiftUI**,
   embed in **Runner**, deployment target **watchOS 10.0**.
3. Delete the auto-generated `ContentView.swift` / `JarvisWatchApp.swift` and
   add the files in this folder to the watch target instead.
4. Add `WatchBridge.swift` to the **Runner** (iOS) target; add
   `WatchBridgeTests.swift` to **RunnerTests**; add `WatchViewModelTests.swift`
   to the **JarvisWatch Watch AppTests** target.
5. Set these on the watch target (Build Settings → "Info.plist values", or a
   file-based Info.plist):
   - `INFOPLIST_KEY_NSMicrophoneUsageDescription` = "JarvisCopilot uses the microphone so you can talk to JARVIS."
   - `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` = "JarvisCopilot transcribes your speech to send to JARVIS."
6. Build the watch scheme on the watchOS simulator.

### Note on editor errors before the target exists
Until step 2–4 are done, an editor/SourceKit may flag "No such module
'WatchConnectivity'/'UIKit'/'XCTest'", "AVAudioSession is unavailable in
macOS", "@main … top-level code", or "Cannot find type WatchConnector in
scope". These are **false positives** from analyzing the files without the
watchOS/iOS SDK or their sibling files in a target. They disappear once the
files are members of the proper Xcode targets.

## Manual end-to-end verification (real paired hardware)

- Logged-in phone → watch shows the mic button (not the setup banner).
- Log out on the phone → watch flips to "Open JarvisCopilot on your iPhone…".
- Tap mic → dictate "what time is it" → reply text appears + is spoken.
- Phone in airplane mode → watch shows "Couldn't reach JarvisCopilot."
- Force-quit the phone app, then ask from the watch → still answers (validates
  the engine-free native relay).
- Audio routes to the watch speaker and to paired AirPods.
