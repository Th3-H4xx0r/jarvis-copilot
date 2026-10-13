"""Ask for one Mac move: the decision model first, a vision chat model when unsure.

Any decision model works (``providers.is_decision_model``): it gets the numbered
screenshot plus the element list and picks one of ``choices.build_choices``.
The fallback model gets the same screen and answers in JSON, so it can also
click a pixel or type text no option offered. ``plan_steps`` turns a direct ask
("on my Mac play lo-fi in Spotify") into steps with the literal text to type.
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass

from agent.computer.choices import build_choices, element_line, parse_choice
from agent.harness.refs import split_ref

logger = logging.getLogger(__name__)

QUESTION = ("Which single move gets the current step done? Pick done when the screen already shows the step "
            "finished, and stuck when no option moves it forward.")
DECISION_TIMEOUT = 3.0
FALLBACK_TIMEOUT = 25.0
_FALLBACK_ACTIONS = ("click", "fill", "key", "scroll", "open_app", "wait", "done", "stuck")

_FALLBACK_PROMPT = """You are driving the user's Mac one move at a time. The screenshot shows the current window with \
numbered boxes; the same numbers are listed below.

{context}

Reply with ONLY one JSON object:
{{"action": "click"|"fill"|"key"|"scroll"|"open_app"|"wait"|"done"|"stuck", "element": <number>, \
"text": "<text to type>", "keys": "<e.g. return or cmd+f>", "direction": "up"|"down", "app": "<app name>", \
"x": <px>, "y": <px>, "why": "<a few words>"}}
- click: an element number, or x/y in screenshot pixels when no box covers the target.
- fill: an element number and the exact text to type into it.
- open_app: switch to or launch an app by name. Never use Spotlight (cmd+space) or cmd+tab for that.
- done: the current step already shows as finished. stuck: you cannot see a way forward, or the window shown is \
not the app this task is about."""

_PLAN_PROMPT = """The user asked for something to be done on their Mac. Split it into short UI steps.

Request: {goal}
Frontmost app now: {app}
{notes}
Reply with ONLY one JSON object:
{{"steps": [{{"do": "<one step>", "text": "<exact text to type, if any>", "app": "<app to open first, if any>"}}], \
"say": "<one short line for the user when it's done, e.g. Playing lo-fi in Spotify.>"}}
Use as few steps as possible (1-8). Each step is one UI move: "click the <label> button" (name buttons by \
their visible label, one press per step), "search for …" / "type … into …" only where there is a text field \
(put the text in "text", word for word), or "press <key>". The first step opens the app ("app") unless it is \
already in front."""


@dataclass
class Move:
    action: dict
    confidence: float | None
    by: str  # decision · fallback
    ms: int
    why: str = ""


def data_url(look: dict) -> str | None:
    b64 = (look or {}).get("base64")
    return f"data:{look.get('mime') or 'image/jpeg'};base64,{b64}" if b64 else None


def context(look: dict, goal: str, step: dict, history: list, instructions: str = "") -> str:
    step_line = f"Current step: {step.get('do') or goal}"
    if step.get("text"):
        step_line += f" (text to type: “{step['text']}”)"
    lines = [f"Goal: {goal}", step_line, f"Window: {look.get('app') or '?'} — {look.get('window') or ''}".rstrip(" —")]
    if instructions:
        lines.append(f"Notes: {instructions}")
    if history:
        lines += ["Last moves:"] + [f"- {h}" for h in history[-5:]]
    lines.append("Numbered elements on screen:")
    lines += [element_line(e) for e in look.get("elements") or []] or ["(none found; use the screenshot)"]
    return "\n".join(lines)


def _ref(ref: str) -> tuple[str | None, str]:
    q = split_ref(ref)
    return (q[0], q[1]) if q else (None, str(ref or ""))


def decide(ref, look, goal, step, history, *, instructions="", choose=None, timeout=DECISION_TIMEOUT) -> Move:
    """The decision model's move; any failure is a zero-confidence ``stuck``."""
    if choose is None:
        from agent.decision_client import choose
    provider, model = _ref(ref)
    url = data_url(look)
    started = time.monotonic()
    try:
        d = choose(provider, model, instructions=QUESTION, choices=build_choices(look, step),
                   text=context(look, goal, step, history, instructions), images=[url] if url else None,
                   timeout=timeout)
    except Exception as exc:
        return Move({"action": "stuck"}, 0.0, "decision", int((time.monotonic() - started) * 1000),
                    why=str(exc)[:160] or type(exc).__name__)
    return Move(parse_choice(d.choice, look, step), d.confidence, "decision",
                d.ms or int((time.monotonic() - started) * 1000))


def _json(text: str):
    t = str(text or "")
    try:
        return json.loads(t[t.index("{"):t.rindex("}") + 1])
    except Exception:
        return None


def _call(call, ref, prompt, look, max_tokens):
    if call is None:
        from agent.auxiliary_client import call_llm as call
    provider, model = _ref(ref)
    content = [{"type": "text", "text": prompt}]
    url = data_url(look)
    if url:
        content.append({"type": "image_url", "image_url": {"url": url}})
    # A fast JSON answer needs no thinking; Claude 5.x thinks by default and
    # spent the whole max_tokens on it (empty reply → every fallback "stuck").
    extra = {"thinking": {"type": "disabled"}} if str(provider or "").startswith("anthropic") else None
    resp = call(task="vision", provider=provider, model=model, temperature=0,
                messages=[{"role": "user", "content": content}], max_tokens=max_tokens, timeout=FALLBACK_TIMEOUT,
                extra_body=extra)
    from agent.auxiliary_client import extract_content_or_reasoning
    return extract_content_or_reasoning(resp)


def _valid(raw, look, step) -> dict:
    if not isinstance(raw, dict) or raw.get("action") not in _FALLBACK_ACTIONS:
        return {"action": "stuck"}
    act = raw["action"]
    ids = {e.get("i") for e in look.get("elements") or []}
    el = raw.get("element")
    el = int(el) if isinstance(el, (int, float)) or (isinstance(el, str) and el.isdigit()) else None
    if act in ("done", "stuck", "wait"):
        return {"action": act}
    if act == "click":
        if el in ids:
            return {"action": "click", "element": el}
        if isinstance(raw.get("x"), (int, float)) and isinstance(raw.get("y"), (int, float)):
            return {"action": "click", "x": int(raw["x"]), "y": int(raw["y"])}
    if act == "fill" and el in ids:
        text = str(raw.get("text") or step.get("text") or "")
        if text:
            return {"action": "fill", "element": el, "text": text}
    if act == "key" and str(raw.get("keys") or "").strip():
        return {"action": "key", "keys": str(raw["keys"]).strip()}
    if act == "scroll" and raw.get("direction") in ("up", "down"):
        return {"action": "scroll", "direction": raw["direction"]}
    if act == "open_app" and str(raw.get("app") or "").strip():
        return {"action": "open_app", "app": str(raw["app"]).strip()}
    return {"action": "stuck"}


def fallback_step(ref, look, goal, step, history, *, instructions="", call=None) -> Move:
    """One move from a vision chat model, as JSON; anything unusable is ``stuck``."""
    started = time.monotonic()
    try:
        out = _call(call, ref, _FALLBACK_PROMPT.format(context=context(look, goal, step, history, instructions)),
                    look, 300)
    except Exception as exc:
        logger.debug("computer: fallback step failed", exc_info=True)
        return Move({"action": "stuck"}, None, "fallback", int((time.monotonic() - started) * 1000),
                    why=str(exc)[:160] or type(exc).__name__)
    raw = _json(out)
    why = str(raw.get("why") or "")[:160] if isinstance(raw, dict) else str(out or "")[:160]
    return Move(_valid(raw, look, step), None, "fallback", int((time.monotonic() - started) * 1000), why=why)


def plan_steps(ref, goal, look, *, instructions="", call=None) -> dict:
    """``{"steps": [{do, text?, app?}], "say"}`` for a direct ask; the goal as one step on failure."""
    notes = f"Notes: {instructions}\n" if instructions else ""
    try:
        raw = _json(_call(call, ref, _PLAN_PROMPT.format(goal=goal, app=(look or {}).get("app") or "?",
                                                        notes=notes), look or {}, 400))
    except Exception:
        logger.debug("computer: plan failed", exc_info=True)
        raw = None
    steps = []
    for s in (raw.get("steps") or []) if isinstance(raw, dict) else []:
        if isinstance(s, dict) and str(s.get("do") or "").strip():
            steps.append({k: str(s[k]).strip() for k in ("do", "text", "app") if str(s.get(k) or "").strip()})
    if not steps:
        return {"steps": [{"do": goal}], "say": ""}
    return {"steps": steps[:8], "say": str(raw.get("say") or "").strip()[:200]}


def _has_key(provider: str) -> bool:
    try:
        from jarviscopilot_cli.auth import resolve_api_key_provider_credentials
        return bool(str((resolve_api_key_provider_credentials(provider) or {}).get("api_key") or "").strip())
    except Exception:
        return False


def pick_decision_ref(preferred: str | None) -> str | None:
    """``preferred`` when it is a decision model, else the first decision model with a key."""
    import providers
    if preferred:
        q = split_ref(preferred)
        if q and providers.is_decision_model(q[0], q[1]):
            return preferred
    for p in providers.list_providers():
        for m in getattr(p, "decision_models", ()) or ():
            if _has_key(p.name):
                return f"@{p.name}:{m}"
    return None
