"""JarvisCopilot `pair` and `devices` subcommands.

`jarviscopilot pair`  — generates a one-shot pairing code, renders a TUI
                       showing the code + URL, polls until the device
                       claims (or until TTL expires / user hits Ctrl-C).

`jarviscopilot devices`
  list                 — show paired devices
  revoke <id>          — remove a device record + invalidate its session
  logout <id>          — invalidate the session but keep the device record

The pair flow coordinates with the running webui through a shared 0600
file under STATE_DIR; no HTTP round-trip is required, so the command
works even when the webui itself enforces auth on every endpoint.
"""
from __future__ import annotations

import os
import signal
import socket
import sys
import time
from pathlib import Path
from typing import Optional


# ── colors / TTY helpers ────────────────────────────────────────────────────

def _supports_color() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if not sys.stdout.isatty():
        return False
    return True


_USE_COLOR = _supports_color()


def _c(code: str, s: str) -> str:
    if not _USE_COLOR:
        return s
    return f"\033[{code}m{s}\033[0m"


BOLD = lambda s: _c("1", s)            # noqa: E731
DIM = lambda s: _c("2", s)             # noqa: E731
RED = lambda s: _c("31", s)            # noqa: E731
GREEN = lambda s: _c("32", s)          # noqa: E731
YELLOW = lambda s: _c("33", s)         # noqa: E731
BLUE = lambda s: _c("34", s)           # noqa: E731
CYAN = lambda s: _c("36", s)           # noqa: E731
ORANGE = lambda s: _c("38;5;208", s)   # noqa: E731 — JarvisCopilot accent


# ── webui import shim ───────────────────────────────────────────────────────
# pair_cmd lives in jarviscopilot_cli/, the pairing module lives in webui/api/.
# Both ship from the same repo; add webui/ to sys.path so we can import.

def _ensure_pairing_import():
    """Locate webui/ relative to this file and add it to sys.path.

    The webui directory sits next to jarviscopilot_cli/ in the JarvisCopilot
    repo. Falls back to walking up from the venv-installed location.
    """
    candidates = []
    here = Path(__file__).resolve()
    # repo layout: <repo>/jarviscopilot_cli/pair_cmd.py + <repo>/webui/
    candidates.append(here.parent.parent / "webui")
    # editable install via pip -e: __file__ may be deep in site-packages
    # but the repo root usually has both folders. Walk up looking for it.
    for parent in here.parents:
        cand = parent / "webui"
        if cand.is_dir() and (cand / "api" / "pairing.py").exists():
            candidates.append(cand)
            break
    for cand in candidates:
        if cand.is_dir() and (cand / "api" / "pairing.py").exists():
            sys.path.insert(0, str(cand))
            return
    raise RuntimeError(
        "Could not locate webui/api/pairing.py. "
        "Run from the JarvisCopilot repo or reinstall the venv."
    )


# ── URL detection ───────────────────────────────────────────────────────────

def _detect_lan_url() -> str:
    """Pick the most useful URL to show on the TUI ("the one the user types
    on their phone"). Prefers LAN IP over loopback. Honors env overrides."""
    scheme = "https" if os.environ.get("HERMES_WEBUI_TLS_CERT") else "http"
    # Manual override wins.
    explicit = os.environ.get("JARVISCOPILOT_PAIR_URL", "").strip()
    if explicit:
        return explicit
    port = os.environ.get("HERMES_WEBUI_PORT", "8787")
    host = os.environ.get("HERMES_WEBUI_PUBLIC_HOST", "").strip()
    if not host:
        # Probe an outbound socket to discover the LAN IP without sending.
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            host = s.getsockname()[0]
            s.close()
        except Exception:
            host = "localhost"
    return f"{scheme}://{host}:{port}/pair"


# ── TUI rendering ───────────────────────────────────────────────────────────

_SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]


def _term_width(default: int = 60) -> int:
    try:
        return max(40, os.get_terminal_size().columns)
    except OSError:
        return default


def _hide_cursor():
    if _USE_COLOR:
        sys.stdout.write("\033[?25l")
        sys.stdout.flush()


def _show_cursor():
    if _USE_COLOR:
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()


def _clear_screen():
    if _USE_COLOR:
        sys.stdout.write("\033[2J\033[H")
        sys.stdout.flush()


def _move_home():
    if _USE_COLOR:
        sys.stdout.write("\033[H")
        sys.stdout.flush()


def _format_remaining(seconds: int) -> str:
    m, s = divmod(max(0, int(seconds)), 60)
    return f"{m}:{s:02d}"


def _render_frame(*, code: str, url: str, remaining: int,
                  spinner: str, status: str = "waiting",
                  device_name: str = "", error: str = "") -> str:
    """Build the TUI string in one shot so partial flushes don't tear."""
    width = min(_term_width(), 78)
    inner = width - 4

    def line(s: str = "") -> str:
        # Pad to width-4 (account for "│ " and " │")
        visible = _visible_len(s)
        pad = max(0, inner - visible)
        return "│ " + s + " " * pad + " │"

    top = "╭" + "─" * (width - 2) + "╮"
    bot = "╰" + "─" * (width - 2) + "╯"
    sep = "├" + "─" * (width - 2) + "┤"

    title = ORANGE(BOLD("  JarvisCopilot — Pair a new device"))
    code_pretty = "  ┃  " + BOLD(ORANGE(code)) + "  ┃"

    out = [
        top,
        line(title),
        sep,
        line(DIM("Open this URL on the device you want to pair:")),
        line(CYAN(BOLD("  " + url))),
        line(),
        line(DIM("Then enter this code:")),
        line(code_pretty),
        line(),
    ]
    if status == "waiting":
        out.append(line(DIM("Expires in ") + BOLD(_format_remaining(remaining)) + DIM("  · press Ctrl-C to cancel")))
        out.append(line(spinner + "  " + DIM("Waiting for device...")))
    elif status == "claimed":
        name_disp = device_name or "device"
        out.append(line(GREEN("✓ Paired with ") + BOLD(name_disp)))
        out.append(line(DIM("Session active. Device can now reach the webui.")))
    elif status == "expired":
        out.append(line(YELLOW("⌛ Code expired without a pairing.")))
        out.append(line(DIM("Run `jarviscopilot pair` again to issue a new one.")))
    elif status == "error":
        out.append(line(RED("✗ " + (error or "Unknown error"))))
    out.append(bot)
    return "\n".join(out)


def _visible_len(s: str) -> int:
    """Length of s as displayed, ignoring ANSI escape codes."""
    import re
    return len(re.sub(r"\x1b\[[0-9;]*m", "", s))


# ── pair command ────────────────────────────────────────────────────────────

def cmd_pair(args) -> int:
    """`jarviscopilot pair` entry point."""
    _ensure_pairing_import()
    from api.pairing import (  # type: ignore
        create_pairing_code,
        poll_pairing_code,
        cancel_pairing_code,
        is_pairing_required,
    )

    ttl = int(getattr(args, "ttl", 600) or 600)
    label = (getattr(args, "label", None) or "").strip() or None

    # Heads-up if pairing-required mode isn't on — codes still work for
    # joining when auth is enabled, but the user might be surprised.
    if not is_pairing_required():
        sys.stderr.write(DIM(
            "[pair] Note: JARVISCOPILOT_PAIRING_REQUIRED is not set. Codes "
            "still work, but the webui isn't enforcing auth on every "
            "request. Enable in settings or via env var to lock it down.\n"
        ))

    info = create_pairing_code(label=label, ttl=ttl)
    code = info["code"]
    expires_at = info["expires_at"]
    url = _detect_lan_url()

    # Install Ctrl-C handler that cleans up the pending code so a
    # later browser claim against a code from a cancelled session
    # can't succeed.
    _cancelled = {"flag": False}

    def _on_sigint(signum, frame):
        _cancelled["flag"] = True

    prev_handler = signal.signal(signal.SIGINT, _on_sigint)
    _hide_cursor()
    _clear_screen()

    spin_i = 0
    last_frame_text = ""
    final_status = "expired"
    final_device = ""
    try:
        while True:
            remaining = int(expires_at - time.time())
            if remaining <= 0:
                final_status = "expired"
                break
            spinner = _SPINNER_FRAMES[spin_i % len(_SPINNER_FRAMES)]
            spin_i += 1
            state = poll_pairing_code(code)
            status = state.get("status", "waiting")
            if status == "claimed":
                final_status = "claimed"
                final_device = state.get("device_name") or "device"
                frame = _render_frame(
                    code=code, url=url, remaining=remaining,
                    spinner=spinner, status="claimed",
                    device_name=final_device,
                )
                _move_home()
                sys.stdout.write(frame + "\n")
                sys.stdout.flush()
                break
            if status == "expired" or status == "unknown":
                # "unknown" means file was pruned out from under us (manual
                # delete or another process); treat as expired.
                final_status = "expired"
                break

            frame = _render_frame(
                code=code, url=url, remaining=remaining,
                spinner=spinner, status="waiting",
            )
            if frame != last_frame_text:
                _move_home()
                sys.stdout.write(frame + "\n")
                sys.stdout.flush()
                last_frame_text = frame

            if _cancelled["flag"]:
                break

            # 500ms tick — responsive without hammering the file.
            time.sleep(0.5)
    finally:
        signal.signal(signal.SIGINT, prev_handler)
        _show_cursor()

    if _cancelled["flag"]:
        cancel_pairing_code(code)
        print(YELLOW("\nCancelled. Pairing code invalidated."))
        return 130

    if final_status == "expired":
        cancel_pairing_code(code)
        # Final frame so the user sees an explicit expiry message.
        sys.stdout.write(_render_frame(
            code=code, url=url, remaining=0,
            spinner=" ", status="expired",
        ) + "\n")
        return 1

    return 0


# ── devices command ────────────────────────────────────────────────────────

def cmd_devices(args) -> int:
    """`jarviscopilot devices {list,revoke,logout}` entry point."""
    _ensure_pairing_import()
    from api.pairing import list_devices, revoke_device  # type: ignore

    sub = getattr(args, "devices_command", None) or "list"
    if sub == "list":
        rows = list_devices()
        if not rows:
            print(DIM("No devices paired yet. Run `jarviscopilot pair` to add one."))
            return 0
        # Header
        print(BOLD(f"{'ID':<12}  {'NAME':<20}  {'IP':<16}  {'PAIRED':<19}  USER-AGENT"))
        for d in rows:
            ts = _fmt_ts(d.get("paired_at", 0))
            ua = (d.get("user_agent", "") or "")[:40]
            print(f"{d.get('id','')[:10]:<12}  "
                  f"{(d.get('name','') or '')[:20]:<20}  "
                  f"{(d.get('ip','') or '')[:16]:<16}  "
                  f"{ts:<19}  {ua}")
        return 0

    if sub == "revoke":
        dev_id = getattr(args, "device_id", "") or ""
        if not dev_id:
            print(RED("device id required"), file=sys.stderr)
            return 2
        # Best-effort: also invalidate any session matching this device's prefix.
        _invalidate_session_for_device(dev_id)
        if revoke_device(dev_id):
            print(GREEN(f"✓ Revoked device {dev_id[:10]}"))
            return 0
        print(RED(f"No device with id {dev_id!r}"), file=sys.stderr)
        return 1

    if sub == "logout":
        dev_id = getattr(args, "device_id", "") or ""
        if not dev_id:
            print(RED("device id required"), file=sys.stderr)
            return 2
        if _invalidate_session_for_device(dev_id):
            print(GREEN(f"✓ Session for {dev_id[:10]} invalidated. Device remains paired and can re-auth."))
            return 0
        print(YELLOW("No active session found for that device (already logged out)."))
        return 0

    print(RED(f"Unknown subcommand: {sub}"), file=sys.stderr)
    return 2


def _invalidate_session_for_device(dev_id: str) -> bool:
    """Remove any auth session whose token prefix matches the device's
    recorded session_prefix. Returns True if a session was removed."""
    try:
        from api.pairing import list_devices  # type: ignore
        from api.auth import _sessions, _save_sessions  # type: ignore
    except Exception:
        return False
    target = None
    for d in list_devices():
        if d.get("id") == dev_id:
            target = d.get("session_prefix")
            break
    if not target:
        return False
    removed = False
    for tok in list(_sessions.keys()):
        if tok.startswith(target):
            _sessions.pop(tok, None)
            removed = True
    if removed:
        _save_sessions(_sessions)
    return removed


def _fmt_ts(ts) -> str:
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(float(ts)))
    except Exception:
        return "-"
