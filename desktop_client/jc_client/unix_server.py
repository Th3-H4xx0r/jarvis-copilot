"""A private Unix socket server: one listening socket only this user can open (a stale one at the
path is replaced), and a thread per connection. The hook server, the Mac app's UI socket and the
VS Code bridge are each one of these with their own `_connection`."""
from __future__ import annotations

import os
import socket
import threading
from typing import Optional


class UnixSocketServer:
    backlog = 8
    thread_name = "unix"

    def __init__(self, path: str) -> None:
        self.path = path
        self._sock: Optional[socket.socket] = None
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
        sock.listen(self.backlog)
        self._stop.clear()
        self._sock = sock
        threading.Thread(target=self._accept_loop, daemon=True, name=f"{self.thread_name}-accept").start()

    def close(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        self._drop_connections()
        try:
            os.unlink(self.path)
        except OSError:
            pass

    def _drop_connections(self) -> None:
        """Closes the connections still open (servers that keep them)."""

    def _connection(self, conn: socket.socket) -> None:
        raise NotImplementedError

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            sock = self._sock
            if sock is None:
                return
            try:
                conn, _ = sock.accept()
            except OSError:
                return
            threading.Thread(target=self._connection, args=(conn,), daemon=True,
                             name=f"{self.thread_name}-conn").start()
