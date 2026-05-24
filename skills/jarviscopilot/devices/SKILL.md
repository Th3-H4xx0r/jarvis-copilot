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

## How pairing works under the hood

The helper script does **not** make HTTP calls to the webui. It writes the pending code straight to `~/.jarviscopilot/webui/.pending_pair.json` (0600), then polls the same file for `claimed=true`. The webui reads from the same file when a browser POSTs `/api/auth/pair/claim`. This avoids needing any kind of host-secret to bootstrap auth.

All other commands (list, revoke, logout, skills, invoke) go through the webui's REST API at `http://localhost:8787` and rely on a local-only carve-out plus the `~/.jarviscopilot/webui/.signing_key` to authenticate as the host.

## Important rules

- **Never quote or paste the user's pairing code into permanent storage** (a memory file, a doc, a commit message). Treat it like a one-time password.
- **Always wait for `claimed`** before telling the user pairing is done. The webui marks codes claimed atomically, so a polled `status=claimed` is authoritative.
- If `pair` returns `status=expired`, just generate a new one — never advise the user that "their device pairing failed" if all that happened is the TTL ran out.
- **Persona styling:** if the user has set a personality (e.g. JARVIS), keep the persona voice. Don't drop into a generic CLI tone just because you're invoking a tool.
