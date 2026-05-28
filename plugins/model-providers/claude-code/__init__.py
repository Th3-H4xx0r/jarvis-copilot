"""Claude Code provider profile.

Routes inference through the locally-installed, already-logged-in `claude`
CLI (claude -p), reusing the CLI's own login so requests are billed to the
user's Claude subscription. JarvisCopilot keeps its own agent loop and tools;
the CLI is invoked only as a text generator (native tools disabled via
`--tools ""`).

Pattern mirrors `plugins/model-providers/copilot-acp/` — declarative profile
with auth_type="external_process", dispatch handled by
`agent/claude_code_client.py` (selected in `agent/agent_runtime_helpers.py`
and `agent/auxiliary_client.py`).
"""

from providers import register_provider
from providers.base import ProviderProfile


class ClaudeCodeProfile(ProviderProfile):
    """Claude Code — local CLI subprocess, no REST models endpoint."""

    def fetch_models(
        self,
        *,
        api_key: str | None = None,
        timeout: float = 8.0,
    ) -> list[str] | None:
        """Live catalog isn't exposed by the CLI; the picker uses fallback_models."""
        return None


claude_code = ClaudeCodeProfile(
    name="claude-code",
    aliases=("claude-cli", "claude-code-cli", "claude-max"),
    display_name="Claude Code",
    description="Claude Code (local CLI — uses your Claude subscription)",
    signup_url="https://claude.com/claude-code",
    api_mode="chat_completions",  # intercepted before HTTP, like copilot-acp
    env_vars=(),  # login lives entirely in the `claude` CLI
    base_url="claude-cli://local",  # marker scheme; routed to ClaudeCodeClient
    auth_type="external_process",
    supports_health_check=False,
    default_aux_model="claude-haiku-4-5",
    fallback_models=(
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-sonnet-4-6",
        "claude-sonnet-4-5",
        "claude-haiku-4-5",
    ),
)

register_provider(claude_code)
