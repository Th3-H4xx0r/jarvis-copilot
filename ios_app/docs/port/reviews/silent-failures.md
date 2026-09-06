# Silent-failure review (2026-09-05, read-only pass over Copilot/ + JarvisWidget/)

Paths are relative to `JarvisWearables/` unless they start with `JarvisWidget/`.

## HIGH
- H1 `Copilot/Voice/VoiceStore.swift:187` — `session.onClose = { _ in … raise(.stopRequested) }` drops the error; a dropped socket looks like the user pressed Stop. Fix: `{ error in if let error { raise(.failed(apiErrorMessage(error))) } else { raise(.stopRequested) } }`.
- H2 `Copilot/Voice/VoiceSession.swift:224,226` (`task.send(...) { _ in }`) and `:149,:151` (`socket?.send` when nil) — send failures vanish; turn hangs in "thinking". Fix: route completion errors into `onClose?(error)`; make `send` return Bool / raise `.failed` when socket is nil.
- H3 `Copilot/Chat/ChatAttachments.swift:70` (used by `ChatStore.swift:320`) — failed uploads `continue`; message sends without the attachment and `attachError` never set. Fix: return `(uploads, failed: Int)` and set `attachError` when failed > 0 (mirror `CodingAttachments.swift:63` + `CodingChatComposer.swift:118`).
- H4 `Copilot/Coding/CodingSessionStore.swift:370-372` — terminal stream `catch` leaves `terminalAttached=true`, no reattach, no `terminalError`; terminal frozen until app restart. Fix: mirror the `.closed` branch (`:347-360`): notice into buffer, `terminalError = apiErrorMessage(error)`, clear `terminalAttached/terminalTask`, `scheduleReattach()`.
- H5 whole tree — no `os.Logger` anywhere (133 `try?`, 139 catch). Fix: add `Copilot/Core/JcLog.swift` (`os.Logger`, subsystem `com.jarvis.JarvisWearables`, category per area) and make `apiErrorMessage(_:)` log at `.error`; use it in every `try?` on a network call.
- H6 `Copilot/Chat/ChatStore.swift:298-305` — `pendingClarify = nil` before the POST; `try?` on `respondClarify`. Fix: clear only after success; on failure restore the prompt and set `error`.
- H7 `Copilot/More/Memory/MemoryStore.swift:54-66` + `MemoryPage.swift:47,246-254` — save failure sets `errorMessage` that the editor never shows. Fix: surface the message inside `MemoryEditorView` (or toast).
- H8 `Copilot/Skills/InvokeRunner.swift:86-92` — `Task { try? await notifier.post(...) }` then returns `queued: true`. Fix: await the post inside `run`; return `.err("notifications are off — enable them to run this")` when it throws.
- H9 `Copilot/Services/NotificationActions.swift:137` — `try? await coding.submitPermissionVerdict(...)`. Fix: on failure post a follow-up local notification ("Couldn't send your decision — open the app") and keep the request pending.

## MEDIUM
- M1 `Copilot/Services/PushHandler.swift:119` — notification authorization result discarded. Store granted flag, expose on SettingsStore, show "Notifications are off" row.
- M2 `PushHandler.swift:156` — `/api/devices/mobile/token` failure silent until next launch. Retry with backoff; record last status.
- M3 13 pages render `errorMessage` only when the collection is empty (`Memory/MemoryPage.swift:47`, `Todos/TodosPage.swift:39`, `Workspaces/WorkspacesPage.swift:57`, `Kanban/KanbanPage.swift:106`, `CodeMemory/CodeMemoryPage.swift:33`, `CodeMemory/CodeMemoryEntriesView.swift:117`, `Profiles/ProfilesPage.swift:46`, `Crons/TasksPage.swift:52`, `ServerLogs/ServerLogsPage.swift:47`, `Insights/InsightsPage.swift:42`, `SelfImprovement/SelfImprovementPage.swift:34`, `Devices/DevicesPage.swift:102`, `Coding/Views/CodingFleetList.swift:25`). Pull-to-refresh failures are invisible. Fix: one shared modifier that shows a non-blocking banner/toast when `hasLoaded && !isEmpty`.
- M4 `Copilot/Coding/CodingStore.swift:344` — pending-permission poll swallows all failures. Count consecutive failures, set `error` after 2–3.
- M5 `Copilot/Core/JarvisAPI.swift:424` — non-JSON 2xx body becomes `[:]`, then ChatAPI treats "no stream_id" as retryable → turn re-posted. Fix: finish throwing `APIError.badResponse("start returned <ctype>, not JSON")`.
- M6 `JarvisAPI.swift:134-145` — `array()` picks an arbitrary array from a dict (iteration order unspecified). Fix: `array(key:)` or fixed key order; throw otherwise. Caller: `Voice/VoiceStoreTransport.swift:401`.
- M7 `JarvisAPI.swift:452-455` — NDJSON malformed lines skipped silently (carries push-to-talk voice). Count skips; finish with `.badResponse` when zero valid objects.
- M8 `Copilot/Skills/SkillRegistry.swift:98-105` — corrupt `skills_disabled` fails OPEN (every skill enabled). Keep previous set / fail closed; don't let `persist()` overwrite.
- M9 `Copilot/Skills/SkillBoundariesData.swift:116,151`, `SkillBoundariesMedia.swift:24` — `(try? await …) ?? false` turns errors into "denied". Propagate the error text.
- M10 `Copilot/Chat/ChatStore.swift:430` — cancel failure ignored. Set `error = "Stopped locally — the server may still be running this turn."`.
- M11 `ChatStore.swift:499` — `models = try? …` → blank picker. Keep last good catalog; set `error` when nil.
- M12 `Copilot/Coding/CodingSessionStore.swift:403-405` (`catch { return false }`, no terminalError) and `Coding/Views/CodingChatComposer.swift:99` (slash-command result discarded). Set `terminalError`; route slash-command result through `warning`.
- M13 `try? … ?? []` on required-looking data: `CodingStore.swift:176,126`, `More/Devices/DevicesStore.swift:74`, `CodingSessionsAPI.swift:73`, `More/Workspaces/WorkspacesStore.swift:159`, `More/JarvisMemory/JarvisMemoryStore.swift:81`, `More/CodeMemory/CodeMemoryStore.swift:41`. Add "couldn't load" affordance or at least log.
- M14 `CodingSessionStore.swift:414,429` — terminal resize/close fire-and-forget; failed close leaks PTY → next attach 409s. Retry close once; set `terminalError` on repeat.
- M15 `Copilot/Voice/VoiceAPI.swift:115-118` — `synthesizeOrEmpty` hides partial TTS failures. Set soft status "voice unavailable — showing text" when some clips are empty.
- M16 `Copilot/Services/AppGroupIslandDesignCache.swift:46,113,105-113` — App Group writes and image prefetch ignore errors/HTTP status. Use `try` + log; check status code.
- M17 `JarvisWidget/JarvisDesignModel.swift:40-41,86-92,110-114,143-160` — `schema` decoded but never validated. `guard schema <= supportedSchema else { return nil }` in `JCDesignCache.load`.
- M18 `Copilot/Services/LiveActivityController.swift:56-59` — second `Activity.request` failure swallowed. Log; expose `lastActivityError`.
- M19 `Copilot/Services/BackgroundLocation.swift:147`, `Services/LocalConnectionNotifier.swift:32` — silent posts. Log both; propagate notifier permission failure to Settings once.
- M20 `ChatStore.swift:141-151,173-184` — quiet session polling never escalates. Set `error` after N consecutive failures.
- M21 `Copilot/More/Insights/InsightsAPI.swift:24-32,44-46,54` — health/messages/activeSession failures collapse to empty. Give `SystemHealth` a `failed` flag; render "Unavailable" like `wikiStatus` (`:31-37`).

## LOW
- L1 `Copilot/More/Kanban/KanbanStore.swift:38,147` — `isPolling` set but no view reads it. Render "updates delayed" pill or drop.
- L2 `Copilot/UI/AsyncView.swift:74-77` — refresh failure with stale value shows nothing. Fix in `AsyncLoad`.
- L3 `CodingStore.swift:218-228,377-387` — any 5xx treated as transient forever. Surface after N.
- L4 `JarvisAPI.swift:125-132` — `object()` returns `[:]` for empty body (truncation reads as "nothing").
- L5 `Copilot/Chat/Views/AttachPicker.swift:132-133` — temp write/cleanup failures silent.
- L6 `SkillRegistry.swift:87-95` — `generation` bumps even when the write failed.
- L7 `ChatStore.swift:164` — `try? sessionsAPI.get(id)` on focus; log.
- L8 `VoiceStore.swift:196,299,501` — `try? audioSession.setActive`; playback may never resume after a call.
- L9 `CodingStore.swift:256-260` — "Sync now" failure invisible.

Start with H1+H2, H4, H3, H5.
