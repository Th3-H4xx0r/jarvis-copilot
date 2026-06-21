#!/usr/bin/env python3
"""Tiny MCP stdio<->unix-socket proxy.

The `claude` CLI spawns this as an MCP server `command`. It forwards newline-
delimited JSON-RPC between the CLI's stdio and the in-process JarvisCopilot
McpToolBridge listening on the unix socket at $JC_MCP_SOCKET. Stdlib only; no JC
imports (it runs as a separate process the CLI launches).
"""
import os
import socket
import sys
import threading


def main() -> int:
    path = os.environ.get("JC_MCP_SOCKET", "")
    if not path:
        sys.stderr.write("claude_mcp_proxy: JC_MCP_SOCKET not set\n")
        return 2
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # The bridge may still be binding when the CLI launches us — retry briefly.
    import time
    for _ in range(100):
        try:
            sock.connect(path)
            break
        except OSError:
            time.sleep(0.05)
    else:
        sys.stderr.write(f"claude_mcp_proxy: could not connect to {path}\n")
        return 3

    stop = threading.Event()

    def stdin_to_sock() -> None:
        try:
            for line in sys.stdin.buffer:
                sock.sendall(line if line.endswith(b"\n") else line + b"\n")
        except Exception:
            pass
        finally:
            stop.set()
            try:
                sock.shutdown(socket.SHUT_WR)
            except Exception:
                pass

    t = threading.Thread(target=stdin_to_sock, daemon=True)
    t.start()

    buf = b""
    try:
        while not stop.is_set():
            try:
                chunk = sock.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                sys.stdout.buffer.write(line + b"\n")
                sys.stdout.buffer.flush()
    finally:
        try:
            sock.close()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
