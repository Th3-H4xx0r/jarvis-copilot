"""jc-client's end of the Jarvis Terminal Bridge VS Code extension.

Nothing outside VS Code can type into its built-in terminal, so a tiny
extension (desktop_client/vscode_extension) in every VS Code window connects
to a UNIX socket here and says hello: its window id, its open folders and its
terminals' shell pids. Jarvis then asks the window that owns a shell to type a
message into it, the window that has a folder open to run a command there, or
a window to show a terminal.

Wire format: newline-delimited JSON both ways.

* extension → here: ``{"type": "hello", "window", "folders", "terminals", "submit"?}``
  (``submit`` lists the keys it can press: "enter", and "now" = Ctrl+Enter)
  (again whenever a terminal opens or closes) and
  ``{"type": "result", "req", "ok", "error"?}`` (one per request).
* here → extension: ``{"type": "send_text"|"run"|"focus", "req", ...}``.

Every call is best-effort and answers False rather than raising.
"""
from __future__ import annotations

import itertools
import json
import logging
import os
import socket
import subprocess
import threading
from typing import Optional

log = logging.getLogger(__name__)

_MAX_LINE = 4 * 1024 * 1024
_MAX_ANCESTORS = 8


def default_socket_path() -> str:
    from jc_client.logger import state_dir
    return str(state_dir() / "vscode.sock")


def shell_pid_of(pid: int) -> Optional[int]:
    """The parent pid of ``pid`` (a Claude/Codex process → its shell), or None."""
    try:
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(int(pid))],
                             capture_output=True, text=True, timeout=3)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    try:
        ppid = int((out.stdout or "").strip())
    except ValueError:
        return None
    return ppid if ppid > 0 else None


_PASTE_START, _PASTE_END, _CTRL_ENTER = "\x1b[200~", "\x1b[201~", "\x1b[13;5u"


class _Conn:
    """One extension connection = one VS Code window."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.hello: Optional[dict] = None
        self.alive = True
        self.send_lock = threading.Lock()
        self.pending: dict[int, tuple[threading.Event, dict]] = {}

    def pids(self) -> set[int]:
        if not self.hello:
            return set()
        return {t["pid"] for t in self.hello.get("terminals", []) if isinstance(t.get("pid"), int)}


class VSCodeBridge:
    def __init__(self, sock_path: Optional[str] = None) -> None:
        self.path = sock_path or default_socket_path()
        self._lock = threading.RLock()
        self._conns: list[_Conn] = []
        self._sock: Optional[socket.socket] = None
        self._stop = threading.Event()
        self._req = itertools.count(1)

    # ── lifecycle ──────────────────────────────────────────────────────
    def start(self) -> None:
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            sock.bind(self.path)
        finally:
            os.umask(old)
        os.chmod(self.path, 0o600)
        sock.listen(16)
        self._stop.clear()
        self._sock = sock
        threading.Thread(target=self._accept_loop, daemon=True, name="vscode-accept").start()
        log.info("vscode bridge listening on %s", self.path)

    def stop(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        with self._lock:
            conns = list(self._conns)
        for conn in conns:
            self._drop(conn)
        try:
            os.unlink(self.path)
        except OSError:
            pass

    # ── what the windows told us ───────────────────────────────────────
    def windows(self) -> list[dict]:
        """The latest hello of every connected window: {window, folders, terminals}."""
        with self._lock:
            return [{"window": c.hello["window"], "folders": list(c.hello["folders"]),
                     "terminals": [dict(t) for t in c.hello["terminals"]]}
                    for c in self._conns if c.alive and c.hello]

    def terminal_pid_for(self, pid: int) -> Optional[int]:
        """The VS Code terminal shell that ``pid`` runs under, walking up its parents.

        Claude is usually a direct child of the shell; Codex runs behind a node
        wrapper, so its shell is a grandparent.
        """
        with self._lock:
            known = set().union(*(c.pids() for c in self._conns if c.alive))
        cur: Optional[int] = int(pid)
        for _ in range(_MAX_ANCESTORS):
            if cur is None or cur <= 1:
                return None
            if cur in known:
                return cur
            cur = shell_pid_of(cur)
        return None

    # ── requests ───────────────────────────────────────────────────────
    def send_text(self, shell_pid: int, text: str, timeout: float = 3.0, now: bool = False) -> bool:
        """Type ``text`` into the terminal whose shell is ``shell_pid`` and submit
        it: Return (Claude queues it while it works), or Ctrl+Enter with ``now``
        (Claude's "send now")."""
        conn = self._owner(shell_pid)
        if conn is None:
            return False
        text = str(text)
        if now and "now" not in ((getattr(conn, "hello", None) or {}).get("submit") or []):
            # Extension 0.1.0 ignores "submit": it pastes and presses Enter. End
            # the paste early and press Ctrl+Enter inside it; its Enter then lands
            # on an empty prompt, which does nothing (checked on a live session).
            text += _PASTE_END + _CTRL_ENTER + _PASTE_START
        return self._request(conn, {"type": "send_text", "pid": int(shell_pid), "text": text,
                                    "submit": "now" if now else "enter"}, timeout)

    def run_in_terminal(self, cwd: str, command: str, timeout: float = 3.0) -> bool:
        """Run ``command`` in a new terminal of the window that has ``cwd`` open."""
        best, best_len = None, -1
        with self._lock:
            for conn in self._conns:
                if not conn.alive or not conn.hello:
                    continue
                for folder in conn.hello["folders"]:
                    n = _containing_len(folder, cwd)
                    if n > best_len:
                        best, best_len = conn, n
        if best is None:
            return False
        return self._request(best, {"type": "run", "cwd": str(cwd), "command": str(command)},
                             timeout)

    def focus(self, shell_pid: int, timeout: float = 3.0) -> bool:
        """Show the terminal whose shell is ``shell_pid``."""
        conn = self._owner(shell_pid)
        if conn is None:
            return False
        return self._request(conn, {"type": "focus", "pid": int(shell_pid)}, timeout)

    # ── internals ──────────────────────────────────────────────────────
    def _owner(self, shell_pid: int) -> Optional[_Conn]:
        try:
            pid = int(shell_pid)
        except (TypeError, ValueError):
            return None
        with self._lock:
            for conn in reversed(self._conns):  # newest window wins a (rare) tie
                if conn.alive and pid in conn.pids():
                    return conn
        return None

    def _request(self, conn: _Conn, msg: dict, timeout: float) -> bool:
        req = next(self._req)
        done = threading.Event()
        slot: dict = {"ok": False}
        with self._lock:
            if not conn.alive:
                return False
            conn.pending[req] = (done, slot)
        try:
            data = (json.dumps(dict(msg, req=req)) + "\n").encode()
            with conn.send_lock:
                conn.sock.sendall(data)
            done.wait(timeout)
            return bool(slot["ok"])
        except OSError:
            self._drop(conn)
            return False
        finally:
            with self._lock:
                conn.pending.pop(req, None)

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            sock = self._sock
            if sock is None:
                return
            try:
                raw, _ = sock.accept()
            except OSError:
                return
            conn = _Conn(raw)
            with self._lock:
                self._conns.append(conn)
            threading.Thread(target=self._serve, args=(conn,), daemon=True,
                             name="vscode-conn").start()

    def _serve(self, conn: _Conn) -> None:
        buf = b""
        try:
            conn.sock.settimeout(None)
            while not self._stop.is_set():
                chunk = conn.sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self._on_line(conn, line)
                if len(buf) > _MAX_LINE:
                    log.debug("vscode bridge: oversized line, dropping window")
                    break
        except OSError:
            pass
        finally:
            self._drop(conn)

    def _on_line(self, conn: _Conn, line: bytes) -> None:
        try:
            msg = json.loads(line)
        except Exception:
            return
        if not isinstance(msg, dict):
            return
        kind = msg.get("type")
        if kind == "hello":
            hello = _clean_hello(msg)
            with self._lock:
                conn.hello = hello
        elif kind == "result":
            with self._lock:
                waiter = conn.pending.get(msg.get("req"))
            if waiter is not None:
                done, slot = waiter
                slot["ok"] = msg.get("ok") is True
                if msg.get("error"):
                    log.info("vscode bridge: window said no: %s", msg.get("error"))
                done.set()

    def _drop(self, conn: _Conn) -> None:
        with self._lock:
            conn.alive = False
            if conn in self._conns:
                self._conns.remove(conn)
            waiters = list(conn.pending.values())
        for done, _slot in waiters:
            done.set()  # slot stays ok=False → the caller answers at once
        try:
            conn.sock.shutdown(socket.SHUT_RDWR)  # wakes the reader blocked in recv
        except OSError:
            pass
        try:
            conn.sock.close()
        except OSError:
            pass


def _clean_hello(msg: dict) -> dict:
    folders = [str(f) for f in (msg.get("folders") or []) if isinstance(f, str) and f]
    terminals = []
    for t in msg.get("terminals") or []:
        if not isinstance(t, dict):
            continue
        pid = t.get("pid")
        entry = dict(t)
        entry["pid"] = pid if isinstance(pid, int) and not isinstance(pid, bool) else None
        terminals.append(entry)
    submit = [str(s) for s in (msg.get("submit") or []) if isinstance(s, str)]
    return {"window": str(msg.get("window") or ""), "folders": folders, "terminals": terminals,
            "submit": submit}


def _containing_len(folder: str, path: str) -> int:
    """len(folder) if ``path`` is ``folder`` or inside it, else -1 (symlinks resolved too)."""
    for f, p in ((os.path.normpath(folder), os.path.normpath(path)),
                 (os.path.realpath(folder), os.path.realpath(path))):
        if p == f or p.startswith(f.rstrip(os.sep) + os.sep):
            return len(f)
    return -1
