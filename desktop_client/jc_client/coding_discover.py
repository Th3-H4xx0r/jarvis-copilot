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
         "title": <str>, "last_activity": <float epoch>,
         "claude_session_id": <str|absent>},   # the cwd's newest transcript id

        {"kind": "transcript", "claude_session_id": <str>, "cwd": <str>,
         "summary": <str>, "last_activity": <float epoch>, "live": <bool>},
        ...
     ]}

Inbound (server -> client)::

    {"type": "coding_discover_request"}   # -> immediate scan + push (no throttle)

    {"type": "coding_transcript_get",     # -> stream the named transcript back
     "req_id": <str>, "claude_session_id": <str>, "cwd": <str>}

The ``coding_transcript_get`` request asks this device to ship a past session's
on-disk ``.jsonl`` transcript so the SERVER can resume it (resume runs on the
server now — the device's only job is to send the file). The reply streams one
or more::

    {"type": "coding_transcript_data", "req_id": <str>, "claude_session_id": <str>,
     "seq": <int 0-based>, "eof": <bool>, "content_b64": <str>}

chunks whose concatenated base64 decodes to the GZIP-compressed transcript
bytes; on failure a single::

    {"type": "coding_transcript_data", "req_id": <str>, "ok": false, "error": <str>}

Two session ``kind``s ship today: ``"tmux"`` (live sessions, from ``tmux
list-sessions``) and ``"transcript"`` (PAST/resumable sessions, scanned from
Claude Code's own on-disk session store at ``~/.claude/projects``). A
transcript carries ``live=true`` when there is a live tmux session in the same
cwd; the server dedups/links the two. Discovery only surfaces REAL work:
sessions/transcripts whose cwd is hidden, deleted, or otherwise not an existing
directory on this machine are filtered out.
"""
from __future__ import annotations

import base64
import glob
import gzip
import hashlib
import json
import logging
import os
import re
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

# Transcript-send (coding_transcript_get) tunables.
# Hard cap on a transcript we'll ship; bigger -> ``ok:false, "transcript too large"``.
_TRANSCRIPT_GET_MAX_BYTES = 64 * 1024 * 1024  # 64 MiB
# Each ``coding_transcript_data`` frame carries at most this many base64 chars.
_TRANSCRIPT_CHUNK_B64 = 256 * 1024  # ~256 KiB of base64

# Transcript-RECEIVE (coding_transcript_put) tunables. The SERVER pushes a
# session's transcript to this device at session OPEN/CLOSE (one-shot, not live)
# so a later local `claude --resume` sees the other side's turns. Cap buffered
# COMPRESSED bytes/stream, concurrent streams, AND the inflated size (anti-bomb).
_TRANSCRIPT_PUT_MAX_GZ_BYTES = 96 * 1024 * 1024  # buffered gzip bytes per stream
_TRANSCRIPT_PUT_MAX_STREAMS = 8
_TRANSCRIPT_PUT_MAX_RAW_BYTES = 64 * 1024 * 1024  # hard cap on inflated bytes

# Tab-separated fields, one line per session. Keep in sync with parse_tmux_list.
_TMUX_FORMAT = (
    "#{session_name}\t#{pane_current_path}\t#{pane_current_command}\t"
    "#{session_activity}"
)


# ── pure parsing ──────────────────────────────────────────────────────────────


def tmux_list_argv() -> list:
    """argv for listing tmux sessions in the format ``parse_tmux_list`` expects."""
    return ["tmux", "list-sessions", "-F", _TMUX_FORMAT]


def tmux_capture_argv(tmux_name: str, lines: int = 80) -> list:
    """argv to print the last ``lines`` rows of a tmux pane to stdout (for live
    activity classification). ``-p`` -> stdout; ``-S -N`` includes N scrollback
    rows so a prompt that scrolled up a line is still seen."""
    return ["tmux", "capture-pane", "-p", "-t", tmux_name, "-S", f"-{lines}"]


# ── live activity_state classifier ─────────────────────────────────────────────
# Replicated VERBATIM from ``agent/coding_activity_state.classify_pane`` — the
# desktop client can't import ``agent/``. KEEP THE TWO IN SYNC. working = Claude
# is processing ("esc to interrupt"); waiting = blocked on the user (a permission
# / choice prompt); idle = at rest. Precedence: waiting > working > idle.
# Classify from the bottom _TAIL_LINES (the LIVE UI) only — NOT scrollback — so a
# marker in claude's own output or an echoed user message can't fake a prompt.
# KEEP IN SYNC with agent/coding_activity_state.
_TAIL_LINES = 15
_WAITING_MARKERS = (
    "do you want to proceed", "do you want to run",
    "do you want to make this edit", "do you want to create",
    "do you want to delete", "would you like to proceed",
    "(y/n)", "press enter to continue",
    "esc to cancel", "enter to select",   # selection-popup footer
)
_WORKING_MARKERS = (
    "esc to interrupt", "esc to stop", "ctrl+b to run in background",
)
# The live spinner status line — a parenthesized elapsed time + middot, e.g.
# "(35s · ↑ 2.4k tokens · …)". Present in standard Claude AND custom forks (whose
# verb/suffix differ but this prefix doesn't), so it's the robust "working"
# signal — more reliable than "esc to interrupt", which some forks omit.
_WORKING_SPINNER_RE = re.compile(r"\(\d[\dhms\s]*·")


def _live_tail(text: str) -> str:
    lines = text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines[-_TAIL_LINES:])


def classify_pane(text: str) -> str:
    """Return ``"working" | "waiting" | "idle"`` for a captured tmux pane."""
    if not text:
        return "idle"
    # WAITING from the live TAIL only (its markers can appear in scrollback /
    # echoed user messages); WORKING from the WHOLE pane (a long tool's output
    # scrolls the spinner above the tail, but the session is still working — and
    # the spinner never appears in prose). KEEP IN SYNC with
    # agent/coding_activity_state.classify_pane.
    if any(m in _live_tail(text).lower() for m in _WAITING_MARKERS):
        return "waiting"
    low = text.lower()
    if any(m in low for m in _WORKING_MARKERS) or _WORKING_SPINNER_RE.search(text):
        return "working"
    return "idle"


# Distinctive Claude Code TUI strings. A tmux session whose pane contains any of
# these IS a Claude session even when ``pane_current_command`` is NOT "claude"
# (e.g. Claude is mid-tool, so the pane's foreground process is the tool, or the
# session was started by full path). Used to keep working sessions from
# vanishing from discovery while a tool runs.
_CLAUDE_PANE_MARKERS = (
    "esc to interrupt",
    "esc to stop",
    "for shortcuts",          # the idle footer "? for shortcuts"
    "shift+tab to cycle",     # the permission-mode cycler footer
    "bypass permissions",     # matches "bypass permissions on" / "bypassing…"
    "accept edits",           # "⏵⏵ accept edits on/off"
    "plan mode on",           # the plan-mode footer
    "auto-compact",           # "Context left until auto-compact"
    "welcome to claude",
    "/help for help",
)

# Cap pane-probes of NON-command-matched sessions per scan (claude/jc- sessions
# are always captured for classification; this only bounds probing other shells).
_MAX_PANE_PROBES = 24


def is_claude_pane(text: str) -> bool:
    """True if a captured pane looks like a live Claude Code TUI."""
    if not text:
        return False
    low = text.lower()
    return any(m in low for m in _CLAUDE_PANE_MARKERS)


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


def _cwd_is_visible_dir(cwd: str) -> bool:
    """True if ``cwd`` is a non-empty path that EXISTS as a directory on this
    machine and whose basename is not hidden (dot-prefixed).

    Discovery uses this to drop junk: throwaway tmux sessions and stale
    transcripts whose cwd is hidden (e.g. ``~/.config/...``, a ``.HIDDEN`` test
    dir), was deleted, or is empty must NOT resurrect as a real project. Never
    raises (a stat error / odd path -> ``False``)."""
    if not cwd:
        return False
    try:
        base = os.path.basename(cwd.rstrip("/"))
        if base.startswith("."):
            return False
        return os.path.isdir(cwd)
    except (OSError, ValueError):
        return False


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


def _enrich_tmux_with_csids(tmux_sessions: list, transcripts: list) -> None:
    """Stamp each live tmux session with the ``claude_session_id`` of the NEWEST
    transcript in the SAME cwd (in place).

    A bare tmux discovery item carries no session id, so if the Mac goes offline
    the server can't resume that row (no id to ``--resume``). Claude writes a
    transcript per live session in the same cwd, so the newest transcript's id IS
    the session running in that tmux — copy it across so one row serves both
    ADOPT (live attach) and RESUME-to-server (offline fallback)."""
    by_cwd: dict = {}
    for tr in transcripts or []:
        if not isinstance(tr, dict):
            continue
        csid = (tr.get("claude_session_id") or "").strip()
        cwd = _norm_cwd(tr.get("cwd") or "")
        if not (csid and cwd):
            continue
        ts = float(tr.get("last_activity") or 0.0)
        prev = by_cwd.get(cwd)
        if prev is None or ts >= prev[0]:
            by_cwd[cwd] = (ts, csid)
    for s in tmux_sessions or []:
        if not isinstance(s, dict) or s.get("claude_session_id"):
            continue
        hit = by_cwd.get(_norm_cwd(s.get("cwd") or ""))
        if hit:
            s["claude_session_id"] = hit[1]


# ── transcript (Claude Code session store) scan ───────────────────────────────


# Chunk size for the bounded head reader.
_TRANSCRIPT_READ_CHUNK = 1 << 16  # 64 KiB


def _iter_head_lines(fh, *, head_lines: int, max_line_bytes: int):
    """Yield up to ``head_lines`` logical lines from binary file ``fh`` WITHOUT
    ever buffering more than ~``max_line_bytes`` at a time.

    Claude Code transcripts can contain a single multi-megabyte (or larger) JSONL
    line — a pasted file, a base64 image, a big tool result. Iterating the file
    object directly (``for line in fh``) reads the WHOLE line up to the next
    ``\\n`` into memory BEFORE any length check can skip it, so a pathological
    line (worst case: no newline at all) would read the entire file into RAM and
    block the poll thread. This reader instead pulls fixed-size chunks and yields
    ``(text, overlong)`` per logical line, draining (and discarding) any line that
    exceeds the cap so memory stays bounded and we never read past ``head_lines``
    real newlines worth of content. ``text`` is decoded UTF-8 (errors replaced);
    for an overlong line ``text`` is ``""`` and ``overlong`` is ``True``.
    """
    emitted = 0
    buf = b""
    overflowed = False  # current logical line already blew past the cap
    while emitted < head_lines:
        chunk = fh.read(_TRANSCRIPT_READ_CHUNK)
        if not chunk:
            break
        buf += chunk
        while True:
            nl = buf.find(b"\n")
            if nl == -1:
                # No complete line yet. If what we're holding already exceeds the
                # cap, this line is overlong: drop the buffer (drain) and remember
                # so we skip everything until the terminating newline.
                if len(buf) > max_line_bytes:
                    overflowed = True
                    buf = b""
                break
            raw = buf[:nl]
            buf = buf[nl + 1:]
            if overflowed or len(raw) > max_line_bytes:
                # Overlong line (possibly spanning several chunks) -> skip it.
                overflowed = False
                emitted += 1
                yield "", True
            else:
                emitted += 1
                yield raw.decode("utf-8", "replace"), False
            if emitted >= head_lines:
                break
    # A trailing line with no final newline: surface it too (if not overlong and
    # we still have budget) so a tiny single-line transcript isn't missed.
    if emitted < head_lines and buf and not overflowed:
        if len(buf) <= max_line_bytes:
            yield buf.decode("utf-8", "replace"), False
        else:
            yield "", True


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
        # Binary + a bounded reader so a single pathological (multi-MB / no-newline)
        # line can't read the whole file into memory and wedge the poll thread.
        with open(path, "rb") as fh:
            for raw_text, overlong in _iter_head_lines(
                    fh, head_lines=head_lines,
                    max_line_bytes=_TRANSCRIPT_MAX_LINE_BYTES):
                if overlong:
                    continue  # overlong line already drained -> skip
                line = raw_text.strip()
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


def _norm_cwd(c) -> str:
    """Normalize a cwd for the live-match comparison: strip surrounding
    whitespace and any trailing slash, but keep root ``/`` intact. Returns ``""``
    for anything that isn't a non-empty string."""
    if not isinstance(c, str):
        return ""
    s = c.strip()
    if not s:
        return ""
    return s.rstrip("/") or "/"


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

    # Normalize cwds (strip a trailing slash, keep root "/") ONLY for the
    # live-match comparison: tmux's ``pane_current_path`` and Claude's recorded
    # ``cwd`` are normally both un-slashed, but if one side ever carries a
    # trailing slash an exact ``in`` test would wrongly report ``live=False`` for
    # a session that IS live. The emitted ``cwd`` stays verbatim (the server
    # resumes against it).
    live = {n for n in (_norm_cwd(c) for c in (live_cwds or ())) if n}

    # Dedup by session id, keeping the newest. ``candidates`` is newest-first,
    # so the first time we see an id wins.
    by_id: dict = {}
    filtered = 0
    for mtime, fpath in candidates:
        session_id = os.path.splitext(os.path.basename(fpath))[0]
        if not session_id or session_id in by_id:
            continue
        cwd, summary = _extract_cwd_summary(
            fpath, head_lines=_TRANSCRIPT_HEAD_LINES)
        # Only surface REAL work: skip a transcript whose recorded cwd is empty,
        # hidden (dot-prefixed basename), or no longer an existing directory on
        # this machine (its project folder was deleted -> don't resurrect it).
        if not _cwd_is_visible_dir(cwd):
            filtered += 1
            continue
        by_id[session_id] = {
            "kind": "transcript",
            "claude_session_id": session_id,
            "cwd": cwd,
            "summary": summary or "",
            "last_activity": float(mtime),
            "live": _norm_cwd(cwd) in live,
        }

    if filtered:
        log.debug("coding_discover: filtered %d transcript(s) with hidden/"
                  "missing/nonexistent cwd", filtered)
    return list(by_id.values())


def _sessions_hash(sessions: list) -> str:
    """Stable hash of the normalized session set (order-independent), used to
    suppress duplicate pushes when nothing changed.

    ``last_activity`` is intentionally EXCLUDED — it ticks on every keypress and
    would defeat the throttle. The 30s heartbeat carries freshness instead. Both
    ``tmux`` and ``transcript`` kinds are folded into one stable identity tuple
    keyed on the fields that actually define the session set.

    ``activity_state`` IS included: an idle↔working↔waiting transition (same tmux
    set) must count as "changed" so it pushes on the next 5s poll instead of
    waiting up to 30s for the heartbeat — otherwise the iOS Live Activity / WebUI
    shows a stale "idle" while a Mac session is actively running (the bug where
    closing+resuming on the Mac didn't surface the running session).
    """
    norm = sorted(
        (str(s.get("kind") or ""),
         str(s.get("tmux_name") or ""),
         str(s.get("claude_session_id") or ""),
         str(s.get("cwd") or ""),
         str(s.get("title") or ""),
         str(s.get("summary") or ""),
         str(s.get("activity_state") or ""),
         bool(s.get("live")))
        for s in sessions
    )
    blob = json.dumps(norm, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# ── transcript locate (coding_transcript_get) ─────────────────────────────────


def _encode_project_dir(cwd: str) -> str:
    """Encode ``cwd`` the way Claude Code names its on-disk project dir.

    Mirror of ``agent.coding_session_capture.encode_project_dir`` (the desktop
    client can't import ``agent.*``): realpath the cwd, then replace every ``/``
    and every ``.`` with ``-``. Realpath-ing first matches the directory Claude
    actually wrote to (``/tmp`` -> ``/private/tmp`` on macOS, symlinks resolved).
    Never raises (a bad realpath falls back to the raw path)."""
    try:
        resolved = os.path.realpath(cwd or "")
    except (OSError, ValueError):
        resolved = cwd or ""
    return resolved.replace("/", "-").replace(".", "-")


def _claude_projects_dir(home_dir: str) -> str:
    """Directory holding Claude Code's per-project transcript folders.

    Honors ``CLAUDE_CONFIG_DIR`` (``<that>/projects``) if set, else
    ``<home_dir>/.claude/projects`` (``home_dir`` falling back to the real home)."""
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if config_dir:
        return os.path.join(config_dir, "projects")
    base = home_dir if home_dir else os.path.expanduser("~")
    return os.path.join(base, ".claude", "projects")


def _locate_transcript(home_dir: str, claude_session_id: str, cwd: str):
    """Return the on-disk ``.jsonl`` path for ``claude_session_id`` or ``None``.

    Prefers the encoded-cwd location
    ``<projects>/<encode(cwd)>/<id>.jsonl``; FALLS BACK to globbing
    ``<projects>/*/<id>.jsonl`` (handles realpath/symlink quirks where the
    recorded cwd doesn't re-encode to the dir Claude used). On multiple glob
    hits the newest by mtime wins. Never raises."""
    fname = claude_session_id + ".jsonl"
    projects_dir = _claude_projects_dir(home_dir)
    try:
        if cwd:
            candidate = os.path.join(
                projects_dir, _encode_project_dir(cwd), fname)
            if os.path.isfile(candidate):
                return candidate
    except (OSError, ValueError):
        pass
    try:
        # glob.escape the session-id stem so a ``[`` etc. in it can't turn into a
        # wildcard; the ``*`` (project dir) is the only intentional wildcard.
        matches = glob.glob(os.path.join(
            projects_dir, "*", glob.escape(fname)))
        matches = [m for m in matches if os.path.isfile(m)]
    except (OSError, ValueError):
        return None
    if not matches:
        return None
    if len(matches) == 1:
        return matches[0]
    try:
        return max(matches, key=os.path.getmtime)
    except OSError:
        return matches[0]


# ── runner ────────────────────────────────────────────────────────────────────

# runner(argv) -> (returncode:int, stdout:str, stderr:str)
Runner = Callable[[list], tuple]


def _default_runner(argv: list) -> tuple:
    try:
        # A launchd-started jc-client inherits a MINIMAL PATH
        # (/usr/bin:/bin:/usr/sbin:/sbin), which excludes Homebrew — so a tmux at
        # /opt/homebrew/bin would be unfindable and live discovery would silently
        # find nothing (the session would only surface via the transcript scan).
        # Augment PATH with the common install dirs so `tmux` resolves.
        env = dict(os.environ)
        extra = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"
        env["PATH"] = (env.get("PATH", "") + os.pathsep + extra).lstrip(os.pathsep)
        p = subprocess.run(argv, capture_output=True, text=True,
                           timeout=_TMUX_TIMEOUT, env=env)
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
        # tmux_names confirmed (by command or pane content) to be Claude sessions
        # in the last scan — so a session mid-tool-run (whose pane scrolled the
        # Claude UI away) is still kept rather than flickering out of discovery.
        self._known_claude: set = set()
        self._last_hash: Optional[str] = None
        self._last_push_at: float = 0.0
        # In-flight coding_transcript_put streams: req_id -> accumulator.
        self._put_buffers: dict = {}

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
            elif t == "coding_transcript_get":
                self._on_transcript_get(frame)
            elif t == "coding_transcript_put":
                self._on_transcript_put(frame)
        except Exception as exc:  # noqa: BLE001 — never bubble into the pump
            log.warning("coding_discover handle_frame failed: %s", exc)

    def _on_transcript_get(self, frame: dict) -> None:
        """Ship a past session's on-disk transcript back to the server (resume
        runs on the server now; the device's only job is to SEND the file).

        Locates ``<projects>/<encode(cwd)>/<id>.jsonl`` (falling back to a glob),
        gzip-compresses + base64-encodes the bytes, and streams them as
        ``coding_transcript_data`` chunks (final ``eof:true``). Any failure
        (missing/oversize/unreadable) becomes a single ``ok:false`` frame. Never
        raises into the pump."""
        req_id = str(frame.get("req_id") or "")
        csid = str(frame.get("claude_session_id") or "").strip()
        cwd = str(frame.get("cwd") or "").strip()

        # Guard against an empty / path-traversal / glob-meta session id before it
        # ever touches the filesystem.
        bad_id = (
            not csid
            or os.sep in csid
            or (os.altsep and os.altsep in csid)
            or "\x00" in csid
            or csid in (".", "..")
        )
        if bad_id:
            self._send_transcript_error(req_id, "missing or invalid "
                                                "claude_session_id")
            return

        try:
            path = _locate_transcript(self._home_dir, csid, cwd)
        except Exception as exc:  # noqa: BLE001 — locate must never raise
            log.debug("coding_transcript_get locate failed: %s", exc)
            path = None
        if not path:
            self._send_transcript_error(req_id, "transcript not found")
            return

        try:
            size = os.path.getsize(path)
        except OSError as exc:
            log.debug("coding_transcript_get stat failed for %s: %s", path, exc)
            self._send_transcript_error(req_id, "transcript not found")
            return
        if size > _TRANSCRIPT_GET_MAX_BYTES:
            self._send_transcript_error(req_id, "transcript too large")
            return

        try:
            with open(path, "rb") as fh:
                # Read one byte past the cap so a file that grew since stat is
                # still rejected rather than truncated.
                raw = fh.read(_TRANSCRIPT_GET_MAX_BYTES + 1)
        except (OSError, IOError) as exc:
            log.debug("coding_transcript_get read failed for %s: %s", path, exc)
            self._send_transcript_error(req_id, "transcript read error")
            return
        if len(raw) > _TRANSCRIPT_GET_MAX_BYTES:
            self._send_transcript_error(req_id, "transcript too large")
            return

        try:
            payload = base64.b64encode(gzip.compress(raw)).decode("ascii")
        except Exception as exc:  # noqa: BLE001
            log.debug("coding_transcript_get encode failed for %s: %s", path, exc)
            self._send_transcript_error(req_id, "transcript encode error")
            return

        self._send_transcript_chunks(req_id, csid, payload)

    def _send_transcript_chunks(self, req_id: str, csid: str,
                                payload: str) -> None:
        """Send ``payload`` (base64 of gzip'd bytes) as one-or-more data frames
        of ≤ ``_TRANSCRIPT_CHUNK_B64`` chars each, the last carrying ``eof:true``.
        Always emits at least one frame (an empty payload -> a single empty
        ``eof`` chunk)."""
        chunk = _TRANSCRIPT_CHUNK_B64
        total = len(payload)
        seq = 0
        pos = 0
        while True:
            piece = payload[pos:pos + chunk]
            pos += chunk
            eof = pos >= total
            self._send_safe({
                "type": "coding_transcript_data",
                "req_id": req_id,
                "claude_session_id": csid,
                "seq": seq,
                "eof": eof,
                "content_b64": piece,
            })
            seq += 1
            if eof:
                break

    def _send_transcript_error(self, req_id: str, error: str) -> None:
        self._send_safe({
            "type": "coding_transcript_data",
            "req_id": req_id,
            "ok": False,
            "error": error,
        })


    # ── transcript RECEIVE (coding_transcript_put) ──────────────────────

    def _on_transcript_put(self, frame: dict) -> None:
        """Accept a transcript the SERVER is pushing back to this device.

        The inverse of ``_on_transcript_get``: a resumed session runs on the
        server, whose growing ``<csid>.jsonl`` is streamed here as
        ``coding_transcript_put`` chunks (same gzip+base64 framing as
        ``coding_transcript_data``: ``seq`` ordered, final ``eof:true``). We
        accumulate per ``req_id``; on ``eof`` we gunzip and write the file to
        this device's ``<projects>/<encode(cwd)>/<csid>.jsonl`` so a LOCAL
        ``claude --resume <csid>`` on the Mac sees the server-side conversation.

        Defensive: validates the session id, caps buffered bytes + concurrent
        streams, and never raises into the WS pump."""
        req_id = str(frame.get("req_id") or "")
        if not req_id:
            return
        csid = str(frame.get("claude_session_id") or "").strip()
        cwd = str(frame.get("cwd") or "").strip()
        # Same id guard as _on_transcript_get — block traversal/glob/NUL before
        # the id is ever used to build a filesystem path.
        bad_id = (
            not csid
            or os.sep in csid
            or (os.altsep and os.altsep in csid)
            or "\x00" in csid
            or csid in (".", "..")
        )
        if bad_id or not cwd:
            self._put_buffers.pop(req_id, None)
            return
        # A device-reported-style failure frame just drops the stream.
        if frame.get("ok") is False or frame.get("error"):
            self._put_buffers.pop(req_id, None)
            return
        content_b64 = frame.get("content_b64") or ""
        try:
            chunk = base64.b64decode(content_b64) if content_b64 else b""
        except Exception:  # noqa: BLE001 — corrupt chunk -> abandon the stream
            self._put_buffers.pop(req_id, None)
            return
        buf = self._put_buffers.get(req_id)
        if buf is None:
            # Bound concurrent streams: evict the OLDEST single stream if a peer
            # floods us (dicts preserve insertion order) — never clear them all,
            # which would also wipe other legit in-flight streams.
            if len(self._put_buffers) >= _TRANSCRIPT_PUT_MAX_STREAMS:
                self._put_buffers.pop(next(iter(self._put_buffers)), None)
            buf = {"csid": csid, "cwd": cwd, "chunks": {}, "size": 0}
            self._put_buffers[req_id] = buf
        buf["chunks"][int(frame.get("seq") or 0)] = chunk
        buf["size"] += len(chunk)
        if buf["size"] > _TRANSCRIPT_PUT_MAX_GZ_BYTES:
            self._put_buffers.pop(req_id, None)
            log.warning("coding_transcript_put[%s]: over size cap, dropped", req_id)
            return
        if not frame.get("eof"):
            return
        # Final chunk: reassemble + gunzip (size-bounded) + write.
        self._put_buffers.pop(req_id, None)
        try:
            blob = b"".join(buf["chunks"][i] for i in sorted(buf["chunks"]))
            raw = self._gunzip_bounded(blob) if blob else b""
        except Exception as exc:  # noqa: BLE001 — partial/corrupt stream
            log.warning("coding_transcript_put[%s]: gunzip failed: %s", req_id, exc)
            return
        if raw is None:  # would inflate past the cap (decompression bomb)
            log.warning("coding_transcript_put[%s]: decompressed over cap, dropped",
                        req_id)
            return
        self._write_transcript_file(csid, cwd, raw)

    @staticmethod
    def _gunzip_bounded(blob: bytes):
        """Gunzip ``blob`` but stop inflating past ``_TRANSCRIPT_PUT_MAX_RAW_BYTES``.

        The chunk/stream caps bound only the COMPRESSED bytes, so a small gzip
        could still inflate to gigabytes (a decompression bomb from a misbehaving
        server). ``GzipFile.read(n)`` only inflates enough to yield ``n`` bytes,
        so reading ``cap+1`` bounds memory to the cap. Returns the bytes, or
        ``None`` if the stream would exceed the cap."""
        import io

        with gzip.GzipFile(fileobj=io.BytesIO(blob)) as gz:
            raw = gz.read(_TRANSCRIPT_PUT_MAX_RAW_BYTES + 1)
        if len(raw) > _TRANSCRIPT_PUT_MAX_RAW_BYTES:
            return None
        return raw

    def _write_transcript_file(self, csid: str, cwd: str, raw: bytes) -> None:
        """Write ``raw`` to ``<projects>/<encode(cwd)>/<csid>.jsonl`` atomically
        (temp file + ``os.replace``) so a concurrent ``claude --resume`` never
        reads a half-written transcript. Never raises."""
        tmp = None
        try:
            projects_dir = _claude_projects_dir(self._home_dir)
            pdir = os.path.join(projects_dir, _encode_project_dir(cwd))
            os.makedirs(pdir, exist_ok=True)
            dest = os.path.join(pdir, csid + ".jsonl")
            tmp = dest + ".jc-tmp"
            with open(tmp, "wb") as fh:
                fh.write(raw)
            os.replace(tmp, dest)
        except Exception as exc:  # noqa: BLE001 — never break the pump on I/O
            log.warning("coding_transcript_put write failed for %s: %s", csid, exc)
            if tmp:
                try:
                    os.remove(tmp)
                except OSError:
                    pass

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
        # Give each live tmux row the claude_session_id of its cwd's newest
        # transcript, so an OFFLINE Mac session can still be resumed on the server.
        _enrich_tmux_with_csids(tmux_sessions, transcripts)
        return tmux_sessions + transcripts

    def _capture(self, tmux_name: str) -> Optional[str]:
        """The session's pane text, or ``None`` on any failure. Never raises —
        discovery must degrade gracefully."""
        try:
            rc, out, _err = self._run(tmux_capture_argv(tmux_name))
        except Exception:  # noqa: BLE001 — discovery must never raise
            return None
        if rc not in (0, None):
            return None
        return out

    def _scan_tmux(self) -> list:
        """Live Claude Code tmux sessions in the wire shape; ``[]`` on any error.

        A session is kept if its ``pane_current_command`` is ``claude`` / its
        tmux name is ``jc-*``, OR it was a known-Claude session last scan, OR its
        pane content looks like Claude's TUI. The last two matter because while
        Claude runs a tool the pane's foreground process is the TOOL, not
        ``claude`` — without them a working session would flicker out of
        discovery (and get reconciled to "stopped"). Hidden / nonexistent cwds
        are dropped. The captured pane doubles as the ``activity_state`` source.
        """
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
        known = self._known_claude
        new_known: set = set()
        kept: list = []
        filtered = 0
        probes = 0
        for s in parsed:
            if not _cwd_is_visible_dir(str(s.get("cwd") or "")):
                if _is_coding_session(s):
                    filtered += 1
                continue
            tmux_name = str(s.get("tmux_name") or "")
            is_claude = _is_coding_session(s) or (tmux_name in known)
            pane: Optional[str] = None
            if is_claude:
                pane = self._capture(tmux_name)  # for activity_state
            elif probes < _MAX_PANE_PROBES:
                # Command isn't claude and it wasn't known — probe the pane to
                # see if it's actually a Claude session before dropping it.
                probes += 1
                pane = self._capture(tmux_name)
                if is_claude_pane(pane or ""):
                    is_claude = True
            if not is_claude:
                continue
            new_known.add(tmux_name)
            wire = _to_wire(s)
            # A BLANK capture (None = tmux error, OR "" / whitespace = a mid-
            # teardown repaint racing this capture — common when a SIBLING session
            # is dying) is "unknown", NOT idle. Emit None so the server keeps the
            # last-known state instead of clobbering a live "working" with a
            # guessed "idle". Without this, one session ending flipped an UNRELATED
            # session to idle for a cycle (the cross-session status bleed): the
            # blank frame classified idle AND the sibling's removal forced a push
            # that same cycle, carrying the bad state upstream.
            wire["activity_state"] = (classify_pane(pane)
                                      if (pane and pane.strip()) else None)
            kept.append(wire)
        with self._lock:
            self._known_claude = new_known
        if filtered:
            log.debug("coding_discover: filtered %d tmux session(s) with "
                      "hidden/nonexistent cwd", filtered)
        return kept

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
        self._send_safe({
            "type": "coding_discover",
            "device_id": self._device_id,
            "scanned_at": float(scanned_at),
            "sessions": sessions,
        })

    def _send_safe(self, frame: dict) -> None:
        """Send a frame, swallowing any error: a send failure (WS closed mid-push)
        must never break the poll loop or bubble into the pump."""
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
