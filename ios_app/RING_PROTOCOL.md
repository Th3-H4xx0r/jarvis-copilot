# QRing smart-ring protocol (Colmi R12)

Reverse-engineered from the **QRing Android app 1.0.1.179**, which drives rings through the
Oudmon BLE SDK, for interoperability with the user's own ring — a Colmi R12 advertising
`R12_7E04`, firmware 3.10.06. This is an original, condensed description of the wire
behaviour for maintainers of `JarvisCopilot/Ring/`; it contains no decompiled code. Items
marked **(unverified)** were inferred from the app and have not been confirmed on the ring.

Implementation: `RingProtocol.swift` (framing and request builders), `RingDecoders.swift`
(replies), `RingTransport.swift` (transactions), `RingSession.swift` (setup, settings,
measurements, events), `RingSync.swift` (history).

## 1. Conventions

- **pN** is byte N of a command payload — frame byte N + 1. Reply decoders see p0…p13.
- **dN** is byte N of a large-data payload — frame byte 6 + N.
- Integers are **little-endian** unless marked **BE**. Today's totals (`48`) and the live
  activity event (`73`/18) are big-endian.
- Dates in `01`, `43` and `44`, and clock times in `23`, `25` and `27`, are **BCD** (`0x25` =
  25). Years are 2000 + BCD.
- Settings commands put an action in p0: `01` read, `02` write, `03` a ring-specific read.
  Replies echo it. Write acknowledgements carry nothing useful and several writes are never
  acknowledged, so read the setting back to learn what the ring holds.
- On/off encodings differ: `1`/`2` for the heart-rate monitor, do not disturb and the
  temperature unit; `1`/`0` for SpO₂, stress, HRV and temperature monitoring.
- Day offsets count back from today: `0` today, `1` yesterday, and so on.

## 2. GATT

| Service | Characteristic | Use |
|---|---|---|
| `6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E` command | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | write 16-byte command frames |
| | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | notify: replies and ring-initiated events |
| `DE5BF728-D711-4E47-AF26-65E3012A5DC7` large data | `DE5BF72A-D711-4E47-AF26-65E3012A5DC7` | write `BC` frames in chunks, without response |
| | `DE5BF729-D711-4E47-AF26-65E3012A5DC7` | notify: `BC` frames in MTU-sized pieces |
| `180A` device information | `2A26` / `2A27` | firmware / hardware revision strings |

**Finding a ring.** Rings may not advertise the command service, so scan without a service
filter and match the name: `R` followed by two digits (`R02…`, `R12_7E04`), or one of
`VK-5098`, `MERLIN`, `Hello Ring`, `RING1`, `boAtring`. QRing fetches its name list from its
server; `R12` is missing from the app's built-in fallback.

## 3. Command frames

```
byte  0      opcode
bytes 1-14   payload, zero-padded (anything longer is dropped)
byte  15     checksum = (sum of bytes 0-14) & 0xFF
```

Example — find ring: `50 55 AA 00 00 00 00 00 00 00 00 00 00 00 00 4F`.

- Replies and events use the same 16-byte shape on the notify characteristic. Drop frames
  whose checksum fails.
- **Error flag.** Bit 7 of byte 0 marks an error reply to opcode `byte0 & 0x7F` — `83` is a
  rejected battery request.
- **High opcodes.** A few real opcodes are ≥ `0x80`: `93`, `A1` (wearing calibration), `C9`/`CA`
  (factory test) and `FF` (factory reset). Keep them whole instead of reading an error flag.
- **Multi-packet replies** repeat the request's opcode; each command defines its last packet
  (§7).
- The SDK runs one request at a time and matches replies by opcode; anything unmatched is an
  event. Jarvis serialises both channels through one queue for the same reason.

## 4. Large-data frames

```
byte  0      0xBC
byte  1      opcode
bytes 2-3    payload length
bytes 4-5    CRC-16/MODBUS of the payload   (empty payload: length 0000, CRC FFFF)
bytes 6-     payload
```

Examples — today's sleep: `BC 27 02 00 C0 70 00 01`; every stored night:
`BC 27 02 00 81 80 FF 01`.

- **CRC-16/MODBUS:** initial value `FFFF`, reflected polynomial `A001`, no final XOR. Check
  value: `"123456789"` → `4B37`.
- **Sending.** Split the whole frame into chunks and write them in order without response. The
  SDK uses 20-byte chunks; the ring can announce a bigger size in a `2F` event (p0, never below
  20). Jarvis uses the smaller of the peripheral's write-without-response limit and the
  announced size (20 when none), never below 20, and paces writes on the ready-to-send callback.
- **Receiving.** A notification that starts with `BC` and holds at least 6 bytes opens a frame;
  append the following notifications until `6 + length` bytes are buffered, then dispatch on
  byte 1. Frames can arrive back to back in one notification. QRing never checks the CRC;
  Jarvis logs a mismatch and still delivers the frame. Jarvis also skips stray bytes before a
  `BC` and drops a partial frame when a new one starts more than 3 s later.

## 5. Connection setup

Jarvis runs this on every connect; QRing runs its equivalent on a fresh bind and on every
reconnect alike.

1. Enable notifications on both notify characteristics; read `2A26` and `2A27`.
2. `01` set time, using phone time + 1 s. The reply is capability block A (§9).
3. `3C`. The reply is capability block B (§10).
4. `03` battery.
5. Settings reads, each best-effort (a timeout leaves the value unknown):
   `16` heart-rate monitor · `38` HRV (block A HRV) · `2C` SpO₂ (block A SpO₂) · `36` stress
   (block A stress) · `3B 01 01` gesture (block B gesture) · `3B 01 00` touch (block B touch) ·
   `06` do not disturb (block B DND) · `19` temperature unit and `3A 03 01` temperature monitor
   (any temperature flag) · `21` goals · `0A` profile · `05 03` wear hand · `26` sedentary
   reminder (block B sedentary).
6. Pull history when stale (§7, §8).

QRing also sends `04` (phone OS — an Android-specific payload), `61` (message-push support
mask) and `0C` (blood-pressure schedule), writes the profile back with `0A 02 …`, and sets a
nickname over large-data `4A`. Jarvis skips all of these.

## 6. Settings, actions and measurements

### Device

| Op | Request | Reply |
|---|---|---|
| `01` | `yy mm dd HH MM SS lang` (BCD; lang `1` = English) | capability block A |
| `03` | — | p0 battery %, p1 `1` = charging |
| `3C` | — | capability block B |
| `2F` | (ring → phone) | p0 large-data chunk size |
| `22` | (ring → phone) | find phone: p0 `1` start, `2` stop |

### Settings

| Op | Read | Write | Read reply |
|---|---|---|---|
| `16` heart-rate monitor | `01` | `02 en(1/2) interval start low high main` | p1 `1` on, p2 interval min, p3 start (`0` means 5), p4 low alert, p5 high alert, p6 main switch, p7 max interval |
| `2C` SpO₂ monitor | `01` | `02 en(1/0)` (optionally `+ interval`) | p1 on, p2 interval |
| `36` stress monitor | `01` | `02 en(1/0)` | p1 on |
| `38` HRV monitor | `01 00 00 00 00 00 00` | `02 en(1/0) 0A code 00 00 00` | p1 on, p2 `0A` = interval supported, p3 interval code |
| `3A` temperature monitor | `03 01` | `03 02 en interval start remind flags custom` | p2 on, p3 interval, p4 start, p5 alert interval, p6 flags, p7 custom threshold |
| `3B` touch / gesture | touch `01 00`, gesture `01 01` | touch `02 00 app sleep`, gesture `02 01 app strength` | p1 `0` touch / `1` gesture, p2 app type (§11), p3 sleep time (touch) or strength (gesture), p4 `1` touch sleep on |
| `06` do not disturb | `01` | `02 en(1/2) sH sM eH eM` | p1 on, p2–p5 window, p6 `1` = manual |
| `19` temperature unit | `01` | `02 01 unit` (`1` °C, `2` °F) | p1 on, p2 unit |
| `21` goals | `01` | `02 steps(3) calories(3) distance(3) sport(2) sleep(2)` | p1–3 steps, p4–6 calories, p7–9 distance m, p10–11 sport min, p12–13 sleep min |
| `0A` profile | `01` | `02 clock units sex age height weight sbp dbp hrAlert open` | p1 clock (`0` 24 h, `1` 12 h), p2 units (`0` metric, `1` imperial), p3 sex (`0` male, `1` female), p4 age, p5 height cm, p6 weight kg, p7 sbp, p8 dbp, p9 heart-rate alert, p10 open |
| `05` wear hand | `03` | — | p1 on, p2 left hand, p3 brightness, p4 max brightness, p5 `≠1` = DND all day, p6–7 start, p8–9 end (only p2 matters on a ring — unverified) |
| `25` / `26` sedentary | `26` | `25 sH sM eH eM week cycle` (BCD times) | p0–p3 window, p4 weekday mask (`0` = off), p5 cycle 30/60/90 min |

- `16`: carry the start, alert and main-switch values from the last read into every write so
  they aren't reset.
- `38`: 60 minutes travels as code `0x60`; other intervals as plain minutes (unverified beyond
  60).
- `3A`: flags b0 low, b1 middle, b2 high, b3 custom threshold; custom byte = °C × 10 − 200.
- `21`: calories are small calories — QRing multiplies the kcal goal by 1000.
- `0A`: QRing stores sex as 1 male / 2 female and sends it minus one.
- `3B 02 02 a b` sets touch sleep (QRing uses it on its prayer screen); Jarvis doesn't.

### Actions

| Op | Payload | Notes |
|---|---|---|
| `50` | `55 AA` | find ring: vibrate/flash; no reply |
| `1E` | `03` | heart-rate keep-alive, every 20 s while measuring heart rate; reply p0 bpm |
| `7E` | `02 inUse counter(2)` | phone still-time, the answer to event `73`/62 |
| `A1` | `06` start, `02` cancel | wearing calibration |
| `08` | `01` | power off — the SDK also names the opcode "reboot" (unverified which); QRing never sends it |
| `FF` | `66 66` | factory reset; no reply |

- `7E`: `inUse` is `1` while the phone is in use (QRing follows screen on/off; Jarvis uses "app
  active"); the counter counts the ring's queries and resets when the phone is back in use.
  Probably a phone-use hint for sleep detection (unverified).
- `A1`: replies carry p0 data type and p9 result; calibration succeeded when data types 1 and 2
  have both reported result `1`. A `73`/12 event reporting charging aborts it. Gated by block B
  p1 b2.

### Measurements (`69` / `6A`)

Start with `69 type action`. Types: 1 heart rate · 2 blood pressure · 3 SpO₂ · 4 fatigue ·
5 health check · 6 real-time heart rate · 7 ECG · 8 stress · 9 blood sugar · 10 HRV ·
11 temperature. The SDK defines actions 1 start, 2 pause, 3 continue, 4 stop, but QRing's
simple start sends `00` for types 1–2 and `25` for the rest; Jarvis does the same for types 1,
2, 3, 5, 8, 9, 10 and 11.

Results arrive as `69` notifications: p0 type, p1 error code, p2 value, p3 systolic, p4
diastolic.

- p1 `1` → the ring is not worn.
- p1 `0` with a non-zero value (systolic/diastolic for blood pressure) → the reading. A health
  check (type 5) keeps sending values for its 30 s window.
- Temperature: Jarvis reads p2 as (°C − 20) × 10 (unverified). Blood-sugar scaling is
  unverified too.

Stop with `6A type value 00` — `6A 02 sbp dbp` for blood pressure, `6A 05 00 00` / `6A 0B 00 00`
for health check and temperature — when a result arrives, on error, after about 60 s, or on
cancel. Heart rate also needs `1E 03` every 20 s. Run one measurement at a time.

## 7. History on the command channel

| Op | Request | Reply |
|---|---|---|
| `48` today | — | steps (3 BE), running steps (3 BE), calories (3 BE, small cal), distance m (3 BE), sport minutes (2 BE) |
| `43` step slots | `day 0F 00 5F 01` | `FF` = no data. Optional header `F0 ? scale` (scale `1` → calories × 10). Records: `yy mm dd` (BCD), slot 0–95 (15 min), packet index, packet total, calories (2), steps (2), distance m (2). Last when index = total − 1. |
| `44` legacy sleep | `day 0F 00 5F` | Framed like `43`; records `yy mm dd slot index total q1 … q7` (meaning of q1–q7 unverified). Rings with block A p8 = 1 use large-data `27` instead. |
| `15` legacy heart rate | u32 timestamp for the day | `00 count interval` · `01 time(4) v×9` · `n v×13`, last when n = count − 1 · `FF` = none. u8 bpm per interval (5 min → 288 per day). Used when block B p7 b3 is clear; timestamp convention unverified. |
| `37` stress / `39` HRV | `day` | `00 count interval` · `01 day v×12` · `n v×13` · `FF` = none. u8 per interval (default 30 min). |
| `14` blood pressure | `00 00 00 00 00 32` | Up to 50 six-byte records: u32 local time, then two u8 values (the SDK reads diastolic first — unverified); `FF FF FF FF` ends the list. |

## 8. History on the large-data channel

| Op | Request | Reply payload |
|---|---|---|
| `27` sleep | `00 01` today, `FF 01` all nights | d0 block count (`0` = none), then blocks `day len start(2) end(2) (stage minutes)…`; the next block starts `len + 2` bytes after the current one begins |
| `3E` naps | arrives with `27` | blocks `day len start(2) end(2) (flag minutes)…`; flag `0` marks the gap between two naps (unverified) |
| `28` manual heart rate / `49` manual SpO₂ | `00` today, `FF` all | d0 days ago, then triples `minute_of_day(2) value(1)` |
| `2A` SpO₂ / `47` blood sugar | `00` | 49-byte records: byte 0 days ago; bytes 1, 3 … 47 are the hourly maxima and bytes 2, 4 … 48 the hourly minima (24 pairs; the hourly reading is unverified) |
| `75` interval heart rate / `5F` interval SpO₂ / `77` interval temperature | `day packet` | d0 day, d1 interval min, d2 packet count, d3 packet index, d4… values. Ask for packet + 1 until index = count − 1; count `0` = empty. Heart rate and SpO₂ are u8; temperature is u16 ÷ 100 °C. |

- **Sleep timing.** end = local midnight of (today − day) + `end` minutes; start = end − the sum
  of stage minutes. QRing ignores the start minute in the header. A night belongs to the day it
  ends.
- **Gating.** `27` when block A p8 = 1; `75` when block B p7 b3; `77` when block B p8 b7. QRing
  never requests `5F`. Whether `day` in `75`/`77` counts forwards or back is unverified.
- Command `27`/`28` (drink reminders, §14) and large-data `27`/`28` are unrelated — different
  channels.

## 9. Capability block A — reply to `01`

| Byte | Meaning |
|---|---|
| p0 | `1` = temperature |
| p1 | watch faces (watch only) |
| p2 | `1` = menstrual tracking |
| p3 | b1 **SpO₂** · b2 **blood pressure** · b4 **one-key health check** · b3 extra feature · b5 weather · b6 WeChat (`0` = supported) · b7 avatar · b0 wallpaper |
| p4–p5, p6–p7 | screen width, height |
| p8 | `1` = **new sleep protocol** (large-data `27`) |
| p9 | max watch faces |
| p10 | b5 app measure · b6 **manual SpO₂** · b0 contacts · b1 lyrics · b2 album · b3 GPS · b4 JieLi music · b7 YaWei |
| p11 | b0 **manual heart rate** · b7 **blood sugar** · b1 e-card · b2 location · b4 music · b5 RTK MCU · b6 e-book |
| p12 | max contacts ÷ 10 (`0` = 20) |
| p13 | b4 **stress** · b5 **HRV** · b0 recording · b1 BP settings · b2 4G · b3 navigation picture |

Bold flags gate Jarvis features; the rest are watch features a ring leaves clear.

## 10. Capability block B — reply to `3C`

p0 is not used; bytes p5 and later matter only when non-zero.

| Byte | Bits |
|---|---|
| p1 | b0 **touch** · b1 prayer features · b2 **wearing calibration** · b3 needs BLE pairing · b6 no screen (QRing then treats the device as a band) · b7 **gesture** |
| p2 | b0 music · b1 short video · b2 page turn · b3 camera · b4 phone call · b5 game · b6 heart rate by tap |
| p3 | b0 **skin temperature** · b2 **sedentary reminder** · b3 drink reminder · b4 no single temperature · b5 message push · b7 AI analysis |
| p4 | b3 gesture DND · b4 touch sleep · b5 "RT11" (ignore the ring's 12/24 h value) · b7 resume services |
| p5 | non-zero = touch-only mode set: b0–b6 as p2 · b7 prayer (touch) |
| p6 | b2 **no take-photo** · b3 lover space · b4 worship · b5 new praise · b6 alarms · b7 **do not disturb** |
| p7 | b0 UV · b1 call reminder · b2 real-time SpO₂ · b3 **real-time heart rate** (history over `75`) · b4 heart-rate alerts · b5 friends · b6 lover interaction · b7 editable temperature interval |
| p8 | b0 no-screen band 24 h · b5 body tag · b6 temperature reminder · b7 **interval temperature** (history over `77`) |
| p9 | b1 ECG · b2 **both temperatures** · b3 breath training · b4 audio · b5 meeting recording · b6 body battery · b7 Wi-Fi import |
| p10 | b0 audio coding · b3 Opus audio |

Jarvis builds the touch-mode list from p2, or from p5 when p5 is non-zero: off always; music
b0, video b1, page turn b2, photo b3 (unless p6 b2), game b5, heart rate b6. A ring reporting
touch or gesture with no mode bits gets music, video, page turn and photo. The exact bit-to-mode
mapping per ring is unverified.

## 11. Touch and gesture app types (`3B`)

| Value | Mode |
|---|---|
| 0 | off |
| 1 | music — tap play/pause, swipe previous/next; as a gesture, next track |
| 2 | short video |
| 3 | tasbih counter (touch only) |
| 4 | page turn |
| 5 | photo — double-tap is the shutter |
| 7 | phone-side game |
| 8 | heart-rate reading on double-tap |
| 10 | couple interaction |

In photo mode the ring sends opcode `02` (p0 `1` entered, `2` shutter, `3` finished); the phone
can send `02 04` enter camera, `02 05` keep awake, `02 06` finish. In music mode keys arrive as
opcode `1D` p0: 1 play/pause, 2 previous, 3 next, 4 volume up, 5 volume down (unverified).

## 12. Device events (`73`)

p0 is the event type; later bytes are its data.

| Type | Data | Meaning |
|---|---|---|
| 1 | — | new heart-rate data (sync today) |
| 2 | — | new blood-pressure data |
| 3 | — | new SpO₂ data (sync today) |
| 4 | — | new step data (sync today) |
| 5, 39 | — | new temperature data (sync today) |
| 12 | p1 battery %, p2 > 0 charging | battery or charging changed |
| 13 | — | new blood-sugar data (sync today) |
| 16 | — | goals changed on the ring (re-read `21`) |
| 17 | p2 | wear hand (unverified) |
| 18 | p1–3 steps, p4–6 calories, p7–9 distance (BE) | live activity |
| 37 | p1–4 u32 BE | tasbih total |
| 40 | — | settings changed (re-read them) |
| 41 | — | ring game event |
| 42 | p1 `1` = on | touch sleep state |
| 43 | — | new HRV data (sync today) |
| 44 | — | new stress data (sync today) |
| 45 | p1: 1 swipe down · 2 swipe up · 3 tap · 4 long press | touch key |
| 48 | — | couple double-tap |
| 49 | p1 bpm | heart rate during the prayer screen |
| 52 | — | alarm fired |
| 55 | p1 bpm | instant heart rate |
| 56 | p2–3 | praise count |
| 61 | p1–2 ÷ 10 | live temperature °C (unverified) |
| 62 | — | phone still-time query — answer with `7E` |
| 63 | p1 | ECG connection event |
| 64 | p1 % | instant SpO₂ |

## 13. Stages and units

- **Sleep stage codes:** `2` light · `3` deep · `4` REM · `5` awake (from how QRing buckets
  stage minutes into its night totals).
- **Energy** is in small calories (1 kcal = 1000) in `48`, `43` (× 10 when the header's scale
  flag is set), `21` and `73`/18. QRing divides by 1000 before showing a value or handing it to
  Health Connect, and multiplies a kcal goal by 1000 before writing `21`.
- **Distance** in metres; sport and sleep goals in minutes.
- **Temperature:** `77` u16 ÷ 100 °C · `73`/61 u16 ÷ 10 °C (unverified) · `3A` threshold byte
  = °C × 10 − 200 · `69` type 11 value = (°C − 20) × 10 (Jarvis's reading; unverified). The `19`
  unit only changes how the ring and QRing present values.
- Heart rate (bpm), SpO₂ (%), HRV (ms) and stress (score) are single unsigned bytes; `0` in a
  series slot means no reading.

## Unverified on hardware

- The block A/B values an R12 really reports, including whether it sets "no screen".
- `08 01`: power off or reboot.
- `73`/61 meaning and scale; `73`/17 wear-hand semantics; `7E` still-time semantics.
- Day index direction for `75`/`5F`/`77`; the timestamp `15` expects.
- Hourly pairing in `2A`/`47`; blood-sugar and temperature scaling for `69`.
- Which touch/gesture modes each capability bit enables.
- Systolic/diastolic order in `14`; nap block layout in `3E`.
- Everything in §14.

## 14. Recipes for commands the app doesn't expose

Send these with the `ring_raw_command` device skill (`confirm: true`). `hex` is the opcode
followed by the payload — the checksum is added, and spaces or colons are ignored. The reply
lists `{channel, cmd, error, payload_hex}` per frame, `payload_hex` being p0…p13 in uppercase
hex. None of these recipes has been tried on an R12: check the capability bit and try a read
before a write.

```json
{"hex": "03", "confirm": true}
```

reads the battery (p0 = percent), which is a safe first test of the raw path.

### Alarms — `23` set, `24` read

Set: `23 idx en hh mm mo tu we th fr sa su` — idx 0–4, en `1` on / `0` off, `hh mm` in BCD,
then one byte per weekday (`1` = ring that day). Read: `24 idx`; the reply has the same layout
from p0. Alarm 0 at 07:30 on weekdays:

```json
{"hex": "23 00 01 07 30 01 01 01 01 01 00 00", "confirm": true}
```

QRing uses a large-data alarm list instead when block B p6 b6 is set: read
`{"big_data_cmd": 44, "payload_hex": "01", "confirm": true}`; write `02 total` followed by one
entry per alarm, `len flags minute_of_day(2) label…`, where the flags combine repeat days and
the on switch (entry layout unverified).

### Drink reminders — `27` set, `28` read

Same layout as alarms with idx 0–7: `27 idx en hh mm mo tu we th fr sa su`; read with `28 idx`.
Gated by block B p3 b3. Reminder 2 at 10:00 every day:

```json
{"hex": "27 02 01 10 00 01 01 01 01 01 01 01", "confirm": true}
```

### Message push — `72`

Text is UTF-8, at most 128 bytes, split into 11-byte chunks, one frame per chunk:
`72 type total index chunk…` with index counting from 1. Types: 0 incoming call · 1 SMS ·
2 QQ · 3 WeChat · 4 call action · 5 Facebook · 6 WhatsApp · 7 Twitter · 8 Skype · 9 Line.
QRing first enables notification categories with `60 FF 9F`. Gated by block B p3 b5; on a
screenless ring expect at most a vibration. The two SDK layers disagree on whether `total` or
`index` comes first (unverified). An SMS reading "Hi":

```json
{"hex": "72 01 01 01 48 69", "confirm": true}
```

### Vibration and light events — `51`

`51 event` plays a stock pattern: 1 double-tap · 2 pairing · 3 miss you · 4 love you · 5 need
you · 6 sad · 7 love letter. Custom light is `51 08 a b c duration e` and custom vibration
`51 09 a b c duration e`, with duration 1–127. The SDK defines light values 0 none, 1 stop,
2 green, 3 red and vibration values 0 none, 1 stop, 2 start, but which of `a`, `b`, `c`, `e`
carries them is unverified. Gated by block B p6 b3 or p7 b6. The double-tap pattern:

```json
{"hex": "51 01", "confirm": true}
```
