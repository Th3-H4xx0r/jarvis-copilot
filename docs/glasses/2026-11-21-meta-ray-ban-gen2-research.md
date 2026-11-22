# Meta Ray-Ban Gen 2 (Scriber) × Jarvis — connection research

*2026-11-21. Sources: Meta's Wearables docs (DAT v1.1 llms.txt dump), meta/meta-wearables-dat-ios issues + Meta staff answers, community repos. Measurements marked [1src] come from one developer only.*

## The glasses

- **Ray-Ban Meta Scriber Optics (Gen 2)** — real product, the prescription-first frame (announced 2026-03-31, $499). 12 MP / 3K camera, 5–6 mics, open-ear speakers, ~8 h battery, **no action button** (Gen 3 added one).
- Supported by Meta's SDK (DAT) since iOS SDK 0.6. Expect it to report as `rayBanMetaOptics`, not `rayBanMeta` — accept both.
- Current SDK: **iOS 1.1.0 (2026-11-20)**, needs glasses firmware V130, Meta AI app V292, iOS 17.2+. Repo: `github.com/meta/meta-wearables-dat-ios` (SPM).

## Three ways to connect

| | A. Meta SDK (DAT) + Meta AI app | B. Plain Bluetooth headset | C. Jarvis owns the glasses (Visor-style protocol port) |
|---|---|---|---|
| Photo on command | ✅ still from stream ~1080×1440; beta full 12 MP (4032×3024) but 9–48 s transfer, flaky | ❌ | ✅ native capture + import over glasses Wi-Fi (~10 MB/s) |
| Start/stop native 3K video | ❌ (only a 720p stream into the app) | ❌ | ✅ |
| Live video to iPhone | ✅ up to 720×1280 @30 over glasses Wi-Fi (phone leaves home Wi-Fi) or ~504×896 bursty over BT Classic | ❌ | ✅ HEVC ~720p30 over glasses SoftAP |
| Mic when you talk | ✅ HFP 8/16 kHz, beamformed (music drops to mono while open); beta 16–48 kHz in-stream audio only with camera + LED on | ✅ same HFP | ✅ glasses send transcript + raw audio on follow-ups; no HFP needed |
| **Custom wake word** | ❌ No. Only "Hey Meta, start Jarvis" (beta, launch only, no words passed). Otherwise phone-side keyword spotting over HFP | phone-side keyword spotting over HFP | ✅ **"Hey Jarvis" enrolled ON the glasses** (3 samples, built on-device, US English) + "Hey Meta" redirected to Jarvis |
| Touch / buttons | ⚠️ beta, session only: double-tap=select, swipes=nav, capture button short/hold/double. Single tap + tap-and-hold reserved (pause/stop session). No remap | ⚠️ taps arrive as media keys (1×play/pause, 2×next, 3×prev) only if Jarvis is the Now Playing app | ✅ every event readable (tap, double, triple, hold, swipes, capture); defaults can't be suppressed; remap looks possible via settings |
| Music | ✅ A2DP — but **any camera stream mutes app audio on the glasses** (#256, #358) | ✅ A2DP | ✅ A2DP |
| Meta AI app | required | optional | **must be disconnected** (glasses hold one owner) |
| Risk | low (Meta-sanctioned) | none | high — see below |

## A. Meta SDK (DAT) — details that matter for Jarvis

**Distribution limits mostly don't apply to us.** App Store is blocked (MFi / ExternalAccessory), but Jarvis ships ad-hoc via release.sh. Beta features (Inputs, Speech, Motion, voice launch, full-res photo, in-stream audio) work in **Developer Mode** (Meta AI app → Settings → App Info → tap version 5×). Only **one** third-party app can be registered in Developer Mode. Some iOS users can't get the toggle to appear (#325).

**What we get:** camera stream (`addCamera`, 2/7/15/24/30 fps; `.hvc1` keeps frames coming in background, `.raw` stops), photos, HFP mic, A2DP out, Inputs (beta), on-glasses Speech-to-text (beta), IMU Motion (beta, foreground, rotated 90° on non-display glasses), battery/worn/hinge/thermal state (no session needed), "Hey Meta, start {app}" voice launch (beta).

**Hard limits:**
1. **No custom wake word.** "Hey Meta" can't be changed or replaced; the glasses never give audio to apps without a session. Voice launch carries no transcript, name matching is flaky, and Meta contradicts itself on whether it works in Developer Mode.
2. **Nothing starts Jarvis from the glasses except voice.** Taps/buttons reach the app only while a session is already running (#316). Gen 2 has no action button.
3. **Camera stream mutes app audio** on the glasses → Jarvis can't talk while looking. Pattern: grab frames → stop stream → speak.
4. **Wi-Fi streaming pulls the iPhone off home Wi-Fi** (joins the glasses' hotspot; Wi-Fi Aware unsupported) → Jarvis server traffic goes over cellular. BT Classic (`external-accessory` background mode + `com.meta.ar.wearable`) keeps Wi-Fi at lower quality.
5. **HFP + photo conflict:** capturePhoto silently fails while the glasses are the HFP mic (#260). HFP must settle *before* a stream starts.
6. **Fragility:** if iOS suspends the app mid-stream the glasses get stuck until put in the case (#231); stream restarts refused after minutes on Optics firmware 130 (#375); Speech silently stops after ~60 s (restart it, #360).
7. Battery: streaming ~1.2–2 %/min on Gen 2 [1src]; Wi-Fi hits "moderate" thermal in ~10 s [1src]; looping Speech ~50 %/h [1src].
8. Policy: no face/voice identification of people, capture LED can't be hidden or covered.

**Wake word options inside A** (all phone-side or hacky):
- Always-on keyword spotter on the iPhone fed by the glasses' HFP mic (8/16 kHz). Cost: music is call-quality mono whenever listening; glasses battery ~5 h (calling rating) instead of 8 h; iOS orange mic dot. Used by OpenVision ("Ok Vision"), TeroGlasses ("Hey Jarvis"), OpenGlasses.
- Loop the beta on-glasses Speech capability and match "Jarvis" in the text. Keeps A2DP music, but restarts every ~60 s and ~50 %/h battery [1src].
- "Hey Meta, start Jarvis" → opens a Jarvis session (two-step, launch only).

## C. Owning the glasses (community protocol work)

- **Visor** (github.com/macedonga/visor, Android, AGPL-3.0, 240★, active daily): a full replacement for the Meta AI app. Speaks the glasses' encrypted protocol (BLE L2CAP on service 0xFD5F + glasses Wi-Fi). Sends "Hey Meta" to any model, imports photos/videos, live view, every touch event, settings, and **custom on-glasses wake word enrolment** (`CustomWakeWord.kt`: session 390 → record samples → batch 386 → glasses build the model, no server). Protocol docs: visor.macedonga.com/protocol.
- **cipher982/ray-ban-meta-custom-agents** (MIT, Swift): CoreBluetooth port of the same protocol — works on **macOS**; its iPhone app "builds but has not been run on a phone". Only the audio-only model (orca, firmware v129) so far. ~0.7 s replies, barge-in.
- Also: meta-g-link-direct (OBS plugin, Gen 2 live 720p30 + 48 kHz stereo straight from the glasses' Wi-Fi), henriqueleote/visor fork ("Hey Jarvis" + Claude bridge, ~5 s wake→answer, Gen 1).
- **How the link works:** BLE advert company id 0x01AB / service 0xFD5F; an L2CAP channel (PSM read from characteristic 05acbe9f-…91c0; **128 on Ray-Ban Meta Gen 2**, and it comes up even folded in the charging case) carries one AirShield-encrypted session; RFCOMM is the Classic fallback (MFi-only on iOS, not needed); photo/video import and live view hop to TCP over the glasses' Wi-Fi while the Bluetooth session pauses. Plain iOS apps may open BLE L2CAP via CoreBluetooth.
- **Ownership:** each pair holds ONE owner key (EC P-256). Becoming owner = one-time change-owner flow: Meta login → two Meta-signed receipts from graph.facebook-hardware.com → glasses swap the owner key to the phone's. It replaces the Meta AI app as owner; going back = re-pair in the Meta AI app.
- **Blockers/risks:** setup needs a Meta login with the Meta AI app's own client tokens (not shipped by Visor) to get ownership receipts; after setup the phone and glasses talk directly. Meta's Terms forbid reverse engineering (§3.4) and allow account suspension; no ban reports found. Firmware updates already changed behaviour (signature checks, LED tamper lockout) and likely need the Meta AI app again. Custom wake word: US English pack only, newer firmware needs `hatch_enabled`. **Nobody has run this on an iPhone yet.** Copying Visor code brings AGPL obligations; cipher982 is MIT.
- **Quick hack:** Visor on a spare Android phone, pointed at Jarvis's OpenAI-compatible endpoint (gateway api_server) — Jarvis answers "Hey Meta"/"Hey Jarvis" today, but you carry a second phone and lose the iPhone integration.

## Where it plugs into Jarvis (from the code map)

- New `WearableKind.metaGlasses` + `ios_app/JarvisCopilot/MetaGlasses/`, registered via `DeviceRegistry.syncMembership`; skills go through the bridge (512-skill cap shared by the whole iPhone).
- Photo skill returning `{base64, mime}` + `question` gets server vision for free (`_materialize_image` in `tools/device_skill_tools.py`).
- Voice: `VoiceStore` + `AudioSessionArbiter` (only audio-session writer). Glasses mic = HFP; INMO's `InmoAIChannel → VoiceStore.useExternalInput/beginExternalTurn` is the model for a glasses-triggered turn (fits path C's assistant channel exactly).
- **No wake word exists on the iPhone today** (only the Siri App Intent). Live Jarvis must not record through the glasses' HFP (`ambientAvoidsCallMic`). `GlassesAudioLink`'s INMO matcher could claim the Meta glasses — needs a separate matcher.
- Touch → reuse `Ring/RingInputs.swift` `RingActionRunner` (shared action picker).
- Info.plist lacks `external-accessory`, MWDAT keys, Hotspot Configuration entitlement, local-network/Bonjour keys. Packages are pinned exactVersion in a hand-kept pbxproj.
- Fits a Power integration (`jarvis_power/integrations/meta_glasses/`) if it gets server parts (frame upload / stream settings).

## Alternatives if Ray-Ban falls short
Mentra Live (open-source MentraOS, iOS app, camera, Wi-Fi), Brilliant Labs Halo (open, display), OpenGlass (DIY ESP32). Even Realities has no camera.
