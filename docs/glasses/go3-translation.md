# INMO GO3: live translation, and how Jarvis does it

How the official INMO app runs translation on the GO3 lens, and how Jarvis now
does the same without INMO's cloud.

**Evidence so far:**
- One captured official session: **Dialogue** mode, started from the glasses,
  English → Chinese, 2026-09-27 17:55 CDT, in the second AI-notes capture.
- The decompiled app's `TranslationMasterProto`.
- The phone-started **live / simultaneous** run (Spanish → English) was not
  recorded: the iPhone had stopped streaming Bluetooth logs. It needs a re-capture;
  see "Still to capture".

## The shape of it

| Job | Who | How |
|---|---|---|
| Open the lens app | Phone or glasses | `SWITCHAPP` open: 0 = Simultaneous, 1 = Dialogue, 14 = Call |
| Languages on the lens | Phone | `TRANSLATION_MASTER { SETTING { mode, source, target, captions, online } }` |
| Microphone | Glasses | Opus over Bluetooth: live/simultaneous `AUDIO_TYPE 8` (`AUDIO_LIVETRANSLATE_MASTER`), dialogue `AUDIO_TYPE 9` (`AUDIO_CHATTRANSLATE_MASTER`) |
| Hearing + translating | Phone (INMO: its cloud; Jarvis: see below) | — |
| Each line on the lens | Phone | `TEXT_CONTENT { original, translation, role, finished }` |
| End | Glasses or phone | phone sends `TRANSLATION_SAVE { success }`, then closes the app |

Message type **8** = `TRANSLATION_MASTER`, payload in `Message` field **11**. The
official app sends no `VERSION` on these.

## The captured dialogue session

→G = phone to glasses, G→ = glasses to phone. The hex is the protobuf `Message`, as sent.

| Δt | Dir | Message | Hex |
|---|---|---|---|
| 0 | G→ | `SWITCHAPP { DIALOGUE }` (opened on the glasses) | `100f9201020801` |
| +2.1 s | →G | `SETTING { mode=DIALOGUE, source="en", target="zh", online }` | `10085a0e120c08011202656e1a027a683001` |
| … | G→ | audio, `AUDIO_TYPE 9`, ~33 msgs/s | same framing as AI notes |
| per line | →G | `TEXT_CONTENT { "Cool.", "好", role=GLASSES }` | `10085a1208011a0e0a05436f6f6c2e1203e5a5bd1801` |
| +20 ms | →G | `TEXT_CONTENT { "Cool.", "好的。", role=GLASSES, finished }` | `10085a1a08011a160a05436f6f6c2e1209e5a5bde79a84e3808218012001` |
| end | G→ | `SWITCHAPP { DIALOGUE, close }` | `100f92010408011001` |
| +50 ms | →G | `TRANSLATION_SAVE { success }` | `10085a0608052a020801` |
| +20 ms | →G | `SWITCHAPP { DIALOGUE, close }` | `100f92010408011001` |

- **Line updates:** the official app sends each finished sentence (already
  punctuated) with its translation growing, then once more with `finished`. The
  lens replaces the line in place. Each sentence was re-sent in full a few
  seconds later (the same pair twice). This was probably a re-render and was left out of Jarvis.
- **Audio:** same framing as AI notes: two interleaved 10 ms Opus streams per
  frame, CELT wideband 16 kHz. Stream A is the louder one in dialogue (RMS 435
  against 134). Jarvis uses stream A, as for notes.

## Audio: live mode is different

This comes from the official Android app's `BleProtocolManager.audioByteProcess` and
`TranslateAsrDenoiseProcessor`. The first Jarvis build missed it, and every live
session heard nothing:

- **Splitting:** both types cut `OPUS_DATA` into frames using `FRAME_LENGTH`.
- **Live / simultaneous (type 8):** each frame is **one raw 20 ms Opus packet**
  (320 samples at 16 kHz). There is no stream wrapper.
- **Dialogue (type 9):** each frame is the two-stream wrapper (BE32 length + 4
  bytes + a 10 ms packet, twice).
  - The first stream is the wearer (`Role.GLASS`).
  - The second is uploaded as the other side (`Role.PHONE`).
- **Starting from the phone:** the app opens the lens app first. It sends
  `SETTING` only once the glasses confirm that the app is open. By default the
  settings are captions = `ONLY_TRANSLATION`, online = true, translate-self-sound =
  `NOT`.

## Schema

```
TranslationMaster {                  // Message field 11, msg_type 8
  1 msg_type: 0 SETTING, 1 TEXT_CONTENT, 2 PAUSE, 3 RESUME, 4 ERROR, 5 SAVE
  2 setting {
      1 mode: 0 SIMULTANEOUS, 1 DIALOGUE, 2 CALL
      2 source_language: bytes ("en", "es", "zh", …)
      3 target_language: bytes
      4 glasses_captions: 0 ALL_DISPLAY, 1 ONLY_TRANSLATION
      5 translate_self_sound: 0 NOT, 1 YES
      6 is_online_translate: bool
      7 mdl_id: 0 ELEVOC_NON_DIRECTIONAL, 1 ELEVOC_DIRECTIONAL   // mic beam model
      8 display_self_said: 0 DISPLAY_YES, 1 DISPLAY_NOT
    }
  3 text_content { 1 original, 2 translation, 3 role (0 PHONE, 1 GLASSES), 4 is_finished,
                   5 user_separation, 6 is_asr_finished, 7 is_translation_finished }
  4 error { 1 code }
  5 save { 1 is_save_success }
}
```

## In Jarvis

**Glasses → Notes & translation → Live translation** in the iPhone app
(`ios_app/JarvisCopilot/Glasses/Translate/`).

- **Languages:** pick "They speak" and "Show me", then Start. You can also open
  translation on the glasses (toggle "Start from the glasses").
- **On the lens:** the line being heard, then the line with its translation.
- **Saving:** a session is saved with your AI notes, with each line next to its translation.
- **Translator:** three routes, switchable on the screen. None of them touch INMO.

| Translator | Hearing | Translating | Needs |
|---|---|---|---|
| **On device** (default) | Jarvis's on-device speech engine | Apple Translation (`TranslationSession`) | the language pair downloaded ("Download languages") |
| **Jarvis** | on-device speech engine | Jarvis server model, `POST /api/translate/text` (auxiliary task `translation`) | the server |
| **Soniox** | Soniox on the Jarvis server | Soniox real-time translation, `/api/translate/ws` (the existing `jarvis_speech` Soniox stream, purpose `translate`) | the server + its Soniox key |

| Piece | File |
|---|---|
| Wire (setting, lines, save, parsing) | `Glasses/Translate/GlassesTranslateWire.swift` |
| Session, the three routes, lens pacing, saving | `Glasses/Translate/GlassesTranslator.swift` |
| Screen | `Glasses/Translate/GlassesTranslateView.swift` |
| Server socket + text endpoint | `webui/api/translate_ws.py` |
| Tests | `JarvisCopilotTests/Glasses/GlassesTranslateWireTests.swift`, `webui/tests/test_translate_ws.py`, `tests/jarvis_speech/test_soniox_stream.py` |

**Lens pacing:**
- The line being heard is sent at most about 3 times a second.
- A finished sentence goes up at once without its translation, then again with the translation and `finished`.
- While a translation is still pending (the server routes take 1–3 s), the next line waits, so the lens never jumps back to an older line.

## Still to capture

- **The phone-started live / simultaneous run:**
  - the exact setting bytes for mode 0 (captions, `mdl_id`, self-sound),
  - whether the phone streams growing originals before a sentence ends,
  - which audio stream carries the other person when the glasses use the
    directional model,
  - pause/resume from the glasses.
- **Call translation (mode 2, app 14):** not tried.
