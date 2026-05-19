# JarvisCopilot — Desktop Client

A small background service that pairs your Mac, PC, or Linux box with a JarvisCopilot server and lets the chat agent invoke native skills on the machine.

Examples once paired:

> "open chrome on my laptop" → server tells your laptop to launch Chrome
> "what's on my macbook screen?" → server pulls a screenshot
> "move the cursor to 800, 400 and click" → mouse + keyboard control
> "type 'hello world' into the focused window"
> "lock my windows machine"
> "what's the current volume on my mac?" / "set it to 25"

The client runs in the background, holds a persistent WebSocket to the server, registers a catalogue of skills, and executes whatever the agent invokes.

## Install

**macOS** (and Linux):
```bash
curl -fsSL https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/desktop_client/installers/install-mac.sh | bash
# or
curl -fsSL https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/desktop_client/installers/install-linux.sh | bash
```

**Windows** (PowerShell):
```powershell
irm https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/desktop_client/installers/install-windows.ps1 | iex
```

What the installer does:
- Clones the repo into a per-user dir (`~/.local/share/jc-client` / `~/Library/Application Support/jc-client` / `%LOCALAPPDATA%\Programs\jc-client`)
- Builds a Python venv with `wsproto`, `pynput`, `pyperclip`, `pillow`, `pystray`, `keyring`
- Drops a `jc-client` binary on PATH (`~/.local/bin` / WindowsApps)
- Wires up autostart (LaunchAgent / systemd-user / Startup shortcut)
- Launches the tray which opens the first-run pair dialog

## Pair

1. On the server, run `jarviscopilot pair` (or "+ Pair new device" in the webui). You get a 6-char code.
2. On the client, run `jc-client pair`. A dialog opens. Enter the server URL + the code + a device name.
3. Click **Pair**. The client contacts the server, captures the TLS cert fingerprint, and shows it for you to confirm against `jarviscopilot status` on the server.
4. **Confirm & save**. Credentials land in your OS keychain (or `~/.jarviscopilot-client/config.yaml` mode 0600 if keychain isn't available). The service starts and connects.

Non-interactive (CI / SSH terminals):
```
jc-client pair --server https://1.2.3.4:8787 --code ABC-DEF --name "ci-runner"
```

## Skills shipped with the client

| Skill | What it does |
|---|---|
| `open_url` | Open a URL in the default browser |
| `open_app` | Launch an app by name (mac: `open -a`, Win: `Start-Process`, Linux: `gtk-launch`/PATH) |
| `quit_app` | Quit an app |
| `current_window` / `list_windows` / `focus_window` | Window enumeration + activation |
| `screenshot` | PNG (base64) of the full screen or a region |
| `clipboard_read` / `clipboard_write` | Read/write the system clipboard |
| `notify` | Native desktop notification |
| `system_info` | OS, hostname, arch, Python version |
| `lock_screen` | Lock the workstation |
| `volume_get` / `volume_set` | Master output volume 0–100 |
| `mouse_position` | Current cursor (x, y) |
| `mouse_move` | Move cursor absolute or relative, optionally animated |
| `mouse_click` | Click left/right/middle, optional coordinates and count (double-click etc.) |
| `mouse_scroll` | Wheel scroll dx/dy |
| `mouse_drag` | Press at (x1,y1), drag to (x2,y2), release |
| `type_text` | Type a string into the focused window |
| `key_press` | Tap or hold individual keys / combos (`['cmd','c']`, `['ctrl','alt','t']`, `'enter'`, …) |
| `run_shell` | **OFF by default.** Run a shell command. Enable with `jc-client config set allow_shell true` |

`run_shell` is the only client-side gated skill; the rest are governed by the **server-side per-device skill ACL** that you control from the webui Devices tab.

## CLI

```
jc-client pair               # interactive Tk dialog
jc-client status             # paired server, connection state, # skills
jc-client logs --follow      # tail the rolling log
jc-client start              # foreground (systemd / launchd uses this)
jc-client stop / restart
jc-client skills list        # show what's advertised
jc-client skills disable mouse_click   # hide a skill from the server
jc-client config set allow_shell true  # opt in to run_shell
jc-client tray               # spawn the tray app
jc-client unpair             # wipe credentials
```

## Logs

`~/.jarviscopilot-client/logs/client.log` (5 MB × 5 rotating). Every invoke logs the skill name and a truncated arg summary; tail it during demos with `jc-client logs --follow`.

## Security

- **TLS cert pinned at pairing** — SHA-256 fingerprint stored in config. If the server's cert ever changes, the client refuses to reconnect until you re-pair (and re-confirm the new fingerprint).
- **Session cookie in OS keychain** when available, otherwise 0600 file.
- **Server-side ACL** — paired devices on the server side have a per-device skill allow-list (you can also revoke or log out a device from the Devices tab).
- **`run_shell` is off by default.**
- **No per-call confirmations** in v1 (the autonomous mode you picked). If you want them later, the protocol supports `destructive: true` flags on the manifest and a confirmation round-trip can be bolted on without breaking compatibility.

## Architecture in 50 lines

```
desktop_client/jc_client/
    cli.py          argparse: pair/start/stop/restart/status/logs/skills/config/tray/unpair
    service.py      reconnect loop, register, dispatch invokes (ThreadPoolExecutor)
    protocol.py     wsproto-based WS + lightweight HTTPS (TLS fingerprint capture/pin)
    credentials.py  keyring + config.yaml (atomic 0600 writes)
    pair_ui.py      tkinter dialog with fingerprint confirmation step
    tray.py         pystray menu, status indicator, runs the service in a thread
    logger.py       rotating file + stderr
    skills/
        __init__.py     @skill decorator, registry, manifest builder, invoke()
        common.py       URL / clipboard / notify / screenshot / mouse / keyboard / system_info / run_shell (gated)
        mac.py          open_app / window enum / lock / volume via osascript
        windows.py      same surface via PowerShell + ctypes/user32
        linux.py        same surface via xdotool / wmctrl / pactl / loginctl
```

The protocol on the wire is the same as the server's existing `device_bridge.py` — the client is the WebSocket *client* that connects to that endpoint. Nothing on the server side needed to change.
