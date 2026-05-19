# JarvisCopilot Mobile App — Implementation Plan

Tracking doc for the iOS + Android client. Captures the agreed architecture, decisions already locked in, the skill catalogue, phased implementation order, and open follow-ups so anyone (future-you, future-me, a collaborator) can pick this up cold.

Generated: 2026-05-18.
Status: planning complete, implementation not started.

---

## Goal

A mobile app for iOS and Android that pairs with a JarvisCopilot server, exposes platform-native skills back to the chat agent, AND surfaces the full webui experience (chat, voice, sessions, kanban, memory, workspaces, …) so the user can talk to JARVIS and manage the server from a phone.

The mobile app is a **second-class peer** to the desktop client (the existing pywebview pair dialog + cross-platform skill bridge already in `desktop_client/`). It shares the same pairing protocol, the same WebSocket bridge, and the same `device_bridge` server-side endpoint — but adds push notifications for background invocation, since mobile platforms can't hold a WS open indefinitely.

---

## Decisions locked in

| Decision | Choice | Rationale |
|---|---|---|
| Framework | **Flutter (Dart)** | Native compilation, smooth animations matching webui's dark+gradient design, simpler Android foreground service than RN, Material 3 fidelity. |
| Distribution | **Personal side-loading first** | Apple Developer for TestFlight + ad-hoc IPA; Android via signed APK side-load. No App Review constraints — lets us ship `AccessibilityService`, `SEND_SMS`, `NotificationListener` skills on Android without store rejection. Public store as a follow-up if you decide to share. |
| Push notifications | **Phase 3 — set up FCM + APNs** | Without push, the phone is useless when locked or in pocket. FCM is free; APNs uses your Apple Developer account. Foreground-only would be too crippled for a primary device. |
| Chat / Voice UI | **Native from day one** | Webview chat composer feels webby (especially iOS). Native streaming markdown, native attachment picker, native push-to-talk, background streaming + reply notifications. Worth the ~1 extra week of work. |
| Hybrid native + webview | **Native for hot paths, webview for admin tabs** | 5 native pages cover 90% of mobile sessions; remaining 9 server tabs are admin screens better served by webview wrapping the existing webui (gets feature parity for free, auto-updates on server ship). |

---

## Architecture

```
                              ┌────────────────────────────────┐
                              │   JarvisCopilot Server (VPS)   │
                              │                                │
                              │  Existing endpoints:            │
                              │   /api/auth/pair/claim          │
                              │   /api/devices/bridge/ws        │
                              │   /api/chat/stream              │
                              │   /api/voice/* …                │
                              │                                │
                              │  NEW (phase 3):                 │
                              │   /api/devices/mobile/token     │
                              │   /api/devices/mobile/poll      │
                              │   /api/devices/mobile/result    │
                              │   webui/api/push/{fcm,apns}.py  │
                              │                                │
                              │   invoke_skill() refactor:      │
                              │     - WS frame if live          │
                              │     - silent push if mobile-bg  │
                              └──────────────┬─────────────────┘
                                             │ HTTPS + FCM/APNs
                  ┌──────────────────────────┼──────────────────────────┐
                  │                          │                          │
          ┌───────▼────────┐         ┌───────▼────────┐          ┌──────▼───────┐
          │   iOS app      │         │  Android app   │          │  Desktop /   │
          │   Flutter      │         │   Flutter      │          │  Browser     │
          │                │         │                │          │  pairings    │
          │ Foreground: WS │         │ Foreground svc │          │              │
          │ Background:    │         │   holds WS     │          │              │
          │   silent APNs  │         │ FCM as backup  │          │              │
          │   → poll queue │         │                │          │              │
          └────────────────┘         └────────────────┘          └──────────────┘
```

### Mobile app internal layout

```
Mobile app (Flutter)
│
├── Native shell
│   ├── Bottom nav: Chat • Voice • Skills • Devices • More
│   ├── Dark + gold/orange-gradient theme (matches webui)
│   ├── Deep-link router (jarviscopilot:// scheme)
│   └── Native screens
│       ├── pair_page.dart            QR scanner + manual 6-char code
│       ├── chat_page.dart            native streaming markdown, native composer + attachments
│       ├── voice_page.dart           Flutter CustomPainter orb, PTT + realtime, engine picker
│       ├── devices_page.dart         list paired devices, revoke / log out / skill ACL
│       ├── skills_page.dart          per-device skill manifest with toggles
│       ├── settings_page.dart        local prefs + push status + link to server settings
│       ├── logs_page.dart            THIS device's invocation history
│       └── more_page.dart            3×3 grid launching webview tabs
│
├── Embedded webview
│   ├── jc_webview.dart               Flutter InAppWebView wrapper
│   ├── cookie injection              session cookie pre-set, TLS pinned
│   ├── JS↔Native bridge              window.JarvisCopilotMobile.{share,vibrate,popView,…}
│   └── Routes wrapped:
│         /tasks  /kanban  /memory  /workspaces  /profiles
│         /todos  /insights  /logs  /settings (server-side)
│
└── Native infrastructure
    ├── Skill bridge (WS foreground + push background)
    ├── Permission manager (camera, mic, contacts, …)
    ├── Push handler (FCM + APNs token registration)
    └── Credential store (flutter_secure_storage)
```

### Hybrid split — what's native vs webview

| Tab | Approach | Why |
|---|---|---|
| Pair | Native | First-run UX, QR scanner, secure-storage, fingerprint pinning. |
| Chat | Native | Hot path. Streaming markdown, native composer, attachments, voice input, background streaming. |
| Voice | Native | Mic access, orb visualizer, PTT + realtime audio. Webview can't do any of this well. |
| Devices | Native | Sensitive (revoke/logout); better UX with platform-native confirmations. |
| Skills | Native | Per-device skill toggle ACL. |
| Settings | Native | Local prefs (push opt-in, skill allow-list, allow_shell). Has a link out to webview "Server settings". |
| Logs (client) | Native | This-device invocation history. Distinct from server logs. |
| Tasks (cron) | Webview | Admin screen. Loads existing webui tab. |
| Kanban | Webview | Same. |
| Memory | Webview | Same. |
| Workspaces | Webview | Same. |
| Profiles | Webui | Same. |
| Todos | Webview | Same. |
| Insights | Webview | Same. |
| Logs (server) | Webview | Same. |
| Settings (server) | Webview | Reaches webui via "Server settings" link. |

---

## Skill catalogue — what runs on the phone

### Tier 1 — cross-platform, low risk, ship in phase 3

| Skill | iOS | Android | Notes |
|---|---|---|---|
| `open_url` | UIApplication.open | Intent.ACTION_VIEW | universal |
| `open_app` | URL scheme only (twitter://) | package name OR intent | iOS limit |
| `notify` | UNUserNotificationCenter | NotificationManager | local notification |
| `clipboard_read` / `clipboard_write` | UIPasteboard | ClipboardManager | iOS 16+ shows a paste banner |
| `share_text` / `share_image` | UIActivityViewController | ACTION_SEND | invokes share sheet |
| `device_info` | UIDevice + ProcessInfo | Build.MODEL + os.* | model, OS, locale |
| `battery_level` | both | both | 0-100 + charging state |
| `vibrate` | Haptics | Vibrator | |
| `set_volume` / `get_volume` | media volume only | AudioManager | iOS has no public ringer-volume API |
| `flashlight_on` / `flashlight_off` | AVCaptureDevice torch | CameraManager torch | camera permission |
| `get_location` (one-shot) | CoreLocation | FusedLocationProvider | needs `whenInUse` |
| `take_photo` | ImagePicker | ACTION_IMAGE_CAPTURE | base64 PNG |
| `pick_photo` | PHPickerViewController | ACTION_PICK | user selects |
| `text_to_speech` (output) | AVSpeechSynthesizer | TextToSpeech | local TTS |

### Tier 2 — medium effort, big value

| Skill | iOS | Android | Notes |
|---|---|---|---|
| `record_audio` (short clip) | AVAudioRecorder | MediaRecorder | for "transcribe this" |
| `make_call` | tel:// URL | ACTION_DIAL | opens dialer (user taps) |
| `read_contacts` (search) | Contacts framework | ContactsContract | contacts permission |
| `add_calendar_event` | EventKit | CalendarContract | calendar permission |
| `list_calendar_events` | EventKit | CalendarContract | by date range |

### Tier 3 — platform-specific power features

**iOS-only:**
- `run_shortcut` — invoke a user-created Shortcut by name via x-callback-url. Cleanest way for arbitrary side effects on iOS.
- `siri_intent_donation` — surface predicted actions in Spotlight / Lock Screen (read-only, not invoked by agent).
- `read_healthkit` — heart rate, steps, sleep, workouts. Read-only.
- App Intents (iOS 16+) — register JarvisCopilot actions for Siri/Shortcuts.

**Android-only:**
- `send_sms` — SmsManager.sendTextMessage. Programmatic; iOS requires user tap. Play Store flag.
- `read_notifications` — NotificationListenerService exposes every notification. Powerful for "what's on my phone?" queries. Play Store flag.
- `type_text` / `tap_at` / `swipe` — only via AccessibilityService. User must enable in settings; Play Store flags it.
- `tasker_invoke` — fire a Tasker task by name. Free integration if user has Tasker.
- Quick Settings tile — "Talk to JARVIS" in the system pull-down.

### Not possible on mobile

- Mouse / keyboard control of the device itself (sandbox).
- Window enumeration.
- Arbitrary shell.
- Screen capture of other apps (iOS: ReplayKit user-initiated only; Android: cast permission per session).
- System-settings writes beyond a narrow allowed list (volume, screen brightness on some OEMs).

---

## Pairing flow

Same handshake as the desktop client (`/api/auth/pair/claim`) plus a mobile-specific QR shortcut.

1. **On the webui's "+ Pair new device" modal**, display a QR code containing:
   ```
   jarviscopilot://pair?server=https%3A%2F%2F1.2.3.4%3A8787&code=ABC-DEF
   ```
   alongside the existing visible 6-char code.

2. **On first app launch**, Pair page has a "Scan QR" button → camera permission → recognises QR → all fields prefilled.

3. **Manual fallback**: same three-field form (server URL, code, device name) as the desktop client's pywebview dialog.

4. **Cert pinning** identical to desktop:
   - On the first claim POST, capture the server's TLS leaf-cert SHA-256.
   - Show it in a confirmation step alongside `jarviscopilot status` instructions.
   - User confirms → fingerprint stored in `flutter_secure_storage`.
   - Subsequent connections refuse if the cert ever changes.

5. **Result on success**: device appears in the webui Devices tab with `mobile: true`, registered skill manifest visible, push token stored.

---

## Background execution strategy

### Android — foreground service holds the WS

Android allows foreground services with a persistent notification ("JarvisCopilot is active") to run indefinitely. The WS bridge connection stays open across screen-off, app-backgrounded, even after low-battery. Same protocol as desktop. FCM is a fallback if the service dies (system kill, OOM).

### iOS — silent push wakes the app

iOS terminates background apps aggressively. No WS-hold strategy works long-term.

Pattern:
1. App in foreground → WS bridge identical to desktop.
2. App backgrounded → server falls back to APNs.
3. Agent invokes skill on a backgrounded iOS device:
   - Server queues invocation in `_pending_mobile_invokes[device_id]`.
   - Sends silent APNs (`content-available: 1`).
   - iOS wakes the app for ~30 seconds of background runtime.
   - App calls `GET /api/devices/mobile/poll` (long-poll, 30s timeout).
   - Gets the queued invocations.
   - Executes them.
   - Posts results via `POST /api/devices/mobile/result`.
   - Server resolves the waiting `Future` keyed by call_id.
   - Agent's `invoke_skill()` returns to the chat loop.
4. End-to-end latency: 1-3 seconds dominated by APNs delivery.

For genuinely real-time use cases (audio streaming during a voice call), iOS PushKit / VoIP background mode keeps the app alive indefinitely. We don't ship this for v1 — voice goes through the WS endpoint, used only while the user has the app foregrounded.

---

## Server-side changes required

| File | What | Effort |
|---|---|---|
| `webui/api/push/__init__.py` | new module | small |
| `webui/api/push/fcm.py` | FCM HTTP v1 send (JWT-signed POST, no SDK) | ~150 LOC |
| `webui/api/push/apns.py` | APNs send (JWT auth key, HTTP/2) | ~150 LOC |
| `webui/api/device_bridge.py` | refactor `invoke_skill()` to handle WS OR mobile-queue paths | ~80 LOC patch |
| `webui/api/routes.py` | `/api/devices/mobile/{token,poll,result}` endpoints | ~120 LOC |
| `webui/api/pairing.py` | add `push_token` + `push_kind` fields to device record; `update_push_token()` helper | ~40 LOC |
| `webui/static/devices.js` | render QR code on "+ Pair new device" modal (alongside the existing 6-char code) | ~30 LOC + qrcodejs CDN |
| `webui/static/boot.js` | detect `window.JarvisCopilotMobile`, add `<body class="in-mobile-app">` | ~10 LOC |
| `webui/static/style.css` | `.in-mobile-app .rail, .in-mobile-app .sidebar-nav { display:none }` plus a `.popView()` back-button affordance | ~10 LOC |
| `STATE_DIR/.fcm-service-account.json` | manual one-time upload by you | n/a |
| `STATE_DIR/.apns-auth-key.p8` | manual one-time upload by you | n/a |

Total server-side: ~600 LOC + two credentials files.

---

## File layout

```
mobile_client/
├── PLAN.md                            ← this document
├── README.md                          ← user-facing setup instructions
├── pubspec.yaml                       ← Flutter deps
├── analysis_options.yaml              ← lints
│
├── lib/
│   ├── main.dart                      ← app entry, theme, routing
│   ├── theme.dart                     ← dark + gradient palette (matches webui)
│   ├── nav.dart                       ← bottom nav + route table
│   │
│   ├── pages/
│   │   ├── pair_page.dart             ← QR + manual code, fingerprint pin
│   │   ├── chat_page.dart             ← native streaming markdown
│   │   ├── voice_page.dart            ← orb + PTT + realtime
│   │   ├── devices_page.dart          ← list / revoke / log out
│   │   ├── skills_page.dart           ← per-device skill toggles
│   │   ├── settings_page.dart         ← local prefs + push status
│   │   ├── logs_page.dart             ← this-device invocation log
│   │   ├── more_page.dart             ← grid of webview launchers
│   │   └── webview_page.dart          ← generic webview wrapper
│   │
│   ├── services/
│   │   ├── api_client.dart            ← Dio with cert pinning + cookie
│   │   ├── ws_bridge.dart             ← foreground WS connection
│   │   ├── push_handler.dart          ← FCM/APNs registration, silent-push hook
│   │   ├── credentials.dart           ← flutter_secure_storage wrapper
│   │   └── invoke_runner.dart         ← central skill dispatch
│   │
│   ├── skills/
│   │   ├── registry.dart              ← @MobileSkill registry
│   │   ├── common.dart                ← clipboard, notify, url, share, vibrate, …
│   │   ├── ios.dart                   ← Shortcuts, HealthKit (platform channel)
│   │   └── android.dart               ← SMS, NotificationListener (platform channel)
│   │
│   ├── api/
│   │   ├── chat.dart                  ← /api/chat/stream NDJSON consumer
│   │   ├── voice.dart                 ← voice endpoints + WS bridge
│   │   ├── sessions.dart              ← session list / pin / rename
│   │   ├── models.dart                ← model & provider picker
│   │   └── devices.dart               ← /api/devices/* wrappers
│   │
│   └── widgets/
│       ├── gradient_button.dart       ← orange→amber CTA
│       ├── jc_logo.dart               ← gradient JC disc
│       ├── status_badge.dart          ← ● online/offline/reconnecting
│       ├── orb_visualizer.dart        ← Flutter CustomPainter
│       ├── chat_message_bubble.dart
│       ├── markdown_stream.dart       ← streaming markdown renderer
│       └── ...
│
├── ios/Runner/
│   ├── Info.plist                     ← URL scheme, background modes, NS*UsageDescription
│   ├── AppDelegate.swift              ← APNs registration, silent-push handler
│   └── ShortcutsBridge.swift          ← x-callback-url for run_shortcut
│
├── android/app/src/main/
│   ├── AndroidManifest.xml            ← FOREGROUND_SERVICE, SEND_SMS, …
│   ├── kotlin/.../MainActivity.kt
│   ├── kotlin/.../BridgeService.kt    ← foreground service holding WS
│   └── kotlin/.../FcmService.kt       ← FirebaseMessagingService
│
└── scripts/
    ├── build-ios.sh                   ← xcodebuild + signing
    └── build-android.sh               ← ./gradlew assembleRelease
```

---

## Phased implementation

Each phase is independently committable. Useful checkpoints highlighted.

| # | Phase | What ships | Est. effort |
|---|---|---|---|
| 1 | Flutter scaffold + theme + bottom nav | App installs + opens, 5 empty native tabs + More grid stub, dark theme + gradient logo working | 1 day |
| 2 | Pair page + secure-storage + cert pinning | **Checkpoint: phone shows up in webui Devices tab with `mobile:true`.** | 2 days |
| 3 | Skill registry + foreground WS bridge + Tier-1 skills | **Checkpoint: agent can invoke skills (`open_url`, `clipboard_*`, `notify`, `share`, `vibrate`, `device_info`, `get_location`, `flashlight`, `volume`) while app is foregrounded.** | 2 days |
| 4 | Server push infra (FCM + APNs) + mobile poll endpoints + `invoke_skill` refactor | **Checkpoint: skills work while phone is locked, via silent push → poll → execute → result.** | 3 days |
| 5 | Android foreground service + iOS background mode | Persistent WS on Android (visible notif), APNs silent push reliable on iOS. Battery-tested. | 2 days |
| 6 | More grid + webview wrapper + cookie injection + webui mobile-detect CSS | **Checkpoint: full feature parity — every webui tab reachable from mobile via webview.** | 1 day |
| 7 | Native Devices page | List paired devices, online indicator, revoke / log out, per-device skill ACL toggle | 1 day |
| 8 | Native Chat page | Session list, message list, streaming markdown, native composer, attachments, push-to-talk on composer, background streaming + reply notifications | 4 days |
| 9 | Native Voice page | Orb visualizer (CustomPainter), PTT + realtime, engine/voice picker, mic capture, audio playback | 3 days |
| 10 | Tier-2 + platform-specific skills | contacts, calendar, photo, audio, call, send_sms (Android), run_shortcut (iOS), AccessibilityService skills | 3 days |
| 11 | Distribution | TestFlight build, signed APK, README install instructions, optional store submission | 1 day |

**Total estimate: ~3.5 weeks of focused work.** Useful milestones at phases 3 (skill bridge live), 6 (full webview parity), 9 (polished native chat+voice).

Sequence flexibility: phases 7 / 10 can run in parallel with 8 / 9 if multiple people work on this. Phase 4 should not be deferred past phase 5 because the background mode design depends on push being live.

---

## Webui changes required (minimal)

`webui/static/boot.js` — detect mobile-app context:
```js
if (window.JarvisCopilotMobile) {
  document.body.classList.add('in-mobile-app');
  // expose a popView callback to native: hidden back-button handler
}
```

`webui/static/style.css` (snippet):
```css
body.in-mobile-app .rail { display: none; }
body.in-mobile-app .sidebar-nav { display: none; }
body.in-mobile-app main.main { padding-bottom: 0; }
```

`webui/static/devices.js` — render QR code on "+ Pair new device" modal alongside the 6-char code. Use a small inline QR library (qrcode.js, ~3KB) loaded from a CDN. The QR contents:
```
jarviscopilot://pair?server=<urlencoded>&code=<code>
```

~50 lines of webui-side patches total.

---

## Open questions / future work

- **Wake word ("Hey JARVIS")** — needs Flutter binding to Porcupine or Snowboy. Android needs foreground audio service; iOS needs Background Mode = audio. Deferred — not in v1.
- **Stylus / Apple Pencil support** in chat composer — nice but not required for v1.
- **iPad / large-screen Android layouts** — Flutter handles this with `MediaQuery` breakpoints; we'll add a two-column layout at >= 768px but won't optimise heavily until usage warrants it.
- **Public store submission** — design choice deferred until v1 lands and you decide whether to share publicly.
- **CarPlay / Android Auto** — voice-first car experience would be killer. Both platforms have specific UI requirements. Deferred until v2.
- **Continuous voice mode** (always-listening, like Siri/Alexa) — requires VoIP background mode on iOS plus careful battery + privacy UX. Worth a separate planning doc when we get there.
- **End-to-end encryption** — currently the paired session cookie + TLS pinning is enough for a personal deployment. If multi-user, look at per-device asymmetric keys with the server verifying signed invoke requests.

---

## Useful references

- Existing desktop client: `desktop_client/jc_client/` — same protocol, mostly portable patterns
- Existing pair UI: `desktop_client/jc_client/pair_ui.py` — the HTML in there is the visual target for mobile pair page
- Existing device bridge: `webui/api/device_bridge.py` — server-side WS endpoint we connect to
- Existing pairing module: `webui/api/pairing.py` — `claim_pairing_code()` + `touch_device_by_session()`
- Existing webui: `webui/static/` — what the webview tabs render
- Decisions: scroll up in this file
