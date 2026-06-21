"""Structured `claude-code` driver: claude drives the task, JarvisCopilot executes
the tools via the in-process MCP bridge (native tool_use, no `<tool_call>` text).

Phase 1 (flag ``HERMES_CLAUDE_CODE_STRUCTURED=1``). ``run_structured_turn`` runs one
user turn to completion: claude calls JC's tools (executed by ``execute_tool``) and
returns its final assistant text. The conversation/loop integration lives in the
client; this module is the self-contained, testable engine validated end-to-end
against the real CLI.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from types import SimpleNamespace
from typing import Any, Callable

from agent.claude_code_mcp_bridge import (
    McpToolBridge,
    openai_tools_to_mcp,
)

_DEFAULT_TIMEOUT = 900.0


def structured_enabled() -> bool:
    return (os.environ.get("HERMES_CLAUDE_CODE_STRUCTURED", "") or "").strip().lower() in {
        "1", "true", "yes", "on",
    }


def _build_argv(command: str, model_cli: str, mcp_config: str, system_prompt: str) -> list[str]:
    return [
        command, "-p",
        "--mcp-config", mcp_config,
        "--strict-mcp-config",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--permission-mode", "bypassPermissions",
        "--setting-sources", "",
        "--system-prompt", system_prompt,
        "--model", model_cli,
        "--no-session-persistence",
    ]


def run_structured_turn(
    *,
    user_text: str,
    tools: list[dict[str, Any]] | None,
    execute_tool: Callable[[str, dict[str, Any]], str],
    command: str = "claude",
    model_cli: str = "claude-opus-4-8",
    system_prompt: str = "You are JarvisCopilot's model. Use the available tools to fully complete the user's request, then give a concise final answer.",
    env: dict[str, str] | None = None,
    timeout: float = _DEFAULT_TIMEOUT,
    on_text: Callable[[str], None] | None = None,
    on_tool_event: Callable[[str, dict[str, Any], str], None] | None = None,
) -> SimpleNamespace:
    """Drive one structured turn. ``execute_tool(name, args) -> result_text`` runs a
    JC tool. Returns ``SimpleNamespace(text, tool_events, is_error, error, usage)``.
    """
    mcp_tools = openai_tools_to_mcp(tools)
    tool_events: list[dict[str, Any]] = []

    def _on_call(name: str, args: dict[str, Any]) -> str:
        result = execute_tool(name, args)
        result = "" if result is None else str(result)
        tool_events.append({"name": name, "arguments": args, "result": result})
        if on_tool_event is not None:
            try:
                on_tool_event(name, args, result)
            except Exception:
                pass
        return result

    # Reuse the text-shim's env builder: it STRIPS ANTHROPIC_API_KEY / bedrock /
    # vertex (so the CLI can't silently bill the rate-limited API path) and injects
    # the managed subscription OAuth token + HOME. Then layer our extras / overrides.
    from agent.claude_code_client import _build_subprocess_env
    proc_env = _build_subprocess_env()
    if env:
        proc_env.update(env)
    proc_env.setdefault("ENABLE_TOOL_SEARCH", "false")

    text_parts: list[str] = []
    is_error = False
    error = None
    usage: dict[str, Any] = {}

    bridge = McpToolBridge(mcp_tools, _on_call)
    bridge.start()
    proc: subprocess.Popen | None = None
    watchdog: threading.Timer | None = None
    try:
        argv = _build_argv(command, model_cli, bridge.mcp_config_json(), system_prompt)
        proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1, env=proc_env,
        )
        user = {"type": "user", "message": {"role": "user",
                "content": [{"type": "text", "text": user_text}]}}
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(user) + "\n")
        proc.stdin.flush()
        proc.stdin.close()

        # Hard watchdog: terminate the CLI if the whole turn overruns, so a hang
        # anywhere (CLI or a stuck tool) can't park readline() forever.
        def _fire_watchdog() -> None:
            try:
                if proc is not None and proc.poll() is None:
                    proc.terminate()
            except Exception:
                pass
        watchdog = threading.Timer(max(timeout, 1.0) + 15.0, _fire_watchdog)
        watchdog.daemon = True
        watchdog.start()

        start = time.monotonic()
        assert proc.stdout is not None
        for raw in proc.stdout:
            if time.monotonic() - start > timeout:
                is_error = True
                error = f"structured claude turn timed out after {timeout:.0f}s"
                break
            line = (raw or "").strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            etype = ev.get("type")
            if etype == "assistant":
                for block in (ev.get("message") or {}).get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "text":
                        t = block.get("text") or ""
                        if t:
                            text_parts.append(t)
                            if on_text is not None:
                                try:
                                    on_text(t)
                                except Exception:
                                    pass
            elif etype == "result":
                is_error = bool(ev.get("is_error"))
                usage = ev.get("usage") or {}
                break
    except Exception as exc:
        is_error = True
        error = str(exc)
    finally:
        if watchdog is not None:
            try:
                watchdog.cancel()
            except Exception:
                pass
        if proc is not None:
            try:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=2.0)
                    except Exception:
                        proc.kill()
            except Exception:
                pass
        bridge.close()

    return SimpleNamespace(
        text="".join(text_parts),
        tool_events=tool_events,
        is_error=is_error,
        error=error,
        usage=usage,
    )
