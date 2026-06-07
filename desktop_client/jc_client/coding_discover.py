"""Desktop agent that DISCOVERS live coding sessions and pushes them upstream.

Phase 2.1 of Coding Sessions. The jc-client agent periodically scans the device
for live ``claude`` tmux sessions (and Jarvis-launched ``jc-*`` sessions) and
PUSHES them to the server over the existing device-bridge WebSocket, so the
server can surface them as coding sessions the user can attach to.

Mirrors the sibling :class:`~jc_client.coding_sync_mutagen.CodingMutagenAgent`:
takes a ``send`` callback, has a ``handle_frame(frame)`` dispatcher, runs a
background poll thread, and is defensive — it never raises into the WS pump.

Like :mod:`jc_client.coding_mutagen` the subprocess access is split out behind an
injectable ``runner`` and the parsing is a PURE, unit-tested function, so the
tests never touch real tmux or the wall clock.

Wire protocol
-------------
Outbound (client -> server), via ``send``::

    {"type": "coding_discover",
     "device_id": <str or "">,
     "scanned_at": <float epoch>,
     "sessions": [
        {"kind": "tmux", "tmux_name": <str>, "cwd": <str>,
         "title": <str>, "last_activity": <float epoch>},
        ...
     ]}

Inbound (server -> client)::

    {"type": "coding_discover_request"}   # -> immediate scan + push (no throttle)

A future ``kind: "transcript"`` will join ``kind: "tmux"``; the structures are
shaped to allow extra kinds, but only ``"tmux"`` is implemented now.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import subprocess
import threading
import time
from typing import Callable, Optional

log = logging.getLogger(__name__)

_POLL_INTERVAL = 5.0
# Even when nothing changed, re-push at least this often so the server can
# distinguish "still here / fresh" from "client went away / stale".
_HEARTBEAT_SECS = 30.0
# tmux list-sessions can hang if the server is wedged; keep it short.
_TMUX_TIMEOUT = 5

# Tab-separated fields, one line per session. Keep in sync with parse_tmux_list.
_TMUX_FORMAT = (
    "#{session_name}\t#{pane_current_path}\t#{pane_current_command}\t"
    "#{session_activity}"
)


# ── pure parsing ──────────────────────────────────────────────────────────────


def tmux_list_argv() -> list:
    """argv for listing tmux sessions in the format ``parse_tmux_list`` expects."""
    return ["tmux", "list-sessions", "-F", _TMUX_FORMAT]


def parse_tmux_list(stdout: str) -> list:
    """Parse ``tmux list-sessions -F '...'`` output (see ``_TMUX_FORMAT``).

    Each non-blank line is ``name<TAB>cwd<TAB>command<TAB>activity``. Returns a
    list of ``{tmux_name, cwd, command, last_activity(float)}``. Robust to blank
    lines and lines missing trailing fields (those default to "" / 0.0); a line
    with no session name at all is skipped.
    """
    sessions: list = []
    for raw in (stdout or "").splitlines():
        line = raw.rstrip("\r")
        if not line.strip():
            continue
        parts = line.split("\t")
        name = (parts[0] if len(parts) > 0 else "").strip()
        if not name:
            continue
        cwd = (parts[1] if len(parts) > 1 else "").strip()
        command = (parts[2] if len(parts) > 2 else "").strip()
        activity_raw = (parts[3] if len(parts) > 3 else "").strip()
        try:
            last_activity = float(activity_raw) if activity_raw else 0.0
        except (TypeError, ValueError):
            last_activity = 0.0
        sessions.append({
            "tmux_name": name,
            "cwd": cwd,
            "command": command,
            "last_activity": last_activity,
        })
    return sessions


def _is_coding_session(sess: dict) -> bool:
    """A tmux session we care about: a ``claude`` process, or Jarvis-launched."""
    command = str(sess.get("command") or "")
    tmux_name = str(sess.get("tmux_name") or "")
    return command == "claude" or tmux_name.startswith("jc-")


def _to_wire(sess: dict) -> dict:
    """Map a parsed tmux session to the outbound wire shape."""
    cwd = str(sess.get("cwd") or "")
    tmux_name = str(sess.get("tmux_name") or "")
    title = os.path.basename(cwd.rstrip("/")) or cwd or tmux_name
    return {
        "kind": "tmux",
        "tmux_name": tmux_name,
        "cwd": cwd,
        "title": title,
        "last_activity": float(sess.get("last_activity") or 0.0),
    }


def _sessions_hash(sessions: list) -> str:
    """Stable hash of the normalized session set (order-independent), used to
    suppress duplicate pushes when nothing changed.

    ``last_activity`` is intentionally EXCLUDED — it ticks on every keypress and
    would defeat the throttle. The 30s heartbeat carries freshness instead.
    """
    norm = sorted(
        (str(s.get("kind") or ""), str(s.get("tmux_name") or ""),
         str(s.get("cwd") or ""), str(s.get("title") or ""))
        for s in sessions
    )
    blob = json.dumps(norm, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# ── runner ────────────────────────────────────────────────────────────────────

# runner(argv) -> (returncode:int, stdout:str, stderr:str)
Runner = Callable[[list], tuple]


def _default_runner(argv: list) -> tuple:
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           timeout=_TMUX_TIMEOUT)
        return p.returncode, p.stdout or "", p.stderr or ""
    except FileNotFoundError:
        # tmux not installed -> behave like "no sessions".
        return 1, "", "tmux not found"
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"
    except Exception as exc:  # noqa: BLE001 — discovery must never raise
        return 1, "", str(exc)


# ── agent ─────────────────────────────────────────────────────────────────────


class CodingDiscoverAgent:
    """Scans for live coding sessions and pushes them over the bridge.

    Defensive by construction: a wedged/missing tmux, a send failure, or a parse
    hiccup all degrade to "no sessions" / a dropped push — never an exception in
    the WS pump or the poll thread.
    """

    def __init__(self, send: Callable[[dict], None], *,
                 device_id: Optional[str] = None,
                 runner: Optional[Runner] = None,
                 clock: Callable[[], float] = time.time,
                 poll_interval: float = _POLL_INTERVAL):
        self._send = send
        self._device_id = device_id or ""
        self._run = runner or _default_runner
        self._clock = clock
        self._poll = poll_interval
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._last_hash: Optional[str] = None
        self._last_push_at: float = 0.0

    # ── lifecycle ───────────────────────────────────────────────────────

    def start(self) -> None:
        """Begin the background poll loop (idempotent)."""
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
            t = threading.Thread(target=self._poll_loop, daemon=True,
                                 name="coding-discover")
            self._thread = t
            t.start()

    def close(self) -> None:
        """Stop the poll loop. Never raises."""
        self._stop.set()
        with self._lock:
            t = self._thread
            self._thread = None
        if t is not None:
            try:
                t.join(timeout=2.0)
            except Exception:  # noqa: BLE001
                pass

    # ── inbound frames ──────────────────────────────────────────────────

    def handle_frame(self, frame: dict) -> None:
        try:
            t = frame.get("type")
            if t == "coding_discover_request":
                # On-demand: immediate scan + push, bypassing the throttle.
                self._scan_and_push(force=True)
        except Exception as exc:  # noqa: BLE001 — never bubble into the pump
            log.warning("coding_discover handle_frame failed: %s", exc)

    # ── scan + push ─────────────────────────────────────────────────────

    def scan(self) -> list:
        """Return live coding sessions in the outbound wire shape.

        Runs ``tmux list-sessions`` via the runner, parses it, keeps only
        ``claude`` / ``jc-*`` sessions, and maps them to the wire dict. Returns
        ``[]`` on any error (no tmux, non-zero rc, parse failure)."""
        try:
            rc, out, _err = self._run(tmux_list_argv())
        except Exception as exc:  # noqa: BLE001
            log.debug("coding_discover tmux run failed: %s", exc)
            return []
        if rc not in (0, None):
            # No server / no sessions / tmux missing -> nothing to report.
            return []
        try:
            parsed = parse_tmux_list(out)
        except Exception as exc:  # noqa: BLE001
            log.debug("coding_discover parse failed: %s", exc)
            return []
        return [_to_wire(s) for s in parsed if _is_coding_session(s)]

    def _scan_and_push(self, *, force: bool) -> None:
        """Scan; push if forced, the set changed, or the heartbeat elapsed."""
        sessions = self.scan()
        h = _sessions_hash(sessions)
        now = self._clock()
        with self._lock:
            changed = h != self._last_hash
            heartbeat_due = (now - self._last_push_at) >= _HEARTBEAT_SECS
            if not (force or changed or heartbeat_due):
                return
            self._last_hash = h
            self._last_push_at = now
        self._push(sessions, now)

    def _push(self, sessions: list, scanned_at: float) -> None:
        frame = {
            "type": "coding_discover",
            "device_id": self._device_id,
            "scanned_at": float(scanned_at),
            "sessions": sessions,
        }
        try:
            self._send(frame)
        except Exception as exc:  # noqa: BLE001 — a send failure must not break the loop
            log.debug("coding_discover send failed: %s", exc)

    def _poll_loop(self) -> None:
        # Push once immediately so the server learns the current set on connect.
        self._safe_scan_and_push(force=True)
        while not self._stop.wait(self._poll):
            if self._stop.is_set():
                break
            self._safe_scan_and_push(force=False)

    def _safe_scan_and_push(self, *, force: bool) -> None:
        try:
            self._scan_and_push(force=force)
        except Exception as exc:  # noqa: BLE001 — the poll thread must never die
            log.warning("coding_discover scan/push failed: %s", exc)
