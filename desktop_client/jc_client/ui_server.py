"""``ui.sock`` — the local link between jc-client and the Jarvis Mac app.

The app (``mac_app/JarvisMac``) connects to ``~/.jarviscopilot-client/ui.sock``
(owner-only) and gets, as newline JSON:

* ``hello`` first — the loopback API origin (the pinned proxy, so the app never
  holds credentials), and the approvals / instructions switches;
* then whatever changes: ``sessions`` (the local engine), ``pending`` (the
  approvals and questions waiting in the arbiter), ``usage`` (Claude plan
  limits from the status line), ``topic`` (server pushes it subscribed to).

The app's requests (``decide``, ``session``, ``hooks``, ``subscribe``…) carry an
``id`` and get one ``reply`` with the same id. One thread per client; a client
that goes away is dropped on the next send.
"""
from __future__ import annotations

import json
import logging
import os
import socket
import threading
from typing import Callable, Optional

log = logging.getLogger(__name__)

_MAX_LINE = 1024 * 1024


class UiServer:
    def __init__(self, path: str, hello: Callable[[], dict],
                 on_request: Callable[[dict], dict]) -> None:
        self.path = path
        self._hello = hello
        self._on_request = on_request
        self._sock: Optional[socket.socket] = None
        self._clients: list[socket.socket] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()

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
        sock.listen(8)
        self._sock = sock
        threading.Thread(target=self._accept_loop, daemon=True, name="ui-accept").start()

    def close(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        with self._lock:
            clients, self._clients = self._clients, []
        for c in clients:
            try:
                c.close()
            except OSError:
                pass
        try:
            os.unlink(self.path)
        except OSError:
            pass

    def client_count(self) -> int:
        with self._lock:
            return len(self._clients)

    def broadcast(self, message: dict) -> None:
        line = (json.dumps(message, default=str) + "\n").encode()
        with self._lock:
            clients = list(self._clients)
        for c in clients:
            if not self._send(c, line):
                self._drop(c)

    # ── internals ──────────────────────────────────────────────────────
    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            sock = self._sock
            if sock is None:
                return
            try:
                conn, _ = sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True, name="ui-client").start()

    def _serve(self, conn: socket.socket) -> None:
        try:
            hello = dict(self._hello() or {})
        except Exception:
            hello = {}
        hello["type"] = "hello"
        if not self._send(conn, (json.dumps(hello, default=str) + "\n").encode()):
            conn.close()
            return
        with self._lock:
            self._clients.append(conn)
        buf = b""
        try:
            conn.settimeout(None)
            while not self._stop.is_set():
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
                if len(buf) > _MAX_LINE and b"\n" not in buf:
                    break
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self._handle_line(conn, line)
        except OSError:
            pass
        finally:
            self._drop(conn)

    def _handle_line(self, conn, line: bytes) -> None:
        try:
            req = json.loads(line)
        except Exception:
            return
        if not isinstance(req, dict):
            return
        rid = req.get("id")
        try:
            result = self._on_request(req) or {}
            reply = {"type": "reply", "id": rid}
            reply.update(result if isinstance(result, dict) else {"ok": bool(result)})
        except Exception as exc:  # noqa: BLE001 — answer, never kill the link
            log.debug("ui request %r failed", req.get("type"), exc_info=True)
            reply = {"type": "reply", "id": rid, "ok": False, "error": str(exc)}
        self._send(conn, (json.dumps(reply, default=str) + "\n").encode())

    def _send(self, conn, data: bytes) -> bool:
        try:
            conn.sendall(data)
            return True
        except OSError:
            return False

    def _drop(self, conn) -> None:
        with self._lock:
            if conn in self._clients:
                self._clients.remove(conn)
        try:
            conn.close()
        except OSError:
            pass
