# Plan: Jarvis ↔ Ray-Ban Meta Gen 2 over the glasses' own Bluetooth protocol

*2026-11-21. Planning document only — nothing here is built yet. Approach chosen by Pranav: the glasses' own protocol (Jarvis becomes owner), not Meta's SDK.*
*Companion research: [2026-11-21-meta-ray-ban-gen2-research.md](./2026-11-21-meta-ray-ban-gen2-research.md). Device owned by the user; this is personal-device interop for his own glasses.*

---

## 1. Intent and why

Pranav is getting Ray-Ban Meta Scriber Optics (Gen 2) and wants it to be a first-class Jarvis peripheral: take photos, start/stop video, stream video and photos to the iOS app, receive his voice, a **custom on-glasses wake word ("Hey Jarvis") — the top priority**, handle and remap touch controls, and play music. Meta's official SDK cannot do the custom wake word and cannot start Jarvis from the glasses. The glasses' own protocol can, because the detector runs in the glasses' firmware. The cost is that Jarvis must become the glasses' owner, which disconnects the Meta AI app and steps outside Meta's terms. He accepts that for a personal build.

This mirrors what he already did with the INMO GO3 (see [[inmo-go3-glasses]]): captured the vendor app's own traffic on his own device, then built a Jarvis-side client to the same wire protocol.

## 2. Goals / non-goals / anti-goals

**Goals**
- On-glasses "Hey Jarvis" enrolled on the device, answered by Jarvis.
- Photo on command; start/stop native video; import to the iOS app; live view.
- His voice into a Jarvis turn (transcript from the glasses, raw audio on follow-ups).
- Every touch event readable; map gestures to Jarvis actions.
- Music playback through the glasses (unchanged A2DP).
- One "glasses connected" truth, like the INMO one-connected rule.

**Non-goals**
- Shipping to the App Store or to anyone but Pranav. Personal sideload via release.sh.
- Supporting glasses models other than his Gen 2 at first (Audio/Neural Band later).
- Running the Meta AI app side by side. The glasses hold one owner.

**Anti-goals (failure even if it "works")**
- A build that bricks or de-pairs the glasses with no clean path back to the Meta AI app.
- Jarvis's existing INMO / voice / Live pipelines regressing because the new audio route fights the audio session.
- The wake word or camera firing without his intent, or the camera LED being defeated (policy + trust line he set).

## 3. Reference work this builds on (public)

- **Visor** — `github.com/macedonga/visor`, Android, AGPL-3.0, active daily. Full de-Meta'd client + a published protocol spec at visor.macedonga.com/protocol. This is the authority for the wire format. **AGPL: do not copy its source into Jarvis** (license would propagate); use it as a spec, like the INMO jadx work.
- **cipher982/ray-ban-meta-custom-agents** — MIT, Swift, CoreBluetooth. Opens the BLE L2CAP channel and runs the encrypted session on **macOS**; its iPhone app "builds but hasn't been run on a phone." MIT means we *can* reference/adapt its approach. Audio-only model (orca) so far.
- **meta-g-link-direct** — Gen 2 live 720p30 + 48 kHz stereo over the glasses' own Wi-Fi.

The plan is to prove the path on the Mac first (reference code exists), then port the proven pieces to iOS inside Jarvis.

## 4. What the protocol gives us (from the public spec)

- **Link:** BLE advertises company id 0x01AB / service 0xFD5F. An L2CAP channel (PSM **128** on Gen 2, read from characteristic `05acbe9f-…91c0`) carries one encrypted "AirShield" session. The channel comes up even folded in the case (~3 s). CoreBluetooth on iOS can open BLE L2CAP channels, so no MFi/External-Accessory approval is needed (that's only for Classic RFCOMM).
- **Encryption:** P-256 key exchange → HKDF → AES-256-CBC + HMAC tag, plus a per-connection owner-trust signature. Publicly documented; the Mac port implements it.
- **Ownership (the hard dependency):** each pair holds one owner key. A one-time change-owner flow re-points it at the phone. It requires a Meta login and Meta-signed receipts, using the Meta app's own client tokens. **This is the blocker and the ToS break.** After setup, no Meta calls. Reverting = re-pair in the Meta AI app. We treat this as a prerequisite step the user performs on his own account/device, documented by reference to the public Visor flow — not re-implemented blind.
- **Media:** photo/video/live view move to TCP over the glasses' own Wi-Fi (SoftAP or Wi-Fi Direct); the BT session pauses meanwhile.
- **Assistant channel:** the glasses detect the wake word and transcribe on-device, then send text; raw audio on follow-ups. Custom wake word is enrolled by sending 3× 16 kHz samples; the glasses build the model themselves (US English; newer firmware needs a `hatch_enabled` setting).

## 5. Detailed design — transport, session, and Mac-first feasibility

This designs the lowest two layers — the Bluetooth transport and the encrypted owner-trusted session — then gates the whole effort behind one macOS proof. Grounded in the public **Visor protocol docs** (`visor.macedonga.com/protocol/*`) and the **cipher982/ray-ban-meta-custom-agents** MIT Swift port (`docs/PROTOCOL.md`, README). Design only; the crypto key schedule is referenced to those sources, never reproduced. Treat Visor's figures as single-source unless corroborated.

### 5.1 BLE L2CAP transport on iOS (CoreBluetooth)

**KNOWN.** Glasses advertise manufacturer data under company id `0x01AB` (Meta) and GATT service `0xFD5F`. A connection-oriented L2CAP channel on that service carries one encrypted session. The dynamic PSM is read from characteristic `05acbe9f-6f61-4ca9-80bf-c8bbb52991c0`; **on Gen 2 it reads 128 (0x80)** — distinct from the audio-only orca model's 129 (0x81). Gen 2 keeps the LE link up while **folded and charging in the case**, channel up in ~3 s (Visor, single-source) — so Jarvis can hold the link without the glasses being worn.

**iOS design.** `MetaGlasses/` owns a `CBCentralManager`. Bonded glasses stop advertising, so retrieve the known peripheral by identifier (`retrievePeripherals`/`retrieveConnectedPeripherals`) and auto-connect, then discover `0xFD5F`, read the PSM characteristic, and `CBPeripheral.openL2CAPChannel(_:)`. cipher982 confirms this is Apple-sanctioned: same AirShield + DataX multiplexer over a standard BLE L2CAP CoC, so **no MFi / External-Accessory approval is needed** (that's only for Classic RFCOMM). The channel opens without link-layer encryption (AirShield provides confidentiality), so iOS should not force a pairing dialog.

**Framing.** L2CAP preserves message boundaries, but both reference clients read the socket as a byte stream and re-cut SDUs with a shared length rule; sealed frames cap near 4 KB and longer payloads split. The iOS transport needs a stream framer. **UNVERIFIED on iOS:** how CoreBluetooth surfaces bonding (Android uses `createBond` DUAL; iOS triggers bonding only on an encrypted characteristic), and background behaviour of an open `CBL2CAPChannel` across suspension (Phase-5 validation, not an assumption). Registration reuses `WearableKind.metaGlasses` + `WearablesHub` + `DeviceRegistry.syncMembership(identity:"metaGlasses")`. "One session per peer, newest wins" maps onto the INMO one-connected truth.

### 5.2 The AirShield session and per-connection owner trust

**KNOWN — handshake shape.** Link setup runs on **service 5**, once per link, before any sealed traffic, no network calls:
1. Each side sends **RequestEncryption** / **EnableEncryption** carrying an ephemeral P-256 public key, challenge, seed, IV, starting sequence, and a device/firmware **parameters** bitmask.
2. Both compute a P-256 ECDH secret → **separate per-direction** AES-256 + HMAC-SHA-256 keys. *(Derivation is in the public sources; not restated here.)*
3. **Owner trust (service 36):** the phone signs a 32-byte channel-binding digest (hashing the glasses' challenge+key with the phone's seed+key — new every connect) with ECDSA-P256 and presents `SHA-256(owner public key)`. Mismatch → `0x1043 INVALID_APP_IDENTITY`. Glasses push their own trust message; the phone acks — mutual proof.
4. **EndLinkSetup** completes bring-up.

**What each side proves:** the phone proves possession of the owner key against the stored owner hash; per-connection binding defeats replay; the glasses prove liveness. **UNVERIFIED (per Visor):** several trust-field meanings and whether the official app signs the identical value. **Gen-2 parameter set is the risk:** cipher982 tags `7 = 2025 Gen-2`, `27 = orca` and warns *never hard-code one* — so the handshake anticipates Gen 2 but is **tested only on orca**.

### 5.3 The change-owner prerequisite (user-performed, one-time)

The account-risk core. Treated as a **one-time step Pranav performs himself**, by reference to the public **Visor meta-login-and-ownership** flow — not re-derived or automated in Jarvis. In outline: each pair holds one EC P-256 owner key; becoming owner needs a **Meta login** (OIDC) → **two Meta-signed ownership receipts** from `graph.facebook-hardware.com`, exchanged over svc36 change-owner messages, swapping the owner key to the phone's. It **replaces the Meta AI app as owner** (Meta app Bluetooth off); reverting = re-pair in the Meta AI app. Visor's three app tokens are **not shipped** and must come from the official app — **Jarvis will not embed or extract them.** This is the explicit **ToS-breaking, account-risk** boundary, done knowingly on his own device. At runtime Jarvis only consumes the resulting owner key for the §5.2 trust step; it makes no Meta calls.

### 5.4 Mac-first feasibility gate (the hard decision point)

Before any iOS work, prove on **macOS** with cipher982's `glasses-cli` against his own Gen 2:
- **(a) Transport + session:** BLE L2CAP opens on PSM 128, AirShield completes with the Gen-2 parameter set (`7`), owner trust succeeds after the one-time provision.
- **(b) The specific unknown — assistant path divergence.** cipher982 is proven **only on orca** (audio-only, fw v129), whose svc15 assistant **streams raw mic as Opus** — README: *"Other Meta glasses use a different assistant path."* His Gen 2 is a **camera model** that per Visor *assistant-protocol* does the opposite: **on-device speech recognition sending Thrift NetEvents** (`ev57` question → phone answers `ev60`). That Thrift svc15 path is documented by Visor (AGPL Android) but is **NOT in the MIT Swift reference**, so the assistant layer is **net-new Swift work guided only by the Visor spec**.

**Gate:** if (a) fails, stop — transport unreachable. If (a) passes but (b) shows Gen 2's assistant/enrolment path doesn't come up, fall back to the SDK plan rather than starting iOS work on a layer with no proven reference.

### 5.5 Wi-Fi handoff for media — and what it costs the iPhone

**KNOWN.** Bluetooth carries control/trust/assistant/small files; **photos, video, live view move to TCP over Wi-Fi** — a phone-owned Wi-Fi Direct group the glasses join, or a **SoftAP the glasses host** (port 20203). Throughput jumps from ~120–165 KB/s (RFCOMM) to **~10 MB/s** (Visor, single-source). AirShield/trust/EndLinkSetup re-run over TCP, and the **Bluetooth session pauses** for the duration. Live view wants **2.4 GHz**; Visor reports a firmware hang on 5 GHz/80 MHz (single-source).

**iPhone cost (design-critical).** Joining the glasses' Wi-Fi **takes the iPhone off home Wi-Fi** → Jarvis-server traffic over cellular during transfers (same as the SDK path). The viewer must tolerate that and the bursty ~190 ms-buffered delivery. iOS needs entitlements the app lacks: **Hotspot Configuration** (`NEHotspotConfiguration`) + local-network/Bonjour keys. **UNVERIFIED on iOS:** whether `NEHotspotConfiguration` can join the no-internet network without a prompt each time, and the group-owner address.

## 6. Detailed design — Jarvis iOS + server integration and phasing

Grounds §5 in the real Jarvis surfaces. Nothing re-derives the protocol or ownership flow.

### 6.1 `MetaGlassesDevice` — a first-class `WearableDevice`

The INMO GO3 is only an audio route today (`Glasses/GlassesAudioLink.swift`: no `WearableDevice`, no skills). The Meta glasses are different — Jarvis owns the BLE L2CAP link — so they become a real device.
- **`WearableKind`**: add `case metaGlasses` (raw value is a permanent defaults key — never rename). Unlike `.glasses` (`keepAliveName == nil`, "iOS holds the glasses' Bluetooth audio"), `.metaGlasses` owns an L2CAP session of ours, so `keepAliveName` returns a real name and it gets a Keep Alive switch; symbol `eyeglasses`.
- **`MetaGlassesDevice: WearableDevice`**: `model`, `deviceID`, `isConnected`, `capabilities`, `invoke`, `snapshot`, `commandState`, `notificationChannel`.
- **Folder** `ios_app/JarvisCopilot/MetaGlasses/` mirroring `Glasses/`: CoreBluetooth transport/session, `MetaGlassesDevice.swift`, `Features/MetaWakeChannel.swift`, media-transfer, live viewer.
- **Hub + registry wiring** (`WearablesHub.swift`): mirror the INMO block; add `MetaGlassesDevice.shared`, `install(...)`, `DeviceRegistry.shared.syncMembership(of: meta, identity: "metaGlasses", model: …)` — same path bottle/ESP32 use.

**512-cap and register-frame discipline.** `_MAX_SKILLS_PER_DEVICE = 512` in `webui/api/device_bridge.py` is **per bridge device, and the whole iPhone is one** — phone actions + every wearable, sorted by name, tail past 512 silently dropped (already bit `x5_get_status`). Keep the Meta catalogue to a handful of `meta_*` skills, **fixed regardless of link state** (don't add/remove on connect/disconnect — it thrashes the ~85 KB register frame and can push other wearables off the cut). Use `unavailableCapabilities` for picker-only greying.

### 6.2 Photo → vision (reuses `_materialize_image`, with a confirm step)

A `meta_glasses_photo` capability returns `{"base64": …, "mime": "image/jpeg"}` + `question`. Server `_materialize_image` (`tools/device_skill_tools.py` L226) decodes, writes a file, runs `_handle_vision_analyze` with the question — vision for free, like the INMO/jc-client path. The still imports over the glasses' Wi-Fi (BT paused); save add-only to Photos mirroring `InmoGallery`. **Shutter needs an explicit confirm** (the `DeviceError.confirmationRequired` pattern) — his trust rule; LED stays on, never defeated.

### 6.3 Custom wake word → voice turn (modelled on `InmoAIChannel`)

Model: `Glasses/Features/InmoAIChannel.swift`. `MetaWakeChannel.install(on:)` arms "Hey Jarvis" on the owned L2CAP session; on a wake event it hands the turn to `VoiceStore` as INMO does (`VoiceStore.swift` ~L744):
- `VoiceStore.shared.useExternalInput(input, isCurrent:)` with `input` = a `MetaGlassesAudioInput: AudioInput` that only emits glasses PCM and **cannot open the phone mic** (`InmoAudioInput`'s discipline). Sets `host.playbackOnlyEngine(true)`.
- `VoiceStore.shared.beginExternalTurn(isCurrent:)` → `machine.mode = .realtime`, `raise(.startRequested)`; model/session/ASR/TTS unchanged.
- Guard with a `generation`/`isCurrent` closure so a stale turn no-ops. Teardown: `useExternalInput(nil, …)`.
- Follow-up raw audio decodes like `InmoOpusDecoder` (Opus 16 kHz mono → Int16 PCM) → `MetaGlassesAudioInput.receive(pcm)`.

**Music stays on A2DP.** The protocol's voice audio rides L2CAP, not HFP, so we never claim the hands-free mic — A2DP music should not drop to mono (verify in Phase 0).

### 6.4 Audio-session guardrails

`AudioSessionArbiter` is the *only* session writer. Hold the `externalVoice` client → `playbackPlan`. Set `ambientAvoidsCallMic = { true }` while the Meta glasses are present so Live's ambient plan drops `.allowBluetooth`, and keep the Meta glasses **out of Live's mic entirely**. **New matcher:** `GlassesAudioLink`'s INMO matcher `looksLikeGo3(_:)` must not claim the Meta glasses; because Meta audio rides L2CAP and never appears on the AVAudioSession route, the Meta device should not surface in `GlassesAudioLink` at all — its own identity key, **not** `WearableKeepAlive.glasses`, so they never collide.

### 6.5 Touch → `RingActionRunner` (shared picker)

Decode gestures (tap/double/triple/hold/swipes/capture) into a `RingGestureEvent` (`Ring/RingInputs.swift`) and bind each to a `RingAction` through the existing picker (`Ring/ActionPickerView.swift`). Run with `RingActionRunner.run(action, context:)`: `.prompt` → a Jarvis turn; `.wearable(deviceID, skill, values)` → `DeviceRegistry.invoke` back onto `MetaGlassesDevice`. Remap via the glasses' own settings messages. Reuse `RingInputsView` — no new UI.

### 6.6 Live video + server/Power

Live view: HEVC ~720p30 over the glasses' SoftAP into an in-app viewer — the iPhone leaves home Wi-Fi during transfers, so `BridgeClient` WS and server calls go cellular meanwhile; viewer and in-flight invokes must tolerate the stall. If server parts land (frame upload, stream settings), wrap as a Power integration: copy `jarvis_power/integrations/_template/` → `meta_glasses/` (`protected=True` so turning it — and the camera — off needs Face ID), register surfaces in `jarvis_power/surfaces.py` (`ios.devices.meta_glasses`, `ios.bridge.meta_glasses`), gate on `PowerState.isOn("meta_glasses")`.

### 6.7 Phased build order with verifiable success checks

| Phase | Build | Success check |
|---|---|---|
| **0 — Mac feasibility gate** | On macOS with the MIT reference, bring up the owned session on *his Gen 2* and confirm the assistant + custom-wake-word path (ownership is his one-time prerequisite). | "Hey Jarvis" yields a transcript on the Mac **with music still A2DP (un-ducked)**. If the Gen 2 assistant path doesn't come up → stop, fall back to the SDK plan (§8). |
| **1 — iOS transport + registration** | `MetaGlasses/` CoreBluetooth + L2CAP; `WearableKind.metaGlasses`; `MetaGlassesDevice` state-only capabilities; `WearablesHub` install + `syncMembership`. No media/voice. | A "Meta glasses" row shows live battery/worn/hinge; registration lists `meta_*`; whole-phone catalogue still ≤512. |
| **2 — Photo + vision** | `meta_glasses_photo` → `{base64,mime}`+`question`; confirm step; add-only Photos save. | "What am I looking at?" returns a vision answer from a glasses still, LED on, after a confirm. |
| **3 — Wake word + voice turn (priority)** | Enrol "Hey Jarvis"; `MetaWakeChannel` → `useExternalInput`/`beginExternalTurn`; Opus follow-up. | A spoken "Hey Jarvis, …" completes a Jarvis turn through the glasses' speakers, music resumes on A2DP, `usesExternalInput == true` (phone mic never opened). |
| **4 — Live video + touch + music** | Live viewer; gesture → `RingActionRunner`; confirm `media_control` unaffected. | A double-tap runs a bound prompt; the viewer shows ~720p; glasses music still plays. |
| **5 — Background / teardown / Power** | Validate the L2CAP session survives lock (BLE background mode); back off reconnects like `InmoAIChannel.reconnectDelay`; fixed capability list; clean teardown + documented "hand ownership back to the Meta AI app"; optional `jarvis_power/integrations/meta_glasses/`. | Glasses reconnect after a locked walk with no manual re-pair; hourly registration bandwidth flat; toggling the Power integration off stops the session and hides surfaces. |

## 7. Risks / open questions
- **Gen 2 vs orca (biggest):** the Swift port is proven only on the audio-only model. Phase 0 must confirm Gen 2's assistant + enrolment path. Unknown until tested on his pair.
- **Ownership / ToS / account:** change-owner needs a Meta login with the Meta app's tokens and breaks Meta's terms; Meta could act at the account level (no ban reports found, but absence of evidence). This is a deliberate, user-made choice on his own device.
- **Firmware updates** have already changed behaviour (signature checks, LED-tamper lockout) and can break the client; updating likely means re-pairing in the Meta AI app.
- **Custom wake word:** US English only; newer firmware needs `hatch_enabled`.
- **AGPL:** Visor is spec-only for us; implementation leans on the MIT Swift port and original code.
- **iOS first-ever:** nobody has shipped this protocol on an iPhone; the port is real work with unknowns (background L2CAP, Wi-Fi join prompts).
- **Audio/Live regressions:** must not let the new route fight the voice engine or have Live record through the glasses for hours.

## 8. Fallback
If Phase 0 fails or the account risk proves too high: Meta's SDK path (see research doc §A) — camera/photo/touch/music sanctioned, with "Hey Jarvis" listened for on the iPhone. Or run Visor on a spare Android phone pointed at Jarvis's OpenAI-compatible endpoint as a stopgap.
