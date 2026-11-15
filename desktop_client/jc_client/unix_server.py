"""The private local link: one listening socket only this user can reach, and a thread per
connection. The hook server, the app's UI link and the VS Code bridge are each one of these
with their own `_connection`.

Two modes (contract C1 in docs/superpowers/plans/2026-11-15-windows-client-00-index.md):

* ``unix`` (macOS/Linux): an AF_UNIX socket at ``path`` (owner-only; a stale one is replaced).
* ``tcp`` (Windows, where Python has no AF_UNIX): a 127.0.0.1 port, and ``path`` is an endpoint
  file ``{"v":1,"port":…,"token":…,"pid":…}`` written after ``listen()``. A client's first line
  must be ``{"auth":"<token>"}`` within AUTH_TIMEOUT; after it the stream is the same protocol.

Standard library only: the server loads this file by path (agent/agent_engine_shim.py).
"""
from __future__ import annotations

import hmac
import json
import os
import secrets
import socket
import sys
import threading
from typing import Optional

AUTH_TIMEOUT = 2.0
_AUTH_MAX = 512


def default_mode() -> str:
    return "tcp" if sys.platform == "win32" else "unix"


class _Prebuffered:
    """A connection whose first bytes were already read (they followed the auth line)."""

    def __init__(self, sock: socket.socket, data: bytes) -> None:
        self._sock = sock
        self._data = data

    def recv(self, n: int, *flags) -> bytes:
        if self._data:
            out, self._data = self._data[:n], self._data[n:]
            return out
        return self._sock.recv(n, *flags)

    def __getattr__(self, name):
        return getattr(self._sock, name)


class UnixSocketServer:
    backlog = 8
    thread_name = "unix"

    def __init__(self, path: str, mode: Optional[str] = None) -> None:
        self.path = path
        self.mode = mode or default_mode()
        self._sock: Optional[socket.socket] = None
        self._stop = threading.Event()
        self._token = ""

    def start(self) -> None:
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        if self.mode == "tcp":
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.bind(("127.0.0.1", 0))
            sock.listen(self.backlog)
            self._token = secrets.token_hex(32)
            self._write_endpoint(sock.getsockname()[1])
        else:
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

    def _write_endpoint(self, port: int) -> None:
        tmp = self.path + ".tmp"
        old = os.umask(0o177) if sys.platform != "win32" else None
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"v": 1, "port": port, "token": self._token, "pid": os.getpid()}, fh)
        finally:
            if old is not None:
                os.umask(old)
        os.replace(tmp, self.path)

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
            target = self._authenticated if self.mode == "tcp" else self._connection
            threading.Thread(target=target, args=(conn,), daemon=True,
                             name=f"{self.thread_name}-conn").start()

    def _authenticated(self, conn: socket.socket) -> None:
        """tcp mode: the first line must carry the token, or the connection is closed."""
        buf = b""
        try:
            import time as _time
            deadline = _time.monotonic() + AUTH_TIMEOUT   # the whole handshake, not each recv
            while b"\n" not in buf and len(buf) < _AUTH_MAX:
                left = deadline - _time.monotonic()
                if left <= 0:
                    break
                conn.settimeout(left)
                chunk = conn.recv(_AUTH_MAX)
                if not chunk:
                    break
                buf += chunk
            line, _, rest = buf.partition(b"\n")
            token = str((json.loads(line) or {}).get("auth") or "") if line.strip() else ""
            ok = bool(token) and hmac.compare_digest(token.encode("utf-8"), self._token.encode("ascii"))
        except (OSError, ValueError, AttributeError, TypeError):
            ok, rest = False, b""
        if not ok:
            try:
                conn.close()
            except OSError:
                pass
            return
        try:
            conn.settimeout(None)
        except OSError:
            return
        self._connection(_Prebuffered(conn, rest) if rest else conn)


def connect(path: str, timeout: float) -> socket.socket:
    """Open the link at ``path`` (endpoint file → loopback + auth line; else AF_UNIX).

    Raises ConnectionRefusedError when nothing is listening there."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(4096)
    except FileNotFoundError:
        raise ConnectionRefusedError(f"nothing listening at {path}") from None
    except OSError:
        head = b""   # an AF_UNIX socket can't be opened like a file
    if head.lstrip().startswith(b"{"):
        try:
            ep = json.loads(head)
            port, token = int(ep["port"]), str(ep["token"])
        except (ValueError, KeyError, TypeError):
            raise ConnectionRefusedError(f"bad endpoint file {path}") from None
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        except OSError as exc:
            raise ConnectionRefusedError(str(exc)) from None
        s.sendall(json.dumps({"auth": token}).encode() + b"\n")
        return s
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        s.close()
        raise ConnectionRefusedError(str(exc)) from None
    return s


def peer_pid(conn) -> int:
    """The connecting process: macOS LOCAL_PEERPID (Unix sockets), Windows the owner of the
    client's loopback port; 0 when unknown."""
    sock = getattr(conn, "_sock", conn)
    if sys.platform == "win32":
        try:
            return _win_tcp_owner(sock.getpeername()[1], sock.getsockname()[1])
        except Exception:  # noqa: BLE001
            return 0
    try:
        import struct
        return struct.unpack("i", sock.getsockopt(0, 2, 4))[0]   # SOL_LOCAL, LOCAL_PEERPID
    except (OSError, AttributeError, ValueError):
        return 0


def _win_tcp_owner(local_port: int, remote_port: int) -> int:
    """PID owning the IPv4 TCP row whose local port is the client's (and remote ours)."""
    import ctypes
    from ctypes import wintypes

    class Row(ctypes.Structure):
        _fields_ = [("state", wintypes.DWORD), ("laddr", wintypes.DWORD), ("lport", wintypes.DWORD),
                    ("raddr", wintypes.DWORD), ("rport", wintypes.DWORD), ("pid", wintypes.DWORD)]

    iphlpapi = ctypes.windll.iphlpapi
    size = wintypes.DWORD(0)
    AF_INET, TCP_TABLE_OWNER_PID_ALL, ERROR_INSUFFICIENT_BUFFER = 2, 5, 122
    iphlpapi.GetExtendedTcpTable(None, ctypes.byref(size), False, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0)
    for _ in range(4):   # the table can grow between the size call and the read: retry with room
        size = wintypes.DWORD(size.value + 4096)
        buf = ctypes.create_string_buffer(size.value)
        rc = iphlpapi.GetExtendedTcpTable(buf, ctypes.byref(size), False, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0)
        if rc == 0:
            break
        if rc != ERROR_INSUFFICIENT_BUFFER:
            return 0
    else:
        return 0
    count = wintypes.DWORD.from_buffer(buf).value
    rows = ctypes.cast(ctypes.addressof(buf) + ctypes.sizeof(wintypes.DWORD), ctypes.POINTER(Row))

    def port(v: int) -> int:
        return ((v & 0xFF) << 8) | ((v >> 8) & 0xFF)

    for i in range(count):
        r = rows[i]
        if port(r.lport) == local_port and port(r.rport) == remote_port:
            return int(r.pid)
    return 0
