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
# Bound a reassembled inbound frame so a pathological client can't balloon
# memory. Generous enough for large pasted prompts.
_MAX_FRAME_BYTES = 16 * 1024 * 1024


def _reconstruct_http_request(handler) -> bytes:
    """Synthesize the raw HTTP request bytes the wsproto SERVER state machine
    needs (the handler already consumed the request line + headers)."""
    lines = [f"{handler.command} {handler.path} HTTP/1.1"]
    for k, v in handler.headers.items():
        lines.append(f"{k}: {v}")
    lines.append("")
    lines.append("")
    return ("\r\n".join(lines)).encode("latin-1")


def _take_complete_frame(buf, data, finished: bool, max_bytes: int):
    """Reassemble a WS message split across recv chunks.

    wsproto emits one event per chunk with ``message_finished=True`` only on the
    last. Append ``data`` to ``buf``; return ``(line, new_buf, dropped)``:
      - not finished → ``(None, buf, False)`` (keep accumulating)
      - finished + within limit → ``(complete, empty_buf, False)``
      - finished + oversize → ``(None, empty_buf, True)`` (drop, reset)
    Works for both str and bytes buffers (``buf[:0]`` yields the right empty)."""
    if data:
        buf = buf + data
    if not finished:
        return None, buf, False
    if len(buf) > max_bytes:
        return None, buf[:0], True
    return buf, buf[:0], False


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
    # text_buf/bytes_buf accumulate a WS message that wsproto splits across recv
    # chunks (it emits one event per chunk, message_finished=True only on the
    # last). We must reassemble before writing a line to the gateway, or any
    # RPC over ~8 KB gets chopped into invalid partial JSON lines. (Same bug as
    # device_bridge.py commit afc1c9039.)
    state = {"closed": False, "text_buf": "", "bytes_buf": b""}
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
                    line, state["text_buf"], dropped = _take_complete_frame(
                        state["text_buf"], event.data or "",
                        getattr(event, "message_finished", True), _MAX_FRAME_BYTES)
                    if dropped:
                        logger.warning("tui WS oversize text frame — dropping")
                    elif line is not None:
                        _write_to_gateway(proc, line)
                elif isinstance(event, BytesMessage):
                    raw, state["bytes_buf"], dropped = _take_complete_frame(
                        state["bytes_buf"], event.data or b"",
                        getattr(event, "message_finished", True), _MAX_FRAME_BYTES)
                    if dropped:
                        logger.warning("tui WS oversize binary frame — dropping")
                    elif raw is not None:
                        _write_to_gateway(proc, raw.decode("utf-8", "replace"))
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
        # Close stdin first: tui_gateway.entry exits on stdin EOF, which closes
        # its stdout and lets the reader thread's blocking readline() return.
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.terminate()
        except Exception:
            pass
        try:
            proc.wait(timeout=3)
        except Exception:
            # SIGTERM ignored / slow → force-kill so we never leak the agent.
            try:
                proc.kill()
            except Exception:
                pass
            try:
                proc.wait(timeout=2)
            except Exception:
                pass
        # Gateway dead → stdout EOF → reader thread returns; reap it.
        try:
            reader.join(timeout=2)
        except Exception:
            pass
        with lock:
            try:
                sock.sendall(conn.send(CloseConnection(code=1000)))
            except Exception:
                pass
        try:
            sock.close()
        except Exception:
            pass
