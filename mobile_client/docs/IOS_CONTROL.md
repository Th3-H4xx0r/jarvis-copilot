# iOS phone control via Shortcuts

This explains how JarvisCopilot controls an iPhone/iPad, what's actually
possible on iOS, and the one-time setup that unlocks the most capability.

## What iOS allows (and what it doesn't)

iOS sandboxes third-party apps hard. **No App Store app — including this
one — can tap, type, or swipe in other apps, or drive the system UI.**
There is no iOS equivalent of Android's accessibility automation, and a
"configuration profile" does **not** grant an app screen control. Anyone
claiming otherwise is describing jailbreak, a paired-Mac developer rig
(WebDriverAgent/Appium), or full MDM device supervision — see the bottom
of this doc.

The supported, genuinely powerful control surface on iOS is **Shortcuts**.
A Shortcut can:

- toggle settings: Low Power Mode, Wi‑Fi, Bluetooth, Focus, brightness, volume, orientation lock
- control **HomeKit** scenes and accessories (lights, locks, thermostats)
- play/pause/skip media, set the playing app, AirPlay
- read battery, location, clipboard, the current date, device details
- send messages/emails, start calls, open apps and deep-link URLs
- run **SSH** commands (e.g. to your Mac) and **HTTP** requests
- get/set the clipboard, show notifications, speak text, and more

So on iOS, "control my phone" almost always means **"run the right
Shortcut."** JarvisCopilot's `run_shortcut` skill runs a Shortcut by name
and returns its text output to the agent.

## How `run_shortcut` works

The app opens `shortcuts://x-callback-url/run-shortcut?name=…` with an
`x-success` callback pointing back at `jarviscopilot://shortcut-result`.
When the Shortcut finishes, iOS re-opens JarvisCopilot with the Shortcut's
output, which is returned to the agent as:

```json
{ "ran": true, "result": "<the shortcut's output text>" }
```

(or `{ "ran": false, "error": "…" }` on failure/cancel). You'll briefly
see JarvisCopilot → Shortcuts → JarvisCopilot bounce; that round trip is
how the result comes back. iOS exposes **no** API to list your Shortcuts,
so the agent can't enumerate them — tell it the name, or use the Runner
below.

## One-time setup

### 1. Install the "JarvisCopilot Runner" Shortcut (recommended)

The Runner is a single dispatcher Shortcut: the agent passes it a small
JSON command and it performs the task — so you don't have to author a new
Shortcut for everything. Build it once in the Shortcuts app:

1. **Shortcuts → +** (new shortcut), name it exactly **`JarvisCopilot Runner`**.
2. Add **"Get Dictionary from Input"** (so the Shortcut Input is parsed as JSON).
3. Add **"Get Dictionary Value"** → key `action` (from the dictionary above).
4. Add an **If** on `action`, with a branch per task you want. Useful actions:
   - `set_low_power` → **Set Low Power Mode** (read `value` on/off)
   - `set_brightness` → **Set Brightness** to `value`
   - `set_focus` → **Set Focus**
   - `home_scene` → **Run Home Scene** / **Control <accessory>**
   - `speak` → **Speak Text** with `text`
   - `notify` → **Show Notification** with `text`
   - `clipboard_set` → **Copy to Clipboard** `text`
   - `clipboard_get` → **Get Clipboard** → **Stop and Output**
   - `open` → **Open App** / **Open URL** `target`
   - `ssh` → **Run Script Over SSH** to your Mac with `command`
   - `http` → **Get Contents of URL** `url`
5. End each branch with **"Stop and Output"** returning a short text result
   (this is what comes back to the agent).

The agent then calls:

```text
run_shortcut  name="JarvisCopilot Runner"  input={"action":"set_brightness","value":0.4}
```

Add branches over time — the agent will tell you which `action` it wanted
if one is missing.

### 2. Let automations run without prompts (optional)

For event-triggered automations (time of day, arriving home, NFC tag,
opening an app), iOS 17+ lets them **Run Immediately**:

- Shortcuts → **Automation** → your automation → turn **off** "Ask Before
  Running" (tap **Don't Ask**), and turn **off** "Notify When Run" to
  remove the banner.
- Note: automations that touch sensitive data (contacts, location, camera,
  health, Home) still prompt the first time.

### 3. Allow the JarvisCopilot ↔ Shortcuts hand-off

The first time `run_shortcut` runs, iOS may ask to allow JarvisCopilot to
open Shortcuts (and Shortcuts to open JarvisCopilot back). Allow both, or
it can't return results.

## Letting the agent **create** Shortcuts

An iOS app can't install a Shortcut, but the agent can still add new
capabilities two ways:

1. **Author on your paired Mac → iCloud sync.** If you also pair your Mac
   and have iCloud Shortcuts sync on (Settings → your name → iCloud →
   Shortcuts), the agent can build/edit Shortcuts on the Mac. They sync to
   the iPhone within seconds and `run_shortcut` can call them immediately.
   This is the cleanest "make a new task" path.
2. **Extend the Runner.** Ask the agent which `action` it needs, then add
   that one branch to the Runner Shortcut. From then on the agent drives it
   over the existing install.

## The heavy alternative: MDM / Supervision

If you genuinely want device-management control (force-install/remove apps,
lock, wipe, kiosk/single-app mode, enforce restrictions), that requires
**supervising** the device — via Apple Configurator on a Mac or Apple
Business Manager + an MDM server. That changes the device's ownership model,
is overkill for a personal assistant, and **still** does not allow
arbitrary tapping in apps. It's intentionally out of scope here; Shortcuts
is the right tool for assistant-style control.
