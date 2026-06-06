"""Host drivers for Coding Sessions.

A ``HostDriver`` abstracts *where* a Claude Code session runs. ``LocalDriver``
runs ``tmux`` + ``claude`` on this host (the Jarvis server). A future
``DesktopDriver`` (Phase 4) issues the same operations to the paired desktop
client over the device bridge.

Security posture (hardened after the Phase-1 bug sweep):
- The session is launched as the tmux pane's **argv command** (no intermediate
  shell), so model/path values are never parsed by a shell — eliminating the
  command-injection vector and the "type into a not-yet-ready shell" race.
- The argv is prefixed with ``env -u <secret> …`` so Anthropic credentials are
  stripped at exec time regardless of what environment a pre-existing tmux
  *server* holds (a plain ``env=`` on the new-session client does NOT reach the
  pane when tmux attaches to an already-running server).
- ``--model`` is only included when it passes an allowlist (``_looks_like_claude_model``).
- Free-text messages are sent with ``send-keys -l -- <text>`` so a message
  beginning with ``-`` is not parsed as tmux options.
"""
from __future__ import annotations

import subprocess

from agent.claude_code_client import (
    _build_subprocess_env,
    _looks_like_claude_model,
    _resolve_command,
)

# Anthropic credentials that must NOT reach a launched claude (it must bill the
# user's subscription, not an API key). Mirrors claude_code_client._build_subprocess_env.
SCRUB_KEYS = (
    "ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
)


def is_valid_model(model: str | None) -> bool:
    """True when ``model`` is a safe value to pass to ``claude --model``."""
    return bool(model) and _looks_like_claude_model(model)


class HostDriver:
    """Base host driver. Subclasses implement command construction + execution."""

    name = "base"

    def subprocess_env(self) -> dict:
        return _build_subprocess_env()


class LocalDriver(HostDriver):
    """Runs tmux + claude locally on the Jarvis server host."""

    name = "server"

    def _scrub_prefix(self) -> list[str]:
        prefix = ["env"]
        for k in SCRUB_KEYS:
            prefix += ["-u", k]
        return prefix

    def claude_argv(self, *, plugin_dir: str, context_file: str,
                    model: str | None, initial_prompt: str | None) -> list[str]:
        """argv that starts a real agentic claude session.

        Deliberately omits the inference-shim's crippling flags (``--tools ""``,
        ``--no-session-persistence``, ``--strict-mcp-config``). ``--plugin-dir``
        makes the jarviscopilot-code-assist plugin available; the Jarvis memory
        seed is fed via ``--append-system-prompt-file`` (an absolute path).
        Returned as argv (no shell), so no value needs shell-quoting.
        """
        argv = self._scrub_prefix() + [
            _resolve_command(),
            "--plugin-dir", plugin_dir,
            "--append-system-prompt-file", context_file,
        ]
        if is_valid_model(model):
            argv += ["--model", model]
        if initial_prompt:
            argv += [initial_prompt]
        return argv

    def tmux_new_argv(self, *, tmux_name: str, cwd: str,
                      launch_argv: list[str]) -> list[str]:
        """argv to create a detached tmux session that runs ``launch_argv``."""
        return ["tmux", "new-session", "-d", "-s", tmux_name, "-c", cwd] + list(launch_argv)

    def send_message_argvs(self, *, tmux_name: str, text: str) -> list[list[str]]:
        """Two ``tmux send-keys`` argvs: literal text (after ``--``), then Enter.

        ``-l`` sends text literally (not interpreted as key names); the ``--``
        terminator ensures a message starting with ``-`` is treated as payload,
        not as more tmux options. Enter is sent as its own keystroke to submit.
        """
        return [
            ["tmux", "send-keys", "-t", tmux_name, "-l", "--", text],
            ["tmux", "send-keys", "-t", tmux_name, "Enter"],
        ]

    def kill_argv(self, *, tmux_name: str) -> list[str]:
        return ["tmux", "kill-session", "-t", tmux_name]

    # --- execution (mocked in unit tests) -----------------------------------

    def _run(self, argv: list[str]) -> subprocess.CompletedProcess:
        return subprocess.run(argv, capture_output=True, text=True,
                              env=self.subprocess_env())


class DesktopDriver(LocalDriver):
    """Runs the session on the user's paired desktop client.

    Command *construction* is identical to ``LocalDriver`` (same tmux+claude
    argvs); only *execution* differs — argvs are dispatched to the desktop
    client over the device bridge instead of run locally. The bridge transport
    is injected (``bridge_run``) so it is testable and so the agent process,
    which can't see the webui's in-memory device registry, can route through
    the webui REST API the same way ``tools/chrome_device_tool.py`` does.
    """

    name = "desktop"

    def __init__(self, bridge_run=None):
        # bridge_run(argv) -> object with .returncode/.stderr (or None)
        self._bridge_run = bridge_run

    def _run(self, argv: list[str]):
        if self._bridge_run is None:
            raise RuntimeError(
                "desktop session transport not configured — pair a desktop "
                "client (jc-client) and provide a bridge_run")
        return self._bridge_run(argv)
