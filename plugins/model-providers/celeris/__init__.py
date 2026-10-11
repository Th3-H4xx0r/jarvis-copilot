"""Celeris provider profile.

Celeris serves diffusion LLMs (``celeris-1``, ``celeris-1-magnus``) over an
OpenAI-compatible chat API and a decision model (``celeris-1-decision``) that
answers typed questions with probabilities. Every model has its own base URL —
``https://inference.celeris.ai/<model>/v1`` — and the path model must match the
body ``model``, so :meth:`base_url_for_model` builds it from the model.

Reasoning: ``celeris-1`` thinks only with ``chat_template_kwargs.enable_thinking``
(one mode); ``celeris-1-magnus`` thinks by default with ``reasoning_effort``
low|medium|xhigh. Docs: https://docs.celeris.ai/models.md
"""

from __future__ import annotations

from typing import Any

from providers import _bare_model, register_provider
from providers.base import ProviderProfile

ROOT = "https://inference.celeris.ai"
_MAGNUS_EFFORT = {"minimal": "low", "low": "low", "medium": "medium",
                  "high": "xhigh", "xhigh": "xhigh", "max": "xhigh"}


def _root(base_url: str | None) -> str:
    """``https://inference.celeris.ai`` from a root, a ``…/v1`` root or a
    pasted per-model URL (``…/celeris-1/v1``)."""
    b = (base_url or "").strip().rstrip("/") or ROOT
    if b.endswith("/v1"):
        b = b[:-3].rstrip("/")
        if b.count("/") > 2:  # scheme:// + host + /<model>
            b = b.rsplit("/", 1)[0]
    return b


class CelerisProfile(ProviderProfile):
    """Per-model base URLs + Celeris's reasoning switches."""

    def base_url_for_model(self, model, base_url=None):
        m = _bare_model(model)
        if not m:
            return base_url
        return f"{_root(base_url or self.base_url)}/{m}/v1"

    def build_api_kwargs_extras(self, *, reasoning_config=None, model=None, **context
                                ) -> tuple[dict[str, Any], dict[str, Any]]:
        rc = reasoning_config if isinstance(reasoning_config, dict) else {}
        effort = str(rc.get("effort") or "").strip().lower()
        off = rc.get("enabled") is False or effort == "none"
        if "magnus" in _bare_model(model).lower():
            if off:
                return {"chat_template_kwargs": {"enable_thinking": False}}, {}
            level = _MAGNUS_EFFORT.get(effort)
            return {}, ({"reasoning_effort": level} if level else {})
        think = not off and effort in ("high", "xhigh", "max")
        return {"chat_template_kwargs": {"enable_thinking": think}}, {}


register_provider(CelerisProfile(
    name="celeris",
    display_name="Celeris",
    description="Celeris (fast diffusion LLMs + decision models)",
    signup_url="https://console.celeris.ai/",
    env_vars=("CELERIS_API_KEY", "CELERIS_BASE_URL"),
    base_url=ROOT,
    # Each URL lists only its own model, so no live catalog; `doctor` probes
    # celeris-1's models endpoint to check the key.
    models_url=f"{ROOT}/celeris-1/v1/models",
    supports_model_listing=False,
    fallback_models=("celeris-1", "celeris-1-magnus"),
    decision_models=("celeris-1-decision",),
    default_aux_model="celeris-1",
    default_max_tokens=16384,
))
