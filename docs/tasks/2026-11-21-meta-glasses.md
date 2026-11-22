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

## Full glasses simulator (2026-11-22). Design v2: docs/superpowers/specs/2026-11-22-meta-glasses-sim-design.md
His asks: a full simulator he uses until the glasses arrive. Jarvis drives it like the real glasses ("Hey Jarvis, what am I looking at" → sim camera → vision). It simulates touch, audio, video and live, enforces the real Gen 2 limits, puts a 3D model on Wearables, and has a Device | Sim toggle (the Device screen is built now for the hardware). His picks: a real Jarvis voice turn, prompt as spoken audio, the iPhone camera as the glasses camera (test scenes as fallback).
1. [x] Relay logs each turn's heard/said. ✅ 8 relay tests pass
2. [x] `scripts/glasses-sim.sh`: one Mac command. ✅ Verified on his Mac: "What is 7 times 8?" → "7 times 8 is 56." (3.0 s), PASS. Found: no Jarvis model configured on the Mac → the script now says so and uses local Claude Code (haiku); relay failures are now reported instead of a silent "something went wrong"
3. [x] v1 voice pieces (voice→glasses relay, session watch, prompt voice, runner) green in XCTest. ✅ 17 tests pass; committed d075a60d2e
4. [x] Gen 2 hardware profile + battery/heat/storage model (real limits). ✅ 8 limit tests pass (streaming 1.2–2 %/min, case 50 % in 20 min, 3K overheats ~15 min and cools in 3–5 min, storage full, clip cap, refusal order)
5. [x] Simulator engine: enforces limits, answers every command, command feed. ✅ 8 simulator tests (each limit refuses with the glasses' reason, LED cover / cap stop a recording, touch defaults, wake needs worn, range drop + return, Wi-Fi import)
6. [x] 7 Jarvis tools + Device/Sim registration. ✅ 7 tool tests (fixed catalogue, photo vision copy + LED refusal, video capped, look returns the live frame, status, speak/volume vs folded, hold → Jarvis turn)
7. [x] iPhone camera as the glasses camera (ultra-wide, 3024×4032 portrait, clips, live frames) + test-scene fallback + hold-to-talk
8. [x] Page: Device | Sim toggle, controls, glasses state, sim speed/overrides, feed, live view, storage, capture settings, touch → Jarvis, limits
9. [x] Drop 1 to his phone. ✅ release.sh build 263260740 (commit 94118210d0) published 2026-11-22 07:46 UTC
10. [x] Touchpad buttons opened iOS Shortcuts (his screenshot: Tap / Double tap / Triple tap → "◀ Shortcuts"). Found: the sim's media defaults called the phone's real media_control, which runs JC Shortcuts on iOS 27. Fix: the sim drives its own simulated music (play/pause, track N) and nothing leaves the sim; the refined transcript no longer shows "Heard" twice. ✅ Shipped in build 263260753 (8117642c6b)
    - Also seen in his run: "That model's usage limit is reached" was his voice model's quota, not the glasses (wake → mic → heard → speaking → closed all worked)
11. [x] Hold to talk showed "Meta glasses transport unavailable: the recorder refused to start" while the typed prompt worked (his screenshot). Found: the press gesture fires on every finger movement, so the mic recorder was started several times; the second start failed while the first held the mic. Fix: one start per press, early-release handling, 16 kHz → 44.1 kHz fallback converted on read (+ conversion test). ✅ Shipped in build 263260753
12. [x] 3D Ray-Ban Meta model on the card + page (helper agent; measured from Ray-Ban's RW7002 catalogue renders)
    - His add (2026-11-22): "pans and zooms into the element and shows an indicator there when that part of the glasses is being simulated… hold to talk… pulsing blue… speaking → speakers… photo, button clicks". Plan: camera glides (0.8 s ease) to the part plus a pulsing marker. Listening = mics, blue breathing; speaking/volume = speakers, blue ripples; photo = white flash at the lens; video/live = steady white at the lens; touch/button = ripple; back to the turntable after ~1.5 s idle. Sim side done (MetaGlassesFocus + simulator focus state + test). ✅ Model done by the helper agent: outline matches Ray-Ban's RW7002 Shiny Black catalogue shots within ~1 mm front / 0.5 mm side; glide 0.8 s + markers; 13 render tests
13. [x] "Hey Jarvis" wake word, for the real glasses + sim (his ask). Shared enrolment flow (3 samples, US English) → GlassesFrame.enrolWakeWord → sim builds/remembers it; real glasses: same flow, the on-glasses enrolment message waits for the hardware. Sim: "Listen for Hey Jarvis" switch, on-device recognition while the Sim screen is open, words after the phrase go to Jarvis. ✅ 44 tests; shipped in build 263260801 (6988ee4155). To verify on his phone: enrol, then say it hands-free
14. [x] His add: "make the textures and resolution of the glasses a little bit better so that it looks like the scriber one that I got" — his pair is **Shiny Black** with clear lenses. Sent to the helper agent: physically based glossy acetate with a clear-coat sheen, studio environment light + rim light, metal hinges/button/rings, clear lenses with reflections, smoother geometry, 4× MSAA, colourway in one place. ✅ Done (MetaGlassesModel.colourway = .shinyBlack)
15. [x] Drop 3 (3D model + materials + focus animations). ✅ build 263260829 (d870531bc5), 57 tests

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

16. [x] His asks (2026-11-22): "The touch controls card needs to be on the top right below the glasses model", "add vibrations and haptic feedback when I tap or touch and hold", "when I import photos or videos taken on glasses sim to the phone, it doesn't save it to my gallery".
    - Found: Import only moved items into the in-app list; it never touched the Photos library.
    - Fix: touchpad card moved right under the 3D model; MetaGlassesHaptics (taps at the glasses' rhythm, swipe ticks, shutter, a firm thump when a hold registers; Touch-and-hold and Hold-video tiles now need a real 0.5 s hold); hold to talk ticks on open/close; Import saves to Photos (add-only), tiles show it, the feed says "N of M saved to Photos" with the reason for any miss; clips are moved out of tmp. ✅ 58 tests; shipped in build 263261701 (1673674dbd)
17. [x] His report: "Did u implement support for wake word? I don't see it working".
    - Found (his phone, devicectl prefs pull): build 263261701 installed; no meta.sim.wakePhrase / listenWake, so it was never set up. He then found the setup button himself.
    - His follow-up: "When wake word gets activated, there needs to be a chime so I know it got activated". Fix: on detection, play his chosen Jarvis "listening" chime (VoiceEarconSounds, nothing synthesized) through the speaker (recording plan has .defaultToSpeaker), plus a haptic tap, and the 3D model glides to the mics right away. ✅ Shipped in build 263261756 (d1eefbead6)
    - His question about battery: real glasses = the glasses' own wake detector (same path as "Hey Meta"), so roughly the same battery and no phone listening. The sim uses the phone mic + on-device recognition, but only while the Sim screen is open.
18. [x] His asks: "I need to hear the done chime as well once it stops listening", "support for tying the ring into this just like the inmo's", "the haptics don't work anymore, did u remove that? Add it back".
    - Haptics, found (his prefs: listenWake = true): with "Listen for Hey Jarvis" on, the sim holds the mic, and iOS mutes app haptics while recording. Fix: setAllowHapticsAndSystemSoundsDuringRecording(true) while the sim holds the mic (listener, hold to talk, assistant), back to false after.
    - Done chime: his Jarvis "done" earcon when listening ends (after the wake-word question, on hold-to-talk release, when the assistant stops listening); the listening chime on hold-to-talk press.
    - Ring: like the INMO, through the ring action picker: a "Meta glasses" section with the glasses icon and clean names (Talk, Photo, Video…), plus a new "Talk" tool that opens the glasses' assistant. Sim: chime → phone mic as the glasses mic until quiet → done chime → Jarvis. The Touch-and-hold tile now does the same (it used to start a turn with no audio).
    - ✅ 63 tests; shipped in build 263261808 (a482fb0b15)
19. [x] His ask: "make sure that Jarvis picks up all the tools exposed by the glasses and have a skill for meta glasses control… it shouldn't see a difference between the real glasses or the sim… it should be able to do everything on the glasses".
    - Found (server .devices.json on jc-hermes): the iPhone device already advertises the 7 meta_glasses_* tools, so Jarvis picks them up through the wearables route.
    - Done: the status has no "simulated" flag and the sim registers as plain "Ray-Ban Meta (Gen 2)", so Jarvis can't tell them apart. New tools meta_glasses_media (list / latest_photo / import) and meta_glasses_settings (clip length, video mode), 10 in total, with the same transport API for the real glasses (hardware-gated defaults). Skill skills/smart-home/jarvis-meta-glasses (SKILL.md + scripts/meta_glasses.py + 9 tests).
    - ✅ Shipped in build 263261817 (10f0b5093f). The skill is installed on jc-hermes (~/.jarviscopilot/skills/smart-home/jarvis-meta-glasses; skills_list finds it); the server code wasn't touched or restarted.
20. [x] His report: "I don't hear the stop chime when it stops listening still" (on 263261808).
    - Found: in all three paths the done chime started at the exact moment the sim released the mic; releasing switches/deactivates the audio session, which stops the player mid-sound. Fix: play it while the mic is still held, wait its length (ToneEarconPlayer returns it), then release. Red test first (the capture's beforeRelease hook), now green. ✅ build 263261825 (77135df096)
21. [x] His ask: "a toggle video setting since there's only video on, no video stop on the same action… on ring I can only set either video on or off, so have a toggle menu". Fix: meta_glasses_video gets an action menu (record / start / stop / toggle); one ring binding with toggle starts, then stops. Skill + script updated. ✅ build 263261825
22. [x] His report: "Getting issue with mic in use when I activate Jarvis through ring, it doesn't work. And the chimes get cut off after playing for a few ms".
    - Found: (a) from the background iOS refuses any audio-session switch; his keepalive is plain playback (no jc.talkHere.armed in his prefs), so the ring's mic claim was refused and the failed switch cut the chime. (b) With a record-ready keepalive, the glasses turn's own playbackPlan claim would ALSO be refused from the background.
    - Fix: new AudioSessionClient .glassesSim = mixedVoicePlan (the record-ready keepalive's exact plan), outranking .externalVoice; the simulator holds it from the ring press through the end of Jarvis's turn; the keepalive is record-ready while the sim is on (no orange dot until a press). The arbiter truth-table test is extended. Note: build 263261825's archive overlapped these edits, so it's interim. ✅ build 263261835 (6838f83b9b)
23. [x] His ask: "a live video stream as well on phone which emulates what the glasses sends". Fix: full-screen MetaLiveViewer: the iPhone camera held to the glasses' 720×1280 live format (session preset while live), smooth preview, LIVE + time, format, battery/heat, Wi-Fi note, Stop; shows why the stream ended (LED/heat/battery). Opens on Start live; "Watch live" whenever streaming. ✅ build 263261835
24. [ ] His hypothesis: "Maybe the mic issue has something to do with the wake word listening right after the mic stops". Confirmed, three windows: the hold-to-talk chime handoff (~0.35 s with nothing "busy"), Jarvis thinking after a ring press (the listener restarted mid-turn), and the background (going to the background isn't "leaving the screen", so the listener could keep the mic with the phone locked). Fix: one pure gate MetaSimWakeListener.shouldListen (on screen + app active + not pressing/handing off/capturing/assistant busy/turn running/Jarvis speaking) plus simulator.assistantBusy. Unit-tested per window.

## Shipped (2026-11-22)
- build 263260740 (94118210d0): full Gen 2 simulator, 7 meta_glasses_* tools, Device | Sim page
- build 263260753 (8117642c6b): touchpad stays in the sim; hold to talk fixed; one Heard row
- build 263260801 (6988ee4155): "Hey Jarvis" enrolment (glasses + sim) + hands-free listening in the sim
- build 263260829 (d870531bc5): 3D Shiny Black Scriber model + focus animations
- build 263261701 (1673674dbd): touchpad under the model, haptics, imports saved to Photos
- build 263261756 (d1eefbead6): chime + haptic when "Hey Jarvis" is heard
- build 263261808 (a482fb0b15): done chime, ring Talk via the action picker, haptics while the sim records
- Mac: scripts/glasses-sim.sh (d075a60d2e)

## For you
- Update the app, then Devices → Wearables → Meta glasses → Sim
- Try "Hey Jarvis, what am I looking at?" (hold to talk, or set up the wake word and just say it)
- Your voice model hit its usage limit in your first run: switch the voice model if answers say so
- When the glasses arrive: the Device tab is where the real link, ownership and on-glasses wake enrolment get finished
