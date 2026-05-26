"""Bridge /api/tui/ws ⇄ a spawned `tui_gateway.entry` (stdio JSON-RPC).

The local Ink TUI (ui-tui attach mode, via the client's loopback proxy) connects
here over WebSocket; we spawn the exact same stdio gateway `jarviscopilot --tui`
uses and relay newline-JSON both ways, so every RPC method / slash command /
approval flow / agent event works verbatim. One gateway (agent session) per
connection. Auth is the webui's existing check_auth (cookie), which runs before
this handler in do_GET.
"""
from __future__ import annotations

import logging
import os
import subprocess
import sys
import threading
import traceback

logger = logging.getLogger(__name__)

_PATH = "/api/tui/ws"
_RECV_CHUNK = 8192


def _reconstruct_http_request(handler) -> bytes:
    """Synthesize the raw HTTP request bytes the wsproto SERVER state machine
    needs (the handler already consumed the request line + headers)."""
    lines = [f"{handler.command} {handler.path} HTTP/1.1"]
    for k, v in handler.headers.items():
        lines.append(f"{k}: {v}")
    lines.append("")
    lines.append("")
    return ("\r\n".join(lines)).encode("latin-1")


def _write_to_gateway(proc, text: str) -> bool:
    """Write one newline-terminated JSON-RPC line to the gateway's stdin."""
    try:
        proc.stdin.write(text.encode("utf-8") + b"\n")
        proc.stdin.flush()
        return True
    except Exception:
        return False


def _pump_stdout(proc, send_text, stop) -> None:
    """Read newline-JSON lines from the gateway stdout; forward each via send_text."""
    try:
        for raw in iter(proc.stdout.readline, b""):
            if stop():
                break
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line and not send_text(line):
                break
    except Exception:
        pass


def _spawn_gateway():
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return subprocess.Popen(
        [sys.executable, "-m", "tui_gateway.entry"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        cwd=repo_root, env=os.environ.copy(), bufsize=0,
    )


def handle_websocket(handler, parsed) -> bool:
    """Claim /api/tui/ws, accept the WS, relay to a spawned tui_gateway.

    Returns True iff this handler claimed the request (path matched)."""
    if parsed.path != _PATH:
        return False
    try:
        from wsproto import WSConnection, ConnectionType
        from wsproto.events import Request, AcceptConnection
    except Exception:
        try:
            handler.send_response(503)
            handler.send_header("Content-Type", "application/json")
            handler.end_headers()
            handler.wfile.write(b'{"error":"wsproto not installed"}')
        except Exception:
            pass
        return True
    sock = handler.connection
    try:
        sock.settimeout(None)
    except Exception:
        pass
    conn = WSConnection(ConnectionType.SERVER)
    conn.receive_data(_reconstruct_http_request(handler))
    accepted = False
    for event in conn.events():
        if isinstance(event, Request):
            try:
                sock.sendall(conn.send(AcceptConnection()))
                accepted = True
            except Exception:
                return True
            break
    if not accepted:
        return True
    _run_bridge(conn, sock)
    return True


def _run_bridge(conn, sock) -> None:
    from wsproto.events import TextMessage, BytesMessage, CloseConnection, Ping, Pong
    state = {"closed": False}
    lock = threading.Lock()

    def send_text(line: str) -> bool:
        from wsproto.events import TextMessage as _TM
        with lock:
            try:
                sock.sendall(conn.send(_TM(data=line)))
                return True
            except Exception:
                state["closed"] = True
                return False

    proc = _spawn_gateway()
    reader = threading.Thread(
        target=_pump_stdout, args=(proc, send_text, lambda: state["closed"]), daemon=True,
    )
    reader.start()
    try:
        while not state["closed"] and proc.poll() is None:
            try:
                data = sock.recv(_RECV_CHUNK)
            except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, TimeoutError, OSError):
                break
            if not data:
                break
            conn.receive_data(data)
            for event in conn.events():
                if isinstance(event, TextMessage):
                    _write_to_gateway(proc, event.data or "")
                elif isinstance(event, BytesMessage):
                    _write_to_gateway(proc, (event.data or b"").decode("utf-8", "replace"))
                elif isinstance(event, Ping):
                    with lock:
                        try:
                            sock.sendall(conn.send(Pong(event.payload)))
                        except Exception:
                            state["closed"] = True
                elif isinstance(event, CloseConnection):
                    with lock:
                        try:
                            sock.sendall(conn.send(event.response()))
                        except Exception:
                            pass
                    state["closed"] = True
                    break
    except Exception:
        print("[webui] tui WS error: " + traceback.format_exc(), flush=True)
    finally:
        state["closed"] = True
        try:
            proc.terminate()
        except Exception:
            pass
        try:
            proc.wait(timeout=3)
        except Exception:
            pass
