# Security review (2026-09-05, read-only). Paths relative to `JarvisWearables/` unless noted. No criticals.

## HIGH
- H1 `BridgeSettingsView.swift:28-38` (reached from `Copilot/Settings/SettingsPage.swift:137`) — legacy QR sheet auto-calls `pair()` with no confirmation and `applyScanned` persists CF creds before the claim succeeds; `PairingScanner.swift:33-39` accepts http. Fix: drop auto-pair, show "Pair with <host>?" + explicit submit (as `Copilot/Pairing/PairStore.swift:118-155` does), persist CF creds only after a successful claim.
- H2 `Copilot/Skills/IOSSkills.swift:128-198`, `PhoneCommand.swift:36-38,77-87`, `ActionBanner.swift:40-53` — `phone_control` `send_message` sends an SMS with no confirmation; banner title is just "Phone control". Fix: gate `send_message` behind the same in-app confirmation as `send_sms` (or remove the verb); add `send_message`/`open_url` cases to `actionBannerTitle` with recipient + truncated body.
- H3 `Copilot/Skills/SystemSkills.swift:13-27,31-65`, `AppSchemeTable.swift:50-61` — `open_url`/`open_app` open any scheme (`shortcuts://` bypasses a disabled `run_shortcut`, `App-Prefs:`, `jarviswearables://` self-callbacks); both are on `LocalActionSafety.swift:38-53` allowlist. Fix: allowlist `http, https, mailto, tel` + `AppSchemeTable.knownApps` values; refuse `shortcuts`/`jarviswearables`.

## MEDIUM
- M1 `Copilot/More/WebViewPage.swift:79,107-124` + `BridgeClient.swift:156-165` — persistent `WKWebsiteDataStore.default()` keeps `hermes_session` on disk; `unpair()` never clears it. Fix: `.nonPersistent()`, and clear all website data on unpair (add-only in BridgeClient or from SettingsStore.unpair).
- M2 `Copilot/Skills/DataSkills.swift:47,58,132,136,220` — `limit` only lower-clamped; schemas promise max 100/200/30. Fix: clamp upper bounds.
- M3 `Copilot/Skills/InvokeRunner.swift:41` (`paused` in memory; set at `Skills/Views/SkillsPageModel.swift:93-95`) — kill switch lost on relaunch. Persist via `KeyValueStore`.
- M4 `BridgeClient.swift:583,596` — CF service token + cookie sync to iCloud Keychain. Recommend `kSecAttrSynchronizable:false` for CF id/secret (note: BridgeClient is add-only; report, don't change unless trivial).
- M5 `Copilot/Chat/Views/MarkdownText.swift:189-200` — markdown links open any scheme on tap. Fix: `.environment(\.openURL, OpenURLAction { http/https/mailto → .systemAction; else confirm })` on chat + coding views.
- M6 `Copilot/Services/AppGroupIslandDesignCache.swift:117-133,98-113` — harvests every http(s) string in design JSON and fetches it. Fix: only known image `source` keys, https only.
- M7 `Copilot/Core/JarvisAPI.swift:367-375` — `bytes(absolute:)` attaches credentials to any host. Fix: `guard url.host == credentials.baseURL?.host`.

## LOW
- L1 `Copilot/Skills/ShortcutRunner.swift:27,57-90` — `early[rid]` unbounded; cap + TTL.
- L2 `Copilot/Skills/MediaSkills.swift:132-137` → `SkillBoundariesMedia.swift:140-143` — `play_audio` fetches any URL incl. `file://`; restrict to https.
- L3 `Copilot/Services/MetricKitReporter.swift:40,49` — diagnostics logged `privacy: .public`; drop it.
- L4 `Copilot/Skills/ActionBanner.swift:52-53` — generic banner for share_text/share_image/make_call/take_photo; add cases.
- L5 `Info.plist:20-56` — 25 `LSApplicationQueriesSchemes` = install fingerprinting; informational.
- L6 `scripts/sync-project.rb` compiles every .swift on disk; informational.

## Accepted (by design): no TLS pinning (ATS on), paired server is the trust root, `drainQueue` ignores the bridge toggle, `UIImage(data:)` on untrusted bytes, App Group holds no credentials, background audio keepalive, `jarviswearables://pair` unhandled (must go through PairStore confirm flow if wired), no app passcode gate.
