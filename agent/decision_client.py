"""Ask a decision model one typed question (OpenAI Decisions API format).

A decision model (Celeris's ``celeris-1-decision``) does not chat: it reads the
input and answers typed questions with probabilities, in ~70 ms. Harness Route
nodes use it to pick a wire. Plain httpx — the pinned openai SDK has no
``decisions`` resource. Docs: https://docs.celeris.ai/decisions.md
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field

import httpx


class DecisionError(Exception):
    """A short, readable reason the decision call failed."""


@dataclass
class Decision:
    choice: str
    confidence: float | None = None
    probabilities: dict = field(default_factory=dict)
    ms: int = 0
    input_tokens: int = 0


def _endpoint(provider: str, model: str) -> tuple[str, str]:
    """(api key, base URL for ``model``) from the provider's own credentials."""
    from jarviscopilot_cli.auth import resolve_api_key_provider_credentials
    from providers import get_provider_profile

    profile = get_provider_profile(provider)
    if profile is None:
        raise DecisionError(f"unknown provider {provider!r}")
    try:
        creds = resolve_api_key_provider_credentials(provider) or {}
    except Exception:
        creds = {}
    key = str(creds.get("api_key") or "").strip()
    if not key:
        raise DecisionError(f"no {profile.env_vars[0] if profile.env_vars else 'API key'}")
    base = profile.base_url_for_model(model, str(creds.get("base_url") or "").strip() or None)
    return key, str(base or "").rstrip("/")


def _message(resp: httpx.Response) -> str:
    try:
        err = resp.json().get("error")
        if isinstance(err, dict) and err.get("message"):
            return str(err["message"])[:160]
    except Exception:
        pass
    return (resp.text or "")[:160]


def choose(provider, model, *, instructions, choices, text, timeout=1.5, client=None, images=None) -> Decision:
    """One ``choice`` question over ``text``; ``choices`` is ``[(value, description|None)]``.
    ``images`` (``data:`` URLs, at most 8) go with the text as one user message."""
    key, base = _endpoint(provider, model)
    question = {"type": "choice", "name": "route", "instructions": instructions,
                "choices": [{"value": v, **({"description": d} if d else {})} for v, d in choices]}
    inp = text or ""
    if images:
        inp = [{"role": "user", "content": [{"type": "input_text", "text": text or ""}] + [
            {"type": "input_image", "image_url": url} for url in list(images)[:8]]}]
    body = {"model": model, "input": inp, "questions": [question]}
    started = time.monotonic()
    try:
        resp = (client or httpx).post(f"{base}/decisions", json=body, timeout=timeout,
                                      headers={"Authorization": f"Bearer {key}"})
    except httpx.TimeoutException as exc:
        raise DecisionError("timed out") from exc
    except httpx.HTTPError as exc:
        raise DecisionError(f"request failed ({type(exc).__name__})") from exc
    ms = int((time.monotonic() - started) * 1000)
    if resp.status_code != 200:
        raise DecisionError(f"HTTP {resp.status_code}: {_message(resp)}")
    try:
        data = resp.json()
        answer = data["answers"][0]
        choice = answer["choice"]
    except Exception as exc:
        raise DecisionError("bad reply") from exc
    if choice not in [v for v, _ in choices]:
        raise DecisionError(f"bad reply (choice {choice!r})")
    probs = {str(p.get("value")): float(p.get("probability") or 0)
             for p in answer.get("probabilities") or [] if isinstance(p, dict)}
    conf = answer.get("confidence")
    return Decision(choice=choice, confidence=float(conf) if isinstance(conf, (int, float)) else None,
                    probabilities=probs, ms=ms,
                    input_tokens=int((data.get("usage") or {}).get("input_tokens") or 0))
