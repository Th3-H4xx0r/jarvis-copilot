---
name: jarvis-esp32
description: "Program a Jarvis ESP32 DevKit V1 board paired through the JarvisWearables iOS app: drive its GPIOs directly, or write a Lua script that runs on the board and can notify the user or call back into Jarvis."
version: 1.0.0
author: pranav
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [Smart-Home, IoT, ESP32, Bluetooth, Wi-Fi, Automation]
---

# Jarvis ESP32

The **JarvisWearables** iOS app pairs to this server as a device and exposes every
ESP32 board it is connected to (over Bluetooth or Wi‑Fi). The board runs the Jarvis
firmware: a fixed base that owns the radios, security and a validated GPIO table, plus a
**sandboxed Lua runtime** you program by uploading a script. You never reflash the board.

Board: DOIT ESP32 DEVKIT V1. Onboard blue LED on GPIO 2.

## Discovering it

```bash
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py list
python3 ~/.jarviscopilot/skills/jarviscopilot/devices/scripts/devices.py skills
```

The board shows as model `Jarvis ESP32 DevKit V1` with `esp32_*` skills. Every skill
takes an optional `device_id`; omit it when only one board is connected. Start with
`esp32_get_state` — it returns the pin table (what each GPIO can do) and the script state.

Do not gate on `bridge_connected`; check `invokable`.

## Direct control skills

| Skill | Arguments | Notes |
|---|---|---|
| `esp32_get_state` | — | Pins with capabilities, mode and level; Wi‑Fi; script state. Safe. |
| `esp32_set_led` | `on` (bool) | Onboard LED. |
| `esp32_blink_led` | `count`, `period_ms` | |
| `esp32_write_pin` | `gpio`, `high` (bool) | Switches the pin to output. |
| `esp32_read_pin` | `gpio` | |
| `esp32_set_pin_mode` | `gpio`, `mode`: `output` \| `input` \| `input_pullup` \| `input_pulldown` \| `pwm` | |
| `esp32_set_pwm` | `gpio`, `duty` 0–255 | |
| `esp32_pulse_pin` | `gpio`, `high`, `duration_ms` ≤ 10000 | Momentary buttons, relays. |
| `esp32_all_off` | — | Safe stop: every output low, timers cancelled. |

Direct control is for one-off actions while the phone is connected. Anything that must
**keep working on its own** — sensors, schedules, reactions — belongs in a script.

## Programming the board

| Skill | Arguments | Notes |
|---|---|---|
| `esp32_upload_script` | `source` (Lua), `name`, `autostart` (default true) | Replaces the current script, compiles, starts. Returns `{ok:false, compile_error}` on a syntax error — fix and resend. |
| `esp32_script_status` | `log_lines` | State (`none/stopped/running/finished/error`), last error, recent console lines. |
| `esp32_script_control` | `action`: `start` \| `stop` \| `delete` | |

Scripts persist on the board and restart after a reboot when `autostart` is true.
Only **one** script is stored at a time; to add behaviour, resend the whole script.

### Lua API (Lua 5.4, `string`/`table`/`math`/`utf8` available; no `io`/`os`/`require`)

```lua
gpio.mode(pin, "output" | "input" | "input_pullup" | "input_pulldown" | "pwm")
gpio.write(pin, 1)          -- or true/false
gpio.read(pin)              -- → 0 or 1
gpio.pwm(pin, duty)         -- 0–255
gpio.pulse(pin, level, ms)  -- drive `level` for ms, then back (≤ 10000)
led.set(true)               -- onboard LED
led.blink(count, period_ms)

on_input(pin, function(level) ... end)  -- debounced edge callback; pin must be an input mode
every(ms, fn)               -- repeating timer (≥ 10 ms)
after(ms, fn)               -- one-shot timer
sleep_ms(ms)                -- inside a callback only; keep it short
millis()
print(...)                  -- appears in the app console and esp32_script_status

jarvis.notify(title, body)  -- an iPhone notification, delivered by the app immediately
jarvis.invoke(name, args_table [, function(ok, text) ... end])
                            -- ask Jarvis (you) to do `name` with `args`; runs as a
                            -- background turn with all your tools; callback gets one line
wifi.status()               -- { state, ip, rssi, hostname, ssid }
```

The script's top level runs once; then the board keeps it alive while any `on_input`,
`every`, `after` or pending `jarvis.invoke` callback exists. With none left it reports
`finished`. Callbacks run one at a time; a runtime error stops the script and its message
shows in `esp32_script_status`.

Limits: 16 KB source, ~48 KB heap, one `jarvis.invoke` payload ≤ ~190 bytes.

### Pins you may use

`2` (LED), `4, 5, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33` as
input/output/PWM; `34, 35, 36, 39` input-only with **no internal pull resistors**.
Pins `2, 5, 12, 15` are strapping pins: fine at runtime, avoid for anything held at boot.
Never suggest GPIO 0, 1, 3 or 6–11. Prefer `4, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33`.

For a switch or reed sensor to ground, use `input_pullup`: the pin reads `1` open and
`0` closed. Ask the user which pin the sensor is on if they haven't said.

### Example: door sensor with a notification

```lua
-- Reed switch between GPIO 4 and GND. Closed door = switch closed = 0.
local PIN = 4
gpio.mode(PIN, "input_pullup")
local last = gpio.read(PIN)

on_input(PIN, function(level)
  if level == 1 and last == 0 then
    jarvis.notify("Front door", "The door just opened")
    led.blink(3, 200)
  end
  last = level
end)

-- Heartbeat so the console shows it is alive.
every(60000, function() print("door sensor alive, door=" .. (gpio.read(PIN) == 1 and "open" or "closed")) end)
```

### Example: asking Jarvis to act

```lua
on_input(27, function(level)
  if level == 0 then
    jarvis.invoke("send_message", { channel = "telegram", text = "Doorbell pressed" },
      function(ok, text) print("jarvis:", ok, text) end)
  end
end)
```

`jarvis.invoke` arrives to you as a prompt like *"The Jarvis ESP32 board … requests the
action `send_message` with arguments {...}. Carry it out with your tools…"* — do it, then
reply with one line; that line is what the script's callback receives.

## Workflow

1. `esp32_get_state` to confirm the board is reachable and see its pins.
2. Write the script. Keep it small and self-explanatory; comment the wiring assumptions.
3. `esp32_upload_script` with a short `name`. If `compile_error` comes back, fix it.
4. `esp32_script_status` after a few seconds to confirm `running` and read the console.
5. Tell the user what was installed, the wiring it assumes, and how to test it.

Chat turns from the app arrive prefixed with `[JarvisWearables board programming. …]`
naming the device and its pins — use that `device_id`.

## Troubleshooting

- Skills missing → the app isn't connected to the board, or the board isn't shared. The
  user turns on Bridge mode and "Share with Jarvis" in the app.
- `esp32_upload_script` times out → the app lost the board mid-upload; retry once.
- Script `error` state → read `esp32_script_status`; the message is Lua's own.
- Notifications need the user to allow them the first time a script calls `jarvis.notify`.
