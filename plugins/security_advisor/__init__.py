"""Security Advisor: one always-on watcher for misuse of Jarvis.

Events come from ``security.events.emit()`` (webui, gateway, cron, host sources).
``guard`` runs inline as agent hooks in every process; ``rules`` classifies events
and the worker in the webui process acts on the result.
"""
from __future__ import annotations

from plugins.security_advisor import guard
from plugins.security_advisor.cli import register_cli, security_command
from plugins.security_advisor.tools import TOOLS, available


def register(ctx) -> None:
    # Always loaded; its Power switch decides whether it acts (jarvis_power).
    from jarvis_power.gate import gated

    def hook(name, fn):
        ctx.register_hook(name, gated("security-advisor", fn))

    hook("pre_llm_call", guard.on_pre_llm_call)
    hook("post_tool_call", guard.on_post_tool_call)
    hook("pre_tool_call", guard.on_pre_tool_call)
    hook("pre_approval_request", guard.on_pre_approval_request)
    hook("post_approval_response", guard.on_post_approval_response)
    hook("pre_gateway_dispatch", guard.on_pre_gateway_dispatch)
    ctx.register_auxiliary_task(
        "security_advisor", display_name="Security Advisor",
        description="Explains flagged security events and writes the daily digest",
        defaults={"provider": "claude-code", "model": "claude-haiku-5-5"})
    for name, schema, handler, emoji in TOOLS:
        ctx.register_tool(name=name, toolset="security_advisor", schema=schema, handler=handler,
                          check_fn=available, emoji=emoji)
    ctx.register_cli_command(
        name="security", help="Security Advisor status and break-glass unblock",
        setup_fn=register_cli, handler_fn=security_command)
