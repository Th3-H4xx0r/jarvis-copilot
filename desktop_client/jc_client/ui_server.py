"""``ui.sock`` — the local link between jc-client and the Jarvis Mac app.

The app (``mac_app/JarvisMac``) connects to ``~/.jarviscopilot-client/ui.sock``
(owner-only) and gets, as newline JSON:

* ``hello`` first — the loopback API origin (the pinned proxy, so the app never
  holds credentials), and the approvals / instructions switches;
* then whatever changes: ``sessions`` (the local engine), ``pending`` (the
  approvals and questions waiting in the arbiter), ``usage`` (Claude plan
  limits from the status line), ``topic`` (server pushes it subscribed to).

The app's requests (``decide``, ``session``, ``hooks``, ``subscribe``…) carry an
``id`` and get one ``reply`` with the same id. Each client has a reader thread
and one writer with its own queue, so a message always goes out whole and in
order, and ``broadcast`` never waits on the app: a client that stops reading
(hung, beachballing, paused in a debugger) fills its queue and is dropped,
instead of stalling the hooks and the bridge that call ``broadcast``.
"""
from __future__ import annotations

import json
import logging
import os
import queue
import socket
import threading
from typing import Callable, Optional

log = logging.getLogger(__name__)

_MAX_LINE = 1024 * 1024
_QUEUE = 64           # messages a client may fall behind before it is dropped
_SEND_TIMEOUT = 5.0   # one send that makes no progress this long drops the client


class _Client:
    """One app connection: its socket and the queue its writer drains."""

    def __init__(self, conn: socket.socket) -> None:
        self.conn = conn
        self.queue: "queue.Queue[Optional[bytes]]" = queue.Queue(maxsize=_QUEUE)
        self.closed = False


class UiServer:
    def __init__(self, path: str, hello: Callable[[], dict],
                 on_request: Callable[[dict], dict]) -> None:
        self.path = path
        self._hello = hello
        self._on_request = on_request
        self._sock: Optional[socket.socket] = None
        self._clients: list[_Client] = []
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
            self._drop(c)
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
            self._enqueue(c, line)

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
        client = _Client(conn)
        conn.settimeout(_SEND_TIMEOUT)
        try:
            hello = dict(self._hello() or {})
        except Exception:
            hello = {}
        hello["type"] = "hello"
        # Hello goes first in the queue; the client joins the broadcast list
        # right after, so nothing pushed from here on is missed.
        self._enqueue(client, (json.dumps(hello, default=str) + "\n").encode())
        with self._lock:
            self._clients.append(client)
        threading.Thread(target=self._write_loop, args=(client,), daemon=True, name="ui-writer").start()
        buf = b""
        try:
            while not self._stop.is_set():
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
                if len(buf) > _MAX_LINE and b"\n" not in buf:
                    break
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self._handle_line(client, line)
        except OSError:
            pass
        finally:
            self._drop(client)

    def _write_loop(self, client: _Client) -> None:
        while True:
            data = client.queue.get()
            if data is None or client.closed:
                return
            try:
                client.conn.sendall(data)
            except OSError:            # gone, or no progress for _SEND_TIMEOUT
                self._drop(client)
                return

    def _enqueue(self, client: _Client, data: bytes) -> None:
        if client.closed:
            return
        try:
            client.queue.put_nowait(data)
        except queue.Full:
            log.info("ui client fell %d messages behind; dropping it", _QUEUE)
            self._drop(client)

    def _handle_line(self, client: _Client, line: bytes) -> None:
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
        self._enqueue(client, (json.dumps(reply, default=str) + "\n").encode())

    def _drop(self, client: _Client) -> None:
        with self._lock:
            if client in self._clients:
                self._clients.remove(client)
            if client.closed:
                return
            client.closed = True
        try:
            client.queue.put_nowait(None)   # wake the writer so it exits
        except queue.Full:
            pass
        try:
            client.conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            client.conn.close()
        except OSError:
            pass
