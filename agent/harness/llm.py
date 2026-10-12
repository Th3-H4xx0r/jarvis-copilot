"""One tool-less model call for harness steps that only need text back: a
model Route labelling a message, a Review node checking an answer."""
from __future__ import annotations

from agent.harness import refs
from agent.harness.refs import split_ref


def resolve_ref(model_ref):
    """``(model, provider, base_url)`` for a ``@provider:model`` (or bare) ref,
    with chat's Anthropic → Claude Code redirect. The provider's base URL comes
    from the runtime resolver, so it is None here."""
    ref = str(model_ref or "").strip()
    q = split_ref(ref)
    model, provider = (q[1], q[0]) if q else (ref, None)
    return refs.route_anthropic_via_claude_code(model, provider, None)


def one_shot_completion(model_ref: str, prompt: str, max_tokens: int = 8, reasoning_off: bool = False,
                        *, platform: str = "cron", resolve=None) -> str:
    """Run ``prompt`` once on ``model_ref`` (``@provider:model``) with no tools,
    no memory and no context files; return the reply text ('' when empty).
    ``reasoning_off`` keeps a thinking model (Celeris Magnus) from spending a
    tiny budget on reasoning — a Route's label needs no thought. ``resolve``
    maps the ref to ``(model, provider, base_url)`` (the web UI passes its
    catalog-aware resolver)."""
    import inspect

    from jarviscopilot_cli.runtime_provider import resolve_runtime_provider
    from run_agent import AIAgent

    model, provider, base_url = (resolve or resolve_ref)(model_ref)
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
        platform=platform,
    )
    if reasoning_off:
        kwargs["reasoning_config"] = {"enabled": False}
    # Only pass what this build of AIAgent accepts.
    accepted = set(inspect.signature(AIAgent.__init__).parameters)
    agent = AIAgent(**{k: v for k, v in kwargs.items() if k in accepted})
    try:
        return str(agent.chat(prompt) or "").strip()
    finally:
        # A long-lived process (the gateway's scheduler) must not keep the
        # client of every one-shot agent open.
        try:
            agent.close()
        except Exception:
            pass
