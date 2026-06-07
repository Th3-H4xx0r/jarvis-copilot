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
                    model: str | None, initial_prompt: str | None,
                    skip_permissions: bool = False,
                    resume: bool = False,
                    mcp_config: str | None = None) -> list[str]:
        """argv that starts a real agentic claude session.

        Deliberately omits the inference-shim's crippling flags (``--tools ""``,
        ``--no-session-persistence``, ``--strict-mcp-config``). ``--plugin-dir``
        makes the jarviscopilot-code-assist plugin available; the Jarvis memory
        seed is fed via ``--append-system-prompt-file`` (an absolute path).
        Returned as argv (no shell), so no value needs shell-quoting.

        ``skip_permissions`` adds ``--dangerously-skip-permissions`` (claude runs
        autonomously, no approval prompts). claude REFUSES that flag as root
        unless ``IS_SANDBOX=1`` — hermes runs as root, so we set it via the env
        prefix when the flag is on. ``resume`` adds ``--continue`` (resume the
        most recent conversation in this cwd — used by Restart).

        ``mcp_config`` (a path to a per-session ``.mcp.json``) adds
        ``--mcp-config`` so the code-assist MCP server is whatever the HOST can
        actually run — on the server that's ``python3 -m agent.coding_mcp_server``
        (the plugin's old static ``jc-client mcp-serve`` only exists on the
        desktop, so server-host sessions hit ENOENT and showed "MCP failed").
        """
        prefix = self._scrub_prefix()
        if skip_permissions:
            prefix = prefix + ["IS_SANDBOX=1"]
        argv = prefix + [
            _resolve_command(),
            "--plugin-dir", plugin_dir,
            "--append-system-prompt-file", context_file,
        ]
        if mcp_config:
            argv += ["--mcp-config", mcp_config]
        if resume:
            argv += ["--continue"]
        if skip_permissions:
            argv += ["--dangerously-skip-permissions"]
        if is_valid_model(model):
            argv += ["--model", model]
        if initial_prompt and not resume:
            argv += [initial_prompt]
        return argv

    def mcp_servers(self, *, cwd: str, repo_root: str) -> dict | None:
        """The ``mcpServers`` config for the code-assist MCP on THIS host.

        Server host: run the local-store MCP (``agent.coding_mcp_server``) with
        the repo root on ``PYTHONPATH`` so ``agent`` imports. Returns a dict the
        manager writes to a per-session ``.mcp.json`` and passes via
        ``--mcp-config``; returns None to add no server.
        """
        return {
            "mcpServers": {
                "jarviscopilot-code-assist": {
                    "command": "python3",
                    "args": ["-m", "agent.coding_mcp_server"],
                    "env": {"PYTHONPATH": str(repo_root)},
                }
            }
        }

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

    def preflight(self) -> str | None:
        """Ensure the host can run a session. Auto-installs tmux if missing.

        Returns None when ready, or a clear human-readable reason string the
        caller should surface (so the user never sees a raw ``[Errno 2] … tmux``).
        """
        from agent.coding_deps import claude_status, ensure_tmux

        ok, detail = ensure_tmux()
        if not ok:
            return detail
        ok, detail = claude_status()
        if not ok:
            return detail
        return None

    # --- execution (mocked in unit tests) -----------------------------------

    def _run(self, argv: list[str]) -> subprocess.CompletedProcess:
        return subprocess.run(argv, capture_output=True, text=True,
                              env=self.subprocess_env())


class DesktopDriver(LocalDriver):
    """Runs the session on the user's paired desktop client.

    Command *construction* is identical to ``LocalDriver`` (same tmux+claude
    argvs); only *execution* differs — argvs are dispatched to the desktop
    client over the device bridge instead of run locally. The bridge transport
    is injected (``bridge_run``) so it is testable.

    ``bridge_run`` may be supplied explicitly (tests) OR resolved lazily via
    ``bridge_run_factory()`` at run time. The factory path lets a single cached
    desktop manager (built once by ``coding_routes.default_manager``) bind to
    whichever desktop client is connected *now*, since devices connect/
    disconnect over the life of the webui process. In the webui process the
    factory builds an in-process bridge_run (api.coding_desktop); the registry
    is right there, so no REST hop like the agent-side chrome tools need.
    """

    name = "desktop"

    def __init__(self, bridge_run=None, preflight_fn=None,
                 bridge_run_factory=None, on_launched_fn=None):
        # bridge_run(argv) -> object with .returncode/.stderr (or None)
        self._bridge_run = bridge_run
        # () -> bridge_run | None, resolved each run (picks the live device)
        self._bridge_run_factory = bridge_run_factory
        # preflight_fn() -> reason|None, run on the DESKTOP (over the bridge),
        # since the server's local tmux/claude is irrelevant for a desktop session.
        self._preflight_fn = preflight_fn
        # on_launched_fn(session_id, cwd, tmux_name, sync) — called by the
        # manager after a successful start to kick off the file sync.
        self._on_launched_fn = on_launched_fn

    def mcp_servers(self, *, cwd: str, repo_root: str) -> dict | None:
        """No server-written ``--mcp-config`` for a desktop-host session: the
        config file would live on the SERVER filesystem, unreadable by the
        desktop's claude. The desktop client supplies its own code-assist MCP
        (``jc-client mcp-serve``). Returning None leaves the desktop path
        unchanged."""
        return None

    def on_launched(self, *, session_id, cwd, tmux_name, sync):
        if self._on_launched_fn is not None:
            self._on_launched_fn(session_id=session_id, cwd=cwd,
                                 tmux_name=tmux_name, sync=sync)

    def _resolve_bridge_run(self):
        if self._bridge_run is not None:
            return self._bridge_run
        if self._bridge_run_factory is not None:
            return self._bridge_run_factory()
        return None

    def preflight(self) -> str | None:
        if self._resolve_bridge_run() is None and self._preflight_fn is None:
            return ("no desktop client is connected. Pair the JarvisCopilot "
                    "desktop app (jc-client) to run sessions on your computer.")
        if self._preflight_fn is not None:
            return self._preflight_fn()
        return None

    def _run(self, argv: list[str]):
        run = self._resolve_bridge_run()
        if run is None:
            raise RuntimeError(
                "desktop session transport not configured — pair a desktop "
                "client (jc-client) and provide a bridge_run")
        return run(argv)
