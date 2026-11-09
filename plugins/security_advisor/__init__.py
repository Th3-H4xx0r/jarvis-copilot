"""Security Advisor: one always-on watcher for misuse of Jarvis.

Events come from ``security.events.emit()`` (webui, gateway, cron, host sources).
``guard`` runs inline as agent hooks in every process; ``rules`` classifies events
and the worker in the webui process acts on the result.
"""
from __future__ import annotations

from plugins.security_advisor import guard


def register(ctx) -> None:
    ctx.register_hook("pre_llm_call", guard.on_pre_llm_call)
    ctx.register_hook("post_tool_call", guard.on_post_tool_call)
    ctx.register_hook("pre_tool_call", guard.on_pre_tool_call)
    ctx.register_hook("pre_approval_request", guard.on_pre_approval_request)
    ctx.register_hook("post_approval_response", guard.on_post_approval_response)
    ctx.register_hook("pre_gateway_dispatch", guard.on_pre_gateway_dispatch)
    ctx.register_auxiliary_task(
        "security_advisor", display_name="Security Advisor",
        description="Explains flagged security events and writes the daily digest",
        defaults={"provider": "claude-code", "model": "claude-haiku-5-5"})
