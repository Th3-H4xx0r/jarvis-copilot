"""Dashcam relay: moves staged clips from the webui's staging area to every destination
(Google Drive, SFTP, FTP, SMB) through a supervised ``rclone rcd``, and streams clips back.

Process model::

    webui ──HTTP (basic auth, 127.0.0.1 only)──► rclone rcd --rc-serve --config <state>/dashcam/rclone.conf
                                                    ├─ config/create|update|delete   remotes "jc_<dest_id>"
                                                    ├─ operations/copyfile _async    one job per clip x destination
                                                    ├─ job/status                    polled by RelayWorker
                                                    └─ GET /[remote:dir]/file        Range-aware stream proxy

- ``rclone rcd`` is spawned lazily on first use with a random rc password passed through
  ``RCLONE_RC_USER``/``RCLONE_RC_PASS`` (not argv, so ``ps`` never shows it), on a free
  localhost port, and respawned when it has died. Missing binary -> ``RelayUnavailable``.
- Destination secrets (passwords, Drive tokens, client secrets) go only into rclone's own
  config, passwords obscured by rclone (``opt.obscure``). They are never logged or returned:
  rclone error text is scrubbed of them before it is raised.
- Drive remotes are created non-interactively from a token made by ``rclone authorize drive``.
  rclone then asks follow-up questions; only the known-safe ones are answered (keep the shared
  client id warning acknowledged, never refresh the pasted token, no shared drive). Any other
  question - e.g. ``config_is_local``, which starts a browser OAuth flow - aborts and deletes
  the half-made remote.
- ``RelayWorker`` (one daemon thread per process, started from the routes) walks staged clips
  every few seconds: pending -> start copy (``uploading``) -> poll -> ``done``; a failure goes
  back to ``pending`` after 30 s, then 120 s, and is ``failed`` (with rclone's message) after the
  third attempt. Once every enabled destination is done the staging file is released.
  Copies overwrite by name, so a retried or restarted job never duplicates a clip.
- On a destination a clip lands at ``<path>/<camera_id>/<YYYY-MM-DD>/<kind>/<lens>/<name>``
  (``remote_path_for``; the UTC day of the clip's start, ``undated`` without one).
"""
from __future__ import annotations

import atexit
import base64
import http.client
import json
import logging
import math
import os
import shutil
import signal
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, Iterator, NamedTuple
from urllib.parse import quote

from api.dashcam_store import KINDS, parse_iso

logger = logging.getLogger(__name__)

RC_USER = "jc"
RC_TIMEOUT_S = 30
TEST_TIMEOUT_S = 75        # testing a destination: longer than rclone's own 60 s connect timeout
START_TIMEOUT_S = 15
RESPAWN_BACKOFF_S = 30     # after rclone rcd failed to start, wait this long before trying again
STREAM_BLOCK = 256 * 1024
MAX_ATTEMPTS = 3
BACKOFF_BASE_S = 30
MAX_ACTIVE_JOBS = 4
JOB_EXPIRE = "6h"          # rclone forgets finished async jobs after 1 min by default
WORKER_INTERVAL_S = 5.0
LOG_MAX_BYTES = 10 * 1024 * 1024

# The only config questions answered while creating a remote non-interactively.
SAFE_ANSWERS = {
    "config_shared_client_id": "true",   # "rclone's shared Drive client id is being retired - continue?"
    "config_refresh_token": "false",     # keep the pasted token; "true" starts an OAuth flow
    "config_change_team_drive": "false",  # a normal My Drive, not a shared drive
}
DEFAULT_PORTS = {"sftp": 22, "ftp": 21, "smb": 445}
DEST_TYPES = ("drive", "sftp", "ftp", "smb")
_SECRET_FIELDS = ("password", "token", "client_secret")
_PRIORITY = {"event": 0, "photo": 1, "parking": 2, "normal": 3}


class RelayUnavailable(Exception):
    """rclone is not installed, or rclone rcd would not start."""


class RelayError(Exception):
    """rclone answered with an error (its message, scrubbed of secrets)."""


class _Down(Exception):
    """The rc endpoint could not be reached (``refused``: nothing listens on the port)."""

    def __init__(self, message: str, refused: bool = False):
        super().__init__(message)
        self.refused = refused


def default_state_dir() -> Path:
    root = os.environ.get("HERMES_WEBUI_STATE_DIR")
    return Path(root) if root else Path.home() / ".jarviscopilot" / "webui"


def local_allowed() -> bool:
    """``local`` destinations exist for tests only."""
    return os.environ.get("JC_DASHCAM_ALLOW_LOCAL", "").strip() == "1"


def _scrub(text: str, secrets: list[str]) -> str:
    for s in secrets:
        if s and len(s) >= 3:
            text = text.replace(s, "***")
    return text


def _segment(value, fallback: str = "_") -> str:
    text = str(value or "").replace("\\", "/").replace("/", "_").strip()
    return fallback if text in ("", ".", "..") else text


def remote_path_for(dest: dict, clip: dict) -> str:
    """``<dest.path>/<camera_id>/<YYYY-MM-DD (UTC) of the clip start>/<kind>/<lens>/<name>``
    (lens ``front`` when the clip has none). The lens folder keeps a front and a rear clip that
    share a file name apart. A leading ``/`` on the destination path is kept (absolute on
    SFTP/SMB/local)."""
    base = str(dest.get("path") or "")
    absolute = base.startswith("/")
    base = base.strip("/")
    ts = parse_iso(clip.get("start"))
    day = time.strftime("%Y-%m-%d", time.gmtime(ts)) if ts is not None else "undated"
    name = str(clip.get("name") or "").replace("\\", "/").rsplit("/", 1)[-1]
    rel = "/".join([_segment(clip.get("camera_id")), day, _segment(clip.get("kind")),
                    _segment(clip.get("lens") or "front"), _segment(name, "clip")])
    prefix = ("/" if absolute else "") + (base + "/" if base else "")
    return prefix + rel


def _split(remote_path: str) -> tuple[str, str]:
    """(folder, file name); the folder goes into the rclone Fs so relative and absolute paths
    both mean what they say on every backend."""
    if "/" not in remote_path:
        return "", remote_path
    folder, name = remote_path.rsplit("/", 1)
    if folder == "" and remote_path.startswith("/"):
        folder = "/"
    return folder, name


def _content_type(name: str) -> str:
    lower = name.lower()
    if lower.endswith((".jpg", ".jpeg")):
        return "image/jpeg"
    if lower.endswith(".mov"):
        return "video/quicktime"
    if lower.endswith(".ts"):
        return "video/mp2t"
    return "video/mp4"


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


def remote_parameters(dtype: str, fields: dict) -> tuple[dict, list[str]]:
    """rclone ``parameters`` for one destination type, and the secret values in them.
    Raises ValueError for a bad type or missing fields."""
    fields = fields or {}
    secrets_ = [str(fields[k]) for k in _SECRET_FIELDS if fields.get(k)]
    if dtype == "local":
        if not local_allowed():
            raise ValueError("local destinations are for tests only")
        return {}, secrets_
    if dtype == "drive":
        token = fields.get("token")
        if isinstance(token, dict):
            token = json.dumps(token, separators=(",", ":"))
        if not isinstance(token, str) or not token.strip():
            raise ValueError("a Drive destination needs the token from `rclone authorize drive`")
        try:
            parsed = json.loads(token)
        except ValueError:
            raise ValueError("the Drive token must be the JSON printed by `rclone authorize drive`") from None
        if not isinstance(parsed, dict):
            raise ValueError("the Drive token must be a JSON object")
        params = {"scope": "drive", "token": token.strip()}
        for key in ("client_id", "client_secret", "root_folder_id"):
            if fields.get(key):
                params[key] = str(fields[key])
        return params, secrets_ + [token.strip()]
    if dtype not in DEFAULT_PORTS:
        raise ValueError(f"destination type must be one of {', '.join(DEST_TYPES)}")
    host, user = fields.get("host"), fields.get("user")
    if not isinstance(host, str) or not host.strip():
        raise ValueError(f"a {dtype} destination needs a host")
    if not isinstance(user, str) or not user.strip():
        raise ValueError(f"a {dtype} destination needs a user")
    port = fields.get("port") or DEFAULT_PORTS[dtype]
    try:
        port = int(port)
    except (TypeError, ValueError):
        raise ValueError("port must be a number") from None
    if not 1 <= port <= 65535:
        raise ValueError("port must be between 1 and 65535")
    params = {"host": host.strip(), "user": user.strip(), "port": str(port)}
    if fields.get("password"):
        params["pass"] = str(fields["password"])
    if dtype == "ftp" and fields.get("explicit_tls"):
        params["explicit_tls"] = "true"
    if dtype == "smb" and fields.get("domain"):
        params["domain"] = str(fields["domain"])
    return params, secrets_


class Relay:
    """Client for (and supervisor of) one ``rclone rcd``. With ``url`` it attaches to an rc
    endpoint someone else runs (tests) instead of spawning one."""

    def __init__(self, state_dir=None, binary: str | None = None, *, url: str | None = None,
                 user: str | None = None, password: str | None = None):
        self.state_dir = Path(state_dir) if state_dir else default_state_dir()
        self.dir = self.state_dir / "dashcam"
        self.config_path = self.dir / "rclone.conf"
        self._binary = binary
        self._attached = url is not None
        self._url = url.rstrip("/") if url else None
        self._user = user or RC_USER
        self._password = password or ""
        self._proc: subprocess.Popen | None = None
        self._lock = threading.RLock()
        # Bumped on every spawn. rclone numbers jobs from 1 in each process, so a job id is only
        # meaningful together with the generation of the process that issued it.
        self.generation = 0
        self._spawn_error: str | None = None   # why the last spawn failed, and when
        self._spawn_failed_at = 0.0

    # ── process ──────────────────────────────────────────────────────────────
    def binary(self) -> str | None:
        exe = self._binary or os.environ.get("JC_RCLONE_BIN") or shutil.which("rclone")
        return exe if exe and os.path.isfile(exe) and os.access(exe, os.X_OK) else None

    def ensure_running(self) -> None:
        if self._attached:
            return
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                return
            if self._spawn_error is not None:
                wait = self._spawn_failed_at + RESPAWN_BACKOFF_S - time.monotonic()
                if wait > 0:
                    raise RelayUnavailable(f"{self._spawn_error}; trying again in {math.ceil(wait)} s")
            self._spawn()

    def _exited(self) -> bool:
        proc = self._proc
        return proc is None or proc.poll() is not None

    def _spawn_failed(self, message: str) -> RelayUnavailable:
        self._spawn_error, self._spawn_failed_at = message, time.monotonic()
        return RelayUnavailable(message)

    def _pid_file(self) -> Path:
        return self.dir / "rclone.pid"

    def _kill_stale(self) -> None:
        """Stops an rcd a previous webui left behind on this config (it holds a stale password)."""
        try:
            pid = int(self._pid_file().read_text().strip())
        except (OSError, ValueError):
            return
        try:
            cmd = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True,
                                 timeout=5).stdout
        except Exception:
            return
        if "rclone" in cmd and "rcd" in cmd and str(self.config_path) in cmd:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass

    def _spawn(self) -> None:
        exe = self.binary()
        if exe is None:
            raise RelayUnavailable("rclone is not installed on the server (run scripts/install-rclone.sh)")
        self.dir.mkdir(parents=True, exist_ok=True)
        self._kill_stale()
        log_path = self.dir / "rclone.log"
        try:
            if log_path.stat().st_size > LOG_MAX_BYTES:
                log_path.unlink()
        except OSError:
            pass
        import secrets as _secrets
        port = _free_port()
        password = _secrets.token_hex(16)
        env = dict(os.environ, RCLONE_RC_USER=self._user, RCLONE_RC_PASS=password)
        cmd = [exe, "rcd", "--rc-addr", f"127.0.0.1:{port}", "--rc-serve",
               "--config", str(self.config_path), "--log-level", "NOTICE",
               "--rc-job-expire-duration", JOB_EXPIRE]
        self.generation += 1
        try:
            with open(log_path, "ab") as log:
                proc = subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                        stderr=subprocess.STDOUT)
        except OSError as exc:
            raise self._spawn_failed(f"could not start rclone rcd: {exc}") from None
        self._proc, self._url, self._password = proc, f"http://127.0.0.1:{port}", password
        try:
            self._pid_file().write_text(str(proc.pid))
        except OSError:
            pass
        deadline = time.monotonic() + START_TIMEOUT_S
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                self._proc = None
                raise self._spawn_failed(f"rclone rcd exited with code {proc.returncode} (see {log_path})")
            try:
                self._post("core/version", {}, timeout=2)
                logger.info("dashcam relay: rclone rcd running on 127.0.0.1:%s (pid %s)", port, proc.pid)
                self._spawn_error = None
                return
            except (_Down, RelayError):
                time.sleep(0.1)
        self.shutdown()
        raise self._spawn_failed("rclone rcd did not start in time")

    def shutdown(self) -> None:
        with self._lock:
            proc, self._proc = self._proc, None
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()

    # ── rc ───────────────────────────────────────────────────────────────────
    def _auth(self) -> str:
        return "Basic " + base64.b64encode(f"{self._user}:{self._password}".encode()).decode()

    def _post(self, method: str, params: dict | None, timeout: float | None = None) -> dict:
        """One rc call. A timeout is a RelayError (rclone is there, just slow - e.g. a dead SFTP
        host); only an unreachable endpoint is ``_Down``."""
        timeout = RC_TIMEOUT_S if timeout is None else timeout
        req = urllib.request.Request(f"{self._url}/{method}", data=json.dumps(params or {}).encode(),
                                     headers={"Content-Type": "application/json", "Authorization": self._auth()},
                                     method="POST")
        timed_out = RelayError(f"rclone timed out after {timeout:g} s on {method}")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            try:
                raw = exc.read()
                msg = json.loads(raw or b"{}").get("error") or f"HTTP {exc.code}"
            except (ValueError, OSError, http.client.HTTPException):
                msg = f"HTTP {exc.code}"
            raise RelayError(str(msg)) from None
        except TimeoutError:
            raise timed_out from None
        except urllib.error.URLError as exc:
            if isinstance(exc.reason, TimeoutError):
                raise timed_out from None
            raise _Down(str(exc), refused=isinstance(exc.reason, ConnectionRefusedError)) from None
        except (http.client.HTTPException, OSError) as exc:
            raise _Down(str(exc), refused=isinstance(exc, ConnectionRefusedError)) from None
        try:
            out = json.loads(raw or b"{}")
        except ValueError:
            raise RelayError("rclone answered with something that is not JSON") from None
        return out if isinstance(out, dict) else {}

    def rc(self, method: str, params: dict | None = None, *, timeout: float | None = None) -> dict:
        """Calls one rc method; RelayError carries rclone's ``error`` text. rclone rcd is restarted
        only when it has exited or refuses connections - never because one call was slow, which
        would kill every copy it is running."""
        self.ensure_running()
        try:
            return self._post(method, params, timeout)
        except _Down as exc:
            if self._attached or not (exc.refused or self._exited()):
                raise RelayError(f"rclone is not answering: {exc}") from None
        # The process died between calls: start a fresh one and try once more.
        self.shutdown()
        self.ensure_running()
        try:
            return self._post(method, params, timeout)
        except _Down as exc:
            raise RelayError(f"rclone is not answering: {exc}") from None

    # ── remotes ──────────────────────────────────────────────────────────────
    def create_remote(self, dest_id: str, dtype: str, fields: dict) -> str:
        """Creates remote ``jc_<dest_id>``; ValueError for bad fields, RelayError if rclone refuses."""
        params, secret_values = remote_parameters(dtype, fields)
        name = "jc_" + dest_id
        opt = {"obscure": True, "nonInteractive": True}
        try:
            reply = self.rc("config/create", {"name": name, "type": dtype, "parameters": params, "opt": opt})
            for _ in range(10):
                if not reply.get("State"):
                    break
                question = (reply.get("Option") or {}).get("Name")
                if question not in SAFE_ANSWERS:
                    raise RelayError(f"rclone asked {question!r} while setting up the destination; "
                                     "set it up with fewer options or report this")
                reply = self.rc("config/update", {"name": name, "parameters": {}, "opt": {
                    "continue": True, "nonInteractive": True, "obscure": True,
                    "state": reply["State"], "result": SAFE_ANSWERS[question]}})
            else:
                raise RelayError("rclone kept asking questions while setting up the destination")
            if reply.get("Error"):
                raise RelayError(str(reply["Error"]))
        except RelayError as exc:
            message = _scrub(str(exc), secret_values)
            try:
                self.rc("config/delete", {"name": name})
            except (RelayError, RelayUnavailable):
                pass
            logger.warning("dashcam relay: creating %s remote %s failed: %s", dtype, name, message)
            raise RelayError(message) from None
        return name

    def delete_remote(self, remote: str) -> None:
        self.rc("config/delete", {"name": remote})

    def test_remote(self, remote: str, path: str) -> tuple[bool, str | None]:
        """Creates the base folder if needed and lists it: proves the login and write access path."""
        fs = f"{remote}:{path or ''}"
        try:
            self.rc("operations/mkdir", {"fs": fs, "remote": ""}, timeout=TEST_TIMEOUT_S)
            self.rc("operations/list", {"fs": fs, "remote": ""}, timeout=TEST_TIMEOUT_S)
        except RelayError as exc:
            return False, str(exc)
        return True, None

    # ── copies ───────────────────────────────────────────────────────────────
    def start_copy(self, local_path: str, remote: str, remote_path: str, group: str | None = None) -> int:
        """Starts an async copy; ``group`` tags the job so ``job_status`` can tell it from another
        job that got the same id in a later rclone process."""
        folder, name = _split(remote_path)
        params = {"srcFs": "/", "srcRemote": str(local_path).lstrip("/"),
                  "dstFs": f"{remote}:{folder}", "dstRemote": name, "_async": True}
        if group:
            params["_group"] = group
        reply = self.rc("operations/copyfile", params)
        try:
            return int(reply["jobid"])
        except (KeyError, TypeError, ValueError):
            raise RelayError("rclone did not return a job id") from None

    def job_status(self, jobid: int, group: str | None = None) -> dict:
        """``{finished, success, error, lost}``. ``lost`` (with finished) means rclone no longer
        knows the job - it restarted, or the job expired - or the id now names a job of another
        group: nothing can be said about the copy, so it must be made again."""
        try:
            reply = self.rc("job/status", {"jobid": int(jobid)})
        except RelayError as exc:
            if "job not found" not in str(exc).lower():
                raise
            return {"finished": True, "success": False, "error": str(exc), "lost": True}
        if group is not None and reply.get("group") != group:
            return {"finished": True, "success": False, "lost": True,
                    "error": f"job {jobid} now belongs to {reply.get('group')!r}"}
        return {"finished": bool(reply.get("finished")), "success": bool(reply.get("success")),
                "error": reply.get("error") or None, "lost": False}

    def stop_job(self, jobid: int, generation: int | None = None) -> bool:
        """Best-effort ``job/stop``. Never starts or restarts rclone, and does nothing when the job
        came from an older process: there the id may name someone else's job."""
        if generation is not None and generation != self.generation:
            return False
        if not self._attached and (self._proc is None or self._proc.poll() is not None):
            return False
        try:
            self._post("job/stop", {"jobid": int(jobid)})
        except (_Down, RelayError):
            return False
        return True

    # ── streaming ────────────────────────────────────────────────────────────
    def open_stream(self, remote: str, remote_path: str, range_header: str | None
                    ) -> tuple[int, dict, Iterator[bytes]]:
        """Proxies ``GET /[remote:folder]/name`` from rclone's ``--rc-serve`` with the caller's Range;
        returns (status, headers, body blocks)."""
        self.ensure_running()
        folder, name = _split(remote_path)
        url = f"{self._url}/" + quote(f"[{remote}:{folder}]/{name}", safe="/")
        headers = {"Authorization": self._auth()}
        if range_header:
            headers["Range"] = range_header
        req = urllib.request.Request(url, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=RC_TIMEOUT_S)
        except urllib.error.HTTPError as exc:
            body = exc.read()
            exc.close()
            return exc.code, {"Content-Type": "application/json"}, iter([body])
        except (urllib.error.URLError, OSError) as exc:
            raise RelayError(f"rclone is not answering: {exc}") from None
        out = {}
        for key in ("Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified"):
            if resp.headers.get(key):
                out[key] = resp.headers[key]
        if out.get("Content-Type", "application/octet-stream").startswith(("application/octet-stream", "text/")):
            out["Content-Type"] = _content_type(name)
        out.setdefault("Accept-Ranges", "bytes")

        def blocks() -> Iterator[bytes]:
            try:
                while True:
                    block = resp.read(STREAM_BLOCK)
                    if not block:
                        break
                    yield block
            finally:
                resp.close()

        return resp.status, out, blocks()


# ── process singleton ────────────────────────────────────────────────────────

_relay: Relay | None = None
_relay_lock = threading.Lock()


def relay() -> Relay:
    global _relay
    with _relay_lock:
        if _relay is None:
            _relay = Relay()
            atexit.register(_relay.shutdown)
        return _relay


# ── worker ───────────────────────────────────────────────────────────────────

def _applicable(dest: dict, clip: dict) -> bool:
    return bool(dest.get("enabled")) and clip.get("kind") in (dest.get("kinds") or KINDS)


class _Job(NamedTuple):
    """One copy in flight: rclone's job id is only meaningful with the generation of the rclone
    process that issued it and the group the copy was tagged with."""
    jobid: int
    generation: int
    group: str
    upload_id: str


def _group(clip_id: str, dest_id: str, upload_id: str) -> str:
    return f"dashcam/{clip_id}/{dest_id}/{upload_id}"


class RelayWorker(threading.Thread):
    """Moves staged clips to their destinations; ``tick()`` is one pass (called every
    ``interval`` seconds by ``run``). Job ids live in memory: after a restart an ``uploading``
    entry without a job simply starts again. A job whose rclone process is gone, or whose id now
    names another job, is *lost*: the entry goes back to pending and the copy is made again
    without counting an attempt (copies overwrite by name)."""

    def __init__(self, store_factory: Callable, relay_obj=None, interval: float = WORKER_INTERVAL_S,
                 clock: Callable[[], float] = time.time):
        super().__init__(name="dashcam-relay", daemon=True)
        self.store_factory = store_factory
        self.relay = relay_obj
        self.interval = interval
        self.clock = clock
        self._jobs: dict[tuple[str, str], _Job] = {}
        self._stop_event = threading.Event()
        self._warned_unavailable = False

    def stop(self) -> None:
        self._stop_event.set()

    def run(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.tick()
            except Exception:
                logger.exception("dashcam relay worker tick failed")
            self._stop_event.wait(self.interval)

    def _relay(self) -> Relay:
        return self.relay if self.relay is not None else relay()

    def tick(self) -> None:
        store = self.store_factory()
        dests = {d["id"]: d for d in store.destinations()}
        self._prune(store, dests)
        staged = store.staged_clip_ids()
        if not staged:
            return
        clips = []
        for cid in staged:
            store.queue_destinations(cid)
            clip = store.get_clip(cid)
            if clip is not None and (clip.get("upload") or {}).get("state") == "staged":
                clips.append(clip)
        clips.sort(key=lambda c: (_PRIORITY.get(c.get("kind"), 9), -(parse_iso(c.get("start")) or 0)))
        try:
            for clip in clips:
                self._clip(store, clip, dests)
                store.release_staging_if_done(clip["id"])
            self._warned_unavailable = False
        except RelayUnavailable as exc:
            if not self._warned_unavailable:
                logger.warning("dashcam relay idle: %s", exc)
                self._warned_unavailable = True

    def _prune(self, store, dests: dict) -> None:
        """Forgets (and best-effort stops) every job nothing waits for any more: its clip's upload is
        gone or replaced, its entry is no longer uploading, or its destination was deleted, disabled
        or stopped taking the clip's kind. Without this the slots leak until MAX_ACTIVE_JOBS blocks
        every copy."""
        for key, job in list(self._jobs.items()):
            cid, dest_id = key
            clip = store.get_clip(cid)
            up = (clip or {}).get("upload") or {}
            entry = ((clip or {}).get("destinations") or {}).get(dest_id)
            dest = dests.get(dest_id)
            if (clip is not None and up.get("state") == "staged" and up.get("upload_id") == job.upload_id
                    and isinstance(entry, dict) and entry.get("state") == "uploading"
                    and dest is not None and _applicable(dest, clip)):
                continue
            del self._jobs[key]
            try:
                self._relay().stop_job(job.jobid, job.generation)
            except (RelayError, RelayUnavailable):
                pass

    def _poll(self, job: _Job) -> dict | None:
        """The job's status, lost when its rclone process is gone; None when rclone could not say
        right now (ask again next tick)."""
        relay_ = self._relay()
        if job.generation != relay_.generation:
            return {"finished": True, "success": False, "lost": True, "error": None}
        try:
            return relay_.job_status(job.jobid, group=job.group)
        except RelayError as exc:
            logger.info("dashcam relay: no status for job %s yet: %s", job.jobid, exc)
            return None

    def _clip(self, store, clip: dict, dests: dict) -> None:
        cid = clip["id"]
        upload_id = clip["upload"].get("upload_id")
        for dest_id, entry in list((clip.get("destinations") or {}).items()):
            dest = dests.get(dest_id)
            if dest is None or not _applicable(dest, clip) or not isinstance(entry, dict):
                continue
            key = (cid, dest_id)
            state = entry.get("state")
            attempts = int(entry.get("attempts") or 0)
            if state == "uploading":
                job = self._jobs.get(key)
                if job is not None:
                    status = self._poll(job)
                    if status is None or not status["finished"]:
                        continue
                    self._jobs.pop(key, None)
                    if status.get("lost"):
                        logger.info("dashcam relay: lost the copy of %s -> %s (%s); copying again",
                                    cid, dest_id, status.get("error") or "rclone restarted")
                        store.set_destination_state(cid, dest_id, "pending", entry.get("error"),
                                                    attempts=attempts, upload_id=job.upload_id)
                    elif status["success"]:
                        store.set_destination_state(cid, dest_id, "done", remote_path=entry.get("remote_path"),
                                                    attempts=attempts, upload_id=job.upload_id)
                        continue
                    else:
                        self._fail(store, cid, dest_id, attempts, status["error"] or "copy failed", job.upload_id)
                        continue
                state = "pending"  # restarted process or lost job: copy again
            if state != "pending":
                continue
            if attempts >= MAX_ATTEMPTS:
                store.set_destination_state(cid, dest_id, "failed", entry.get("error") or "copy failed",
                                            attempts=attempts, upload_id=upload_id)
                continue
            if entry.get("next_at") and self.clock() < float(entry["next_at"]):
                continue
            if not dest.get("remote") or not upload_id or len(self._jobs) >= MAX_ACTIVE_JOBS:
                continue
            remote_path = remote_path_for(dest, clip)
            relay_ = self._relay()
            relay_.ensure_running()
            generation = relay_.generation
            group = _group(cid, dest_id, upload_id)
            try:
                jobid = relay_.start_copy(str(store.staging_path(upload_id)), dest["remote"], remote_path,
                                          group=group)
            except RelayError as exc:
                self._fail(store, cid, dest_id, attempts, str(exc), upload_id)
                continue
            if relay_.generation != generation:
                generation = -1  # rclone restarted around the call: which process owns the id is unclear
            self._jobs[key] = _Job(jobid, generation, group, upload_id)
            store.set_destination_state(cid, dest_id, "uploading", remote_path=remote_path, attempts=attempts,
                                        upload_id=upload_id)

    def _fail(self, store, cid: str, dest_id: str, attempts: int, error: str, upload_id: str) -> None:
        attempts += 1
        if attempts >= MAX_ATTEMPTS:
            store.set_destination_state(cid, dest_id, "failed", error, attempts=attempts, upload_id=upload_id)
            logger.warning("dashcam relay: %s -> %s failed after %d attempts: %s", cid, dest_id, attempts, error)
        else:
            store.set_destination_state(cid, dest_id, "pending", error, attempts=attempts, upload_id=upload_id,
                                        next_at=self.clock() + BACKOFF_BASE_S * 4 ** (attempts - 1))


_worker: RelayWorker | None = None
_worker_lock = threading.Lock()


def ensure_worker(store_factory) -> None:
    """Starts the process's RelayWorker once (``JC_DASHCAM_WORKER=0`` turns it off)."""
    global _worker
    if os.environ.get("JC_DASHCAM_WORKER", "").strip() == "0":
        return
    with _worker_lock:
        if _worker is not None and _worker.is_alive():
            return
        _worker = RelayWorker(store_factory)
        _worker.start()
