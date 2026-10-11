"""Append-only WebUI run event journal helpers.

This is the first #1925 journal/replay slice.  It mirrors SSE events emitted by
the existing in-process streaming path without changing execution ownership.
"""
from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from pathlib import Path
from typing import Iterable, Iterator

logger = logging.getLogger(__name__)

RUN_JOURNAL_DIR_NAME = "_run_journal"
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_WRITER_LOCKS: dict[tuple[str, str, str], threading.Lock] = {}
_WRITER_LOCKS_GUARD = threading.Lock()
_TERMINAL_SSE_EVENTS = {"done", "cancel", "apperror", "error", "stream_end"}
_FSYNC_MODE_ENV = "HERMES_WEBUI_RUN_JOURNAL_FSYNC"
_FSYNC_MODE_EAGER = "eager"
_FSYNC_MODE_TERMINAL_ONLY = "terminal-only"


def _default_session_dir() -> Path:
    from api.models import SESSION_DIR

    return Path(SESSION_DIR)


def _validate_id(value: str, field: str) -> str:
    cleaned = str(value or "").strip()
    if not cleaned or "/" in cleaned or "\\" in cleaned or not _SAFE_ID_RE.fullmatch(cleaned):
        raise ValueError(f"invalid {field}")
    return cleaned


def _run_path(session_id: str, run_id: str, session_dir: Path | None = None) -> Path:
    sid = _validate_id(session_id, "session_id")
    rid = _validate_id(run_id, "run_id")
    root = Path(session_dir) if session_dir is not None else _default_session_dir()
    return root / RUN_JOURNAL_DIR_NAME / sid / f"{rid}.jsonl"


def _lock_for(path: Path) -> threading.Lock:
    key = (str(path.parent), path.name, str(os.getpid()))
    with _WRITER_LOCKS_GUARD:
        lock = _WRITER_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            _WRITER_LOCKS[key] = lock
        return lock


# Journals are read line by line in chunks, keeping only the first _HEAD_BYTES
# of each line while scanning. One line can hold a whole conversation (a `done`
# event carries the session), and reading files whole made a status check or a
# reconnect cost several times the file's size in memory.
_SCAN_CHUNK_BYTES = 1 << 20
_HEAD_BYTES = 8192
# append_run_event writes "payload" last with compact separators, so the fields
# before it (seq, event, terminal, ...) parse without decoding the payload.
_PAYLOAD_KEY = b',"payload":'


def _scan_lines(fh) -> Iterator[tuple[int, int, int, bytes]]:
    """Yield ``(line_no, offset, length, head)`` for each line of a binary file.

    ``head`` is at most the first ``_HEAD_BYTES`` of the line; it is the whole
    line when ``len(head) == length``. Only newline ends a line.
    """
    line_no = 0
    offset = 0
    length = 0
    head = bytearray()
    while True:
        chunk = fh.read(_SCAN_CHUNK_BYTES)
        if not chunk:
            break
        start = 0
        while True:
            newline = chunk.find(b"\n", start)
            end = newline if newline != -1 else len(chunk)
            room = _HEAD_BYTES - len(head)
            if room > 0:
                head += chunk[start:min(end, start + room)]
            length += end - start
            if newline == -1:
                break
            line_no += 1
            yield line_no, offset, length, bytes(head)
            offset += length + 1
            length = 0
            head = bytearray()
            start = newline + 1
    if length:
        yield line_no + 1, offset, length, bytes(head)


def _loads_dict(raw: bytes):
    try:
        parsed = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _event_header(head: bytes):
    """The event's fields before ``payload``, or None when the line is not in
    the layout append_run_event writes."""
    cut = head.find(_PAYLOAD_KEY)
    if cut <= 0:
        return None
    return _loads_dict(head[:cut] + b"}")


def _iter_journal(path: Path, want_payload=None) -> Iterator[tuple[str, dict]]:
    """Yield ``("event", event)`` or ``("malformed", {"line", "raw"})`` per line.

    A line longer than ``_HEAD_BYTES`` is decoded in full only when
    ``want_payload(header)`` is true (None means always); otherwise its header
    -- the event without ``payload`` -- is yielded, and the line never enters
    memory.
    """
    try:
        fh = open(path, "rb")
    except FileNotFoundError:
        return
    reader = None
    try:
        for line_no, offset, length, head in _scan_lines(fh):
            if len(head) == length:
                if not head.strip():
                    continue
                event = _loads_dict(head)
                raw = head
            else:
                header = _event_header(head)
                if header is not None and want_payload is not None and not want_payload(header):
                    yield "event", header
                    continue
                if reader is None:
                    reader = open(path, "rb")
                reader.seek(offset)
                raw = reader.read(length)
                event = _loads_dict(raw)
            if event is None:
                yield "malformed", {"line": line_no, "raw": raw.decode("utf-8", "replace")}
            else:
                yield "event", event
    finally:
        fh.close()
        if reader is not None:
            reader.close()


def _read_jsonl(path: Path) -> tuple[list[dict], list[dict]]:
    events: list[dict] = []
    malformed: list[dict] = []
    for kind, item in _iter_journal(path):
        (events if kind == "event" else malformed).append(item)
    return events, malformed


def _headers_only(_header) -> bool:
    return False


def _next_seq(path: Path) -> int:
    seqs = [
        event["seq"]
        for kind, event in _iter_journal(path, want_payload=_headers_only)
        if kind == "event" and isinstance(event.get("seq"), int)
    ]
    return (max(seqs) + 1) if seqs else 1


# ── Bounded `done` events ────────────────────────────────────────────────────
# A `done` event carries the whole session so the client can settle its
# transcript, which made every run's journal at least as big as the chat (one
# voice chat's runs reached 350 MB each). The journal keeps the same tail
# window GET /api/session?msg_limit=N returns -- `_messages_truncated` and
# `_messages_offset` tell a replaying client to page older messages in the way
# it does after opening a chat. The live stream is unchanged.
_DONE_MESSAGES_ENV = "HERMES_WEBUI_RUN_JOURNAL_DONE_MESSAGES"
_DEFAULT_DONE_MESSAGES = 30


def _done_messages_limit() -> int:
    raw = os.environ.get(_DONE_MESSAGES_ENV)
    if raw is None or not str(raw).strip():
        return _DEFAULT_DONE_MESSAGES
    try:
        return max(0, int(raw))
    except (TypeError, ValueError):
        return _DEFAULT_DONE_MESSAGES


def _messages_include_tool_metadata(messages) -> bool:
    """Same test as api.routes: the messages rebuild their own tool cards."""
    for msg in messages:
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        if isinstance(msg.get("tool_calls"), list) and msg.get("tool_calls"):
            return True
        content = msg.get("content")
        if isinstance(content, list) and any(
            isinstance(part, dict) and part.get("type") == "tool_use" for part in content
        ):
            return True
    return False


def bounded_journal_payload(event_name: str, payload):
    """The payload as the journal stores it: a `done` session keeps only its
    last messages (0 in the env setting keeps them all)."""
    if event_name != "done" or not isinstance(payload, dict):
        return payload
    session = payload.get("session")
    limit = _done_messages_limit()
    if not isinstance(session, dict) or limit <= 0:
        return payload
    messages = session.get("messages")
    if not isinstance(messages, list) or len(messages) <= limit:
        return payload
    tail = messages[-limit:]
    slim = dict(session)
    slim["messages"] = tail
    slim["_messages_truncated"] = True
    slim["_messages_offset"] = len(messages) - len(tail)
    if _messages_include_tool_metadata(tail):
        # As /api/session does for a tail window: the browser ignores the
        # session-level list when messages carry their own tool metadata.
        slim["tool_calls"] = []
    bounded = dict(payload)
    bounded["session"] = slim
    return bounded


def _terminal_state_for_event(event_name: str, payload) -> str | None:
    name = str(event_name or "")
    if name == "done" or name == "stream_end":
        return "completed"
    if name == "cancel":
        return "interrupted-by-user"
    if name in {"apperror", "error"}:
        err_type = str((payload or {}).get("type") or "").strip().lower() if isinstance(payload, dict) else ""
        if err_type in {"cancelled", "canceled"}:
            return "interrupted-by-user"
        if err_type == "interrupted":
            return "interrupted-by-crash"
        return "errored"
    return None


def _run_journal_fsync_mode() -> str:
    raw = os.environ.get(_FSYNC_MODE_ENV, _FSYNC_MODE_TERMINAL_ONLY)
    mode = str(raw or "").strip().lower()
    if mode in {_FSYNC_MODE_EAGER, _FSYNC_MODE_TERMINAL_ONLY}:
        return mode
    return _FSYNC_MODE_TERMINAL_ONLY


def _should_fsync_event(terminal_state: str | None) -> bool:
    if _run_journal_fsync_mode() == _FSYNC_MODE_EAGER:
        return True
    return bool(terminal_state)


def _fsync_parent_dir(path: Path) -> None:
    try:
        dir_fd = os.open(path.parent, getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError:
        pass


def append_run_event(
    session_id: str,
    run_id: str,
    event_name: str,
    payload=None,
    *,
    session_dir: Path | None = None,
    seq: int | None = None,
    created_at: float | None = None,
) -> dict:
    """Append one durable run event and fsync it according to the journal policy."""
    path = _run_path(session_id, run_id, session_dir=session_dir)
    payload = payload if payload is not None else {}
    event_name = str(event_name or "").strip()
    if not event_name:
        raise ValueError("event_name is required")
    payload = bounded_journal_payload(event_name, payload)
    with _lock_for(path):
        assigned_seq = int(seq) if seq is not None else _next_seq(path)
        terminal_state = _terminal_state_for_event(event_name, payload)
        event = {
            "version": 1,
            "event_id": f"{run_id}:{assigned_seq}",
            "seq": assigned_seq,
            "run_id": str(run_id),
            "session_id": str(session_id),
            "event": event_name,
            "type": event_name,
            "created_at": float(created_at if created_at is not None else time.time()),
            "terminal": bool(terminal_state),
            "terminal_state": terminal_state,
            "payload": payload,
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        created_file = not path.exists()
        line = json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
        fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(line)
            fh.flush()
            if _should_fsync_event(terminal_state):
                os.fsync(fh.fileno())
        if created_file:
            _fsync_parent_dir(path)
        return event


class RunJournalWriter:
    """Stateful writer for one WebUI stream/run."""

    def __init__(self, session_id: str, run_id: str, *, session_dir: Path | None = None):
        self.session_id = _validate_id(session_id, "session_id")
        self.run_id = _validate_id(run_id, "run_id")
        self.session_dir = Path(session_dir) if session_dir is not None else None
        self._path = _run_path(self.session_id, self.run_id, session_dir=self.session_dir)
        self._lock = _lock_for(self._path)
        with self._lock:
            self._next_seq = _next_seq(self._path)

    def append_sse_event(self, event_name: str, payload=None) -> dict:
        with self._lock:
            seq = self._next_seq
            self._next_seq += 1
        return append_run_event(
            self.session_id,
            self.run_id,
            event_name,
            payload or {},
            session_dir=self.session_dir,
            seq=seq,
        )


def read_run_events(
    session_id: str,
    run_id: str,
    *,
    after_seq: int | None = None,
    session_dir: Path | None = None,
) -> dict:
    path = _run_path(session_id, run_id, session_dir=session_dir)
    want_payload = None
    if after_seq is not None:
        # Events at or before the cursor are dropped below, so a long one is
        # never decoded just to be thrown away.
        def want_payload(header):
            try:
                return int(header.get("seq") or 0) > int(after_seq)
            except (TypeError, ValueError):
                return True
    events: list[dict] = []
    malformed: list[dict] = []
    for kind, item in _iter_journal(path, want_payload=want_payload):
        (events if kind == "event" else malformed).append(item)
    if after_seq is not None:
        events = [event for event in events if int(event.get("seq") or 0) > int(after_seq)]
    return {
        "session_id": str(session_id),
        "run_id": str(run_id),
        "events": events,
        "malformed": malformed,
    }


def _summary_from_events(session_id: str, run_id: str, events: Iterable[dict]) -> dict:
    # One pass, holding only the last events of interest, so a summary costs no
    # more memory than one event header however long the run was.
    count = 0
    last = None
    last_terminal = None
    last_final = None  # the logical outcome: the last terminal event that is not stream_end
    for event in events:
        if not isinstance(event, dict):
            continue
        count += 1
        last = event
        if event.get("terminal"):
            last_terminal = event
            if event.get("event") != "stream_end":
                last_final = event
    terminal = last_final or last_terminal
    status = terminal.get("terminal_state") if terminal else ("running" if count else "unknown")
    return {
        "session_id": str(session_id),
        "run_id": str(run_id),
        "stream_id": str(run_id),
        "event_count": count,
        "last_seq": int((last or {}).get("seq") or 0),
        "last_event_id": (last or {}).get("event_id"),
        "terminal": bool(terminal),
        "terminal_state": status,
        "last_event": (last or {}).get("event"),
    }


def _summary_from_path(path: Path, session_id: str, run_id: str) -> dict:
    headers = (
        event
        for kind, event in _iter_journal(path, want_payload=_headers_only)
        if kind == "event"
    )
    return _summary_from_events(session_id, run_id, headers)


def latest_run_summary(session_id: str, run_id: str, *, session_dir: Path | None = None) -> dict:
    path = _run_path(session_id, run_id, session_dir=session_dir)
    return _summary_from_path(path, session_id, run_id)


def find_run_summary(run_id: str, *, session_dir: Path | None = None) -> dict | None:
    rid = _validate_id(run_id, "run_id")
    root = Path(session_dir) if session_dir is not None else _default_session_dir()
    journal_root = root / RUN_JOURNAL_DIR_NAME
    for path in journal_root.glob(f"*/{rid}.jsonl"):
        session_id = path.parent.name
        summary = _summary_from_path(path, session_id, rid)
        summary["path"] = str(path)
        return summary
    return None


def stale_interrupted_event(session_id: str, run_id: str, *, after_seq: int | None = None) -> dict | None:
    summary = latest_run_summary(session_id, run_id)
    if summary.get("terminal") or not summary.get("event_count"):
        return None
    seq = int(summary.get("last_seq") or 0) + 1
    if after_seq is not None and seq <= int(after_seq):
        return None
    payload = {
        "type": "interrupted",
        "message": "WebUI restarted or lost the live worker before this run finished.",
        "hint": "The transcript was restored to the last journaled event. Start a new turn if you still need the task to continue.",
        "session_id": session_id,
        "stream_id": run_id,
        "journal_last_seq": summary.get("last_seq"),
    }
    return {
        "version": 1,
        "event_id": f"{run_id}:{seq}",
        "seq": seq,
        "run_id": run_id,
        "session_id": session_id,
        "event": "apperror",
        "type": "apperror",
        "created_at": time.time(),
        "terminal": True,
        "terminal_state": "stale-from-restart",
        "payload": payload,
        "synthetic": True,
    }


# ── Retention ────────────────────────────────────────────────────────────────
# Nothing used to delete a run journal: every turn of every chat stayed on disk
# (2.1 GB on the production box). A journal is read to replay a run to a client
# that reconnects, to show a run's status, and to rebuild a reply after a crash
# (only while the session still points at that run). After the retention age a
# finished run's journal serves none of those -- the session file holds the
# result -- so the janitor removes it. A run that never finished is kept while
# its session still names it as the active stream.
_RETENTION_ENV = "HERMES_WEBUI_RUN_JOURNAL_RETENTION_DAYS"
_DEFAULT_RETENTION_DAYS = 7.0
_TAIL_PROBE_BYTES = 64 * 1024
_JANITOR_INTERVAL_S = 24 * 3600
_JANITOR_FIRST_DELAY_S = 10 * 60
_janitor_lock = threading.Lock()
_janitor_started = False


def _retention_days() -> float:
    """Days a journal is kept after its last write; 0 or less keeps them forever."""
    raw = os.environ.get(_RETENTION_ENV)
    if raw is None or not str(raw).strip():
        return _DEFAULT_RETENTION_DAYS
    try:
        return float(raw)
    except (TypeError, ValueError):
        return _DEFAULT_RETENTION_DAYS


def _journal_is_terminal(path: Path) -> bool:
    """Whether the run reached a terminal event, reading only the file's end
    when that settles it (a finished run ends with done/cancel/error and
    stream_end)."""
    try:
        size = path.stat().st_size
        with open(path, "rb") as fh:
            fh.seek(max(0, size - _TAIL_PROBE_BYTES))
            tail = fh.read()
    except OSError:
        return False
    lines = tail.split(b"\n")
    if size > _TAIL_PROBE_BYTES:
        lines = lines[1:]  # the first piece starts mid-line
    for line in lines:
        if not line.strip():
            continue
        event = _loads_dict(line) or _event_header(line)
        if event is not None and event.get("terminal"):
            return True
    return bool(_summary_from_path(path, path.parent.name, path.stem).get("terminal"))


def _session_active_stream_id(session_dir: Path, session_id: str):
    """The session's active_stream_id from its metadata prefix; "" when the
    session has no sidecar; None when it cannot be read (keep its journals)."""
    path = Path(session_dir) / f"{session_id}.json"
    if not path.exists():
        return ""
    try:
        from api.models import _read_metadata_json_prefix

        prefix = _read_metadata_json_prefix(path)
        meta = json.loads(prefix) if prefix else None
    except Exception:
        return None
    if not isinstance(meta, dict):
        return None
    return str(meta.get("active_stream_id") or "")


def prune_run_journals(
    session_dir: Path | None = None,
    *,
    retention_days: float | None = None,
    now: float | None = None,
) -> dict:
    """Delete run journals untouched for ``retention_days`` (see above).

    Returns counts: ``scanned`` old enough to consider, ``removed``,
    ``removed_bytes``, ``kept_active`` (unfinished runs a session still points
    at, or whose session could not be read).
    """
    days = _retention_days() if retention_days is None else float(retention_days)
    result = {"scanned": 0, "removed": 0, "removed_bytes": 0, "kept_active": 0}
    if days <= 0:
        return result
    root = Path(session_dir) if session_dir is not None else _default_session_dir()
    journal_root = root / RUN_JOURNAL_DIR_NAME
    if not journal_root.is_dir():
        return result
    cutoff = (time.time() if now is None else now) - days * 86400
    for session_path in sorted(journal_root.iterdir()):
        if not session_path.is_dir():
            continue
        active = None
        active_read = False
        for path in sorted(session_path.glob("*.jsonl")):
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime >= cutoff:
                continue
            result["scanned"] += 1
            if not _journal_is_terminal(path):
                if not active_read:
                    active = _session_active_stream_id(root, session_path.name)
                    active_read = True
                if active is None or active == path.stem:
                    result["kept_active"] += 1
                    continue
            try:
                path.unlink()
            except OSError:
                continue
            result["removed"] += 1
            result["removed_bytes"] += stat.st_size
        try:
            session_path.rmdir()  # only succeeds once the directory is empty
        except OSError:
            pass
    return result


def start_retention_janitor() -> bool:
    """Prune journals in a daemon thread: once shortly after startup, then daily.
    Idempotent; returns whether this call started it."""
    global _janitor_started
    if _retention_days() <= 0:
        return False
    with _janitor_lock:
        if _janitor_started:
            return False
        _janitor_started = True

    def _loop():
        delay = _JANITOR_FIRST_DELAY_S
        while True:
            time.sleep(delay)
            delay = _JANITOR_INTERVAL_S
            try:
                result = prune_run_journals()
                if result["removed"]:
                    logger.info(
                        "run journal retention: removed %d journals (%.1f MB), kept %d unfinished",
                        result["removed"], result["removed_bytes"] / 1e6, result["kept_active"],
                    )
            except Exception:
                logger.warning("run journal retention pass failed", exc_info=True)

    threading.Thread(target=_loop, name="run-journal-janitor", daemon=True).start()
    return True
