# Building the "JarvisCopilot Runner" Shortcut

This is the one-time, on-device companion to the `phone_control` / `phone_capabilities`
device skills. iOS forbids third-party apps from authoring Shortcuts, so you build this
once in the **Shortcuts** app. JARVIS then drives it with JSON commands over the existing
x-callback-url bridge.

> **Name it exactly `JarvisCopilot Runner`** — `phone_control` calls it by that name.

## How it works

JARVIS sends a JSON command as the Shortcut's text input, e.g.
`{"action":"open_app","app":"Spotify"}`. The Shortcut reads `action`, dispatches to the
matching branch, performs the native action, and (for non-launch verbs) **Stop and
Output**s a JSON result `{"ok":true,"result":"…"}` that x-callback returns to JARVIS.

- **Launch verbs** (`open_app`, `open_url`) end by switching apps — you stay in the
  opened app; JARVIS doesn't wait for output.
- **Return verbs** (`set`, `media`, `get`, `scene`, `capabilities`) bounce back to JARVIS
  with their JSON output.

Every run briefly flashes through the Shortcuts app — this is unavoidable on iOS and is
the only sanctioned way for an app to control system settings / open apps / run HomeKit.

## Build steps (Shortcuts editor)

1. **New Shortcut** → rename to `JarvisCopilot Runner`. In its settings (ⓘ), the input is
   passed as text via the URL; the first time JARVIS runs it iOS will ask to allow running
   — tap **Allow**.
2. **Get Dictionary from Input** → then **Get Dictionary Value** `action` → set variable
   `Action`.
3. **If `Action` is `capabilities`** → **Stop and Output** this text verbatim (keep it in
   sync whenever you add a verb):

   ```json
   {"ok":true,"version":1,"capabilities":[
     {"action":"open_app","params":["app"],"desc":"Open an app by name"},
     {"action":"open_url","params":["url"],"desc":"Open a URL"},
     {"action":"set","params":["setting","value"],"desc":"brightness|volume|low_power|wifi|bluetooth|cellular|focus|flashlight|orientation_lock (brightness/volume are 0–1)"},
     {"action":"media","params":["op"],"desc":"play|pause|next|previous"},
     {"action":"get","params":["what"],"desc":"battery|clipboard|location|now_playing"},
     {"action":"scene","params":["name"],"desc":"Run a HomeKit scene by name"}
   ]}
   ```

4. **Otherwise If `Action` is `open_app`** → Get Dictionary Value `app` → look it up in a
   **name→scheme dictionary** you maintain (Text/Dictionary action), e.g.:

   | key        | value             |
   |------------|-------------------|
   | spotify    | `spotify://`      |
   | instagram  | `instagram://`    |
   | slack      | `slack://`        |
   | youtube    | `youtube://`      |
   | maps       | `maps://`         |

   If a value is found → **Open URL** with it. If not found → **Stop and Output**
   `{"ok":false,"error":"unknown app"}`. *(To support a new app: add a row here. Apps with
   no URL scheme can instead get their own `Open App` branch.)*

5. **Otherwise If `Action` is `open_url`** → Get Dictionary Value `url` → **Open URL**.

6. **Otherwise If `Action` is `set`** → Get `setting` + `value` → nested If on `setting`:
   *Set Brightness / Set Volume / Set Low Power Mode / Set Wi-Fi / Set Bluetooth /
   Set Cellular Data / Set Focus / Toggle Flashlight / Set Orientation Lock* using `value`
   (brightness/volume are 0–1). **Stop and Output** `{"ok":true,"result":"set <setting>"}`.

7. **Otherwise If `Action` is `media`** → Get `op` → If `play`/`pause` → *Play/Pause*;
   `next` → *Skip Forward*; `previous` → *Skip Back*. **Stop and Output**
   `{"ok":true,"result":"<op>"}`.

8. **Otherwise If `Action` is `get`** → Get `what` → *Get Battery Level* / *Get Clipboard*
   / *Get Current Location* / *Get Current Song* → **Stop and Output**
   `{"ok":true,"result":"<value>"}`.

9. **Otherwise If `Action` is `scene`** → Get `name` → branch per HomeKit scene you want
   (each: If `name` is "Movie Night" → *Run Home Scene: Movie Night*) → **Stop and Output**
   `{"ok":true,"result":"ran <name>"}`.

10. **Final fallback** (no branch matched) → **Stop and Output**
    `{"ok":false,"error":"unknown action"}`.

## Adding a new verb later (the "dynamic" part)

1. Add a new top-level `If Action is <verb>` branch with its actions + a `Stop and Output`.
2. Add a matching entry to the **capabilities** JSON in step 3.

That's it — no app rebuild. Next time JARVIS calls `phone_capabilities` (or
`phone_capabilities({"refresh":true})`) it discovers the new verb and can use it.

## Permissions

The first time a branch touches HomeKit, Location, or the clipboard, iOS prompts for
access — grant it. Some toggles (e.g. Focus) may ask to confirm on first run.

## Quick test

From JARVIS: "what can my phone do?" → `phone_capabilities` should return the manifest.
Then "open Spotify" (`open_app`), "what's my battery?" (`get battery`), "set brightness to
50%" (`set brightness 0.5`).
