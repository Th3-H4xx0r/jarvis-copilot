"""Desktop-side Mutagen driver for coding-session file sync.

Mutagen runs on the desktop (the only side that can dial out) and SSHes to hermes
through the WS<->TCP relay (the SSH host alias ``jc-hermes`` is set up by
``ssh_key.py`` with ``ProxyCommand = jc-client tcp-relay``). This module is the
thin, defensive wrapper the jc-client service uses to start / status / stop a
sync per coding session.

Split for testability:
  * argv builders + ``parse_status`` are PURE (unit-tested with a stub),
  * ``MutagenDriver`` runs them through an injectable ``runner`` (real
    subprocess in prod; a fake in tests), and never raises into the caller —
    a missing binary / dead daemon becomes a typed :class:`MutagenError`.
"""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
from typing import Callable, Optional

log = logging.getLogger(__name__)

# Per-session ignores (Mutagen does NOT read .gitignore — list is explicit).
DEFAULT_IGNORES = [
    "node_modules", ".venv", "__pycache__", "build", "dist", ".DS_Store",
    "*.pyc", ".mypy_cache", ".pytest_cache",
]
_SYNC_MODE = "two-way-safe"


class MutagenError(RuntimeError):
    """Raised for an actionable Mutagen failure (binary missing, daemon, etc.)."""


def session_name(session_id: str) -> str:
    """A Mutagen session name for a coding session (alnum/dash only)."""
    safe = re.sub(r"[^A-Za-z0-9-]", "-", str(session_id or "")).strip("-")
    return f"jc-{safe or 'session'}"


# ── argv builders (pure) ──────────────────────────────────────────────────────


def create_sync_argv(mutagen: str, *, name: str, local_path: str,
                     remote_host: str, remote_path: str,
                     ignore: Optional[list] = None) -> list:
    argv = [
        mutagen, "sync", "create",
        "--name", name,
        "--sync-mode", _SYNC_MODE,
        "--ignore-vcs",
    ]
    for pat in (ignore if ignore is not None else DEFAULT_IGNORES):
        argv += ["--ignore", str(pat)]
    argv += [local_path, f"{remote_host}:{remote_path}"]
    return argv


def status_argv(mutagen: str, name: str) -> list:
    return [mutagen, "sync", "list", "--template", "{{json .}}", name]


def terminate_argv(mutagen: str, name: str) -> list:
    return [mutagen, "sync", "terminate", name]


def parse_status(stdout: str) -> dict:
    """Normalize ``mutagen sync list --template {{json .}}`` output.

    Returns ``{status, conflicts, done, total, error}`` where status is one of
    ``connecting | syncing | synced | conflicts | error | unknown``. Parsed
    defensively (Mutagen's JSON schema varies by version) by keyword-matching the
    status string + counting any conflicts, so it survives field-name drift.
    """
    out = {"status": "unknown", "conflicts": 0, "done": 0, "total": 0,
           "error": None}
    text = (stdout or "").strip()
    if not text:
        return out
    try:
        data = json.loads(text)
    except Exception:
        return out
    # --template {{json .}} may emit a single object or a list of sessions.
    if isinstance(data, list):
        data = data[0] if data else {}
    if not isinstance(data, dict):
        return out

    conflicts = data.get("conflicts")
    out["conflicts"] = len(conflicts) if isinstance(conflicts, list) else 0

    # Find a human-ish status string anywhere obvious.
    status_str = ""
    for k in ("status", "state", "lastError"):
        v = data.get(k)
        if isinstance(v, str) and v:
            status_str = v
            break
    s = status_str.lower()

    err = data.get("lastError") or data.get("error")
    if isinstance(err, str) and err:
        out["error"] = err

    # Progress, if Mutagen exposes staging counters (best-effort field probing).
    for done_k, total_k in (("stagingDone", "stagingTotal"),
                            ("receivedFiles", "expectedFiles"),
                            ("done", "total")):
        d, t = data.get(done_k), data.get(total_k)
        if isinstance(d, (int, float)) and isinstance(t, (int, float)) and t:
            out["done"], out["total"] = int(d), int(t)
            break

    if out["error"] or "error" in s:
        out["status"] = "error"
    elif out["conflicts"] > 0 or "conflict" in s:
        out["status"] = "conflicts"
    elif any(w in s for w in ("disconnect", "waiting", "connecting")):
        out["status"] = "connecting"
    elif "watching" in s or s in ("", "watching for changes"):
        out["status"] = "synced"
    elif any(w in s for w in ("scan", "reconcil", "stag", "transition", "saving")):
        out["status"] = "syncing"
    else:
        out["status"] = "syncing"
    return out


# ── runner + driver ───────────────────────────────────────────────────────────

# runner(argv, env) -> (returncode:int, stdout:str, stderr:str)
Runner = Callable[[list, Optional[dict]], tuple]


def _default_runner(argv: list, env: Optional[dict] = None) -> tuple:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, env=env,
                           timeout=60)
        return p.returncode, p.stdout or "", p.stderr or ""
    except FileNotFoundError as exc:
        raise MutagenError(f"mutagen not found: {exc}") from exc
    except subprocess.TimeoutExpired as exc:
        return 1, "", f"timeout: {exc}"


def find_mutagen() -> Optional[str]:
    """Locate the bundled or PATH mutagen binary."""
    env = os.getenv("JC_MUTAGEN_PATH")
    if env and os.path.isfile(env):
        return env
    # bundled next to the running binary (PyInstaller payload)
    import sys
    here = os.path.dirname(os.path.abspath(getattr(sys, "_MEIPASS", sys.argv[0]) or ""))
    for cand in (os.path.join(here, "mutagen"), os.path.join(here, "bin", "mutagen")):
        if os.path.isfile(cand):
            return cand
    return shutil.which("mutagen")


class MutagenDriver:
    def __init__(self, mutagen_path: Optional[str] = None,
                 runner: Optional[Runner] = None, env: Optional[dict] = None):
        self._mutagen = mutagen_path or find_mutagen()
        self._run = runner or _default_runner
        self._env = env

    def _require(self) -> str:
        if not self._mutagen:
            raise MutagenError(
                "mutagen binary not found — sync engine unavailable on this client")
        return self._mutagen

    def ensure_daemon(self) -> None:
        rc, _out, err = self._run([self._require(), "daemon", "start"], self._env)
        # `daemon start` returns non-zero if already running on some versions;
        # only treat a hard failure (binary/permission) as fatal.
        if rc not in (0, None) and "already running" not in (err or "").lower():
            log.debug("mutagen daemon start rc=%s: %s", rc, err)

    def start_sync(self, *, session_id: str, local_path: str, remote_host: str,
                   remote_path: str, ignore: Optional[list] = None) -> str:
        name = session_name(session_id)
        # Terminate any prior session of this name first (idempotent restart).
        self._run(terminate_argv(self._require(), name), self._env)
        argv = create_sync_argv(self._require(), name=name, local_path=local_path,
                                remote_host=remote_host, remote_path=remote_path,
                                ignore=ignore)
        rc, _out, err = self._run(argv, self._env)
        if rc not in (0, None):
            raise MutagenError(f"mutagen sync create failed: {(err or '').strip()}")
        return name

    def status(self, session_id: str) -> dict:
        name = session_name(session_id)
        rc, out, _err = self._run(status_argv(self._require(), name), self._env)
        if rc not in (0, None):
            return {"status": "error", "conflicts": 0, "done": 0, "total": 0,
                    "error": (_err or "session not found").strip()}
        return parse_status(out)

    def stop_sync(self, session_id: str) -> None:
        self._run(terminate_argv(self._require(), session_name(session_id)), self._env)
