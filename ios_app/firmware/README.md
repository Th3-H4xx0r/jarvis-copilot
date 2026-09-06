# Jarvis ESP32 firmware

Firmware for a **DOIT ESP32 DEVKIT V1** that turns the board into a JarvisWearables
device: discoverable and paired over Bluetooth LE, then optionally reachable over Wi‑Fi,
with the onboard LED and every safe GPIO under app (and Jarvis) control.

```
firmware/
  flash.sh                 compile + upload with the arduino-cli bundled in Arduino IDE
  JarvisEsp32/
    JarvisEsp32.ino        BLE server, command dispatch, GPIO state machine
    WifiLink.h/.cpp        Wi‑Fi station, TCP server, mDNS, stored credentials
    ScriptRuntime.h/.cpp   sandboxed Lua runtime for app/Jarvis-written scripts
    src/lua/               Lua 5.4.7 (io, os, debug, package libs removed)
    Protocol.h             frame format, opcodes, CRC — mirrored in Esp32Protocol.swift
    Pins.h                 which GPIOs are exposed and what each can do
    Config.h               name prefix, pairing passkey, timing limits
```

## Flashing

```
./firmware/flash.sh            # compile and upload to the first /dev/cu.usbserial-*
./firmware/flash.sh --verify   # compile only
./firmware/flash.sh --monitor  # upload, then open the 115200-baud serial console
```

Needs Arduino IDE 2.x with the **esp32 by Espressif** core (3.x) installed. The script
builds as the generic `esp32:esp32:esp32` board with the **Huge APP** partition scheme:
the DOIT board definition has no partition menu and BLE + Wi‑Fi together (~1.7 MB) do not
fit the default 1.3 MB app slot. If the upload hangs at `Connecting...`, hold the BOOT
button until bytes start flowing.

After boot the LED blinks once a second while the board is advertising. It stops the
moment the app connects and hands control of the LED to the app.

## Pairing and ownership

The board advertises as `Jarvis-ESP32-XXXX` (last two bytes of its MAC). BLE pairing is
"Just Works": no passkey, because the board has nothing to show one on. Every
characteristic still requires an encrypted, bonded link, so the first time a phone
subscribes iOS shows a plain Pair / Cancel prompt. Once bonded, reconnects are silent.

On top of that the board has a single **owner**. A freshly flashed board is unclaimed:
the first phone to connect over BLE mints a random 16-byte key, sends `CLAIM`, and the
board stores it in NVS. From then on every session on either link must open with
`AUTH` carrying that key, or every other command answers `unauthorized`. The key never
leaves the board and the phone keeps it in the Keychain, so nobody else can drive the
board — not even over Wi‑Fi. **Reflashing resets ownership**: the firmware stores its
build stamp and wipes the claim whenever a different build boots. The Wi‑Fi network and
the Jarvis session are kept.

## Wi‑Fi

Wi‑Fi is provisioned **over the bonded BLE link only**: the app sends SSID and password
with `WIFI_SET`, the board stores them in NVS and joins, and reports `wifi_changed`
with its IP. It also registers `jarvis-esp32-xxxx.local` via mDNS and advertises
`_jarvis-esp32._tcp`.

Over the LAN the board listens on TCP **4711** and speaks the same frames. A client must
send `AUTH` with the owner key as its first frame, within 5 s, or it is dropped. One TCP
client at a time; a new connection replaces a stale one.

In the app, each board has a **Prefer** switch: *Auto* tries Wi‑Fi first and falls back
to Bluetooth, *Wi‑Fi* and *Bluetooth* force one link. Wi‑Fi credentials can only be
changed while connected over Bluetooth; the network is picked from the board's own scan
(`WIFI_SCAN`) and the password entered in a system popup.

Once connected, the app keeps the session across screens and backgrounding until the
**Disconnect** button (top right of the board screen) is tapped. If a link drops, Auto
mode reconnects on the other one: a Bluetooth drop switches to Wi‑Fi, a Wi‑Fi drop
switches to Bluetooth, and while Bluetooth is out of range the app probes the LAN every
20 s. The board itself serves both links at once and pushes events to whichever is up,
so the switch is invisible to it.

## Protocol

`A5 | LEN | OP | PAYLOAD… | CRC8` — LEN counts OP + payload, CRC-8 (poly 0x07) covers
LEN, OP and payload. Responses echo the opcode with bit 7 set and start with a status
byte. Full opcode table in `Protocol.h`.

| Op | Name | Payload |
|---|---|---|
| `01` | PING | → proto, fw major/minor, uptime, MAC, claimed. Allowed before AUTH. |
| `02` | GET_INFO | → pin table: (gpio, capability flags)… |
| `03` | GET_STATE | → (gpio, mode, value)… |
| `10` | LED_SET | 0 off / 1 on / 2 toggle |
| `11` | LED_BLINK | count (0 = stop), period ms |
| `20` | PIN_MODE | gpio, mode (1 out, 2 in, 3 pull-up, 4 pull-down, 5 pwm) |
| `21` | PIN_WRITE | gpio, level |
| `22` | PIN_READ | gpio |
| `23` | PIN_PWM | gpio, duty 0–255 |
| `24` | PIN_PULSE | gpio, level, duration ms (≤ 10 s) |
| `2F` | ALL_OFF | — |
| `40` | WIFI_SET | ssid, password (BLE only) |
| `41` | WIFI_STATUS | → state, ip, rssi, port, hostname, ssid |
| `42` | WIFI_FORGET | (BLE only) |
| `44` | AUTH | owner key — first frame of every session |
| `45` | CLAIM | owner key (BLE only, unclaimed board) |
| `46` | WIFI_SCAN | page → total, page, (rssi, secure, ssid)… or `scanning`, retry |
| `48`–`4A` | CLOUD_SET / STATUS / FORGET | see *Direct link to Jarvis* below |
| `50`–`57` | SCRIPT_* / JARVIS_RESULT | see *Scripting runtime* below |

Events (`E1` input changed, `E2` pulse done, `E3` blink done, `E4` Wi‑Fi changed, `E5`
script output, `E6` jarvis call, `E7` script state, `E8` cloud link changed) are pushed
to every live link.
Frames are up to 243 bytes (`max_body` 240), sized to the BLE MTU the app negotiates.

## Exposed pins

GPIO 2 (LED), 4, 5, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33 as
in/out/PWM; 34, 35, 36, 39 input-only (no pull resistors). GPIO 0, 1, 3 and 6–11 are
never exposed (boot button, serial console, flash). Pins 2, 5, 12, 15 are strapping pins:
fine at runtime, but don't leave them held by external hardware at reset.

## Safety limits

- Pulses are capped at 10 s, blink periods at 50–5000 ms.
- Input edges are debounced 40 ms before an event is sent.
- Outputs keep their state when the phone disconnects. `ALL_OFF` is the safe stop.
- Frames that fail CRC get a status-only reply with opcode `80` and are otherwise ignored.

## Direct link to Jarvis (cloud mode)

Once the board is on Wi‑Fi, the app can hand it its own pairing with JarvisCopilot
(`CLOUD_SET`: server URL, a one-time pairing code the app fetched from
`/api/devices/pair/start`, and the Cloudflare service token). The board claims the code
over HTTPS, stores the session in NVS, and reboots into **cloud mode**: Bluetooth stays
off (BLE and TLS don't both fit in RAM) and `CloudLink` holds the device-bridge
WebSocket (`/api/devices/bridge/ws`), registering the same `esp32_*` skills the app
advertises. Jarvis then invokes and programs the board with no phone involved. Scripts'
`jarvis.notify` becomes a push through `/api/devices/notify`; `jarvis.invoke` becomes a
`/api/background` turn.

The phone still reaches a cloud-mode board over the LAN (TCP 4711). If the server is
unreachable for 5 minutes, or the BOOT button is held for 3 s, the board reboots back
into Bluetooth mode, keeping the session for later. `CLOUD_FORGET` drops it entirely.
TLS chain validation is skipped on the board (no CA bundle in flash); the session cookie
and CF token are the gate.

Needs the **ArduinoJson** library; `flash.sh` installs it.

## Scripting runtime (Lua)

The board embeds a sandboxed **Lua 5.4** interpreter (`ScriptRuntime.*`, sources under
`src/lua/`, built with `LUA_32BITS`). The app — or Jarvis, through the app's
`esp32_upload_script` device skill — uploads a script with `SCRIPT_BEGIN` / `SCRIPT_CHUNK`
/ `SCRIPT_COMMIT`; the board stores it in LittleFS (`/script.lua`), compiles it, and
runs it in its own FreeRTOS task. With `autostart` it runs again after every reboot.

The script is just another client of the command protocol: every `gpio.*` call becomes a
frame through `loop()`, so the GPIO state machine stays single-threaded and scripts can
only reach the same validated pin table the phone can. Limits: 16 KB source, 48 KB heap
(custom allocator), an instruction-count hook for stop, `io`/`os`/`require` removed.

API: `gpio.mode/write/read/pwm/pulse`, `led.set/blink`, `on_input(pin, fn)`,
`every(ms, fn)`, `after(ms, fn)`, `sleep_ms`, `millis`, `print`, `wifi.status()`,
`jarvis.notify(title, body)`, `jarvis.invoke(name, args [, cb])`. Full reference with
examples: `skills/smart-home/jarvis-esp32/SKILL.md` in the JarvisCopilot repo.

`print()` lines and errors reach the app as `E5 script_output`; `jarvis.*` calls reach it
as `E6 jarvis_call` — the app shows `notify` as an iPhone notification immediately and
relays anything else to the Jarvis agent as a background turn (with all its tools),
sending the one-line result back with `JARVIS_RESULT`.

| Op | Name | Payload |
|---|---|---|
| `50` | SCRIPT_BEGIN | total (u16), autostart, name |
| `51` | SCRIPT_CHUNK | offset (u16), bytes |
| `52` | SCRIPT_COMMIT | crc8 of the source → ok, or `script_error` + message |
| `53`/`54` | SCRIPT_STOP / START | — |
| `55` | SCRIPT_STATUS | → state, autostart, size, name, last error |
| `56` | SCRIPT_DELETE | — |
| `57` | JARVIS_RESULT | call_id (u16), ok, text |
