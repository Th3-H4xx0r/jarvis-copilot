"""Keep the server's copy of this Mac's transcripts live, and merge it back.

Shipping: each watched transcript (an append-only JSONL file the agent
writes) is sent to the server as it grows, by byte offset, poked by the
session's hooks (no file polling: battery) and flushed before the Mac sleeps.
The server applies a chunk only at its copy's current size and answers with
that size, which is where the next chunk starts.

Merging back: when a session continued on the server, the server sends its
copy (``agent_transcript_sync``, in parts) and later its new lines
(``agent_transcript_tail``). The merge is ``transcript_merge.merge`` (the same
file the server runs): nothing is lost; if both copies grew apart, the Mac's
extra lines are kept as a separate forked session.
"""
from __future__ import annotations

import base64
import json
import logging
import os
import re
import tempfile
import threading
import time
import uuid
from pathlib import Path, PurePosixPath
from typing import Callable, Optional

from jc_client.transcript_merge import line_id, merge

log = logging.getLogger(__name__)

CHUNK = 256 * 1024
# A copy far behind (a long chat the server has never seen) goes in bigger
# parts: one in flight at a time, so the part size sets the pace. 2 MB is
# ~2.7 MB as base64, well under the bridge's 8 MB frame cap.
BULK_CHUNK = 2 * 1024 * 1024
BULK_BEHIND = 4 * 1024 * 1024
_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")


def _safe_id(session_id: str) -> bool:
    return bool(_ID_RE.match(session_id or "")) and ".." not in session_id


def _safe_rel(rel) -> Optional[str]:
    if not rel:
        return None
    p = PurePosixPath(str(rel))
    if p.is_absolute() or ".." in p.parts or p.suffix != ".jsonl":
        return None
    return p.as_posix()


def _claude_dir() -> Path:
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(env) if env else Path.home() / ".claude"


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".jc-merge-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _lines(data: bytes) -> list:
    return [ln for ln in data.decode("utf-8", errors="replace").split("\n") if ln.strip()]


def _join(lines: list) -> bytes:
    return ("\n".join(lines) + "\n").encode("utf-8") if lines else b""


class TranscriptShipper:
    def __init__(self, send: Callable[[dict], None], *, chunk: int = CHUNK,
                 bulk_chunk: int = BULK_CHUNK, bulk_behind: int = BULK_BEHIND) -> None:
        self._send = send
        self._chunk = chunk
        self._bulk_chunk = bulk_chunk
        self._bulk_behind = bulk_behind
        self._lock = threading.RLock()
        self._watch: dict = {}     # ckey -> {agent, path, cwd, codex_rel, acked, sent}
        self._parts: dict = {}     # ckey -> {parts, got: {i: bytes}, frame}
        self._online = True

    # ── shipping ─────────────────────────────────────────────────────────
    def set_online(self, online: bool) -> None:
        with self._lock:
            self._online = online
            for w in self._watch.values():
                w["sent"] = w["acked"]
                w["inflight"] = False   # an ack lost with the old connection never comes
            self._parts.clear()         # sync parts lost with it never come either
        if online:
            for ckey in list(self._watch):
                self.poke(ckey)

    def watch(self, ckey: str, agent: str, path: str, *, cwd: str = "",
              codex_rel: Optional[str] = None) -> None:
        with self._lock:
            if ckey not in self._watch:
                self._watch[ckey] = {"agent": agent, "path": path, "cwd": cwd,
                                     "codex_rel": codex_rel, "acked": 0, "sent": 0,
                                     "inflight": False}
            else:
                self._watch[ckey].update(path=path, cwd=cwd or self._watch[ckey]["cwd"])
        self.poke(ckey)

    def unwatch(self, ckey: str) -> None:
        with self._lock:
            self._watch.pop(ckey, None)

    def watching(self) -> list:
        with self._lock:
            return list(self._watch)

    def poke(self, ckey: str) -> None:
        with self._lock:
            w = self._watch.get(ckey)
            if w is None or not self._online or w["inflight"]:
                return
            self._send_next(ckey, w)

    def _send_next(self, ckey: str, w: dict) -> bool:
        try:
            size = os.path.getsize(w["path"])
        except OSError:
            return False
        if size <= w["sent"]:
            return False
        part = self._bulk_chunk if size - w["sent"] > self._bulk_behind else self._chunk
        with open(w["path"], "rb") as fh:
            fh.seek(w["sent"])
            data = fh.read(min(part, size - w["sent"]))
        if not data:
            return False
        agent, _, sid = ckey.partition("|")
        self._send({"type": "event", "name": "agent_transcript_chunk", "data": {
            "ckey": ckey, "agent": agent, "session_id": sid, "cwd": w["cwd"],
            "codex_rel": w["codex_rel"], "offset": w["sent"], "size": size,
            "data_b64": base64.b64encode(data).decode()}})
        w["sent"] += len(data)
        w["inflight"] = True
        return True

    def on_ack(self, ckey: str, ok: bool, size: int, reason: Optional[str] = None) -> None:
        with self._lock:
            w = self._watch.get(ckey)
            if w is None:
                return
            if reason == "not_owner":
                # It runs elsewhere now (moved to the server): the server keeps the
                # copy; resending from 0 on every refusal would loop forever. A
                # new local run's hooks watch it again.
                self._watch.pop(ckey, None)
                return
            w["inflight"] = False
            if ok:
                w["acked"] = max(w["acked"], int(size))
                w["sent"] = max(w["sent"], w["acked"])
            else:
                w["acked"] = w["sent"] = int(size)
        self.poke(ckey)

    def on_need(self, ckey: str, offset: int) -> None:
        with self._lock:
            w = self._watch.get(ckey)
            if w is None:
                return
            w["acked"] = w["sent"] = int(offset)
            w["inflight"] = False
        self.poke(ckey)

    def flush_all(self, deadline_s: float = 3.0) -> None:
        """Send everything not yet sent without waiting for acks (before sleep)."""
        end = time.monotonic() + deadline_s
        with self._lock:
            if not self._online:
                return
            for ckey, w in self._watch.items():
                while time.monotonic() < end and self._send_next(ckey, w):
                    pass

    # ── merging back ─────────────────────────────────────────────────────
    def local_path(self, agent: str, session_id: str, cwd: str,
                   codex_rel: Optional[str] = None) -> Path:
        """Where this Mac keeps that transcript. ValueError for names that would
        leave ~/.claude/projects or ~/.codex/sessions."""
        if not _safe_id(session_id):
            raise ValueError(f"unsafe session id {session_id!r}")
        if agent == "codex":
            return Path.home() / ".codex" / "sessions" / (_safe_rel(codex_rel)
                                                          or f"{session_id}.jsonl")
        enc = os.path.realpath(cwd).replace("/", "-").replace(".", "-")
        return _claude_dir() / "projects" / enc / f"{session_id}.jsonl"

    def apply_sync(self, frame: dict) -> None:
        ckey = str(frame.get("ckey") or "")
        try:
            chunk = base64.b64decode(frame.get("data_b64") or "")
        except (ValueError, TypeError):
            chunk = b""
        parts = max(1, int(frame.get("parts") or 1))
        with self._lock:
            part = int(frame.get("part") or 0)
            slot = self._parts.get(ckey)
            # Parts may arrive in any order; a part seen twice means a new sync began.
            if slot is None or slot["parts"] != parts or part in slot["got"]:
                slot = self._parts[ckey] = {"parts": parts, "got": {}}
            slot["got"][part] = chunk
            if len(slot["got"]) < parts:
                return
            self._parts.pop(ckey, None)
        data = b"".join(slot["got"][i] for i in range(parts))
        result = {"ckey": ckey, "then": frame.get("then"), "ok": True}
        try:
            fork = self.apply_merge(frame.get("agent") or "claude", str(frame.get("session_id") or ""),
                                    frame.get("origin_cwd") or "", data, frame.get("codex_rel"))
            if fork:
                result["fork_session_id"] = fork
        except Exception as exc:  # noqa: BLE001
            log.warning("transcript merge failed for %s", ckey, exc_info=True)
            result.update(ok=False, error=str(exc))
        self._send({"type": "event", "name": "agent_merge_done", "data": result})

    def apply_merge(self, agent: str, session_id: str, cwd: str, server_bytes: bytes,
                    codex_rel: Optional[str] = None) -> Optional[str]:
        """Merge the server's copy into ours. Returns a forked session id when
        our copy had turns the server's didn't (kept, never dropped)."""
        path = self.local_path(agent, session_id, cwd, codex_rel)
        with self._lock:
            mine = _lines(path.read_bytes()) if path.exists() else []
            res = merge(mine, _lines(server_bytes), agent)
            if res.kind != "equal":
                _atomic_write(path, _join(res.merged))
            if not res.fork_tail:
                return None
            fork_id = str(uuid.uuid4())
            keep = [ln for ln in mine if ln not in set(res.fork_tail)]
            prefix = [ln for ln in keep if ln in set(res.merged)]
            _atomic_write(path.with_name(f"{fork_id}.jsonl"),
                          _join([self._resession(ln, fork_id, agent)
                                 for ln in prefix + res.fork_tail]))
            return fork_id

    def apply_tail(self, frame: dict) -> None:
        agent = frame.get("agent") or "claude"
        path = self.local_path(agent, str(frame.get("session_id") or ""),
                               frame.get("origin_cwd") or "", frame.get("codex_rel"))
        try:
            new = _lines(base64.b64decode(frame.get("data_b64") or ""))
        except (ValueError, TypeError):
            return
        with self._lock:
            mine = _lines(path.read_bytes()) if path.exists() else []
            if agent == "codex":
                add = new
            else:
                seen = {line_id(x, agent) or x for x in mine}
                add = [x for x in new if (line_id(x, agent) or x) not in seen]
            if add:
                path.parent.mkdir(parents=True, exist_ok=True)
                with open(path, "ab") as fh:
                    fh.write(_join(add))

    @staticmethod
    def _resession(line: str, session_id: str, agent: str) -> str:
        if agent != "claude":
            return line
        try:
            obj = json.loads(line)
        except ValueError:
            return line
        if isinstance(obj, dict) and "sessionId" in obj:
            obj["sessionId"] = session_id
            return json.dumps(obj)
        return line
