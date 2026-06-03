# "JarvisCopilot Runner" Shortcut (OPTIONAL)

**You probably don't need this.** Most phone control is already built into the app as
native device skills that need **zero setup**: `open_app` / `open_url`, `battery_level`,
`get_location`, `clipboard_read` / `clipboard_write`, `flashlight_on` / `flashlight_off`,
`vibrate`, `notify`, `set_alarm`, `play_audio`, `text_to_speech`, `make_call`,
`send_sms`. Just ask JARVIS — no Shortcut involved.

This Shortcut is **only** for the handful of things iOS won't let any app change directly:

- **System toggles:** brightness, volume, Wi-Fi, Bluetooth, Cellular, Focus, Low Power,
  orientation lock.
- **HomeKit scenes.**

If you never need those, skip this entirely. The `phone_control` skill simply returns an
error when the Shortcut isn't installed.

## Easiest install: a one-tap iCloud link (recommended)

Building a Shortcut by hand is tedious, and importing an unsigned file requires enabling
"Allow Untrusted Shortcuts" + AirDrop. The low-friction path is a **signed iCloud link**,
which installs in **one tap** with no settings changes:

1. Build the Shortcut once (steps below) on any iPhone.
2. In Shortcuts: the Shortcut's **⋯ → Share → Copy iCloud Link**. You get a
   `https://www.icloud.com/shortcuts/…` URL.
3. Open that link on any device → **Add Shortcut** (one tap). Done — no "Allow Untrusted",
   no AirDrop. Re-installs and new devices are one tap forever.

The app's `create_shortcut(import_url: <that link>)` skill opens this link directly, so a
future "Set up phone control" button can drive the one-tap add.

> Name it exactly **`JarvisCopilot Runner`** — `phone_control` calls it by that name.

## What it does

JARVIS sends a JSON command as the Shortcut's text input, e.g.
`{"action":"set","setting":"brightness","value":0.5}`. The Shortcut reads `action`,
dispatches, performs the native action, and **Stop and Output**s a JSON result
`{"ok":true,"result":"…"}` that x-callback returns to JARVIS. (Every run briefly flashes
through the Shortcuts app — unavoidable on iOS.)

## Build steps (Shortcuts editor)

1. **New Shortcut** → name it `JarvisCopilot Runner`. First run from a URL → tap **Allow**.
2. **Get Dictionary from Input** → **Get Dictionary Value** `action` → variable `Action`.
3. **If `Action` is `capabilities`** → **Stop and Output** verbatim (keep in sync as you add verbs):

   ```json
   {"ok":true,"version":1,"capabilities":[
     {"action":"set","params":["setting","value"],"desc":"brightness|volume|wifi|bluetooth|cellular|focus|low_power|orientation (brightness/volume 0–1)"},
     {"action":"scene","params":["name"],"desc":"Run a HomeKit scene by name"}
   ]}
   ```

4. **Otherwise If `Action` is `set`** → Get `setting` + `value` → nested If on `setting`:
   *Set Brightness / Set Volume / Set Wi-Fi / Set Bluetooth / Set Cellular Data /
   Set Focus / Set Low Power Mode / Set Orientation Lock* using `value` (brightness/volume
   are 0–1). **Stop and Output** `{"ok":true,"result":"set <setting>"}`.

5. **Otherwise If `Action` is `scene`** → Get `name` → branch per HomeKit scene you want
   (If `name` is "Movie Night" → *Run Home Scene: Movie Night*). **Stop and Output**
   `{"ok":true,"result":"ran <name>"}`.

6. **Final fallback** → **Stop and Output** `{"ok":false,"error":"unknown action"}`.

## Adding a new verb later

Add a top-level `If Action is <verb>` branch (+ its `Stop and Output`), and add a matching
entry to the **capabilities** JSON in step 3. No app rebuild — next time JARVIS calls
`phone_capabilities` (or `{"refresh":true}`) it discovers the new verb.

## Permissions

The first time a branch touches HomeKit or a restricted toggle, iOS prompts — grant it.

## Quick test (after installing)

"Set my brightness to 30%" → `phone_control({action:"set",setting:"brightness",value:0.3})`.
"Run my Movie Night scene" → `phone_control({action:"scene",name:"Movie Night"})`.
(For "open Spotify" / "battery" / "flashlight", no Shortcut is used — those are native.)
