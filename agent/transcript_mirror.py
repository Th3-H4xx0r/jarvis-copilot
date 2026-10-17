"""The server's copy of every conversation's transcript.

While a Mac owns a session, jc-client ships each new transcript line here as
it is written (append-only, by byte offset), so the copy is complete as of the
Mac's last flush and "Continue on server" works while the Mac sleeps. The copy
lives exactly where the agent itself would read it on the server: Claude under
``~/.claude/projects/<encoded server cwd>/<sid>.jsonl``, Codex under
``~/.codex/sessions/<rollout path>``, so ``claude --resume <sid>`` /
``codex resume <sid>`` pick it up unchanged.

A chunk is applied only at the copy's current size; anything else (a lost or
repeated frame) is refused with the size the sender must resume from, never
appended in the wrong place.
"""
from __future__ import annotations

import os
import re
import tempfile
import threading
from pathlib import Path, PurePosixPath
from typing import Optional

_LOCKS: dict[str, threading.Lock] = {}
_LOCKS_GUARD = threading.Lock()


def _lock(path: Path) -> threading.Lock:
    with _LOCKS_GUARD:
        return _LOCKS.setdefault(str(path), threading.Lock())


def encode_project_dir(cwd: str) -> str:
    """Claude's name for a project dir: realpath, ``/`` and ``.`` become ``-``."""
    return os.path.realpath(cwd).replace("/", "-").replace(".", "-")


def claude_config_dir() -> Path:
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(env) if env else Path.home() / ".claude"


def server_projects_root() -> str:
    return os.environ.get("JC_CODING_PROJECTS_ROOT") or os.path.expanduser("~/codingprojects")


def server_cwd_for(origin_cwd: str) -> str:
    """Where a Mac project's synced copy lives on the server."""
    return os.path.join(server_projects_root(), os.path.basename(origin_cwd.rstrip("/")))


_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")


def safe_id(session_id) -> bool:
    """A session id that is one plain file name (devices send it; it names a file)."""
    sid = str(session_id or "")
    return bool(_ID_RE.match(sid)) and ".." not in sid


def safe_codex_rel(rel) -> Optional[str]:
    """A rollout path relative to ~/.codex/sessions that stays inside it, or None."""
    if not rel:
        return None
    p = PurePosixPath(str(rel))
    if p.is_absolute() or ".." in p.parts or p.suffix != ".jsonl" or "\\" in str(rel):
        return None
    return p.as_posix()


def transcript_path(agent: str, session_id: str, cwd: str,
                    codex_rel: Optional[str] = None) -> Path:
    """Raises ValueError for an id that would leave the transcript dirs."""
    if not safe_id(session_id):
        raise ValueError(f"unsafe session id {session_id!r}")
    if agent == "codex":
        return Path.home() / ".codex" / "sessions" / (safe_codex_rel(codex_rel)
                                                      or f"{session_id}.jsonl")
    return claude_config_dir() / "projects" / encode_project_dir(cwd) / f"{session_id}.jsonl"


def path_for(conv: dict) -> Path:
    cwd = conv.get("server_cwd") or conv.get("cwd") or ""
    return transcript_path(conv.get("agent") or "claude", conv.get("session_id") or "",
                           cwd, conv.get("codex_rel"))


def size(conv: dict) -> int:
    try:
        return path_for(conv).stat().st_size
    except (OSError, ValueError):
        return 0


def append_chunk(conv: dict, offset: int, data: bytes) -> tuple[bool, int]:
    path = path_for(conv)
    with _lock(path):
        current = path.stat().st_size if path.exists() else 0
        if offset != current:
            return False, current
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "ab") as fh:
            fh.write(data)
        return True, current + len(data)


def read_from(conv: dict, offset: int = 0) -> bytes:
    try:
        path = path_for(conv)
    except ValueError:
        return b""
    with _lock(path):
        try:
            with open(path, "rb") as fh:
                fh.seek(max(0, int(offset)))
                return fh.read()
        except OSError:
            return b""


def trim_partial(conv: dict) -> int:
    """Cut a half-shipped last line (the Mac dropped off mid-chunk), so an agent
    resuming here appends after a whole line. Returns the new size."""
    try:
        path = path_for(conv)
    except ValueError:
        return 0
    with _lock(path):
        try:
            with open(path, "rb+") as fh:
                data = fh.read()
                keep = data.rfind(b"\n") + 1
                if keep < len(data):
                    fh.truncate(keep)
                return keep
        except OSError:
            return 0


def replace(conv: dict, data: bytes) -> None:
    """Write the whole copy (a merge result) atomically."""
    path = path_for(conv)
    with _lock(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".merge-")
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


_TITLE_TAIL = 512 * 1024
_TITLE_CACHE: dict = {}


def title_from_tail(path, tail: int = _TITLE_TAIL):
    """The newest ``ai-title`` in a Claude transcript (the title the Claude app
    shows), read from the file's end and cached per size. None when absent."""
    import json as _json
    try:
        st = os.stat(path)
    except OSError:
        return None
    hit = _TITLE_CACHE.get(str(path))
    if hit and hit[0] == st.st_size:
        return hit[1]
    title = None
    try:
        with open(path, "rb") as fh:
            fh.seek(max(0, st.st_size - tail))
            data = fh.read()
    except OSError:
        return None
    for line in reversed(data.split(b"\n")):
        if b'"ai-title"' not in line:
            continue
        try:
            obj = _json.loads(line)
        except ValueError:
            continue
        raw = str(obj.get("aiTitle") or "").strip()
        if raw:
            title = " ".join(raw.splitlines()[0].split())[:120]
            break
    _TITLE_CACHE[str(path)] = (st.st_size, title)
    return title


def latest_title(conv: dict):
    return title_from_tail(path_for(conv))


def last_write(conv: dict):
    try:
        return path_for(conv).stat().st_mtime
    except OSError:
        return None
