# Test-coverage analysis (2026-09-05). Paths relative to `JarvisWearables/` (tests: `JarvisWearablesTests/`).

Summary: 1703 tests / 110 files vs 358 Flutter cases; reducers cover every SSE event; 25 hosting-only tests.
Flutter files with no Swift port: `test/background_keepalive_test.dart` (8), `test/services/async_view_test.dart` (4); watch_sync is out of scope.

## Bug found by the analysis (fix + test)
1. `Copilot/Voice/WakeWord.swift:213,220` — `onWake` sets `suppressed = true` and nothing ever clears it; `WakeService.suppress()/resume()` have no callers (`Shell/AppServices.swift:28` `WakeControlling` lacks them). Wake word dies after one hit. Add `WakeWordTests` (fake audio input / recognizer / `FakeVoiceClock` from `Voice/VoiceMocks.swift`), then wire suppress/resume around voice turns in AppServices.

## Tests to add (priority order)
2. `VoiceLocalLaneTests` + `OnDeviceChatBridgeTests`: `requiresConfirm && confirmLocalActions` escalates ("requires-confirm"), fires when confirm off (`VoiceLocalLane.swift:81`, `OnDeviceChatBridge.swift:57`).
3. `VoiceLocalLaneTests`: `.clientDispatchable` → "not-device-local" in voice, `.answered` in chat (`VoiceLocalLane.swift:83`); `commandShortCircuit == false` skips grammar (`:68`).
4. `VoiceStoreTests`: quality-lane `segment kind:tool` (toolStatus) and `type:error` frames (`VoiceStoreTransport.swift:233`); `postQualityTurn` failures (`ensureSession` throws; stream throws mid-body) land in `.error` not stuck `.thinking` (`:201`).
5. `WakeWordListenerTests`: restart loop after `isDone` with `restartDelayMs`, no replace while running (`WakeWord.swift:121`), case-insensitive match, `stop()` clears `onFrame`.
6. `BackgroundKeepaliveTests`: port the 8 Dart arming cases against `BackgroundKeepalive.swift` + `BridgeClient.syncKeepalive()` (armed only when enabled ∧ paired ∧ backgrounded ∧ voice-inactive; platform call only on state change).
7. `LocalConnectionNotifierTests`: opposite banner cancelled first (`Services/LocalConnectionNotifier.swift:30`), identifiers `jc.connection.down/up`; `BridgeConnectionFeed` edge-triggered.
8. `SkillArgsTests` for `Skills/SkillText.swift`: `text(true)=="true"`, `number("5")==nil`, `intList` maps bad → 0, `titleCase`.
9. `ChatStoreTests`/`CodingStoreTests`: `setListPolling` arms once, skips while streaming, cancels (`ChatStore.swift:173-175`).
10. `VoiceStoreTransportTests`: `speakLocally` enqueues all clips atomically in order, empty-stripped chunk keeps tags aligned (`VoiceStoreTransport.swift:276-308`); `acknowledgeLocally` falls back when synthesizer returns false (`:339`).
11. `VoicePagePresentationTests`: `voiceActiveSegment` boundaries (`VoicePagePresentation.swift:37`), `voiceTabIndex == AppTab.allCases.firstIndex(of: .voice)`, exhaustive caption/colour.
12. `AsyncLoadTests`: port the 4 Dart cases against `UI/AsyncView.swift:59` — or delete `AsyncView.swift` (currently unused).
13. `JarvisAPITests`: mid-stream throw after events surfaces as error; consumer break cancels the transport task (`Core/JarvisAPI.swift:390-440`).
14. Others: `KanbanStore.runDispatcher`, `IslandDesignsStore.setPriority`/`guarded`, `WorkspacesStore` stale-suggest race (`suggestRequestID`), `LiveActivityCoordinator.setCodingVisible`, `TodosAPI.sessionMessages` bare-`messages`, `JarvisAPI.bytes(absolute:)`, `AppleFMEngine.suffixAfterCommonPrefix`, `AudioSessionController` interruption decode, `JarvisMemoryStore.loadHeader` partial failure.

## Weak tests to strengthen
- `MoreUIB/*UITests.swift` `testErrorPageRenders` family (Devices:78, Insights:183, IslandDesigns:43, Photon:37, Profiles:39, SelfImprovement:39, ServerLogs:66, Workspaces:42) + `PhotonUITests:45`, `MoreUIA/MoreUIAHostingTests:76,260,320`: add `XCTAssertEqual(store.error…)`/state assertions before hosting.
- `More/PhotonTests.swift:110`, `Coding/CodingSessionsAPITests.swift:264`: no reachable assertion.
- Locale-fragile: `More/CronsTests.swift:138`, `More/MemoryTests.swift:52` (12-hour/en_US regex) — pin a locale/calendar.
- Real sleeps: `Skills/InvokeRunnerTests.swift:111`, `Skills/ShortcutRunnerTests.swift:105` → use deadline polling (`Services/ServicesTestSupport.swift:205`).
