# "JarvisCopilot Runner" Shortcut — build + install

## The iOS reality (read this first)

Since **iOS 15**, the Shortcuts app refuses to import any Shortcut that isn't **digitally
signed by Apple**. There is no "Allow Untrusted Shortcuts" toggle anymore, and importing a
raw `.shortcut` file fails with *"Importing unsigned shortcut files is not supported."* So
an app **cannot** ship or generate an installable Shortcut.

The only way to get a signed Shortcut is to **build it once in the Shortcuts editor**, then
**Share → Copy iCloud Link** — Apple signs it on iCloud. That signed link installs in **one
tap** on any device, with no Mac and no toggles. That link is what the app's "Set up phone
control" button will open.

> **You build it once (on the phone, ~5–10 min). After that it's one tap forever.**

## What goes through this Shortcut (vs native)

Native device skills already handle most things with **zero setup** — `battery_level`,
`get_location`, `clipboard_read/write`, `flashlight_on/off`, `vibrate`, `notify`,
`text_to_speech`, `make_call`, `send_sms`. Leave those native.

This Shortcut is for the rest: **open_app, set_alarm, and iOS-locked settings** —
brightness, volume, Wi-Fi, Bluetooth, Cellular, Focus, Low Power, orientation, and HomeKit
scenes.

## How it works

JARVIS sends a JSON command as the Shortcut's text input, e.g.
`{"action":"set","setting":"brightness","value":0.3}`. The Shortcut reads `action`,
dispatches to the matching branch, does the native action, and **Stop and Output**s a JSON
result `{"ok":true,"result":"…"}`. (Each run briefly flashes through the Shortcuts app —
unavoidable on iOS.)

## Build it (Shortcuts editor — start small, expand later)

1. **Shortcuts → ➕ New Shortcut**, rename it exactly **`JarvisCopilot Runner`**.
2. Add **Get Dictionary from Input** (it auto-uses the Shortcut Input).
3. Add **Get Dictionary Value** → type **Value**, Key **`action`**. (This is the requested verb.)

Now add one **If** block per verb you want (search "If", set the condition to the
**Dictionary Value** from step 3, **is**, and the verb text). Start with these two:

**`set` (locked settings — the main reason for this Shortcut):**
- **If** Dictionary Value **is** `set`
  - **Get Dictionary Value** Key `setting`  → (the setting name)
  - **Get Dictionary Value** Key `value`     → (the value, 0–1 for brightness/volume)
  - nested **If** `setting` **is** `brightness` → **Set Brightness** to the `value` variable
  - (repeat the nested If for `volume` → Set Volume, `wifi` → Set Wi-Fi, `focus` → Set Focus,
    `low_power` → Set Low Power Mode, `orientation` → Set Orientation Lock, …)
  - **Stop and Output** Text `{"ok":true,"result":"done"}`

**`open_app`:**
- **If** Dictionary Value **is** `open_app`
  - **Get Dictionary Value** Key `app`
  - **Open App** (pick the app) — *or* for dynamic-by-name, **Open URL** with the `app`
    variable followed by `://` (covers apps with a URL scheme)
  - **Stop and Output** `{"ok":true,"result":"opened"}`

Add more later the same way: `scene` → **Run Home Scene**; `alarm` → **Create Alarm**;
a `capabilities` branch that **Stop and Output**s a JSON list of your verbs (so JARVIS can
auto-discover them).

## Publish for one-tap reuse

Once it works: the Shortcut's **⋯ → Share → Copy iCloud Link**. (If prompted, enable
**Private Sharing** in Settings → Shortcuts.) That `https://www.icloud.com/shortcuts/…`
link installs in one tap and is what the app's "Set up phone control" button opens.

## Test

"Set my brightness to 30%" → `phone_control({action:"set",setting:"brightness",value:0.3})`.
(If 30% comes out far too dim, Set Brightness wants a percentage — multiply the value by 100
in the Shortcut, or have brightness sent as 30.)
"Open Spotify" → `phone_control({action:"open_app",app:"Spotify"})`.
