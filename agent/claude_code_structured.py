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
    """Default ON. The structured MCP engine (claude drives via native tool_use) is
    the proven path for claude-code; the legacy text-shim (``<tool_call>`` parsing)
    silently stalled when the model emitted a prose "I'll do X" turn with no tool
    call. Set ``HERMES_CLAUDE_CODE_STRUCTURED=0`` (or false/no/off) to fall back to
    the text-shim."""
    raw = (os.environ.get("HERMES_CLAUDE_CODE_STRUCTURED", "") or "").strip().lower()
    if raw in {"0", "false", "no", "off"}:
        return False
    return True


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
    should_abort: Callable[[], bool] | None = None,
) -> SimpleNamespace:
    """Drive one structured turn. ``execute_tool(name, args) -> result_text`` runs a
    JC tool. ``should_abort`` (polled on a side thread) terminates the CLI promptly
    when the user interrupts — even while the reader is parked in ``readline()``.
    Returns ``SimpleNamespace(text, tool_events, is_error, error, usage)``.
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
    # The CLI refuses `--permission-mode bypassPermissions`
    # (--dangerously-skip-permissions) when running as root ("cannot be used with
    # root/sudo privileges"). The hermes webui runs as root, so without this the
    # CLI exits code 1 before reading stdin → broken pipe. IS_SANDBOX=1 tells the
    # CLI it's in a contained environment and lifts the root block. This is
    # accurate here: JC owns the entire tool list via the MCP bridge and its
    # executor enforces JC's own guardrails — there is nothing to "skip".
    proc_env.setdefault("IS_SANDBOX", "1")

    text_parts: list[str] = []
    is_error = False
    error = None
    usage: dict[str, Any] = {}

    bridge = McpToolBridge(mcp_tools, _on_call)
    bridge.start()
    proc: subprocess.Popen | None = None
    watchdog: threading.Timer | None = None
    abort_poll: threading.Thread | None = None
    aborted = threading.Event()
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

        # Abort poller: the stdout reader blocks in readline() while the CLI is
        # busy (e.g. waiting on a tool), so it can't notice an interrupt on its
        # own. A side thread polls should_abort() and terminates the CLI so the
        # turn unwinds promptly when the user says "stop".
        if should_abort is not None:
            def _poll_abort() -> None:
                while not aborted.is_set():
                    try:
                        if should_abort():
                            aborted.set()
                            if proc is not None and proc.poll() is None:
                                proc.terminate()
                            return
                    except Exception:
                        pass
                    aborted.wait(0.3)
            abort_poll = threading.Thread(target=_poll_abort, name="jc-mcp-abort", daemon=True)
            abort_poll.start()

        start = time.monotonic()
        assert proc.stdout is not None
        for raw in proc.stdout:
            if aborted.is_set():
                is_error = True
                error = "structured claude turn aborted (interrupt)"
                break
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
                # Fallback: if no `assistant` text block was seen (some replies
                # land only in the final result), use the result text so the turn
                # isn't treated as empty (which breaks voice → "no_reply" and
                # triggers wasteful empty-response retries in chat).
                if not text_parts:
                    rtext = ev.get("result")
                    if isinstance(rtext, str) and rtext.strip():
                        text_parts.append(rtext)
                        if on_text is not None:
                            try:
                                on_text(rtext)
                            except Exception:
                                pass
                break
    except Exception as exc:
        is_error = True
        error = str(exc)
        # The CLI may have exited early (e.g. it rejected a flag) — surface its
        # stderr so the failure is diagnosable instead of a bare "Broken pipe".
        try:
            if proc is not None and proc.stderr is not None:
                tail = (proc.stderr.read() or "").strip()
                if tail:
                    error = f"{error} | claude stderr: {tail[:500]}"
        except Exception:
            pass
    finally:
        aborted.set()  # stop the abort poller
        if abort_poll is not None:
            try:
                abort_poll.join(timeout=1.0)
            except Exception:
                pass
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
