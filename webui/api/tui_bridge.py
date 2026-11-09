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
from api import ws_upgrade

logger = logging.getLogger(__name__)

_PATH = "/api/tui/ws"
_RECV_CHUNK = 8192
# Bound a reassembled inbound frame so a pathological client can't balloon
# memory. Generous enough for large pasted prompts.
_MAX_FRAME_BYTES = 16 * 1024 * 1024


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
    upgraded = ws_upgrade.accept(handler)
    if upgraded is None:
        return True
    from security.events import emit
    from security.netid import actor_for
    emit("device", "tui.opened", actor_for(handler))
    conn, sock = upgraded
    _run_bridge(conn, sock)
    return True


def _run_bridge(conn, sock) -> None:
    from wsproto.events import CloseConnection
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
        ws_upgrade.serve(conn, sock, lock=lock, max_message=_MAX_FRAME_BYTES, chunk=_RECV_CHUNK,
                         alive=lambda: not state["closed"] and proc.poll() is None,
                         on_text=lambda line: _write_to_gateway(proc, line),
                         on_bytes=lambda raw: _write_to_gateway(proc, raw.decode("utf-8", "replace")))
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
