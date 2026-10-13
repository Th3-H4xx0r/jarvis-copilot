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
import statistics
import time
from dataclasses import dataclass, field

from agent.computer import decide as _decide_mod
from agent.computer import mac as _mac_mod
from agent.computer.choices import element_line

logger = logging.getLogger(__name__)


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

    def summary(self) -> str:
        head = {"done": "Done on the Mac.", "stuck": "Stopped on the Mac (stuck).",
                "error": "Could not finish on the Mac."}[self.status]
        lines = [head + (f" {self.reason}" if self.reason else "")]
        if self.steps:
            lines.append("Steps: " + "; ".join(f"{i + 1}) {s.get('do')}" for i, s in enumerate(self.steps)))
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


def run(goal, steps, cfg: Config, *, device, device_name="", progress=None, should_stop=None,
        decide=None, fallback=None, mac=None, plan=None) -> Result:
    decide = decide or _decide_mod.decide
    fallback = fallback or _decide_mod.fallback_step
    plan = plan or _decide_mod.plan_steps
    mac = mac or _mac_mod
    started = time.monotonic()
    out = Result("done", device_name=device_name)

    look = mac.look(device)
    if not look.get("ok"):
        out.status, out.reason = "error", look.get("error") or "could not see the screen"
        return out
    # The task stays on its app: if he switches to another app mid-task, the
    # looks keep reading this one (presses work in the background).
    anchor = look.get("app")
    if steps is None:
        planned = plan(cfg.fallback_ref, goal, look, instructions=cfg.instructions)
        steps, out.say = planned["steps"], planned.get("say") or ""
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

    for step in steps:
        if step.get("app"):
            t = time.monotonic()
            action = {"action": "open_app", "app": step["app"]}
            res = mac.act(device, action, look.get("look_id"))
            record(action, res, None, int((time.monotonic() - t) * 1000))
            if not res.get("ok"):
                out.status, out.reason = "error", res.get("error") or "could not open the app"
                break
            nxt = res.get("look") if isinstance(res.get("look"), dict) else None
            look = nxt if nxt and nxt.get("ok", True) else mac.look(device, app=step["app"])
            anchor = look.get("app") or step["app"]
        strikes, last_key, repeats, relooked, refusals = 0, None, 0, False, 0
        while True:
            if should_stop and should_stop():
                out.status, out.reason = "error", "stopped"
                break
            if len(out.actions) >= cfg.max_actions:
                out.status, out.reason = "stuck", f"Reached the {cfg.max_actions}-move limit."
                break
            if time.monotonic() - started > cfg.max_seconds:
                out.status, out.reason = "stuck", f"Ran out of time ({int(cfg.max_seconds)} s)."
                break
            t = time.monotonic()
            move = decide(cfg.decision_ref, look, goal, step, history, instructions=cfg.instructions) \
                if cfg.decision_ref else None
            if move is None or move.action.get("action") == "stuck" or (move.confidence or 0) < cfg.min_conf:
                first = move
                move = fallback(cfg.fallback_ref, look, goal, step, history, instructions=cfg.instructions) \
                    if cfg.fallback_ref else first
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
                break
            refused = _blocked(action)
            if refused:
                out.status, out.reason = "stuck", refused[0].upper() + refused[1:] + "."
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
            if not res.get("ok") and "isn't in front" in str(res.get("error") or ""):
                refusals += 1
                if refusals >= 2:
                    out.status, out.reason = "stuck", (f"{anchor or 'The app'} isn't in front (another app is "
                                                       "in use), so I stopped instead of typing into it.")
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
            if repeats >= 2:
                out.status, out.reason = "stuck", f"“{describe(action, look)}” did nothing three times."
                break
        if out.status != "done":
            break
    out.look = look
    return out
