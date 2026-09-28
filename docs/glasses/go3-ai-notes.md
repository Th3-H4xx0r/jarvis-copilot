# INMO GO3: how the official app does AI notes

How the official INMO iPhone app records an AI note through the GO3 glasses:
what the glasses send, what the phone sends back, how photos are attached, and
what Jarvis would need to do the same. Measured from Bluetooth captures of the
real app, not from guesses.

**Evidence:** two live PacketLogger captures of the official INMO iOS app,
2026-09-27 17:50–17:57 CDT. GO3 firmware `Go3_DC_V1.1.295`, iPhone on iOS 27.
The captures cover three notes, three photos taken with the glasses button and
one photo taken with the phone camera. The decoder reported 0 CRC failures and
0 incomplete messages across 4,879 INMO messages. The raw captures are private
(transcripts, photos, hotspot login) and live only in
`inmo-re/captures/ainotes-20260927/`, which is never committed.

## The short version

| Job | Who does it | How |
|---|---|---|
| Microphone | Glasses | Opus audio over the Bluetooth control link, ~33 messages/s |
| Transcription | Phone (app or INMO cloud) | Phone sends the growing sentence back to the lens ~3×/s |
| Timer on the lens | Phone | One "seconds so far" message per second |
| Photo from the glasses button | Glasses | 320×240 JPEG preview over Bluetooth at once; full-size file saved on the glasses |
| Photo from the phone's camera button | Phone | Stays on the phone; glasses only get a count |
| Full-size glasses photos | Glasses → phone over Wi-Fi | Listed with the glasses hotspot login when the note stops, then pulled |
| AI summary | Phone / cloud | No Bluetooth traffic at all |

The glasses are a mic, a camera and a small screen. Everything clever happens
on the phone.

## Names

| Where | Name |
|---|---|
| App screen | Recording screen: live transcript, `00:21` elapsed over a `60:00` limit, camera button, **Save**, "Audio Source: Glasses Microphone" |
| Protocol message type | `CONVERSATION_RECORD` = **12** (`Message.msg_type`, field 2) |
| Payload | `FastSpeedNote` = `Message` field **15** |
| Glasses app id | `SWITCHAPP` type **5** = `SWITCHPP_CONVERSATION_RECORD` |
| Audio type | `AUDIO_TYPE` **3** = `AUDIO_CONVERSATION_RECORD` |
| Folder on the glasses | `D:\Shorthand\` |
| File-sync module | `QUERY_SPEED_NOTE_DATA` = **2** |
| Unsynced-file counter | `CHANGE_FILE_COUNT.SHORTHAND_COUNT` |

"Fast speed note" and "Shorthand" are both INMO's internal names for AI notes.

## One note, start to finish

→G = phone to glasses, G→ = glasses to phone. Times are from the second
capture. The hex is the protobuf `Message` inside the AA55 frame, exactly as
sent. The official app leaves out `VERSION` on these control messages.

### 1. Start

The phone sends four messages in about 80 ms:

| # | Dir | Message | Hex |
|---|---|---|---|
| 1 | →G | `STATUS { NET_WORK_STATUS = {} }` (network state, default value) | `1011a201024200` |
| 2 | →G | `FastSpeedNote { EXCEPTION { code = 1000 } }` ("speech recognition connected") | `100c7a070804320308e807` |
| 3 | →G | `SWITCHAPP { CONVERSATION_RECORD }` (open the notes app on the lens) | `100f9201020805` |
| 4 | →G | `FastSpeedNote { ONLINE { TYPE = SPEEDNOTE_AUDIO, AUDIO_TIME = <epoch ms> } }` | `100c7a0d08022209080120` + varint |
| 5 | G→ | `SWITCHAPP { CONVERSATION_RECORD }` echo, ~140 ms later | `100f9201020805` |

The phone never sends `START_SPEEDNOTE` (command 0). Opening the app and
sending `SPEEDNOTE_AUDIO` with the note's start time (phone clock, epoch ms) is
what starts the note. That start time becomes the note's ID: photo names use it.

### 2. While recording

- **Audio (G→):** starts ~0.4 s after the start messages. See [Audio](#audio).
- **Timer (→G):** every ~1.0 s, `FastSpeedNote { CURRENT_TIME { n } }`, with n = 0, 1, 2… seconds.
  n=0 is `100c7a0408053a00`; n=7 is `100c7a0608053a020807`.
- **Transcript (→G):** `FastSpeedNote { MSG_TYPE = ASR, ASR_CONTENT { CONTENT = <utf-8>, ISFINISH } }`.
  - The phone re-sends the **whole current sentence** each time it grows (every 0.1–1 s), not only the new words. It is lower-case and unpunctuated while growing.
  - The last version of a sentence has `ISFINISH = 1` and is capitalised and punctuated ("OK OK yeah" → "OK, OK, yeah, …").
  - The next sentence then starts again from empty. The lens shows one sentence at a time; the phone keeps the full transcript.

### 3. Photo from the glasses button

| Dir | Message | Notes |
|---|---|---|
| G→ | `FastSpeedNote { ONLINE { PHOTO = <JPEG>, PHOTO_NAME = "<note start ms>_<ms into note>" } }` | 320×240 baseline JPEG, 18.8–20.0 KB, split over ~83 AA55 fragments |
| →G | `FastSpeedNote { ONLINE { PHOTO_IS_RECEIVED = true } }` | `100c7a06080222022801`, ~20 ms after the preview arrives |

- **Naming:** the name is the note's start time plus the milliseconds into the
  note when the shutter fired, e.g. `1790549761235_11995`. The app uses this to
  place the photo at the right spot in the transcript. The full-size file on
  the glasses gets the same name plus `.jpg`.
- **Delay:** 1.3–3.1 s from shutter to preview on the phone, measured three
  times (from the name offset against capture time; about ±0.2 s clock skew).
- **On screen:** the preview shows up in the transcript right away as a
  blurred image with "Glasses have taken a photo, syncing shortly". The
  full-size photo replaces it after the Wi-Fi sync in step 5.

### 4. Photo from the phone's camera button

The camera button on the recording screen takes the photo with the **phone's**
camera. It does not fire the glasses camera. The only Bluetooth traffic is:

| Dir | Message | Hex |
|---|---|---|
| →G | `FastSpeedNote { ONLINE { PHONE_PHOTO_COUNT = 1 } }` | `100c7a06080222023001` |

Only one phone photo was taken, so it is still open whether this counter adds
up across photos.

### 5. Save (stop) and photo sync

| Δt | Dir | Message | Hex |
|---|---|---|---|
| 0 | →G | `FastSpeedNote { COMMAND = STOP_SPEEDNOTE }` | `100c7a021001` |
| +0.2 s | →G | `SWITCHAPP { CONVERSATION_RECORD, APP_CLOSE }` (sent again ~0.8 s later) | `100f92010408051001` |
| +0.3 s | G→ | same `APP_CLOSE` echo, then `STATUS { CHANGE_FILE_COUNT { SHORTHAND_COUNT = n } }` (n = full-size photos waiting) | `1011a201043a021801` for n=1 |
| 0–3 s | →G | `STATUS { SYNCH = QUERY_SYNCH, UNSYNCED_FILE_LIST_REQUEST { QUERY_ALL_DATA } }` (sometimes sent twice) | `1011a20106080432020804` |
| +~50 ms | G→ | `STATUS { WIFI_DATA { SSID, PWD, TOTAL_COUNT, FILES[] } }` | contains the hotspot login, not reproduced here |
| 3–10 s | →G | `STATUS { SYNCH = NOT_PERFORM, WIFI_CONTROL { WIFI_OPEN } }` | `1011a2010608032a020800` |
| +1.9 s | G→ | `STATUS { WIFI_CONTROL {} }` (open, default value) | `1011a201022a00` |
| — | Wi-Fi | phone joins the glasses hotspot and downloads the files | not in these captures |
| +17 s | →G | `STATUS { SYNCH = NOT_PERFORM, WIFI_CONTROL { WIFI_CLOSE } }` | `1011a2010608032a020801` |
| +1 s | G→ | `STATUS { WIFI_CONTROL { WIFI_CLOSE } }` | `1011a201042a020801` |

Each entry in `WIFI_DATA.FILES` holds `FILE_MODULE_TYPE = QUERY_SPEED_NOTE_DATA (2)`,
`FILE_NAME = <note start ms>_<ms into note>.jpg`, `FILE_PATH = "D:\Shorthand\"` and
`FILE_SIZE`. The observed sizes were 95 KB to 1.14 MB. Photos not yet synced
from an earlier note stay on the list until they are fetched.

Audio stops ~0.3 s after `STOP_SPEEDNOTE`. The Wi-Fi hotspot stays up for
about 17 s in all three notes, for one or two photos.

**The Wi-Fi download itself was not captured** (that needs a network capture).
The earlier photo-album capture showed the glasses' file server: TCP port
10000 on the hotspot's gateway address, AA55 frames with big-endian headers,
the phone requesting a file by its remote path, 8,192-byte chunks and an MD5
check. Note photos are very likely requested the same way as
`D:\Shorthand\<name>.jpg`. That is an inference until it is captured.

## Audio

```
Message {
  VERSION = 1                       // audio does carry VERSION
  AUDIO (field 3) {
    HEADER { SAMPLE_RATE = 16000, CHANNELS = 1, BITRATE = 256000,
             AUDIO_TYPE = 3 /* AUDIO_CONVERSATION_RECORD */ }
    DATA_LENGTH = <bytes>           // 66 when silent, ~100–125 while talking
    OPUS_DATA   = <3 frames>
    FRAME_LENGTH = [a, b, c]        // packed; a+b+c = DATA_LENGTH
  }
}
```

- **Frames:** each of the 3 frames is **two** Opus packets. Each packet is:
  - a 4-byte big-endian packet length,
  - a 4-byte word of unknown meaning (it is *not* the Opus final range; tested against libopus),
  - the Opus packet itself.
- **Codec:** every packet has TOC config 22, which is CELT-only wideband, 10 ms, mono. That is 12,600 + 14,616 packets checked, with no exceptions.
- **Two streams:** the packets alternate between two separate streams: A (even) and B (odd).
  - Decoding each stream with its own libopus decoder gives exactly the note's real length for each. A 34 s note gives 34.0 s from A and 34.0 s from B. Decoding them as one stream gives double length.
  - Stream A carries the speech (RMS 715–830). Stream B is much quieter (RMS 45–124).
  - It is probably a second microphone (ambient / noise reference). The header still says `CHANNELS = 1`.
- **Rate:** 3 frames × 10 ms = 30 ms per message, so ~33 messages/s, about 3–4 KB/s.
- **Silence:** a quiet 10 ms packet is 3 bytes (`b0 ff fe`). A fully silent message is 66 bytes.
- **Other apps:** the same framing carries other lens apps' audio, with only `AUDIO_TYPE` changing. Seen in the same session: 4 = `AUDIO_VOICE_SUBTITLE`, 9 = `AUDIO_CHATTRANSLATE_MASTER` (dialogue translation).

## FastSpeedNote message reference

`Message` field 15, from the decompiled app's `FastSpeedNoteProto`. ✓ = seen
on the wire in these captures.

```
FastSpeedNote {
  1 msg_type: FastSpeedNoteMessageType   // 0 COMMAND, 1 ASR ✓, 2 ONLINE ✓, 3 OFFLINE, 4 EXCEPTION ✓, 5 CURRENT_TIME ✓
  oneof {
    2 command: FastSpeedNoteCommand      // 0 START, 1 STOP ✓, 2 TIMEOUT_STOP, 3 NO_MEMORY_STOP,
                                         // 4 START_OFFLINE, 5 STOP_OFFLINE
    3 asr_content { 1 content: bytes (utf-8) ✓, 2 is_finish: bool ✓ }
    4 online_content {
        1 type: ContentType              // 0 SPEEDNOTE_IMAGE, 1 SPEEDNOTE_AUDIO ✓
        2 photo: bytes (JPEG) ✓
        3 photo_name: bytes ✓
        4 audio_time: int64 (epoch ms) ✓
        5 photo_is_received: bool ✓
        6 phone_photo_count: int64 ✓
      }
    5 offline_content { 1 audio_info: AudioInfo, 2 photo_list: [ { 1 photo_data, 2 event_time } ], 3 create_time }
    6 exception { 1 code: int64 ✓ (1000), 2 content: bytes }
    7 current_time { 1 seconds: int64 ✓ }
  }
}
```

The `STATUS` pieces used by the sync (`Message` field 20, msg_type 17):
- `1 SYNCH`: 3 = `NOT_PERFORM`, 4 = `QUERY_SYNCH`
- `4 WIFI_DATA { 1 SSID, 2 PWD, 3 TOTAL_COUNT, 4 FILES { 1 FILE_MODULE_TYPE, 3 FILE_NAME, 4 FILE_PATH, 5 FILE_SIZE } }`
- `5 WIFI_CONTROL { 1 WIFI_STATUS: 0 open, 1 close }`
- `6 UNSYNCED_FILE_LIST_REQUEST { 1 MODULE_TYPE: 4 = QUERY_ALL_DATA }`
- `7 CHANGE_FILE_COUNT { 3 SHORTHAND_COUNT }`
- `8 NET_WORK_STATUS`

## From the decompiled app

These come from reading the INMO app's code, not from the captures:

- **Two features, not one.** "AI Note" (Quick Notes: voice + glasses photos + an AI title) is
  `CONVERSATION_RECORD` / `FastSpeedNote`, the one captured here. "SmartRec" (meeting/call
  recording with an AI summary) is a separate feature: `SOUND_RECORD` (10), `SuperRecord`,
  audio type 1.
- **Exception codes** (phone → glasses):
  - 1000 = speech recognition connected (this is why it goes out before every start)
  - 1001 = the previous recording is still processing
  - 1002 = permission missing
  - 1003 = phone storage low
  - 1004 = speech recognition dropped
- **Starting a note from the glasses:** the touchpad, a long-press GO shortcut or the INMO voice
  command opens lens app 5. The phone must then serve it.
- **The official app sends everything to INMO's cloud:**
  - Transcription streams to `wss://global.translate.inmolens.com/inmo/asr` with the account's
    token, and falls back to an on-device SDK when offline.
  - The summary is `POST https://ai.overseas.inmolens.com/im/ai/task/submit`, then polling.
  - The audio is uploaded to Aliyun OSS.
  - **Jarvis uses none of this** (see below).
- **Supported modules (type 35):** no notes/record module exists, so the phone doesn't need to
  advertise anything for notes to work.

## Not captured yet

- **Wi-Fi photo download:** the exact request for `D:\Shorthand\` files. Needs
  the RVI network capture (`inmo-re/tools/inmo_capture.py`, sudo) running
  during Save.
- **INMO's cloud traffic:** the hostnames above are from the app's code, not yet from a
  network capture. This doesn't matter to Jarvis, which doesn't use them.
- **Offline notes:** `START_SPEEDNOTE_OFFLINE` / `OFFLINE_CONTENT` (glasses
  record alone and hand over the audio and photos later). Never triggered.
- **Starting a note from the glasses** (button, gesture or voice) and the
  60-minute `TIMEOUT_STOP` / `NO_MEMORY_STOP` paths. Never triggered.
- **`NET_WORK_STATUS`:** sent empty before every start. Its meaning isn't confirmed (code 1000
  is explained above).

## In Jarvis

Built 2026-09-27: **Glasses → AI Notes** in the iPhone app (`ios_app/JarvisCopilot/Glasses/Notes/`).
It does not touch INMO's cloud:

- **Transcription** is Jarvis's own on-device speech engine (SpeechAnalyzer).
- **The title and summary** come from Jarvis through the app's chat with the Jarvis server
  (one chat per note, so you can follow up there).

| Piece | File |
|---|---|
| Wire (start, timer, transcript, photo ack, stop; parsing) + the lens sentence logic | `GlassesNoteWire.swift` |
| Recording, glasses events, save; summary + full-size photo fetch | `GlassesNoteRecorder.swift` |
| Notes on disk (`Application Support/GlassesNotes/<id>/note.json` + JPEGs) | `GlassesNotesStore.swift` |
| List, recording screen, note detail | `GlassesNotesView.swift` |
| Tests (goldens from these captures) | `JarvisCopilotTests/Glasses/GlassesNoteWireTests.swift` |

The recorder follows these steps:

1. **Start:** open lens app 5 and send `ONLINE { SPEEDNOTE_AUDIO, audio_time }`,
   the same bytes as the table above.
2. **Audio:** split `AUDIO_TYPE = 3` messages into the two 10 ms Opus streams,
   decode stream A with libopus (16 kHz mono) and feed it to the speech engine.
3. **Lens feedback:** send the growing sentence back as `ASR_CONTENT`, with
   `is_finish` on the final version, plus `CURRENT_TIME` every second.
4. **Glasses photos:** keep the preview, reply `PHOTO_IS_RECEIVED`, and file it
   at `<ms into note>` in the transcript.
5. **Save:** send `STOP` and close the lens app. Then Jarvis writes the summary, and
   the full-size photos are fetched over Wi-Fi with the existing media-transfer code.
6. **Starting from the glasses:** if the glasses open their notes app while Jarvis is idle,
   Jarvis starts a note. There is a toggle for this on the AI Notes screen.

**Fixed alongside:** in the first capture, Jarvis reconnected to the glasses in the middle
of an INMO note. Within 0.2 s, the glasses closed the running notes app. The cause was Jarvis's
connect setup blindly closing the AI assistant app (module 4). It now closes it only when the
glasses report that app as the one open (`InmoAIChannel.armWake`). This is task 10 in
`docs/tasks/2026-09-27.md`.

## Reproducing

```sh
# live Bluetooth capture from a USB-connected iPhone (no PacketLogger window needed)
~/Applications/PacketLogger.app/Contents/Resources/packetlogger convert -u <iphone-udid> -o note.pklg   # Ctrl-C to stop
# decode INMO frames (needs tshark)
python3 inmo-re/tools/decode_bluetooth_trace.py note.pklg note-decoded.json
```

PacketLogger stores local wall time as if it were UTC (5 h off in CDT). The
`audio_time` in the start message is real UTC epoch milliseconds, so use it to
line up the clocks.
