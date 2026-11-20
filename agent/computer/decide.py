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
import re
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
- A popup in the way (cookies, notifications, location, sign-in): close it (Close / Not now / Don't Allow / ×) \
— never Allow or Accept unless the task says so.
- done: the current step already shows as finished. stuck: you cannot see a way forward, or the window shown is \
not the app this task is about."""

_VERIFY_PROMPT = """The user asked for this on their computer: {goal}
Moves made so far: {history}

Look at the screenshot. Is what the user asked for done? Something visibly starting, launching or loading counts \
as done (apps and games take a while to open). Only the thing they asked for counts: a page or app that merely \
shows it, with the asked action not taken, is not done.

Reply with ONLY one JSON object:
{{"done": true|false, "seen": "<what the screen shows, a few words>", "missing": "<what is still to do, if not done>"}}"""

_PLAN_PROMPT = """The user asked for something to be done on their {computer}. Split it into as few UI steps as possible.

Request: {goal}
Today: {today}
{notes}{apps}{progress}
Reply with ONLY one JSON object:
{{"steps": [{{"do": "<one step>", "app": "<app to open, if any>", "url": "<page to open, if any>", \
"text": "<exact text to type, if any>"}}]}}
Rules (fewer steps = faster):
- Websites: open the exact page in ONE step with "url" — search results directly (https://www.amazon.com/s?k=…, \
https://www.google.com/search?q=…, https://www.youtube.com/results?search_query=…) — and "app" = the browser \
the user named, else "Safari". Never type a web address or a search into a page.
- Apps: the first step opens the app ("app"){app_names}. Then one move per step: "click the <label> button" (its visible \
label, one press per step), "type … into the … field" with "text" word for word (no separate step to click \
the field first), or "press <key>".
- Something you can only know by looking (a price, a name, a number, a date): add a step \
{{"do": "read the …", "read": "<short_name>"}} on the screen that shows it, and write {{<short_name>}} in a later \
step's "text". Never write a placeholder like [price].
- Dates: write the exact date in steps ("go to Wednesday, October 14", working from Today), never "tomorrow"; \
in a calendar, first click Today, then move to the date.
- Only UI moves and read steps: the reply to the user is written afterwards from the screen, so never add a step \
to tell, say or report something.
- If what's on screen isn't the thing asked for (a launcher, hub or start page opened instead), carry on there like a \
person: pick the item the user means, then press the button that opens or starts it. No waiting steps."""


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


def context(look: dict, goal: str, step: dict, history: list, instructions: str = "", *, plan=None, at=None) -> str:
    step_line = f"Current step: {step.get('do') or goal}"
    if step.get("text"):
        step_line += f" (text to type: “{step['text']}”)"
    lines = [f"Goal: {goal}", f"Today: {_today()}"]
    if plan and at is not None and len(plan) > 1:
        # Which steps are already done, so a decider doesn't undo finished work.
        lines.append("Steps: " + "; ".join(
            f"{i + 1}) {'✓' if i < at else '▶' if i == at else ' '} {s.get('do')}".replace("  ", " ")
            for i, s in enumerate(plan)))
    lines += [step_line, f"Window: {look.get('app') or '?'} — {look.get('window') or ''}".rstrip(" —")]
    if instructions:
        lines.append(f"Notes: {instructions}")
    if history:
        lines += ["Last moves:"] + [f"- {h}" for h in history[-5:]]
    lines.append("Numbered elements on screen:")
    lines += [element_line(e) for e in look.get("elements") or []] or ["(none found; use the screenshot)"]
    return "\n".join(lines)


def _today() -> str:
    """Today in the user's own timezone (the server runs on UTC)."""
    try:
        from jarviscopilot_time import now
        return now().strftime("%A, %B %-d, %Y")
    except Exception:
        import datetime
        return datetime.datetime.now().astimezone().strftime("%A, %B %-d, %Y")


def _ref(ref: str) -> tuple[str | None, str]:
    q = split_ref(ref)
    return (q[0], q[1]) if q else (None, str(ref or ""))


def decide(ref, look, goal, step, history, *, instructions="", choose=None, timeout=DECISION_TIMEOUT,
           plan=None, at=None) -> Move:
    """The decision model's move; any failure is a zero-confidence ``stuck``."""
    if choose is None:
        from agent.decision_client import choose
    provider, model = _ref(ref)
    url = data_url(look)
    started = time.monotonic()
    try:
        d = choose(provider, model, instructions=QUESTION, choices=build_choices(look, step),
                   text=context(look, goal, step, history, instructions, plan=plan, at=at),
                   images=[url] if url else None,
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
    # The answer only, never a reasoning model's thoughts (they could be read out).
    try:
        return str(resp.choices[0].message.content or "")
    except Exception:
        return ""


def _valid(raw, look, step) -> dict:
    if not isinstance(raw, dict) or raw.get("action") not in _FALLBACK_ACTIONS:
        return {"action": "stuck"}
    act = raw["action"]
    ids = {e.get("i") for e in look.get("elements") or []}
    el = raw.get("element")
    el = int(el) if isinstance(el, (int, float)) or (isinstance(el, str) and el.isdigit()) else None
    if act in ("done", "stuck", "wait"):
        return {"action": act}
    if act in ("click", "fill") and el in ids:
        from agent.computer.choices import _other_tab, _permission
        target = next(e for e in look.get("elements") or [] if e.get("i") == el)
        if _permission(target, step) or _other_tab(target, step):
            return {"action": "stuck"}  # no unasked site permission; no tab clicks for a non-tab step
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


def fallback_step(ref, look, goal, step, history, *, instructions="", call=None, plan=None, at=None) -> Move:
    """One move from a vision chat model, as JSON; anything unusable is ``stuck``."""
    started = time.monotonic()
    try:
        out = _call(call, ref, _FALLBACK_PROMPT.format(
            context=context(look, goal, step, history, instructions, plan=plan, at=at)), look, 300)
    except Exception as exc:
        logger.debug("computer: fallback step failed", exc_info=True)
        return Move({"action": "stuck"}, None, "fallback", int((time.monotonic() - started) * 1000),
                    why=str(exc)[:160] or type(exc).__name__)
    raw = _json(out)
    why = str(raw.get("why") or "")[:160] if isinstance(raw, dict) else str(out or "")[:160]
    return Move(_valid(raw, look, step), None, "fallback", int((time.monotonic() - started) * 1000), why=why)


def verify_goal(ref, look, goal, history, *, call=None) -> dict:
    """Whether the screen shows the request done: ``{"done": True|False|None, "seen", "missing"}`` (None: the
    model couldn't say — the run keeps its result and says it wasn't confirmed)."""
    try:
        raw = _json(_call(call, ref, _VERIFY_PROMPT.format(goal=goal, history="; ".join(history[-12:]) or "none"),
                          look or {}, 200))
    except Exception as exc:  # noqa: BLE001
        logger.debug("computer: goal check failed", exc_info=True)
        return {"done": None, "seen": "", "missing": "", "error": str(exc)[:160]}
    if not isinstance(raw, dict) or not isinstance(raw.get("done"), bool):
        return {"done": None, "seen": "", "missing": ""}
    return {"done": raw["done"], "seen": str(raw.get("seen") or "")[:160], "missing": str(raw.get("missing") or "")[:200]}


_WINDOWS_APP_NAMES = (" by its Windows name (Settings, File Explorer, Calculator, Notepad, Microsoft Edge, Task "
                      "Manager — never a Mac app like Finder or System Settings)")


def plan_steps(ref, goal, look=None, *, instructions="", call=None, computer="Mac", apps=None, progress="") -> dict:
    """``{"steps": [{do, app?, url?, text?}], "say"}`` from his words alone (no screenshot:
    faster); the goal as one step when the reply can't be read; ``{"steps": [], "error"}`` when the
    planning model itself failed (never guess then: the goal alone names no app to stay on)."""
    notes = f"Notes: {instructions}\n" if instructions else ""
    try:
        # What's installed, so a nickname or a game's own name maps to the real entry (his ask 2026-11-20: like a
        # person who knows their computer — nothing hard-coded per app).
        apps_line = (f"Apps on this {computer} (open the one meant by its exact name here): "
                     f"{', '.join(str(a) for a in list(apps)[:150])}\n" if apps else "")
        progress_line = f"So far: {progress}\nPlan only what's left, from what the screen shows now.\n" if progress else ""
        prompt = _PLAN_PROMPT.format(goal=goal, notes=notes, today=_today(), computer=computer, apps=apps_line,
                                     progress=progress_line,
                                     app_names=_WINDOWS_APP_NAMES if "windows" in computer.lower() else "")
        raw = _json(_call(call, ref, prompt, look or {}, 300))
    except Exception as exc:
        logger.warning("computer: plan failed: %s", exc)
        return {"steps": [], "say": "", "error": str(exc)[:200] or type(exc).__name__}
    steps = []
    for s in (raw.get("steps") or []) if isinstance(raw, dict) else []:
        if isinstance(s, dict) and str(s.get("do") or "").strip():
            step = {k: str(s[k]).strip() for k in ("do", "text", "app", "url") if str(s.get(k) or "").strip()}
            if step.get("url") and not step["url"].startswith(("https://", "http://")):
                step.pop("url")
            name = re.sub(r"[^a-z0-9_]", "", str(s.get("read") or "").strip().lower())
            if name:
                step["read"] = name
            steps.append(step)
    if not steps:
        return {"steps": [{"do": goal}], "say": ""}
    return {"steps": repair_plan(steps[:8]), "say": str(raw.get("say") or "").strip()[:200]}


# Where text gets written: a read placed right after opening one of these reads the empty editor.
_EDITORS = frozenset({"notepad", "textedit", "notes", "word", "microsoft word", "pages", "wordpad"})


def repair_plan(steps: list) -> list:
    """Fix two slips a fast planner makes (live, Celeris-1): a read placed after opening the editor
    the value is for (it would read the empty editor), and typing a read's bare name, not its value."""
    steps = [dict(s) for s in steps]
    names = {s["read"] for s in steps if s.get("read")}
    for i in range(1, len(steps)):
        s, prev = steps[i], steps[i - 1]
        later_text = " ".join(str(t.get("text") or "") for t in steps[i + 1:])
        if (s.get("read") and str(prev.get("app") or "").strip().lower() in _EDITORS and s["read"] in later_text
                and any(p.get("app") or p.get("url") for p in steps[:i - 1])):
            steps[i - 1], steps[i] = s, prev
    for s in steps:
        if str(s.get("text") or "").strip() in names:
            s["text"] = "{" + str(s["text"]).strip() + "}"
    return steps


_CLOSING_PROMPT = """The user asked: {goal}
Today: {today}.{values}
That was just done on their Mac; the screenshot and the window's text below show the result. Write ONE short line \
for them (it may be read aloud): what was done and the answer or result shown. Only state what the screen or its \
text shows.

Window text:
{text}"""


_READ_PROMPT = """Look at the screenshot of the user's Mac ({app} — {window}) and the window's text below \
(it includes text a banner or popup may cover).
Task: {goal}
{do}
Reply with ONLY that value, exactly as shown and complete (e.g. $449.99, or the full title) — no sentence \
around it, at most 25 words. If this screen clearly shows there is nothing \
(an empty day, no results), say so briefly (e.g. "no events"). Reply NONE only if this is not the right screen.

Window text:
{text}"""


# "read the recommended PCs, their prices and details" wants several items, not one value (live: the
# notepad got one PC).
_LIST_READ = re.compile(r"\b(?:recommendations?|list|details|options|results|info(?:rmation)?|summar(?:y|ise|ize)|"
                        r"top\s+\d+|several|compare|comparison)\b", re.I)
_LIST_READ_PROMPT = """Look at the screenshot of the user's computer ({app} — {window}) and the window's text below \
(it includes text a banner or popup may cover).
Task: {goal}
{do}
Reply with ONLY a short list, one per line (at most 8 lines): each item's name and the key details or price shown. \
No intro and no other text. Reply NONE only if this is not the right screen.

Window text:
{text}"""


def read_value(ref, look, goal, step, *, call=None) -> str:
    """A value read off the screen for a later step ('' when it isn't visible); a short list, one item
    per line, when the step asks for recommendations / details / results."""
    many = bool(_LIST_READ.search(str(step.get("do") or "")))
    prompt = (_LIST_READ_PROMPT if many else _READ_PROMPT).format(
        app=look.get("app") or "?", window=look.get("window") or "", goal=goal, do=step.get("do") or "",
        text=str(look.get("text") or "(none)")[:6000 if many else 4000])
    try:
        out = _call(call, ref, prompt, look, 500 if many else 60)
    except Exception:
        logger.debug("computer: read failed", exc_info=True)
        return ""
    if many:
        value = "\n".join(" ".join(line.split()) for line in str(out or "").splitlines() if line.strip()).strip('"')
        return "" if not value or value.upper().startswith("NONE") else value[:2000]
    value = " ".join(str(out or "").split()).strip().strip('"')
    return "" if not value or value.upper().startswith("NONE") else value[:200]


_READING = re.compile(r"\?|\b(?:what|which|how (?:much|many|long)|work out|calculate|compute|tell me|read|"
                      r"find out|check|show me|is there|are there|look up)\b", re.I)


def needs_reading(goal: str) -> bool:
    """Whether the reply must report something read off the screen (else a quick line will do)."""
    return bool(_READING.search(str(goal or "")))


def closing_line(ref, goal, look, *, call=None, values=None) -> str:
    """The reply after a Mac job, read off the final screen ('' if the model fails)."""
    read = ("\nRead on screen during the task: " + "; ".join(f"{k} = {v}" for k, v in values.items())) if values else ""
    try:
        out = _call(call, ref, _CLOSING_PROMPT.format(goal=goal, today=_today(), values=read,
                                                      text=str((look or {}).get("text") or "(none)")[:4000]),
                    look or {}, 120)
    except Exception:
        logger.debug("computer: closing line failed", exc_info=True)
        return ""
    return " ".join(str(out or "").split())[:240]


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
