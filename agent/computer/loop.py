"""look → decide → act until each step shows as done, on the user's Mac.

Each move is one decision-model call (any decision model) on the numbered
screenshot, then one ``ui_do`` round trip that also returns the next screen.
An unsure move (low confidence, or the decision model says ``stuck``) goes to the
fallback vision model; when that can't find a way either, the loop stops as
``stuck`` and its caller (the main model) takes over with the summary.
"""
from __future__ import annotations

import json
import logging
import re
import statistics
import time
from dataclasses import dataclass, field

from agent.computer import decide as _decide_mod
from agent.computer import mac as _mac_mod
from agent.computer.choices import TEXT_ROLES, element_line, match_step

logger = logging.getLogger(__name__)
_OPEN_VERB = re.compile(r"^\s*(?:open|launch|start|switch\s+to|go\s+to|bring\s+up|activate)\s+(?:the\s+)?(.*?)"
                        r"(?:\s+app(?:lication)?)?\s*\.?\s*$", re.I)
# A step that is one move ("click the first result", "press Return"): done once that move works.
_ONE_MOVE = re.compile(r"^\s*(?:click|press|tap|hit|select|choose|pick|open)\b(?!.*\b(?:and|then|until)\b)", re.I)
_REFUSED = ("isn't in front", "using the Mac")
_PAGE_TEXT_MIN = 400  # chars of window text before a just-opened page counts as loaded
# "tell the user the date": not a move on the Mac — the reply is written afterwards.
_TELL = re.compile(r"^\s*(?:tell|say|report|answer|inform|reply|let\s+(?:the\s+user|him|her|them|me)\s+know)\b", re.I)


def _open_only(step: dict) -> bool:
    """"open Spotify" (the whole step is opening its app) — not "go to the Library tab"."""
    m = _OPEN_VERB.match(str(step.get("do") or ""))
    return bool(m and step.get("app") and m.group(1).strip().lower() == str(step["app"]).strip().lower())


@dataclass
class Config:
    decision_ref: str | None
    fallback_ref: str | None
    max_actions: int = 30
    max_seconds: float = 120.0
    min_conf: float = 0.5
    instructions: str = ""


@dataclass
class Result:
    status: str  # done · stuck · error
    say: str = ""
    actions: list = field(default_factory=list)
    look: dict | None = None
    reason: str = ""
    steps: list = field(default_factory=list)
    device_name: str = ""
    values: dict = field(default_factory=dict)  # read off the screen by "read" steps

    def summary(self) -> str:
        head = {"done": "Done on the Mac.", "stuck": "Stopped on the Mac (stuck).",
                "error": "Could not finish on the Mac."}[self.status]
        lines = [head + (f" {self.reason}" if self.reason else "")]
        if self.steps:
            lines.append("Steps: " + "; ".join(f"{i + 1}) {s.get('do')}" for i, s in enumerate(self.steps)))
        if self.values:
            lines.append("Read on screen: " + "; ".join(f"{k} = {v}" for k, v in self.values.items()))
        if self.actions:
            ms = [a["ms"] for a in self.actions]
            lines.append(f"Moves ({len(ms)}, median {int(statistics.median(ms))} ms):")
            for a in self.actions[-12:]:
                conf = "" if a.get("conf") is None else f" {a['conf']:.2f}"
                lines.append(f"- {a['did']} [{a['by']}{conf}]")
        if self.look:
            lines.append(f"Screen now: {self.look.get('app') or '?'} — {self.look.get('window') or ''} "
                         f"(look_id {self.look.get('look_id')}; use these numbers with ui_do):")
            lines += [element_line(e) for e in (self.look.get("elements") or [])[:40]]
        return "\n".join(lines)


def _blocked(action: dict) -> str | None:
    from tools.computer_use.tool import _BLOCKED_KEY_COMBOS, _canon_key_combo, _is_blocked_type
    if action.get("action") == "key" and _canon_key_combo(str(action.get("keys") or "")) in _BLOCKED_KEY_COMBOS:
        return f"refused the key combo {action['keys']}"
    if action.get("action") == "fill" and _is_blocked_type(str(action.get("text") or "")):
        return "refused to type a dangerous command"
    return None


def describe(action: dict, look: dict) -> str:
    a = action.get("action")
    el = next((e for e in (look or {}).get("elements") or [] if e.get("i") == action.get("element")), None)
    thing = element_line(el).split(". ", 1)[1] if el else f"{action.get('x')},{action.get('y')}"
    if a == "click":
        return f"click {thing}"
    if a == "fill":
        return f"type “{action.get('text')}” into {thing}"
    if a == "key":
        return f"press {action.get('keys')}"
    if a == "scroll":
        return f"scroll {action.get('direction')}"
    if a == "open_app":
        return f"open {action.get('app')}"
    return str(a)


def _look_soon(mac, device, app, tries=4, wait=0.5) -> dict:
    """A just-opened app's window can take a moment: look a few times before giving up."""
    look = mac.look(device, app=app)
    for _ in range(tries - 1):
        if look.get("ok"):
            break
        time.sleep(wait)
        look = mac.look(device, app=app)
    return look


def _with_values(step: dict, values: dict) -> dict:
    """A step whose text uses ``{name}`` gets the value a read step found."""
    text = step.get("text")
    if not text or "{" not in text:
        return step
    return {**step, "text": re.sub(r"\{([a-z0-9_]+)\}", lambda m: values.get(m.group(1), m.group(0)), text)}


def run(goal, steps, cfg: Config, *, device, device_name="", progress=None, should_stop=None,
        decide=None, fallback=None, mac=None, plan=None, app=None, read=None) -> Result:
    read = read or _decide_mod.read_value
    decide = decide or _decide_mod.decide
    fallback = fallback or _decide_mod.fallback_step
    plan = plan or _decide_mod.plan_steps
    mac = mac or _mac_mod
    started = time.monotonic()
    out = Result("done", device_name=device_name)

    # Plan from his words first (no screenshot: faster), and skip the first look
    # when the first step opens an app or a page anyway.
    if steps is None:
        planned = plan(cfg.fallback_ref, goal, None, instructions=cfg.instructions)
        steps, out.say = planned["steps"], planned.get("say") or ""
    steps = list(steps)  # read steps may add a navigation step and a second read
    first = steps[0] if steps else {}
    if not app and (first.get("app") or first.get("url")):
        look = {"ok": True, "app": None, "look_id": None, "elements": []}
    else:
        # Start on the task's app when it is named (its window, even behind
        # others), else on whatever is in front.
        look = mac.look(device, app=app) if app else mac.look(device)
        if app and not look.get("ok"):
            opened = mac.act(device, {"action": "open_app", "app": app}, None)
            look = opened.get("look") if opened.get("ok") and isinstance(opened.get("look"), dict) else look
        if not look.get("ok"):
            out.status, out.reason = "error", look.get("error") or "could not see the screen"
            return out
    # The task stays on its app: if he switches to another app mid-task, the
    # looks keep reading this one (presses work in the background).
    anchor = look.get("app")
    out.steps = list(steps)
    history: list[str] = []

    def record(action, res, move, ms):
        did = describe(action, look)
        if not res.get("ok"):
            did += f" (failed: {res.get('error')})"
        entry = {"did": did, "via": res.get("via") or "", "by": move.by if move else "direct",
                 "conf": move.confidence if move else None, "ms": ms,
                 "decide_ms": move.ms if move else 0}
        out.actions.append(entry)
        history.append(did)
        logger.info("Computer step: %s via=%s by=%s conf=%s decide=%sms total=%sms", did, entry["via"],
                    entry["by"], entry["conf"], entry["decide_ms"], ms)
        if progress:
            try:
                progress(f"{did} · {ms / 1000:.1f} s")
            except Exception:
                pass

    for at, step in enumerate(steps):
        step = _with_values(step, out.values)
        if not step.get("url") and re.match(r"^https?://\S+$", str(step.get("text") or "").strip()):
            # "type the URL into the address bar": open it (typing it never loaded the page).
            step = {**{k: v for k, v in step.items() if k != "text"}, "url": step["text"].strip()}
        if _TELL.match(str(step.get("do") or "")) and not (step.get("app") or step.get("url") or step.get("text")):
            continue
        if step.get("read"):
            # Read a value off this screen for later steps (no move on the Mac).
            if should_stop and should_stop():
                out.status, out.reason = "error", "stopped"
                break
            value = read(cfg.fallback_ref, look, goal, step)
            if not value and not step.get("_retry"):
                # Not on this screen: a few moves to where it is shown, then read again.
                steps.insert(at + 1, {"do": f"get to the screen that shows this: {step.get('do')}", "_max": 4})
                steps.insert(at + 2, {**step, "_retry": True})
                history.append(f"{step['read']} isn't on this screen; looking for it")
                continue
            if not value:
                out.status, out.reason = "stuck", f"Couldn't read “{step['read']}” on the screen ({step.get('do')})."
                break
            out.values[step["read"]] = value
            history.append(f"read {step['read']} = {value}")
            logger.info("Computer read: %s = %s", step["read"], value)
            continue
        if re.search(r"\{[a-z0-9_]+\}", str(step.get("text") or "")):
            out.status, out.reason = "stuck", f"Nothing was read for “{step.get('text')}”."
            break
        moves_before = len(out.actions)
        visits: dict = {}  # screens seen during this step (a Go back ↔ open cycle revisits them)
        if step.get("url"):
            t = time.monotonic()
            action = {"action": "open_url", "url": step["url"], "app": step.get("app") or "Safari"}
            res = mac.act(device, action, look.get("look_id"))
            record(action, res, None, int((time.monotonic() - t) * 1000))
            if not res.get("ok"):
                out.status, out.reason = "error", res.get("error") or "could not open the page"
                break
            nxt = res.get("look") if isinstance(res.get("look"), dict) else None
            look = nxt if nxt and nxt.get("ok", True) else _look_soon(mac, device, action["app"])
            if not look.get("ok", True):
                out.status, out.reason = "error", look.get("error") or "could not see the page"
                break
            # Live (Best Buy): the title arrives long before the page; wait (≤3 s) for its text.
            for _ in range(6):
                if len(str(look.get("text") or "")) >= _PAGE_TEXT_MIN or "text" not in look:
                    break
                time.sleep(0.5)
                fresh = mac.look(device, app=action["app"])
                if fresh.get("ok"):
                    look = fresh
            anchor = look.get("app") or action["app"]
            history.append(f"step done: {step.get('do')}")
            continue  # opening the page was the whole step
        if step.get("app") and anchor and str(anchor).lower() == str(step["app"]).lower() and look.get("look_id"):
            step = {k: v for k, v in step.items() if k != "app"}  # already on that app: no re-open
            if _open_only({**step, "app": anchor}):
                history.append(f"step done: {step.get('do')}")
                continue
        if step.get("app"):
            t = time.monotonic()
            action = {"action": "open_app", "app": step["app"]}
            res = mac.act(device, action, look.get("look_id"))
            record(action, res, None, int((time.monotonic() - t) * 1000))
            if not res.get("ok"):
                out.status, out.reason = "error", res.get("error") or "could not open the app"
                break
            nxt = res.get("look") if isinstance(res.get("look"), dict) else None
            look = nxt if nxt and nxt.get("ok", True) else _look_soon(mac, device, step["app"])
            if not look.get("ok", True):
                out.status, out.reason = "error", look.get("error") or f"could not see {step['app']}"
                break
            anchor = look.get("app") or step["app"]
            if _open_only(step):
                history.append(f"step done: {step.get('do')}")
                continue  # "open Calculator": opening it was the whole step
        strikes, last_key, repeats, relooked, refusals = 0, None, 0, False, 0
        # "click the Send button" with exactly one Send on screen: click it, no decision.
        idx = match_step(step, look)
        if idx is not None and not (should_stop and should_stop()):
            t = time.monotonic()
            action = {"action": "click", "element": idx}
            res = mac.act(device, action, look.get("look_id"))
            record(action, res, _decide_mod.Move(action, None, "match", 0), int((time.monotonic() - t) * 1000))
            if not res.get("ok") and res.get("device"):
                out.status, out.reason = "error", res.get("error") or "the Mac stopped answering"
                break
            if res.get("ok"):
                nxt = res.get("look") if isinstance(res.get("look"), dict) else None
                look = nxt if nxt and nxt.get("ok", True) else mac.look(device, app=anchor)
                history.append(f"step done: {step.get('do')}")
                continue
        while True:
            if should_stop and should_stop():
                out.status, out.reason = "error", "stopped"
                break
            if len(out.actions) >= cfg.max_actions:
                out.status, out.reason = "stuck", f"Reached the {cfg.max_actions}-move limit."
                break
            if step.get("_max") and len(out.actions) - moves_before >= step["_max"]:
                break  # a bounded navigation step: the read after it decides
            if time.monotonic() - started > cfg.max_seconds:
                out.status, out.reason = "stuck", f"Ran out of time ({int(cfg.max_seconds)} s)."
                break
            t = time.monotonic()
            move = decide(cfg.decision_ref, look, goal, step, history, instructions=cfg.instructions,
                          plan=steps, at=at) if cfg.decision_ref else None
            # "done" before any move on this step is often wrong (a pressed ×
            # leaves no trace): only the fallback can confirm it.
            early_done = (move is not None and move.action.get("action") == "done"
                          and len(out.actions) == moves_before)
            if (move is None or early_done or move.action.get("action") == "stuck"
                    or (move.confidence or 0) < cfg.min_conf):
                first = move
                move = fallback(cfg.fallback_ref, look, goal, step, history, instructions=cfg.instructions,
                                plan=steps, at=at) if cfg.fallback_ref else first
                if move is None or move.action.get("action") == "stuck":
                    strikes += 1
                    why = (move.why if move else "") or (first.why if first else "") or "no way forward"
                    if strikes >= 2:
                        out.status, out.reason = "stuck", f"Step “{step.get('do')}”: {why}"
                        break
                    history.append(f"unsure ({why}); looking again")
                    time.sleep(0.4)
                    fresh = mac.look(device, app=anchor)
                    if fresh.get("ok"):
                        look = fresh
                    continue
            strikes = 0
            action = move.action
            if action.get("action") == "done":
                history.append(f"step done: {step.get('do')}")
                logger.info("Computer step done: %s by=%s conf=%s", step.get("do"), move.by, move.confidence)
                break
            # Clicking a text field: with text to type that means fill it; without, the
            # click (focus) is the whole step — the screen won't visibly change.
            field = next((e for e in look.get("elements") or [] if e.get("i") == action.get("element")
                          and e.get("role") in TEXT_ROLES), None) if action.get("action") == "click" else None
            if field is not None and step.get("text"):
                action = {"action": "fill", "element": field["i"], "text": step["text"]}
            if action.get("text") and out.values:  # a model may echo {price}: type the value read
                action = {**action, "text": _with_values({"text": action["text"]}, out.values)["text"]}
            refused = _blocked(action)
            if refused:
                out.status, out.reason = "stuck", refused[0].upper() + refused[1:] + "."
                break
            if should_stop and should_stop():  # he may have said stop while the move was decided
                out.status, out.reason = "error", "stopped"
                break
            res = mac.act(device, action, look.get("look_id"))
            ms = int((time.monotonic() - t) * 1000)
            if not res.get("ok") and "look again" in str(res.get("error") or "") and not relooked:
                relooked = True
                fresh = mac.look(device, app=anchor)
                if fresh.get("ok"):
                    look = fresh
                continue
            relooked = False
            record(action, res, move, ms)
            if not res.get("ok") and res.get("device"):
                out.status, out.reason = "error", res.get("error") or "the Mac stopped answering"
                break
            if not res.get("ok") and any(r in str(res.get("error") or "") for r in _REFUSED):
                refusals += 1
                if refusals >= 2:
                    out.status, out.reason = "stuck", (
                        "You're using the Mac right now, so I stopped instead of typing into it."
                        if "using the Mac" in str(res.get("error")) else
                        f"{anchor or 'The app'} isn't in front (another app is in use), so I stopped instead of "
                        "typing into it.")
                    break
                continue
            if action.get("action") == "open_app":
                anchor = action.get("app") or anchor
            new_look = res.get("look") if isinstance(res.get("look"), dict) else None
            if new_look is None or not new_look.get("ok", True):
                new_look = mac.look(device, app=anchor)
            key = json.dumps(action, sort_keys=True)
            unchanged = new_look.get("sig") == look.get("sig")
            repeats = repeats + 1 if (key == last_key and unchanged) else 0
            last_key = key
            if unchanged:
                history.append("nothing changed on screen")
            if new_look.get("ok", True):
                look = new_look
            sig = look.get("sig")
            visits[sig] = visits.get(sig, 0) + 1
            if sig and visits[sig] >= 3 and not unchanged:
                out.status, out.reason = "stuck", ("Going in circles between the same screens on step "
                                                   f"“{step.get('do')}”; stopped (the screen shows where it got to).")
                break
            if res.get("ok") and ((field is not None and not step.get("text"))
                                  or (_ONE_MOVE.match(str(step.get("do") or ""))
                                      and action.get("action") not in ("scroll", "wait"))):
                # A field click, or a one-move step whose move just worked: no "is it done?" call.
                history.append(f"step done: {step.get('do')}")
                break
            if repeats >= 2:
                out.status, out.reason = "stuck", f"“{describe(action, look)}” did nothing three times."
                break
        if out.status != "done":
            break
    out.look = look
    return out
