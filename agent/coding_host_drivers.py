"""Host drivers for Coding Sessions.

A ``HostDriver`` abstracts *where* a Claude Code session runs. ``LocalDriver``
runs ``tmux`` + ``claude`` on this host (the Jarvis server). A future
``DesktopDriver`` (Phase 4) issues the same operations to the paired desktop
client over the device bridge.

Command *construction* is kept pure (and unit-tested); *execution* wraps
``subprocess``. The subprocess env reuses the proven credential scrub from
``agent/claude_code_client.py`` so a launched ``claude`` bills the user's
subscription, not an API key.
"""
from __future__ import annotations

import shlex
import subprocess

from agent.claude_code_client import _build_subprocess_env, _resolve_command


class HostDriver:
    """Base host driver. Subclasses implement command construction + execution."""

    name = "base"

    def subprocess_env(self) -> dict:
        return _build_subprocess_env()


class LocalDriver(HostDriver):
    """Runs tmux + claude locally on the Jarvis server host."""

    name = "server"

    def tmux_new_argv(self, *, tmux_name: str, cwd: str) -> list[str]:
        """argv to create a detached tmux session rooted at ``cwd``."""
        return ["tmux", "new-session", "-d", "-s", tmux_name, "-c", cwd]

    def claude_launch_command(self, *, plugin_dir: str, context_file: str,
                              model: str | None,
                              initial_prompt: str | None) -> str:
        """The shell command (typed into the tmux pane) that starts ``claude``.

        Deliberately omits the inference-shim's crippling flags (``--tools ""``,
        ``--no-session-persistence``, ``--strict-mcp-config``): this is a real
        agentic session. ``--plugin-dir`` makes the jarviscopilot-code-assist
        plugin (+ its bundled skills and MCP back-channel) available; the
        Jarvis memory seed is fed via ``--append-system-prompt-file``.
        """
        claude = _resolve_command()
        cmd = (f"{claude} --plugin-dir {plugin_dir} "
               f"--append-system-prompt-file {context_file}")
        if model:
            cmd += f" --model {model}"
        if initial_prompt:
            cmd += " " + shlex.quote(initial_prompt)
        return cmd

    def send_message_argvs(self, *, tmux_name: str, text: str) -> list[list[str]]:
        """Two ``tmux send-keys`` argvs: literal text, then a separate Enter.

        Sending the text with ``-l`` (literal) then Enter as its own keystroke
        is the reliable, bracketed-paste-safe way to submit a turn into an
        interactive CLI without the text being interpreted as key names.
        """
        return [
            ["tmux", "send-keys", "-t", tmux_name, "-l", text],
            ["tmux", "send-keys", "-t", tmux_name, "Enter"],
        ]

    # --- execution (mocked in unit tests) -----------------------------------

    def _run(self, argv: list[str]) -> subprocess.CompletedProcess:
        return subprocess.run(argv, capture_output=True, text=True,
                              env=self.subprocess_env())
