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
    ``connecting | syncing | synced | conflicts | error | unknown``.

    Mutagen serializes ``Status`` to MACHINE tokens (its ``MarshalText`` form),
    NOT the human ``Description()`` strings — e.g. ``"watching"``,
    ``"scanning"``, ``"staging-beta"``, ``"connecting-alpha"``,
    ``"disconnected"``, ``"halted-on-root-deletion"``. ``{{json .}}`` always
    emits a JSON ARRAY of sessions. Staging progress lives nested under
    ``beta.stagingProgress`` (a ReceiverState with ``receivedFiles`` /
    ``expectedFiles``), never at top level.
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
    if isinstance(data, list):
        data = data[0] if data else {}
    if not isinstance(data, dict):
        return out

    conflicts = data.get("conflicts")
    out["conflicts"] = len(conflicts) if isinstance(conflicts, list) else 0

    s = str(data.get("status") or "").lower()

    err = data.get("lastError") or data.get("error")
    if isinstance(err, str) and err:
        out["error"] = err

    # Progress: beta.stagingProgress.{receivedFiles,expectedFiles} (try alpha
    # too). The object is omitted unless actively staging.
    for endpoint in ("beta", "alpha"):
        ep = data.get(endpoint)
        prog = ep.get("stagingProgress") if isinstance(ep, dict) else None
        if isinstance(prog, dict):
            d, t = prog.get("receivedFiles"), prog.get("expectedFiles")
            if isinstance(d, (int, float)) and isinstance(t, (int, float)) and t:
                out["done"], out["total"] = int(d), int(t)
                break

    if out["error"] or "error" in s or "halted" in s:
        # a halted-on-* session is dead, not syncing — surface it.
        out["status"] = "error"
        if not out["error"] and s:
            out["error"] = s
    elif out["conflicts"] > 0 or "conflict" in s:
        out["status"] = "conflicts"
    elif any(w in s for w in ("disconnect", "waiting", "connecting")):
        out["status"] = "connecting"
    elif "watching" in s:
        out["status"] = "synced"
    elif s == "":
        out["status"] = "unknown"   # no session / empty list
    else:
        # scanning / reconciling / staging-* / transitioning / saving / etc.
        out["status"] = "syncing"
    return out


# ── runner + driver ───────────────────────────────────────────────────────────

# runner(argv, env, timeout) -> (returncode:int, stdout:str, stderr:str)
Runner = Callable[..., tuple]


# `sync create` blocks until both endpoints connect + the remote agent is
# deployed (Mutagen scp's its ~15 MB agent on first use) — over a tunneled relay
# that can take a while. Give it a generous cap; status/terminate stay short.
_DEFAULT_TIMEOUT = 30
_CREATE_TIMEOUT = 300


def _default_runner(argv: list, env: Optional[dict] = None,
                    timeout: Optional[int] = None) -> tuple:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, env=env,
                           timeout=timeout or _DEFAULT_TIMEOUT)
        return p.returncode, p.stdout or "", p.stderr or ""
    except FileNotFoundError as exc:
        raise MutagenError(f"mutagen not found: {exc}") from exc
    except subprocess.TimeoutExpired as exc:
        return 1, "", f"timeout: {exc}"


def _client_state_dir() -> str:
    try:
        from jc_client.logger import state_dir
        return str(state_dir())
    except Exception:
        return os.path.expanduser("~/.jarviscopilot-client")


def find_mutagen() -> Optional[str]:
    """Locate the mutagen binary: explicit override, the fetched cache (managed
    by mutagen_install — the normal case), the PyInstaller payload, then PATH."""
    env = os.getenv("JC_MUTAGEN_PATH")
    if env and os.path.isfile(env):
        return env
    # the version we fetch on update/first-sync lives in the client state dir
    try:
        from jc_client import mutagen_install
        cached = mutagen_install.installed_path(_client_state_dir())
        if cached:
            return cached
    except Exception:
        pass
    # bundled in the PyInstaller payload: _MEIPASS is already the bundle ROOT
    # dir (do NOT dirname it); a non-frozen run looks next to argv[0].
    import sys
    if getattr(sys, "frozen", False) and getattr(sys, "_MEIPASS", None):
        base = sys._MEIPASS
    else:
        base = os.path.dirname(os.path.abspath(sys.argv[0] or ""))
    for cand in (os.path.join(base, "mutagen"), os.path.join(base, "bin", "mutagen")):
        if os.path.isfile(cand):
            return cand
    return shutil.which("mutagen")


class MutagenDriver:
    def __init__(self, mutagen_path: Optional[str] = None,
                 runner: Optional[Runner] = None, env: Optional[dict] = None):
        self._mutagen = mutagen_path or find_mutagen()
        self._run = runner or _default_runner
        self._env = env

    def has_engine(self) -> bool:
        return bool(self._mutagen)

    def set_path(self, path: str) -> None:
        self._mutagen = path

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
        rc, _out, err = self._run(argv, self._env, _CREATE_TIMEOUT)
        if rc not in (0, None):
            raise MutagenError(f"mutagen sync create failed: {(err or '').strip()}")
        return name

    def status(self, session_id: str) -> dict:
        name = session_name(session_id)
        rc, out, _err = self._run(status_argv(self._require(), name), self._env)
        if rc not in (0, None):
            # A just-created session can briefly not be listable (create/list
            # race) — report 'connecting', not a hard error, so startup doesn't
            # flash red. A persistent failure still self-evidences via the panel.
            return {"status": "connecting", "conflicts": 0, "done": 0,
                    "total": 0, "error": None}
        return parse_status(out)

    def stop_sync(self, session_id: str) -> None:
        self._run(terminate_argv(self._require(), session_name(session_id)), self._env)
