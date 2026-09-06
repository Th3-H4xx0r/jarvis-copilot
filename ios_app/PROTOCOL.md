# VSITOO S1 Pro — BLE protocol

Reverse-engineered from `VSITOO_1.0.141_APKPure`. The app is a DCloud/uni-app hybrid, so
the entire protocol lives in JavaScript, not in the DEX:

| What | Where |
|---|---|
| GATT profile table (per model) | `www/app-service.js` → module `b5538` (`static/js/pages/connect_common/connect_common.js`) |
| Transport / queue / write | `www/app-service.js` → module `ab2d` (`mixins/pagesControlUtils1.js`) |
| S1 Pro control page + notify parser | `www/pagesControl/app-sub-service.js` → module `a5de` (`pagesControl/vsitoo-s1lite/index.vue`) |
| Feature command builders | `common/pagesControlUtils/{ui,aiSelfCleaning,bluetooth,heat}.js`, modules `4501`, `4148`, `c761` |

**The S1 Pro is driven by the `vsitoo-s1lite` page** — `devices.js:gotoControl` routes both
`VSITOO S1 Pro` and `VSITOO S1 Lite` to `pagesControl/vsitoo-s1lite/index`. It is a UV-C
self-sterilizing bottle ("cleaning cup", `isCleaningCup = true`), not a heating cup.

## Discovery

BLE advertised local name matches `/^VSITOO-S1-Pro/` (S1 Lite: `/^VSITOO-S1-Lite/`).

## GATT

Service `0000A300-0000-1000-8000-00805F9B34FB`

| Role | UUID | Notes |
|---|---|---|
| Write | `0000A301-0000-1000-8000-00805F9B34FB` | every command goes here |
| Notify | `0000A303-0000-1000-8000-00805F9B34FB` | every response arrives here |
| OTA | `0000A302-0000-1000-8000-00805F9B34FB` | firmware upgrade only |

## Framing

**There is none.** `bleWrite` takes the hex string, converts each pair to a byte, and writes
the raw bytes. No header, no length, no CRC, no sequence number. Byte 0 is the opcode and
responses echo the same opcode in byte 0.

The app serialises commands: one write in flight, wait for the notify whose opcode matches,
then send the next (500 ms/800 ms/1500 ms timeouts by command class).

## Commands (app → bottle)

Several opcodes are obscured in the bundle by `Wutil.findHexStrFromAllByteValue(decimalString)`,
which splits a **decimal** string into byte values and re-emits them as hex — e.g. `"1501"` →
`0F 01`. Decoded below.

| Hex | Meaning | Payload |
|---|---|---|
| `01 xx` | Drink-reminder master switch | `00` off / `01` on |
| `02 HH MM SS` | Set clock | hex-encoded hour/min/sec |
| `03 ss` | Screen/light on-duration | seconds, 3–15 |
| `05` | Query reminder list, part 1 | — |
| `06` | Query reminder list, part 2 | — |
| `07` | **Query device status** | — (this is `deviceStatusCMD`) |
| `09 <18 bytes>` | Set reminder list, part 1 | mask + 8×(hh,mm), see below |
| `0A <18 bytes>` | Set reminder list, part 2 | mask + 7×(hh,mm) |
| `0B` | Query firmware / hardware version | — |
| `0D 00` / `0D 01` | Auto-sterilise schedule off / on | |
| `0E 00` / `0E 01` | Sterilise now: stop / start | |
| `0F 00` / `0F 01` | Touch lock off / on | (obfuscated as `"1500"`/`"1501"`) |
| `10` | Query MAC address | (obfuscated as `"16"`) |
| `11 00` / `11 01` | UV intensity: normal / strong | (obfuscated as `"17"+ii`) |
| `12 <18 bytes>` | Set auto-sterilise time list | same layout as `09` (obfuscated as `"18"`) |
| `14 00` / `14 01` | Tare / zeroing off, on | (obfuscated as `"2000"`/`"2001"`) |
| `15` | Query auto-sterilise time list | (obfuscated as `"21"`) |
| `17 sw b3 b2 b1 b0` | AI self-clean, timed | `sw` = 00/01, then uint32 **big-endian** seconds remaining |
| `18 00` / `18 01` | AI self-clean, permanent off / on | |
| `01FF` / `02FF` | OTA start / end | firmware only |

### Time-list payload (`09`, `0A`, `12`, and the `05`/`06`/`15` responses)

```
byte 0      : enable bitmask, bit i = slot i is on
byte 1+2i   : hour   (hex of the decimal hour)
byte 2+2i   : minute
```
8 slots per frame, unused slots padded with `FF`, so the payload is always 17 bytes
(1 + 8×2) → 34 hex chars, `.padEnd(36,'F')` in the app including the mask.
`09`/`05` carry slots 0–7, `0A`/`06` carry slots 8–14 (15 reminders max).

## Responses (bottle → app)

Dispatched on byte 0 in `processNotify` (`vsitoo-s1lite/index.vue`).

### `07` — device status (the interesting one)

| Byte | Field |
|---|---|
| 0 | `07` |
| 1 | flags: bit0 = charging, bit1 = reminder enabled |
| 2 | current water temperature, °C |
| 3 | battery, % |
| 4 | screen/light on-duration, seconds |
| 5 | sterilising state (0 = idle, 1 = running) |
| 6 | sterilising progress, % |
| 7 | auto-sterilise enabled (1) |
| 8 | touch lock (1) |
| 9 | cumulative sterilisation count |
| 10 | tared / zeroed (1) |
| 11 | UV intensity (0 = normal, non-zero = strong) |
| 12–15 | AI self-clean seconds remaining, **uint32 big-endian** |
| 16 | AI self-clean switch (1 = on) |
| 17 | AI self-clean is-permanent (1) |

18 bytes total.

On hardware 1.0.1 the progress byte counts **up** (`disinfectCountdownDirection = "ASC"`,
starts at 0); on later hardware it counts **down** from 99.

### `0B` — version

| Byte | Field |
|---|---|
| 0 | `0B` |
| 1 | (sub-op, unused) |
| 2,3,4 | firmware major.minor.patch |
| 5,6,7 | hardware major.minor.patch (absent ⇒ assume 1.0.1) |

### `10` — MAC

The app scans the whole frame for the OUI `A4C1` (falling back to `A4B1`, then `4A4D`) and
takes the following 6 bytes as the MAC.

### `02` — clock set ack
Bottle acked the clock. The app then queries `05`, then `15`.

### `05` / `06` — reminder list parts 1 / 2
Payload from byte 1 on, time-list layout above.

### `15` — auto-sterilise time list
Payload from byte 1 on, time-list layout above. Default when unset is `07:00`.

### `09` / `0A` — reminder-list write ack
The app re-queries `05` on receipt.

## Connection sequence the app performs

1. Scan, match local name `^VSITOO-S1-Pro`.
2. Connect, discover service `A300`, subscribe to `A303`.
3. `07` (status) → `10` (MAC) → `0B` (version).
4. On the `02` clock ack: `05` then `15`.
5. Poll `07` on every UI action and on a 500 ms queue tick.
