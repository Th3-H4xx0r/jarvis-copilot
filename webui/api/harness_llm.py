"""One tool-less model call for harness steps that only need text back: a
model Route labelling a message, a Review node checking an answer.

The call lives in ``agent.harness.llm`` (the scheduler makes it too); here it
resolves the model the web UI's way (custom providers, Anthropic picks on the
Claude Code CLI) and runs as the web UI platform."""
from __future__ import annotations


def _webui_resolve(model_ref):
    import api.config as cfg
    return cfg.route_anthropic_via_claude_code(*cfg.resolve_model_provider(model_ref))


def one_shot_completion(model_ref: str, prompt: str, max_tokens: int = 8, reasoning_off: bool = False,
                        *, platform: str = "webui") -> str:
    """Run ``prompt`` once on ``model_ref`` (``@provider:model``) with no tools,
    no memory and no context files; return the reply text ('' when empty).
    ``platform`` names who asked (an integration's background runs pass their
    own, so the Agents tab groups them)."""
    from agent.harness.llm import one_shot_completion as _core_one_shot
    return _core_one_shot(model_ref, prompt, max_tokens=max_tokens, reasoning_off=reasoning_off,
                          platform=platform, resolve=_webui_resolve)
