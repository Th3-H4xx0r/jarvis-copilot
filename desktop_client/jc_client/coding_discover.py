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
        {"kind": "transcript", "claude_session_id": <str>, "cwd": <str>,
         "summary": <str>, "last_activity": <float epoch>, "live": <bool>},
        ...
     ]}

Inbound (server -> client)::

    {"type": "coding_discover_request"}   # -> immediate scan + push (no throttle)

Two session ``kind``s ship today: ``"tmux"`` (live sessions, from ``tmux
list-sessions``) and ``"transcript"`` (PAST/resumable sessions, scanned from
Claude Code's own on-disk session store at ``~/.claude/projects``). A
transcript carries ``live=true`` when there is a live tmux session in the same
cwd; the server dedups/links the two.
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

# Transcript (Claude Code session store) scan tunables.
# Claude Code writes transcripts to ``~/.claude/projects/<enc-cwd>/<uuid>.jsonl``.
_TRANSCRIPT_MAX_AGE_DAYS = 30
_TRANSCRIPT_MAX_FILES = 200
# Only the first handful of lines are read per file to recover cwd + a summary;
# the whole transcript is never parsed (mtime carries last_activity).
_TRANSCRIPT_HEAD_LINES = 20
# Don't let a single pathological line blow up memory while reading the head.
_TRANSCRIPT_MAX_LINE_BYTES = 1 << 20  # 1 MiB

# Tab-separated fields, one line per session. Keep in sync with parse_tmux_list.
_TMUX_FORMAT = (
    "#{session_name}\t#{pane_current_path}\t#{pane_current_command}\t"
    "#{session_activity}"
)


# ── pure parsing ──────────────────────────────────────────────────────────────


def tmux_list_argv() -> list:
    """argv for listing tmux sessions in the format ``parse_tmux_list`` expects."""
    return ["tmux", "list-sessions", "-F", _TMUX_FORMAT]


def tmux_resume_argv(tmux_name: str, cwd: str, claude_session_id: str) -> list:
    """argv to (re)launch a past Claude session as a fresh, detached tmux session
    in ``cwd`` via ``claude --resume <id>``. Pure exec (no shell), so the
    server-supplied values can't shell-inject. Next discovery tick reports it as
    a live tmux session, so it becomes drivable from Jarvis."""
    return ["tmux", "new-session", "-d", "-s", tmux_name, "-c", cwd,
            "claude", "--resume", claude_session_id]


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
    """A tmux session we care about: a ``claude`` process, or Jarvis-launched.

    tmux's ``pane_current_command`` is usually the bare basename (``claude``) but
    can be an absolute path when claude was launched by full path (e.g.
    ``/usr/local/bin/claude``) — match on the BASENAME so those aren't dropped.
    A bare interpreter like ``node`` is intentionally NOT a match (too broad);
    those are only kept via the ``jc-`` prefix.
    """
    command = str(sess.get("command") or "")
    tmux_name = str(sess.get("tmux_name") or "")
    cmd_base = os.path.basename(command.strip()) if command else ""
    return cmd_base == "claude" or tmux_name.startswith("jc-")


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


# ── transcript (Claude Code session store) scan ───────────────────────────────


def _extract_cwd_summary(path: str, *, head_lines: int) -> tuple:
    """Read the first ``head_lines`` JSONL records of a transcript CHEAPLY and
    recover ``(cwd, summary)``.

    Claude Code transcripts are JSON-lines; line shapes we handle:

    * Most event lines carry a top-level ``"cwd"`` field (the real working dir);
      decoding the on-disk ``<encoded-cwd>`` dir name is lossy, so we read the
      recorded cwd from the content instead.
    * A ``{"type": "summary", "summary": "..."}`` line gives a short title.
    * Failing that, the first user message — ``{"type": "user", "message":
      {"role": "user", "content": ...}}`` where ``content`` is a string OR a list
      of ``{"type": "text", "text": ...}`` blocks — yields a fallback summary.

    Robust to malformed/partial JSON lines and overlong lines (both skipped).
    Returns ``("", "")`` when nothing is resolvable. Never raises.
    """
    cwd = ""
    summary = ""
    first_user = ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for i, raw in enumerate(fh):
                if i >= head_lines:
                    break
                if len(raw) > _TRANSCRIPT_MAX_LINE_BYTES:
                    continue
                line = raw.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, TypeError):
                    continue  # malformed/partial line -> skip
                if not isinstance(obj, dict):
                    continue
                if not cwd:
                    c = obj.get("cwd")
                    if isinstance(c, str) and c.strip():
                        cwd = c.strip()
                if not summary:
                    if obj.get("type") == "summary":
                        s = obj.get("summary")
                        if isinstance(s, str) and s.strip():
                            summary = s.strip()
                    elif obj.get("type") == "user" and not first_user:
                        txt = _user_text(obj)
                        # Skip Claude Code's slash-command / caveat boilerplate
                        # (``<local-command-caveat>``, ``<command-name>`` …) — it
                        # injects as the first "user" message but isn't real
                        # prose. Keep looking for a genuine user line.
                        if txt and not _is_boilerplate(txt):
                            first_user = txt
                # Once we have a real cwd AND an explicit summary, we can stop
                # early — but keep scanning for cwd if it's still missing.
                if cwd and summary:
                    break
    except (OSError, IOError) as exc:
        log.debug("coding_discover transcript read failed for %s: %s", path, exc)
        return "", ""
    except Exception as exc:  # noqa: BLE001 — discovery must never raise
        log.debug("coding_discover transcript parse failed for %s: %s", path, exc)
        return "", ""
    if not summary:
        summary = first_user
    return cwd, summary


# Slash-command / system wrappers Claude Code injects as the first "user"
# message; these aren't real prose and make a poor summary.
_BOILERPLATE_MARKERS = (
    "<local-command-caveat>",
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "caveat: the messages below were generated by the user",
)


def _is_boilerplate(text: str) -> bool:
    """True if ``text`` is one of Claude Code's injected slash-command/caveat
    wrappers rather than a genuine user message."""
    low = text.lstrip().lower()
    return low.startswith(_BOILERPLATE_MARKERS)


def _user_text(obj: dict) -> str:
    """Best-effort plain text of a user-message JSONL record (see shapes above)."""
    msg = obj.get("message")
    if isinstance(msg, str):
        return msg.strip()
    if not isinstance(msg, dict):
        return ""
    content = msg.get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                t = block.get("text")
                if isinstance(t, str) and t.strip():
                    parts.append(t.strip())
            elif isinstance(block, str) and block.strip():
                parts.append(block.strip())
        if parts:
            return " ".join(parts).strip()
    return ""


def scan_transcripts(home_dir: str, *, now: float, live_cwds=(),
                     max_age_days: int = _TRANSCRIPT_MAX_AGE_DAYS,
                     max_files: int = _TRANSCRIPT_MAX_FILES) -> list:
    """Scan Claude Code's on-disk session store for PAST/resumable sessions.

    Walks ``<home_dir>/.claude/projects/*/*.jsonl``. For each file:

    * ``claude_session_id`` = the filename stem (the session uuid).
    * Files older than ``max_age_days`` (by mtime) are skipped.
    * At most ``max_files`` files are scanned, **newest first**; the rest are
      skipped (it's history, so capping is fine) and the count is LOGGED — never
      silently truncated.
    * The cwd + a short summary are recovered by reading only the first ~20 lines
      (``_extract_cwd_summary``); ``last_activity`` is the file mtime (the whole
      transcript is never parsed).

    Emits ``{"kind": "transcript", "claude_session_id", "cwd", "summary",
    "last_activity", "live"}`` per file, where ``live`` is ``True`` when ``cwd``
    is in ``live_cwds`` (a current tmux session in that dir). Entries with no
    resolvable cwd are skipped. If multiple files map to the same
    ``claude_session_id``, the NEWEST (by mtime) wins.

    Fully defensive: a missing ``~/.claude``, unreadable files, or a huge store
    degrade to ``[]`` / fewer entries — this never raises.
    """
    projects_dir = os.path.join(home_dir or "", ".claude", "projects")
    try:
        if not os.path.isdir(projects_dir):
            return []
    except OSError:
        return []

    try:
        max_age_secs = float(max_age_days) * 86400.0
    except (TypeError, ValueError):
        max_age_secs = _TRANSCRIPT_MAX_AGE_DAYS * 86400.0
    cutoff = now - max_age_secs if max_age_secs > 0 else None

    # Collect (mtime, path) for every fresh-enough transcript.
    candidates: list = []
    try:
        project_dirs = os.listdir(projects_dir)
    except OSError as exc:
        log.debug("coding_discover transcript listdir failed: %s", exc)
        return []
    for pname in project_dirs:
        pdir = os.path.join(projects_dir, pname)
        try:
            if not os.path.isdir(pdir):
                continue
            entries = os.listdir(pdir)
        except OSError:
            continue
        for fname in entries:
            if not fname.endswith(".jsonl"):
                continue
            fpath = os.path.join(pdir, fname)
            try:
                mtime = os.path.getmtime(fpath)
            except OSError:
                continue
            if cutoff is not None and mtime < cutoff:
                continue
            candidates.append((mtime, fpath))

    if not candidates:
        return []

    # Newest first, so capping keeps the most recent history.
    candidates.sort(key=lambda mp: mp[0], reverse=True)
    try:
        cap = int(max_files)
    except (TypeError, ValueError):
        cap = _TRANSCRIPT_MAX_FILES
    if cap >= 0 and len(candidates) > cap:
        skipped = len(candidates) - cap
        log.info(
            "coding_discover transcript scan: capped at %d files, skipped %d "
            "older transcript file(s)", cap, skipped,
        )
        candidates = candidates[:cap]

    live = set()
    for c in (live_cwds or ()):
        if isinstance(c, str) and c.strip():
            live.add(c.strip())

    # Dedup by session id, keeping the newest. ``candidates`` is newest-first,
    # so the first time we see an id wins.
    by_id: dict = {}
    for mtime, fpath in candidates:
        session_id = os.path.splitext(os.path.basename(fpath))[0]
        if not session_id or session_id in by_id:
            continue
        cwd, summary = _extract_cwd_summary(
            fpath, head_lines=_TRANSCRIPT_HEAD_LINES)
        if not cwd:
            continue  # no resolvable cwd -> skip
        by_id[session_id] = {
            "kind": "transcript",
            "claude_session_id": session_id,
            "cwd": cwd,
            "summary": summary or "",
            "last_activity": float(mtime),
            "live": cwd in live,
        }

    return list(by_id.values())


def _sessions_hash(sessions: list) -> str:
    """Stable hash of the normalized session set (order-independent), used to
    suppress duplicate pushes when nothing changed.

    ``last_activity`` is intentionally EXCLUDED — it ticks on every keypress and
    would defeat the throttle. The 30s heartbeat carries freshness instead. Both
    ``tmux`` and ``transcript`` kinds are folded into one stable identity tuple
    keyed on the fields that actually define the session set.
    """
    norm = sorted(
        (str(s.get("kind") or ""),
         str(s.get("tmux_name") or ""),
         str(s.get("claude_session_id") or ""),
         str(s.get("cwd") or ""),
         str(s.get("title") or ""),
         str(s.get("summary") or ""),
         bool(s.get("live")))
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
                 poll_interval: float = _POLL_INTERVAL,
                 home_dir: Optional[str] = None,
                 transcript_max_age_days: int = _TRANSCRIPT_MAX_AGE_DAYS,
                 transcript_max_files: int = _TRANSCRIPT_MAX_FILES):
        self._send = send
        self._device_id = device_id or ""
        self._run = runner or _default_runner
        self._clock = clock
        self._poll = poll_interval
        # Injectable so tests point at a tmp ``~/.claude`` and never the real one.
        self._home_dir = home_dir if home_dir is not None \
            else os.path.expanduser("~")
        self._transcript_max_age_days = transcript_max_age_days
        self._transcript_max_files = transcript_max_files
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
            elif t == "coding_resume":
                self._on_resume(frame)
        except Exception as exc:  # noqa: BLE001 — never bubble into the pump
            log.warning("coding_discover handle_frame failed: %s", exc)

    def _on_resume(self, frame: dict) -> None:
        """Resume a past Claude session the server asked us to revive: launch
        ``tmux new-session … claude --resume <id>`` in its cwd, then re-scan so
        the now-live tmux session is reported and becomes drivable."""
        tmux_name = str(frame.get("tmux_name") or "").strip()
        cwd = str(frame.get("cwd") or "").strip()
        csid = str(frame.get("claude_session_id") or "").strip()
        if not (tmux_name and cwd and csid):
            log.warning("coding_resume: missing tmux_name/cwd/claude_session_id")
            return
        try:
            rc, _out, err = self._run(tmux_resume_argv(tmux_name, cwd, csid))
            if rc not in (0, None):
                log.warning("coding_resume: tmux launch rc=%s: %s", rc, err)
        except Exception as exc:  # noqa: BLE001
            log.warning("coding_resume: launch failed: %s", exc)
            return
        # Report the new live session promptly (bypass the throttle).
        self._scan_and_push(force=True)

    # ── scan + push ─────────────────────────────────────────────────────

    def scan(self) -> list:
        """Return discovered coding sessions in the outbound wire shape.

        The combined set is the LIVE tmux sessions (``kind: "tmux"``) PLUS the
        PAST/resumable transcripts from Claude Code's session store (``kind:
        "transcript"``). The tmux sessions' cwds are passed as ``live_cwds`` so a
        transcript in a currently-live dir is flagged ``live=true`` (the server
        dedups/links a transcript to its live tmux session). Either half degrades
        to ``[]`` independently on error — this never raises."""
        tmux_sessions = self._scan_tmux()
        live_cwds = [s.get("cwd") for s in tmux_sessions if s.get("cwd")]
        transcripts = self._scan_transcripts(live_cwds)
        return tmux_sessions + transcripts

    def _scan_tmux(self) -> list:
        """Live tmux ``claude`` / ``jc-*`` sessions in the wire shape; ``[]`` on
        any error (no tmux, non-zero rc, parse failure)."""
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

    def _scan_transcripts(self, live_cwds) -> list:
        """PAST/resumable transcripts in the wire shape; ``[]`` on any error.

        Defensive wrapper around the pure :func:`scan_transcripts`: a missing
        ``~/.claude``, unreadable files, or a huge store must never wedge the
        poll thread."""
        try:
            return scan_transcripts(
                self._home_dir,
                now=self._clock(),
                live_cwds=live_cwds,
                max_age_days=self._transcript_max_age_days,
                max_files=self._transcript_max_files,
            )
        except Exception as exc:  # noqa: BLE001 — discovery must never raise
            log.debug("coding_discover transcript scan failed: %s", exc)
            return []

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
