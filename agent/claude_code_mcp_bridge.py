"""In-process MCP bridge that lets the `claude` CLI call JarvisCopilot's OWN tools
as native, structured tool_use — keeping the Claude MAX subscription auth.

Why this exists
---------------
The text-shim (`claude -p --tools ""` + `<tool_call>` text parsing) stalls and is
slow. The `claude` CLI *can* emit structured `tool_use` for tools exposed via an
MCP server (`--mcp-config`), drive the whole task itself, and BLOCK on each
`tools/call` until the server returns a result (empirically proven on the
subscription). So we expose JC's tools as an MCP server and let JC execute them.

MCP servers are stdio subprocesses the CLI spawns, so the bridge is:
  • a unix-socket server hosted IN this process (knows JC's tools + executes them
    via a callback), and
  • a tiny stdio<->socket proxy (`claude_mcp_proxy.py`, written next to this file)
    that the CLI launches as the MCP `command`; it forwards JSON-RPC lines between
    the CLI's stdio and our socket.

This module is intentionally self-contained and dependency-free (stdlib only) so it
is trivially testable without the `claude` CLI: drive `McpToolBridge` directly with
a fake socket peer, or run `run_structured_turn()` against the real CLI in an
end-to-end test.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import tempfile
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from pathlib import Path
from typing import Any, Callable

# Per-tool wall-clock cap. The CLI blocks on a tools/call until we reply, and our
# stdout reader is parked in readline() meanwhile, so a tool that never returns
# would hang the whole turn — cap it and return an error result instead.
_DEFAULT_EXECUTOR_TIMEOUT = 180.0

MCP_PROTOCOL_VERSION = "2024-11-05"
# Tool names are namespaced by the CLI as ``mcp__<server>__<tool>``.
MCP_SERVER_NAME = "jc"
_PREFIX = f"mcp__{MCP_SERVER_NAME}__"


def mcp_tool_name(name: str) -> str:
    return name if name.startswith(_PREFIX) else _PREFIX + name


def jc_tool_name(mcp_name: str) -> str:
    return mcp_name[len(_PREFIX):] if mcp_name.startswith(_PREFIX) else mcp_name


def openai_tools_to_mcp(tools: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
    """Map OpenAI ``{"type":"function","function":{name,description,parameters}}``
    tool schemas to MCP ``{name, description, inputSchema}`` entries."""
    out: list[dict[str, Any]] = []
    for t in tools or []:
        fn = t.get("function") if isinstance(t, dict) else None
        if not isinstance(fn, dict):
            continue
        name = str(fn.get("name") or "").strip()
        if not name:
            continue
        params = fn.get("parameters")
        if not isinstance(params, dict):
            params = {"type": "object", "properties": {}}
        out.append({
            "name": name,
            "description": str(fn.get("description") or "")[:1024],
            "inputSchema": params,
        })
    return out


class McpToolBridge:
    """Hosts an in-process MCP server over a unix socket.

    Handles ``initialize`` / ``tools/list`` from the catalog, and routes
    ``tools/call`` to ``on_tool_call(name, arguments) -> str`` (the JC executor),
    which may block while JarvisCopilot runs the tool. Thread-safe; one accepted
    connection at a time (the CLI spawns a single proxy).
    """

    def __init__(
        self,
        tools: list[dict[str, Any]],
        on_tool_call: Callable[[str, dict[str, Any]], str],
        *,
        socket_path: str | None = None,
        executor_timeout: float = _DEFAULT_EXECUTOR_TIMEOUT,
    ) -> None:
        self._tools = tools
        self._on_tool_call = on_tool_call
        self._executor_timeout = executor_timeout
        self._dir = None
        if socket_path is None:
            # Short socket name under a 0700 temp dir (AF_UNIX paths are capped
            # near 104 bytes — keep the leaf minimal).
            self._dir = tempfile.mkdtemp(prefix="jc-mcp-")
            socket_path = os.path.join(self._dir, "s")
        self.socket_path = socket_path
        self._srv: socket.socket | None = None
        self._conn: socket.socket | None = None
        self._pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="jc-mcp-tool")
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    # ── lifecycle ────────────────────────────────────────────────────────────
    def start(self) -> "McpToolBridge":
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            try:
                os.unlink(self.socket_path)
            except OSError:
                pass
            srv.bind(self.socket_path)
            srv.listen(1)
            srv.settimeout(0.5)
        except Exception:
            try:
                srv.close()
            finally:
                self._cleanup_files()
            raise
        self._srv = srv
        self._thread = threading.Thread(target=self._serve, name="jc-mcp-bridge", daemon=True)
        self._thread.start()
        return self

    def close(self) -> None:
        self._stop.set()
        for sock in (self._conn, self._srv):
            try:
                if sock is not None:
                    sock.close()
            except Exception:
                pass
        if self._thread is not None:
            try:
                self._thread.join(timeout=2.0)
            except Exception:
                pass
        try:
            self._pool.shutdown(wait=False)
        except Exception:
            pass
        self._cleanup_files()

    def _cleanup_files(self) -> None:
        try:
            os.unlink(self.socket_path)
        except OSError:
            pass
        if self._dir:
            shutil.rmtree(self._dir, ignore_errors=True)

    def __enter__(self) -> "McpToolBridge":
        return self.start()

    def __exit__(self, *exc: Any) -> None:
        self.close()

    # ── serving ──────────────────────────────────────────────────────────────
    def _serve(self) -> None:
        assert self._srv is not None
        while not self._stop.is_set():
            try:
                conn, _ = self._srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self._conn = conn
            try:
                self._handle_conn(conn)
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except Exception:
                    pass

    def _handle_conn(self, conn: socket.socket) -> None:
        buf = b""
        conn.settimeout(0.5)
        while not self._stop.is_set():
            try:
                chunk = conn.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line.decode("utf-8"))
                except Exception:
                    continue
                reply = self.handle_message(msg)
                if reply is not None:
                    self._send(conn, (json.dumps(reply) + "\n").encode("utf-8"))

    @staticmethod
    def _send(conn: socket.socket, data: bytes) -> None:
        # The conn carries a 0.5s recv timeout; a large reply can exceed it on
        # send. Do the write in blocking mode so big tool results aren't dropped.
        try:
            conn.sendall(data)
        except (socket.timeout, TimeoutError, BlockingIOError):
            old = conn.gettimeout()
            conn.settimeout(None)
            try:
                conn.sendall(data)
            finally:
                conn.settimeout(old)

    # ── JSON-RPC handlers (pure; unit-testable without a socket) ──────────────
    def handle_message(self, msg: dict[str, Any]) -> dict[str, Any] | None:
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            pv = (msg.get("params") or {}).get("protocolVersion") or MCP_PROTOCOL_VERSION
            return _ok(mid, {
                "protocolVersion": pv,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": MCP_SERVER_NAME, "version": "1.0"},
            })
        if method == "notifications/initialized":
            return None
        if method == "tools/list":
            return _ok(mid, {"tools": self._tools})
        if method == "tools/call":
            params = msg.get("params") or {}
            name = jc_tool_name(str(params.get("name") or ""))
            args = params.get("arguments")
            if not isinstance(args, dict):
                args = {}
            # Run the JC executor with a wall-clock cap. The CLI is blocked on
            # this tools/call and our stdout reader is parked in readline(), so a
            # tool that never returns would hang the turn — bound it and return an
            # error result so the model proceeds.
            try:
                fut = self._pool.submit(self._on_tool_call, name, args)
                result_text = fut.result(timeout=self._executor_timeout)
            except FutureTimeout:
                return _ok(mid, {
                    "content": [{"type": "text",
                                 "text": f"Tool '{name}' timed out after {self._executor_timeout:.0f}s."}],
                    "isError": True,
                })
            except Exception as exc:  # never hang the CLI on an executor error
                return _ok(mid, {
                    "content": [{"type": "text", "text": f"Tool error: {exc}"}],
                    "isError": True,
                })
            return _ok(mid, {"content": [{"type": "text", "text": str(result_text)}]})
        if mid is not None:
            return _ok(mid, {})
        return None

    # ── CLI wiring ────────────────────────────────────────────────────────────
    def mcp_config_json(self) -> str:
        """A ``--mcp-config`` value that launches the proxy pointed at our socket."""
        proxy = str(Path(__file__).resolve().parent / "claude_mcp_proxy.py")
        return json.dumps({"mcpServers": {MCP_SERVER_NAME: {
            "command": "python3",
            "args": [proxy],
            "env": {"JC_MCP_SOCKET": self.socket_path},
        }}})


def _ok(mid: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def new_socket_path() -> str:
    return os.path.join(tempfile.gettempdir(), f"jc-mcp-{uuid.uuid4().hex}.sock")
