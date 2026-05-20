# JarvisCopilot Mobile

Flutter-based iOS + Android client for JarvisCopilot. Pairs with a
JarvisCopilot server, exposes platform-native skills back to the agent
(open URL, share, location, contacts, calendar, photos, SMS on
Android, Shortcuts on iOS, …), and hosts the full webui through a
hybrid native + webview shell.

## Quick start (dev)

```bash
cd mobile_client
flutter pub get

# iOS
open ios/Runner.xcworkspace      # add team + bundle ID once
flutter run -d ios

# Android
flutter run -d android
```

You'll also need:

- **iOS:** `ios/Runner/GoogleService-Info.plist` from your Firebase
  project (so APNs flows through Firebase Messaging). Drop a
  development APNs auth key at `STATE_DIR/.apns-auth-key.p8` on the
  server side, plus `STATE_DIR/.apns-config.json` with `key_id`,
  `team_id`, `topic` (bundle ID), and `use_sandbox: true` for dev.
- **Android:** `android/app/google-services.json` from your Firebase
  project. Drop the project's service-account JSON at
  `STATE_DIR/.fcm-service-account.json` on the server side.

If push isn't configured the app still works in foreground (the WS
bridge handles every invocation). Push only kicks in when the phone
is locked / app is backgrounded.

## Pairing

On the server's webui, click **Devices → + Pair new device**. The
modal now shows a QR code containing
`jarviscopilot://pair?server=…&code=…`. Scan it from the app's pair
screen and the form fills in. Confirm the TLS fingerprint matches the
one `jarviscopilot status` reports on the server, then tap **Pair**.

The fingerprint is persisted in Keychain (iOS) / EncryptedSharedPreferences
(Android). Subsequent connections refuse if the cert ever changes.

## Architecture

```
Mobile app (Flutter)
├── Native shell
│   ├── Bottom nav (Chat • Voice • Skills • Devices • More)
│   └── Native pages: pair, chat, voice, devices, skills,
│       settings, logs, more
├── Embedded webview
│   └── Hosts webui's tasks/kanban/memory/workspaces/profiles/…
├── Skill bridge
│   ├── Foreground: WebSocket to /api/devices/bridge/ws
│   └── Background: silent push → /api/devices/mobile/poll
└── Push handler
    └── FCM (Android) + APNs via Firebase Messaging (iOS)
```

See `PLAN.md` for the full design doc + decision rationale.

## Building for distribution

```bash
# iOS — TestFlight build
./scripts/build-ios.sh --export-method app-store

# Android — signed release APK (split per ABI)
./scripts/build-android.sh
```

## Adding a new skill

1. Add a `SkillEntry` in `lib/skills/common.dart` (cross-platform) or
   `lib/skills/ios.dart` / `lib/skills/android.dart`.
2. If the skill needs native code, add a MethodChannel handler:
   - iOS: extend `ios/Runner/AppDelegate.swift` or add a new
     `…Bridge.swift` file.
   - Android: extend `SkillChannels.kt`.
3. Add the matching permission to `Info.plist` (iOS) or
   `AndroidManifest.xml` (Android). Runtime permission requests live
   in the skill's `run` closure.

The server picks up new skills automatically — every WS reconnect
sends a fresh `register` frame.
