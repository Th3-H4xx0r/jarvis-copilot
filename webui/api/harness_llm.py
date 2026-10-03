"""One tool-less model call for harness steps that only need text back: a
model Route labelling a message, a Review node checking an answer."""
from __future__ import annotations


def one_shot_completion(model_ref: str, prompt: str, max_tokens: int = 8) -> str:
    """Run ``prompt`` once on ``model_ref`` (``@provider:model``) with no tools,
    no memory and no context files; return the reply text ('' when empty)."""
    import api.config as cfg
    from jarviscopilot_cli.runtime_provider import resolve_runtime_provider
    from run_agent import AIAgent

    model, provider, base_url = cfg.route_anthropic_via_claude_code(
        *cfg.resolve_model_provider(model_ref))
    import inspect

    rt = resolve_runtime_provider(requested=provider) or {}
    kwargs = dict(
        model=model,
        provider=provider or rt.get("provider"),
        base_url=base_url or rt.get("base_url"),
        api_key=rt.get("api_key"),
        api_mode=rt.get("api_mode"),
        acp_command=rt.get("command"),
        acp_args=rt.get("args"),
        credential_pool=rt.get("credential_pool"),
        quiet_mode=True,
        enabled_toolsets=[],
        skip_context_files=True,
        skip_memory=True,
        max_iterations=1,
        max_tokens=max_tokens,
        platform="webui",
    )
    # Same defensive filter as api.streaming: only pass what this build accepts.
    accepted = set(inspect.signature(AIAgent.__init__).parameters)
    agent = AIAgent(**{k: v for k, v in kwargs.items() if k in accepted})
    return str(agent.chat(prompt) or "").strip()
