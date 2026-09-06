# Swift correctness review (2026-09-05). Paths relative to `JarvisWearables/`.

## CRITICAL
- C1 `Copilot/Voice/SpeechServices.swift:103-113` (+ `Voice/VoiceStoreTransport.swift:88`) — `SpeechSession.stop()` awaits a continuation only resumed by SFSpeech final/error; no timeout → turn stuck in `thinking`, continuation leaks. Fix: race `stop()` vs 2 s sleep (resume `pendingFinal` with `latest`), or a clock-scheduled `finish(latest)`.
- C2 `Copilot/Coding/CodingSessionStore.swift:370-372` — empty `catch` in `pumpTerminal()` leaves `terminalAttached=true`; `sendTerminalInput` (398-405) returns true into a dead PTY. Fix: mirror `.closed`: `terminalTask=nil; terminalAttached=false; terminalStarting=false; scheduleReattach()` + set `terminalError`.
- C3 `Copilot/Voice/VoiceStore.swift:310-360` `perform(_:)` — unstructured `Task{}` per effect; `startMic` (5×350 ms retries in `AudioInputEngine.swift:37-49`) can complete after `teardown` → mic stays on at `.idle`. Fix: serialise mic effects through one `TaskHandle` or epoch check after `input.start` (`guard epoch == turnEpoch, machine.state.isActive`).
- C4 `Copilot/Services/BackgroundLocation.swift:173-197` — `requestAlwaysAuthorization()` continuation never resumes when iOS no-ops the request; Settings toggle hangs (`SettingsStore.setTrackLocation`). Fix: snapshot status, 10 s timeout returning current status, resume waiters in `stopMonitoring`/deinit.
- C5 `Copilot/Coding/CodingSessionStore.swift:137-143` — `start()` bootstrap task untracked; re-arms `schedulePoll()` after `stop()`. Fix: TaskHandle + `started` flag cleared by `stop()`.

## HIGH
- H6 `guard let self` hoisted outside `while` loops pins self (deinit never runs): `Copilot/More/Kanban/KanbanStore.swift:129-131,148-155,464-471`, `More/Crons/CronsStore.swift:94-101`, `More/ServerLogs/ServerLogsStore.swift:96-105`, `Services/LocalConnectionNotifier.swift:66-68`. Fix: move the guard inside the loop (as `ChatStore.swift:180`, `CodingStore.swift:285`).
- H7 `Copilot/Chat/Views/MarkdownText.swift:18-19` — full `MarkdownBlocks.split` + `AttributedString(markdown:)` per block on every body eval (per token). Fix: cache parse keyed on text (per-message render cache / LRU).
- H8 `Copilot/Coding/Views/CodingTerminalPanel.swift:79` + `Coding/TerminalBuffer.swift:61-63` — 2000 lines rebuilt from `[Character]` every body eval; `id: \.offset`. Fix: cache `lines` in the buffer, invalidate on write; stable monotonic line ids.
- H9 `Copilot/Chat/ChatPage.swift:148,164` — `store.rows` recomputed per body; `.onChange(of: store.messages)` deep-compares per token + animated scroll. Fix: cache rows in store; scroll on count/tick.
- H10 `Copilot/Chat/ChatModels.swift:190` — `ChatMessage.id = UUID()` per parse → every refresh re-identifies rows (lost scroll/expansion). Fix: deterministic id from role+timestamp+index.
- H11 `Copilot/Pairing/QRScanner.swift:50,57` — start/stop in unordered `Task.detached`; camera may stay on. Fix: one serial `DispatchQueue`.
- H12 `Copilot/Chat/ChatStore.swift:298-305` — clarify cleared before POST, `try?` (same as silent-failures H6).
- H13 `Copilot/Chat/ChatAPI.swift:88-91` — 2xx event-stream with zero events → re-POST (duplicate turn). Fix: treat 2xx event-stream as committed at open; snapshot session on empty stream.
- H14 `Copilot/Chat/Views/AttachPicker.swift:86,102` — sync `Data(contentsOf:)` on main actor before size gate. Fix: check `fileSize` first; read off main.
- H15 `Copilot/More/WebViewPage.swift:107-125` — cookie in persistent WK store (same as security M1).
- H16 `Copilot/Voice/VoiceStore.swift:128` — no `deinit`; `qualityTask` + 3 timer tokens never cancelled. Fix: TaskHandle + `deinit`, cancel timers in `teardown()`.
- H17 `Copilot/Coding/CodingStore.swift:97-108` — `sessionStores` unbounded. Fix: evict on deselect (stop+detach) or LRU 3.

## MEDIUM
- M18 `Copilot/Voice/AudioQueue.swift:412-419` — per-frame Task chain never cancelled; `chain` retains last task. Cancel/nil in `stop()`/`dispose()`.
- M19 `Copilot/Core/JarvisAPI.swift:47-65,521-549` — per-byte async layers (3×). Fix: transport vends `AsyncThrowingStream<Data>` chunks; line-split over Data.
- M20 `Copilot/Voice/VoiceSession.swift:224,226` — send errors discarded (same as silent H2).
- M21 `VoiceSession.swift:192-235` — `URLSessionVoiceSocket` no deinit; task never cancelled on server-close path. Add `deinit { receiver?.cancel(); task.cancel(with: .goingAway, reason: nil) }`.
- M22 `Copilot/Services/LiveActivityController.swift:41-44` — per-update Tasks unordered. Serialise.
- M23 `LiveActivityController.swift:108-117` — push-token loop per activity never cancelled; `observed` never shrinks. Keyed dict; cancel on end.
- M24 `Copilot/Voice/VoiceStoreTransport.swift:313-321` — TTS task group not cancelled on epoch change.
- M25 `Copilot/Chat/ChatStore.swift:499` — `models = try?` (same as silent M11).
- M26 `ChatStore.swift:173-184` + `More/MoreSupport.swift:235-248` — `TaskHandle.current` never nil'ed on natural completion → `setListPolling` can wedge. Fix: TaskHandle clears itself, or gate on `isCancelled`.
- M27 `CodingSessionStore.swift:38-43`, `CodingStore.swift:35-39` — `nonisolated(unsafe)` task vars; use TaskHandle.
- M28 `WebViewPage.swift:139-150` — Coordinator holds stale struct; KVO writes bindings off-actor. Refresh in `updateUIView`; `MainActor.assumeIsolated`.
- M29 `Coding/TerminalBuffer.swift:220` — O(n) `removeFirst` loop. Single `removeFirst(k)`.
- M30 `Core/JarvisAPI.swift:300` — `URLComponents(url:)!` on paired base URL. Guard + throw.
- M31 `Chat/ChatPage.swift:186` — `DispatchQueue.main.async { proxy.scrollTo }`. Use Task @MainActor / `.defaultScrollAnchor(.bottom)`.
- M32 `Skills/SkillText.swift:29`, `Coding/CodingChatModels.swift:161,163` — `try! NSRegularExpression`.
- M33 `Voice/SpeechServices.swift:80` — `MainActor.assumeIsolated` in SFSpeech handler; set `recognizer.queue = .main` explicitly.
- M34 `Chat/ChatAPI.swift:28-42` — `streamingStartSupported` static never reset on re-pair. Clear in PairStore.
- M35 `Skills/ShortcutRunner.swift:38-46` — timeout Task armed before continuation installed. Install waiter first.
- M36 `CodingSessionStore.swift:253` — `try? Task.sleep` swallows cancellation before sending `\r`.
- M37 `Voice/VoiceStoreTransport.swift:249` — audio-only segment frame tags previous segment. Tag only when `append` returned one.
- M38 `Shell/RootView.swift:12` — `@StateObject` on singleton; use `@ObservedObject`.
- M39 `Core/JarvisAPI.swift:92-100` — `APIError.message(status:)` ignores status (cosmetic).
- M40 `CodingStore.swift:279`, `Services/LiveActivityCoordinator.swift:101,111,123,227` — fire-and-forget kickers (informational).
