---
name: jarviscopilot-devices
description: "JarvisCopilot device pairing & management: list paired devices, pair a new one, revoke, and invoke device-exposed skills."
version: 1.0.0
author: JarvisCopilot
license: MIT
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [JarvisCopilot, Devices, Pairing, Auth, Security]
---

# JarvisCopilot — Devices

Manage paired devices and the skills they expose to the server. Use this skill when the user asks about:

- **Pairing a new device** ("pair my phone", "let me sign in from my laptop", "add a new device")
- **Listing devices** ("what's connected?", "show me my devices")
- **Revoking access** ("kick the iPad off", "log out the office laptop", "remove that old phone")
- **Invoking a device-exposed skill** ("send an SMS from my phone", "read the clipboard on my Mac")

All operations go through a single Python helper script that talks to the running webui's REST API. It reuses the same session cookie the WebUI uses, so the agent can call it without any extra credentials.

## Available subcommands

Every command runs through:
```bash
SCRIPT="$(find ~/.jarviscopilot /root /home -path '*skills/jarviscopilot/devices/scripts/devices.py' 2>/dev/null | head -1)"
[ -z "$SCRIPT" ] && SCRIPT="$(find / -path '*skills/jarviscopilot/devices/scripts/devices.py' 2>/dev/null | head -1)"
python3 "$SCRIPT" <subcommand> [args...]
```

### `pair`
Start a pairing flow. Generates a 6-character code, prints it (and the URL to enter it on), and **waits up to TTL seconds** for the user to claim it on the new device.

```bash
python3 "$SCRIPT" pair                    # 10-min TTL, blocks until paired or expired
python3 "$SCRIPT" pair --ttl 300          # custom TTL (60-3600s)
python3 "$SCRIPT" pair --label "kitchen-tablet"
python3 "$SCRIPT" pair --no-wait          # print code + return immediately
```

Output is JSON with `code`, `url`, `expires_at`. When `--no-wait` is omitted, the final line is `{"status":"claimed","device_name":"..."}` or `{"status":"expired"}`.

**When the user says "pair a new device":** run this, tell them the code, and tell them to open the URL. The script polls automatically — when paired you'll see a success line. Confirm to the user.

### `list`
Print every paired device as JSON. Includes `id`, `name`, `ip`, `paired_at`, `user_agent`, and `online` (true if the device's bridge WS is currently connected).

```bash
python3 "$SCRIPT" list
```

### `revoke <device-id-or-name>`
Remove a device's pairing AND invalidate its session. ID prefix or device name (case-insensitive substring) both work.

```bash
python3 "$SCRIPT" revoke 9bda467a
python3 "$SCRIPT" revoke "Pranav's iPhone"
```

### `logout <device-id-or-name>`
Invalidate the session but keep the device record (so the user can re-auth without re-pairing).

```bash
python3 "$SCRIPT" logout "Pranav's iPhone"
```

### `skills`
List every skill currently advertised by a connected device. Useful before invoking.

```bash
python3 "$SCRIPT" skills
```

### `invoke <device> <skill-name> [--json-args '{...}'] [--timeout 30]`
Run one of the device's registered skills and return its result. Synchronous.

```bash
python3 "$SCRIPT" invoke "Pranav's iPhone" send_sms --json-args '{"to":"+1...","body":"on my way"}'
```

If a skill returns an inline image (`img_b64` / `png_b64`), `invoke` automatically writes the bytes to a temp file and replaces the field with `image_path` so the printed JSON stays small. You can hand that path to your vision tool directly.

### `screenshot <device> [options]`
**Preferred way to capture a device's screen.** Calls the `screenshot` skill, saves the image to a file, and prints only `{path, format, width, height, bytes}` — no megabyte of base64 to parse. Use this instead of `invoke ... screenshot` whenever you want to actually look at the screen.

```bash
python3 "$SCRIPT" screenshot "Pranav's Macbook"                   # default: JPEG q=70, max 1400px wide
python3 "$SCRIPT" screenshot mac --out /tmp/x.jpg                 # explicit path
python3 "$SCRIPT" screenshot mac --max-dim 900 --quality 50       # smaller / faster
python3 "$SCRIPT" screenshot mac --region '{"x":0,"y":0,"w":500,"h":400}'
python3 "$SCRIPT" screenshot mac --format png                     # lossless
```

After capture, pass the printed `path` to your vision/image-reading tool (e.g. `browser_navigate file:///<path>` or whatever your environment's image-vision call is). **Do not** try to read the base64 yourself or re-invoke `screenshot` until you've actually inspected the saved file.

**When the user asks "what's on my screen" / "can you see my Mac":** find their Mac in `list`, run `screenshot <device>`, then open the saved path with your vision tool. That's the whole flow — three calls, ~1 second.

## Driving the user's real desktop browser (Chrome)

A paired **Mac** (running the JarvisCopilot client + the Playwright Chrome extension) can drive the user's **real, visible, logged-in Chrome**. Use this whenever the user says "on my Mac", "in my browser", "my real Chrome", or wants you to act on a site they're already signed into — and **not** `open_url` or the server's headless `browser_*`.

**Prefer the direct `chrome_*` agent tools** (`chrome_navigate`, `chrome_snapshot`, `chrome_click`, `chrome_type`, `chrome_press_key`) — they surface automatically when a chrome-capable Mac is online (under lazy tool-loading, `tool_search` for `chrome_navigate` to load them), and they call the Mac directly with server-side snapshot truncation. The `devices invoke chrome_*` form below is the equivalent **fallback** if those tools aren't available.

The fallback loop is just `invoke`. Find the Mac in `list`, then:

```bash
python3 "$SCRIPT" invoke "Pranav's Macbook" chrome_navigate \
  --json-args '{"url":"https://en.wikipedia.org/wiki/Houston"}'
# → returns a SIZE-CAPPED accessibility snapshot with clickable refs like [ref=e47]
python3 "$SCRIPT" invoke "Pranav's Macbook" chrome_click \
  --json-args '{"element":"first article body link","ref":"e47"}'
# → returns the resulting page's snapshot (read the title/links from it)
```

Advertised chrome skills (confirm with `skills`):

- `chrome_navigate {url}` — open a URL; returns the page snapshot with refs (no separate `chrome_snapshot` needed afterward).
- `chrome_snapshot {}` — re-read the current page's snapshot.
- `chrome_click {element, ref}` — click the element with that `ref` (from a recent snapshot); `element` is a human-readable description. Returns the new snapshot.
- `chrome_type {element, ref, text, submit?}` — type into a field; `submit:true` presses Enter.
- `chrome_press_key {key}` — press a key (`Enter`, `PageDown`, …).

Notes:

- Snapshots are size-capped to protect your context. On a huge page you'll see a truncation note — narrow the view (scroll or click into the relevant section, or set `JC_BROWSER_SNAPSHOT_DEPTH` on the client) rather than trying to dump the whole tree.
- Refs (`e47`) belong to the most recent snapshot — re-snapshot if the page changed under you.
- Bot-protected sites (Google / Cloudflare CAPTCHA) defeat any automation. For *finding* things prefer your `web_search` tool; reserve real-Chrome driving for logged-in / non-hostile sites.

## Controlling an iPhone / iPad (iOS)

iOS sandboxes apps hard: there is **no** way to tap/type/swipe in arbitrary apps the way Android accessibility allows. The supported, powerful control surface on iOS is **Shortcuts**, exposed through the `run_shortcut` device skill.

- `run_shortcut` runs a Shortcut **by exact name** and returns its text output:
  ```bash
  python3 "$SCRIPT" invoke "Pranav's iPhone" run_shortcut \
    --json-args '{"name":"Set Low Power Mode","input":"on"}'
  # → {"ran": true, "result": "..."}   (or {"ran": false, "error": "..."})
  ```
- A Shortcut can toggle settings (Low Power Mode, Wi-Fi, Focus, brightness, volume), control **HomeKit** scenes/devices, play/pause media, read battery/location/clipboard, send messages, open apps/URLs, run **SSH/HTTP** requests, and much more. So "control the phone" almost always means "find or build the right Shortcut, then `run_shortcut` it."
- `shortcuts_list` returns `[]` on iOS (Apple exposes no enumeration API). Ask the user which Shortcuts they have, or rely on the **JarvisCopilot Runner** dispatcher Shortcut (below).

### Creating Shortcuts ("set up its own tasks")

An iOS app **cannot install a Shortcut programmatically** — Apple blocks it. Two real ways to give the iPhone a new capability:

1. **Author on the paired Mac → iCloud sync.** If the user also has a paired Mac with iCloud Shortcuts sync on, create/edit the Shortcut there (the Shortcuts app / `shortcuts` CLI live on macOS). It syncs to the iPhone within seconds, then `run_shortcut` can call it. This is the preferred "create a new task" path.
2. **JarvisCopilot Runner (dispatcher).** Ask the user to install the one-time **"JarvisCopilot Runner"** Shortcut (see the mobile app's iOS control setup doc). It takes a JSON command as input and performs it (HTTP callback to the server, SSH to the Mac, set clipboard, show notification, control Home, etc.), so you can drive many tasks through a single installed Shortcut without authoring a new one each time:
   ```bash
   python3 "$SCRIPT" invoke "Pranav's iPhone" run_shortcut \
     --json-args '{"name":"JarvisCopilot Runner","input":"{\"action\":\"set_brightness\",\"value\":0.4}"}'
   ```

If a Shortcut needs to exist but doesn't, tell the user exactly what to create (or create it on their Mac) rather than guessing names — `run_shortcut` fails cleanly with `{"ran": false}` when the name doesn't match.

## Location history ("where was I…")

If the user enabled **Location history** in the mobile app (Settings → "Track my location"), the phone **pushes** a reverse-geocoded GPS fix every ~10 min (and on significant movement) to the server — you don't pull it. Each fix is one JSON line appended to:

```
$HERMES_WEBUI_STATE_DIR/location_history/<device_id>.jsonl
# default: ~/.jarviscopilot/webui/location_history/<device_id>.jsonl
```

Line shape: `{"ts": <epoch s>, "lat", "lng", "accuracy_m", "address": "<resolved street address>"}`.

To answer location questions, read that file directly (you have shell access). Get the device id from `list`, then e.g.:

```bash
DIR="${HERMES_WEBUI_STATE_DIR:-$HOME/.jarviscopilot/webui}/location_history"
FILE="$(ls -t "$DIR"/*.jsonl 2>/dev/null | head -1)"   # or match the device id from `list`
tail -n 50 "$FILE" | jq .                               # recent fixes
# Last known place:
tail -n 1 "$FILE" | jq -r '.address'
# Fixes within a time window (epoch seconds):
jq -c 'select(.ts >= 1716600000 and .ts <= 1716686400)' "$FILE"
```

Timestamps are epoch seconds; convert with `date -r <ts>`. If the file is missing or empty, the user hasn't enabled tracking yet (tell them to turn on "Track my location" in the app) or the phone hasn't reported a fix since. Don't try to `get_location`-poll a backgrounded phone for history — it will time out; the pushed history is the source of truth.

## How pairing works under the hood

The helper script does **not** make HTTP calls to the webui. It writes the pending code straight to `~/.jarviscopilot/webui/.pending_pair.json` (0600), then polls the same file for `claimed=true`. The webui reads from the same file when a browser POSTs `/api/auth/pair/claim`. This avoids needing any kind of host-secret to bootstrap auth.

All other commands (list, revoke, logout, skills, invoke) go through the webui's REST API at `http://localhost:8787` and rely on a local-only carve-out plus the `~/.jarviscopilot/webui/.signing_key` to authenticate as the host.

## Important rules

- **Never quote or paste the user's pairing code into permanent storage** (a memory file, a doc, a commit message). Treat it like a one-time password.
- **Always wait for `claimed`** before telling the user pairing is done. The webui marks codes claimed atomically, so a polled `status=claimed` is authoritative.
- If `pair` returns `status=expired`, just generate a new one — never advise the user that "their device pairing failed" if all that happened is the TTL ran out.
- **Persona styling:** if the user has set a personality (e.g. JARVIS), keep the persona voice. Don't drop into a generic CLI tone just because you're invoking a tool.
