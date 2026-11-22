# Task: Meta Ray-Ban Gen 2 → Jarvis (protocol route)

Started 2026-11-21. Plan: docs/glasses/2026-11-21-meta-glasses-protocol-plan.md. Research: docs/glasses/2026-11-21-meta-ray-ban-gen2-research.md. Approach picked by Pranav: the glasses' own Bluetooth protocol (Jarvis owns the glasses), not Meta's DAT SDK.

## Done
- [x] Research (3 Opus agents) + plan doc (2 Opus agents) written.
- [x] **Phase 0 transport proof on his Mac.** Cloned cipher982/ray-ban-meta-custom-agents (MIT), `swift build` clean in ~8s (Xcode 27.2, Swift 6.4.2). `glasses-cli simulate` runs AirShield handshake + svc36 provisioning (MockPairingBackend, fully offline — no Meta, no credentials) + trust + link setup against the SimulatedOrca. Passes.
- [x] **Full simulate loop against a Jarvis-side relay server.** Built a minimal Python WS server implementing `/v1/glasses/realtime`; the simulated wearer says "Hey Meta, what time is it?", the server answers "Hello, this is Jarvis." (macOS `say`, 16 kHz PCM16), turn closes, **Protocol violations: none / Simulation passed.**

## The relay WS contract (authoritative, from cipher982 server/realtime.ts + VoiceServerClient.swift)
Relay→server: text `{"type":"turn.start"|"turn.commit"|"turn.cancel"|"turn.resume"|"turn.close"|"turn.check","interactionId":X}`, `{"type":"proactive.result","replyId":X,"played":bool}`, binary 16 kHz mono PCM16 mic audio. Auth: `Authorization: Bearer <token>` (only if set).
Server→relay: `{"type":"ready"}`, `{"type":"reply.start","replyId":X,"kind":"turn"|"proactive","interactionId":X}`, binary 16 kHz PCM16 reply audio, `{"type":"reply.done","replyId","kind","interactionId","text","nothingSaid","firstAudioMs"}`, `{"type":"reply.error",...}`, `{"type":"turn.verdict","interactionId","complete":bool,"probability":num}` (answers turn.check).

## Artifacts (scratchpad — move into tree when stable)
- Sim repo: .../scratchpad/glasses-sim-<ts>/ray-ban-meta-custom-agents (built, runnable).
- Jarvis relay prototype: .../scratchpad/jarvis-relay/jarvis_glasses_relay.py (canned reply, port arg). Needs venv (websockets 15.0.1). Run on a free port (8787 is taken by his running Jarvis).

## Done (cont.)
- [x] **Relay wired to Jarvis's real brain (standalone bridge, Opus agent, verified 2026-11-21).** scratchpad/jarvis-relay/jarvis_glasses_bridge.py: STT (faster_whisper base.en, fed numpy) → brain (agent.auxiliary_client.call_llm; claude-code/haiku on this box as it has no API keys) → TTS (macOS `say` → 16 kHz PCM16). Simulated wearer "What is seven times eight?" → Jarvis "7 times 8 is 56." → Simulation passed, Protocol violations none. ~3.2 s end-of-speech→first-audio (brain ~2.7 s dominates). Run: .venv/bin/python scratchpad/jarvis-relay/jarvis_glasses_bridge.py <port>; then simulate --server http://127.0.0.1:<port>. Env: JARVIS_RELAY_PROVIDER/MODEL/TTS.


## Done (cont. 2) — iOS scaffolding (Opus 4.8 agent, 2026-11-21)
- [x] **MetaGlassesDevice module scaffolded, runtime-inert, iOS app builds green (arm64, independently re-verified: BUILD SUCCEEDED).**
  - New: ios_app/JarvisCopilot/MetaGlasses/{MetaGlassesDevice.swift (WearableDevice conformance, .shared, empty capabilities + unavailableCapabilities greyed 'not implemented', invoke throws, isConnected=false), MetaGlassesTransport.swift (CoreBluetooth skeleton: svc 0xFD5F, PSM char 05acbe9f-…91c0 / PSM 128, company 0x01AB, retrievePeripherals/openL2CAPChannel TODOs — NO crypto/creds, central created lazily in unused start()), Features/MetaWakeChannel.swift (wake placeholder)}.
  - WearableKind.swift: added case metaGlasses (keepAliveName "Meta glasses", symbol eyeglasses, registryModel nil). All exhaustive WearableKind switches live in that file and were handled; grep confirmed no others.
  - project.pbxproj: 3 files added to the JarvisCopilot app target (plutil -lint ok).
  - NOT wired into WearablesHub install / DeviceRegistry / UI — inert. Not installed, not registered.
- Flags: (1) one new Swift-6-mode warning identical to InmoGo3Device's existing `.shared` default-arg pattern (benign in Swift 5 mode). (2) non-nil keepAliveName makes 'metaGlasses' appear in the wearables_keep_alive enum + ring action catalogue (plan §6.1 intends this); setKeepAlive is a no-op with no device installed. Pre-existing: the generic 'iOS Simulator' (x86_64) build fails on FreeRDP xcframework missing an x86_64 sim slice — unrelated to this work; arm64 (phones + Xcode) is green.
- Uncommitted (pbxproj, WearableKind.swift, MetaGlasses/). STT fix already committed (eff28f8b3f).


## Done (cont. 3) — iOS device logic + in-memory simulator + XCTest (Opus 4.8 agent, 2026-11-22)
- [x] **Full iOS MetaGlasses device/session/turn logic + software-glasses simulator; 4 XCTest tests PASS (independently verified via xcresult: result Passed, 4/0, iPhone 17 Pro iOS 26.5 arm64). App builds green (arm64).**
  - New: MetaGlasses/{GlassesTransport.swift (protocol + value types GlassesLinkState/GlassesInboundEvent/GlassesFrame/MetaTouch*; MetaGlassesError), MetaVoiceTurn.swift (MetaVoiceTurnController seam + VoiceStoreTurnController adapter → VoiceStore.useExternalInput/beginExternalTurn + MetaGlassesAudioInput glasses-only PCM), MetaGlassesSession.swift (connecting→connected→trusted(sim)→ready; wake→turn loop; photo req/await; touch→action; generation guard), SimulatedGlassesTransport.swift (#if DEBUG in-memory simulator: scriptWake/SpokenPrompt/CannedReply/Touch/LinkState, auto synthetic JPEG on capture, records sentFrames)}.
  - Changed: MetaGlassesTransport.swift (now conforms to GlassesTransport as skeleton; connect/send throw 'not implemented (hardware-gated)'); MetaGlassesDevice.swift (holds transport+session; caps meta_glasses_status/look/photo; photo {base64,mime:image/jpeg,bytes,question} behind confirm=true); Features/MetaWakeChannel.swift (installer modeled on InmoAIChannel); project.pbxproj (+48 lines, 4 src into app target, 1 test into JarvisCopilotTests/Glasses).
  - Tests: JarvisCopilotTests/Glasses/MetaGlassesSimulatorTests.swift — testStartBringsLinkThroughTrustToReady, testFullWakeTurnReplyCloseCycle, testPhotoCapabilityReturnsBase64AndMime, testTouchGesturesMapToActions. FakeVoiceTurnController stands in for VoiceStore.
  - Still runtime-inert: no refs to MetaGlassesDevice/metaGlasses outside MetaGlasses/ dir; not in WearablesHub/DeviceRegistry/UI. Simulator is #if DEBUG only.
  - Uncommitted (pbxproj, MetaGlasses/, WearableKind.swift from earlier scaffold, test file).

## Hardware-gated remainder (needs the physical Gen 2 — no simulator can prove these)
- Real CoreBluetooth L2CAP bring-up + AirShield P-256/HKDF/AES handshake + owner trust (§5.1/§5.2) — skeleton in MetaGlassesTransport.connect()/send().
- One-time change-owner / Meta-login prerequisite (§5.3) — user-performed, never automated.
- Custom wake-word enrolment + Gen-2 Thrift assistant path (§5.4) — seam ready (MetaWakeChannel/VoiceStoreTurnController).
- Wi-Fi media handoff / live video / Opus follow-up decode (§5.5/§6.6).

## Follow-ups
- [ ] **Jarvis bug found:** tools/transcription_tools.py transcribe_audio() dies in .venv with `av.open() got unexpected keyword 'metadata_errors'` (PyAV vs faster-whisper mismatch). Bridge sidesteps it with numpy input, but this breaks Jarvis's local STT elsewhere — pin/upgrade `av`.
- [ ] Move the bridge from scratchpad into the Jarvis tree (webui route or gateway process) once the design is settled; wire it to his real voice-lane provider/model config.

## Next
- [ ] Gen-2-specific unknown (REAL BLOCKER, needs the physical glasses): cipher982 is proven only on the audio-only "orca" model; Gen 2 is a camera model with a different (Thrift svc15) assistant path documented only in Visor (AGPL). Simulator can't prove this.
- [ ] iOS side: MetaGlassesDevice (WearableKind.metaGlasses), CoreBluetooth L2CAP transport, wake→VoiceStore, photo→vision, touch→RingActionRunner, Power integration — per plan §6. Hard to test without glasses; can unit-test logic against a mock transport.
- [ ] Ownership/change-owner: user-performed one-time step (Meta login + receipts); Jarvis won't extract/embed tokens. Only needed on real hardware.
