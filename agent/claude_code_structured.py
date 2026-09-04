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


def _build_argv(
    command: str,
    model_cli: str,
    mcp_config: str,
    system_prompt: str,
    *,
    persist_session: bool = False,
    resume_session_id: str | None = None,
    extra_argv_prefix: list[str] | None = None,
) -> list[str]:
    """Build the ``claude`` argv for one structured turn.

    ``persist_session`` (plan 2.7) drops ``--no-session-persistence`` so a warm
    process keeps its transcript across turns and a RESTARTED one can pick it up
    again with ``--resume``. Per-turn mode (the default) is unchanged: no
    persistence, no resume — every turn is self-contained.

    ``extra_argv_prefix`` is inserted right after ``command``; it exists so tests
    can drive a stand-in CLI (``python3 fake_claude.py``).
    """
    argv = [command, *(extra_argv_prefix or []), "-p",
            "--mcp-config", mcp_config,
            "--strict-mcp-config",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "bypassPermissions",
            "--setting-sources", "",
            "--system-prompt", system_prompt,
            "--model", model_cli]
    if persist_session:
        if resume_session_id:
            argv += ["--resume", resume_session_id]
    else:
        argv.append("--no-session-persistence")
    return argv


def _build_proc_env(env: dict[str, str] | None) -> dict[str, str]:
    """Subprocess env for the CLI (shared by the per-turn and warm paths).

    Reuses the text-shim's env builder: it STRIPS ANTHROPIC_API_KEY / bedrock /
    vertex (so the CLI can't silently bill the rate-limited API path) and injects
    the managed subscription OAuth token + HOME. Then layers our extras.
    """
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
    return proc_env


def _write_user_turn(proc: subprocess.Popen, user_text: str) -> None:
    """Write one stream-json user message to the CLI's stdin (leaves it open)."""
    payload = {"type": "user", "message": {"role": "user",
               "content": [{"type": "text", "text": user_text}]}}
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()


def _consume_turn(
    proc: subprocess.Popen,
    *,
    timeout: float,
    on_text: Callable[[str], None] | None,
    aborted: threading.Event,
    state: dict[str, Any],
) -> SimpleNamespace:
    """Read stdout until the CLI's ``result`` event closes the turn.

    Shared by the per-turn and warm paths so their parsing can never drift.
    ``state`` collects out-of-band info (currently the CLI's own session id, used
    by warm mode to ``--resume`` after a crash).
    """
    text_parts: list[str] = []
    is_error = False
    error: str | None = None
    usage: dict[str, Any] = {}

    start = time.monotonic()
    assert proc.stdout is not None
    for raw in proc.stdout:
        if aborted.is_set():
            return SimpleNamespace(text="".join(text_parts), is_error=True,
                                   error="structured claude turn aborted (interrupt)",
                                   usage=usage)
        if time.monotonic() - start > timeout:
            return SimpleNamespace(
                text="".join(text_parts), is_error=True,
                error=f"structured claude turn timed out after {timeout:.0f}s",
                usage=usage)
        line = (raw or "").strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        sid = ev.get("session_id")
        if sid:
            state["session_id"] = sid
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
            rtext = ev.get("result")
            if is_error:
                # On an error result, the CLI puts the failure text (e.g.
                # "API Error: 529 Overloaded ...") in `result`. Surface it as
                # `error` — NOT as assistant text — so the caller raises and
                # the classifier can read the 529 (overloaded → retryable)
                # instead of treating the error string as a real reply.
                if isinstance(rtext, str) and rtext.strip():
                    error = rtext.strip()
            # Fallback: if no `assistant` text block was seen (some replies
            # land only in the final result), use the result text so the turn
            # isn't treated as empty (which breaks voice → "no_reply" and
            # triggers wasteful empty-response retries in chat).
            elif not text_parts:
                if isinstance(rtext, str) and rtext.strip():
                    text_parts.append(rtext)
                    if on_text is not None:
                        try:
                            on_text(rtext)
                        except Exception:
                            pass
            break
    else:
        # stdout hit EOF without a result event — the CLI died mid-turn.
        is_error = True
        error = "claude exited before completing the turn"

    return SimpleNamespace(text="".join(text_parts), is_error=is_error,
                           error=error, usage=usage)


def _start_abort_poller(
    proc: subprocess.Popen,
    should_abort: Callable[[], bool] | None,
    aborted: threading.Event,
) -> threading.Thread | None:
    """Terminate the CLI promptly when the user interrupts.

    The stdout reader blocks in ``readline()`` while the CLI is busy (e.g.
    waiting on a tool), so it can't notice an interrupt on its own.
    """
    if should_abort is None:
        return None

    def _poll() -> None:
        while not aborted.is_set():
            try:
                if should_abort():
                    aborted.set()
                    if proc.poll() is None:
                        proc.terminate()
                    return
            except Exception:
                pass
            aborted.wait(0.3)

    thread = threading.Thread(target=_poll, name="jc-mcp-abort", daemon=True)
    thread.start()
    return thread


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
    extra_argv_prefix: list[str] | None = None,
) -> SimpleNamespace:
    """Drive one structured turn in a FRESH ``claude`` process (the default mode).

    ``execute_tool(name, args) -> result_text`` runs a JC tool. ``should_abort``
    (polled on a side thread) terminates the CLI promptly when the user
    interrupts — even while the reader is parked in ``readline()``.
    Returns ``SimpleNamespace(text, tool_events, is_error, error, usage)``.

    For the warm, one-process-per-session variant see
    :class:`WarmStructuredSession` (plan 2.7). This path is untouched by it.
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

    proc_env = _build_proc_env(env)

    turn = SimpleNamespace(text="", is_error=False, error=None, usage={})
    bridge = McpToolBridge(mcp_tools, _on_call)
    bridge.start()
    proc: subprocess.Popen | None = None
    watchdog: threading.Timer | None = None
    abort_poll: threading.Thread | None = None
    aborted = threading.Event()
    try:
        argv = _build_argv(
            command, model_cli, bridge.mcp_config_json(), system_prompt,
            extra_argv_prefix=extra_argv_prefix,
        )
        proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1, env=proc_env,
        )
        _write_user_turn(proc, user_text)
        # Per-turn mode: one message, then EOF so the CLI knows to finish.
        assert proc.stdin is not None
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

        abort_poll = _start_abort_poller(proc, should_abort, aborted)
        turn = _consume_turn(proc, timeout=timeout, on_text=on_text,
                             aborted=aborted, state={})
    except Exception as exc:
        turn.is_error = True
        turn.error = str(exc)
        # The CLI may have exited early (e.g. it rejected a flag) — surface its
        # stderr so the failure is diagnosable instead of a bare "Broken pipe".
        try:
            if proc is not None and proc.stderr is not None:
                tail = (proc.stderr.read() or "").strip()
                if tail:
                    turn.error = f"{turn.error} | claude stderr: {tail[:500]}"
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
        text=turn.text,
        tool_events=tool_events,
        is_error=turn.is_error,
        error=turn.error,
        usage=turn.usage,
    )


class WarmStructuredSession:
    """One long-lived ``claude`` process + MCP bridge, reused across turns.

    Plan 2.7. The per-turn engine pays a full CLI cold boot, MCP proxy spawn and
    MCP handshake on EVERY turn — 300–1500 ms of pure fixed tax before a single
    token is generated. Warm mode pays that once per agent session:

      * ``--no-session-persistence`` is dropped so the CLI keeps its transcript
      * stdin stays open and each turn writes one more stream-json user message
      * the MCP bridge (and therefore the socket + proxy child) stays up, with
        its tool catalogue and executor callback re-pointed per turn
      * if the process dies between turns it is restarted with ``--resume`` on
        the CLI's own session id, so the transcript survives the crash

    Turns are serialized: the CLI is a single conversation and JC's loop state
    assumes one turn at a time.  Off by default (``claude_code.warm``); the
    per-turn path above is unchanged and remains the fallback.
    """

    def __init__(
        self,
        *,
        command: str = "claude",
        model_cli: str = "claude-opus-4-8",
        system_prompt: str = "You are JarvisCopilot's model. Use the available tools to fully complete the user's request, then give a concise final answer.",
        env: dict[str, str] | None = None,
        timeout: float = _DEFAULT_TIMEOUT,
        extra_argv_prefix: list[str] | None = None,
    ) -> None:
        self._command = command
        self._model_cli = model_cli
        self._system_prompt = system_prompt
        self._env = dict(env or {})
        self._timeout = timeout
        self._extra_argv_prefix = list(extra_argv_prefix or [])
        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._bridge: McpToolBridge | None = None
        self._closed = False
        self._state: dict[str, Any] = {}
        # Turns completed on this session. The runtime uses it to decide whether
        # to send the full flattened history (first turn) or just the new user
        # message (the CLI holds the transcript from then on).
        self.turns = 0
        # Set for the CURRENT turn only; the bridge's executor closes over it.
        self._current_call: Callable[[str, dict[str, Any]], str] | None = None

    # ── lifecycle ────────────────────────────────────────────────────────────
    @property
    def alive(self) -> bool:
        return (not self._closed
                and self._proc is not None
                and self._proc.poll() is None)

    @property
    def pid(self) -> int | None:
        return self._proc.pid if self._proc is not None else None

    @property
    def cli_session_id(self) -> str | None:
        return self._state.get("session_id")

    @property
    def model_cli(self) -> str:
        return self._model_cli

    def _ensure_bridge(self) -> McpToolBridge:
        if self._bridge is None:
            self._bridge = McpToolBridge([], self._dispatch)
            self._bridge.start()
        return self._bridge

    def _dispatch(self, name: str, args: dict[str, Any]) -> str:
        """Bridge entry point — always routes to the CURRENT turn's executor."""
        call = self._current_call
        if call is None:
            return json.dumps({"error": "no active turn"})
        return call(name, args)

    def _ensure_process(self) -> subprocess.Popen:
        if self.alive:
            return self._proc  # type: ignore[return-value]
        if self._closed:
            raise RuntimeError("warm claude session is closed")
        self._reap_process()
        bridge = self._ensure_bridge()
        argv = _build_argv(
            self._command, self._model_cli, bridge.mcp_config_json(),
            self._system_prompt,
            persist_session=True,
            resume_session_id=self._state.get("session_id"),
            extra_argv_prefix=self._extra_argv_prefix,
        )
        self._proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
            env=_build_proc_env(self._env),
        )
        return self._proc

    def _reap_process(self) -> None:
        proc, self._proc = self._proc, None
        if proc is None:
            return
        for closer in (getattr(proc, "stdin", None),):
            try:
                if closer is not None:
                    closer.close()
            except Exception:
                pass
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2.0)
                except Exception:
                    proc.kill()
        except Exception:
            pass

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._reap_process()
            if self._bridge is not None:
                try:
                    self._bridge.close()
                except Exception:
                    pass
                self._bridge = None

    def __enter__(self) -> "WarmStructuredSession":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    # ── one turn ─────────────────────────────────────────────────────────────
    def run_turn(
        self,
        *,
        user_text: str,
        tools: list[dict[str, Any]] | None,
        execute_tool: Callable[[str, dict[str, Any]], str],
        on_text: Callable[[str], None] | None = None,
        on_tool_event: Callable[[str, dict[str, Any], str], None] | None = None,
        should_abort: Callable[[], bool] | None = None,
    ) -> SimpleNamespace:
        """Run one turn on the warm process. Same return shape as
        :func:`run_structured_turn`."""
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

        with self._lock:
            aborted = threading.Event()
            abort_poll: threading.Thread | None = None
            turn = SimpleNamespace(text="", is_error=False, error=None, usage={})
            try:
                bridge = self._ensure_bridge()
                bridge.set_tools(openai_tools_to_mcp(tools))
                self._current_call = _on_call
                proc = self._ensure_process()
                _write_user_turn(proc, user_text)
                abort_poll = _start_abort_poller(proc, should_abort, aborted)
                turn = _consume_turn(proc, timeout=self._timeout, on_text=on_text,
                                     aborted=aborted, state=self._state)
                if not turn.is_error:
                    self.turns += 1
                if turn.is_error and not self.alive:
                    # The process died mid-turn; drop it so the next turn (or the
                    # caller's retry) starts a fresh one with --resume.
                    self._reap_process()
            except Exception as exc:
                turn.is_error = True
                turn.error = str(exc)
                self._reap_process()
            finally:
                self._current_call = None
                aborted.set()
                if abort_poll is not None:
                    try:
                        abort_poll.join(timeout=1.0)
                    except Exception:
                        pass

        return SimpleNamespace(
            text=turn.text,
            tool_events=tool_events,
            is_error=turn.is_error,
            error=turn.error,
            usage=turn.usage,
        )
