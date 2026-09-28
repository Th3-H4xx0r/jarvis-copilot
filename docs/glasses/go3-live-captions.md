# Live Jarvis captions on the GO3 lens

While **Live Jarvis** records, the INMO GO3 lens can show a live transcript:
**who is speaking and what they say**, plus Live's translation when it has one.
Everyone's lines show, his own included.

## Using it

- **Where:**
  - Live settings → Recording → **Show on glasses**
  - Glasses page → **Notes & translation → Live captions**, which has the toggle, the
    lens style, the status and a test button
- **The toggle is remembered and off by default.** Captions show only while it is on,
  Live is recording, the glasses are connected, and no other glasses app has the lens.
- **From the glasses:**
  - Opening **Subtitles** on the glasses turns captions on, and starts Live recording if it
    isn't already.
  - Closing Subtitles on the glasses turns captions off. Live keeps recording.
- **Sharing the lens:**
  - While an AI note, a live translation or any other glasses app is open, captions step
    aside. When it closes, they come back with the latest line.
  - Captions never take the lens back from an app opened on the glasses.
- **Lens style:**
  - **Subtitles** (default) is the glasses' own Subtitles app, lens app 8. A translation
    goes on a second line.
  - **Translation** is the translation lens app 0: the line, with the translation in its
    second slot.
- **Research → Send test captions** puts three test lines on the chosen style for about
  20 seconds.

## What goes on the lens

- **Finished lines:** `"<Name>: <words>"`, using Live's speaker name, or "Speaker N" for
  an unrecognised voice. They are sent at once.
- **Words being spoken:** shown unnamed, since Live only knows the speaker once the line
  is finished. They're sent at most every 0.3 s.
- **Late translation:** when a translation arrives after its line, that line is sent once
  more with the translation.
- **Starting mid-conversation:** only the latest line shows; the backlog isn't replayed.
- **Length:** at most 120 characters. Longer lines keep the most recent words, with "…" in
  front.

## Wire (Subtitles app, lens app 8)

The bytes are worked out from the decompiled app's `VoiceSubtitleProto` (`Message` type 18,
field 21), with no VERSION field, as the official app does. They aren't confirmed by a
capture yet.

| Message | Hex / shape |
|---|---|
| Open the app | `SWITCHAPP{8}` = `100f9201020808` |
| Start | `VOICE_SUBTITLE{command=START}` = `1012aa01021000` |
| A line | `VOICE_SUBTITLE{msg_type=ASR(1), asr_content{1: text, 2: is_finish}}` |
| Stop | `VOICE_SUBTITLE{command=STOP}` = `1012aa01021001` |
| Close | `SWITCHAPP{8, close}` = `100f92010408081001` |
| Glasses → phone error | `VOICE_SUBTITLE{msg_type=EXCEPTION(2), exception{1: code, 2: content}}` |

In the 2026-09-27 notes capture, the glasses' own Subtitles app sent 3
`AUDIO_VOICE_SUBTITLE` (type 4) audio messages. So the app may stream the glasses' mic
while it is open; Jarvis ignores that audio.

## Code

`ios_app/JarvisCopilot/Glasses/LiveLens/`:
- `GlassesSubtitlesWire`: the messages above
- `LiveCaptionComposer`: Live state → captions (pure)
- `LensCaptionSurface`: Subtitles and Translation styles
- `LiveStore+Captions`: what the bridge reads from Live
- `LiveLensBridge`: when to show, stepping aside, glasses events
- `LiveCaptionsSettingsView`

Tests: `JarvisCopilotTests/Glasses/{GlassesSubtitlesWire,LiveCaptionComposer,LiveLensBridge}Tests.swift`.
