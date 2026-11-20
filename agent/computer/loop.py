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
from agent.computer.choices import ONE_MOVE, TEXT_ROLES, batch_run, element_line, match_step, surface_for

logger = logging.getLogger(__name__)
_OPEN_VERB = re.compile(r"^\s*(?:open|launch|start|switch\s+to|go\s+to|bring\s+up|activate)\s+(?:the\s+)?(.*?)"
                        r"(?:\s+app(?:lication)?)?\s*\.?\s*$", re.I)
_ONE_MOVE = ONE_MOVE  # a step that is one move: done once that move works
_REFUSED = ("isn't in front", "using the Mac", "using the PC")
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
    share: str = ""  # the Mac screen share that showed (and recorded) this task
    timing: dict = field(default_factory=dict)  # plan_ms / decide_ms / hands_ms / total_ms

    def summary(self) -> str:
        # The computer it really ran on (live 2026-11-20: a PC run said "on the Mac" and the chat model retried).
        where = self.device_name or "the computer"
        head = {"done": f"Done on {where}.", "stuck": f"Stopped on {where} (stuck).",
                "error": f"Could not finish on {where}."}[self.status]
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


def _blocked(action: dict, allow_copy: bool = False) -> str | None:
    from tools.computer_use.tool import _BLOCKED_KEY_COMBOS, _canon_key_combo, _is_blocked_type
    from agent.mac_browser_gate import is_copy_combo
    if action.get("action") == "key" and _canon_key_combo(str(action.get("keys") or "")) in _BLOCKED_KEY_COMBOS:
        return f"refused the key combo {action['keys']}"
    if action.get("action") == "key" and is_copy_combo(action.get("keys")) and not allow_copy:
        # The clipboard can hold passwords and keys: copy only when he asked to.
        return f"refused to copy ({action['keys']}): the user didn't ask to copy anything"
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


LAUNCH_TRIES = 30          # a launcher or a game takes a while to show its window (~45 s)
LAUNCH_POLL_S = 1.5


_VAGUE_ROLES = ("group", "image", "statictext", "text", "pane", "generic", "unknown", "document", "window")


def _vague_target(action: dict, look: dict) -> bool:
    """A click whose target isn't a real control: a raw pixel, a number not on screen, or an unlabeled group."""
    if action.get("action") != "click":
        return False
    if action.get("element") is None:
        return True
    el = next((e for e in look.get("elements") or [] if e.get("i") == action.get("element")), None)
    if el is None:
        return True
    role = str(el.get("role") or "").lower().replace("ax", "", 1)
    return not str(el.get("label") or "").strip() and any(role.startswith(r) for r in _VAGUE_ROLES)


def _look_after_open(mac, device, app, launched=None) -> dict:
    """After open_app: look for what really started (open_app says: "Warzone" → "Call of Duty"), patiently —
    a game through its launcher takes tens of seconds (live 2026-11-20: gave up after one second)."""
    names = [n for n in dict.fromkeys([launched, app]) if n]
    look = {"ok": False, "error": f"{app} didn't open"}
    for attempt in range(LAUNCH_TRIES):
        for name in names:
            look = mac.look(device, app=name)
            if look.get("ok"):
                return look
        time.sleep(0.5 if attempt < 3 else LAUNCH_POLL_S)
    return look


def _look_soon(mac, device, app, tries=4, wait=0.5) -> dict:
    """A just-opened app's window can take a moment: look a few times before giving up."""
    look = mac.look(device, app=app)
    for _ in range(tries - 1):
        if look.get("ok"):
            break
        time.sleep(wait)
        look = mac.look(device, app=app)
    return look


class _Timed:
    """The computer, with the time spent looking and moving on it added to ``timing["hands_ms"]``."""

    def __init__(self, inner, timing: dict):
        self._inner, self._timing = inner, timing

    def _timed(self, fn, *a, **kw):
        t = time.monotonic()
        try:
            return fn(*a, **kw)
        finally:
            self._timing["hands_ms"] += int((time.monotonic() - t) * 1000)

    def look(self, *a, **kw):
        return self._timed(self._inner.look, *a, **kw)

    def act(self, *a, **kw):
        return self._timed(self._inner.act, *a, **kw)

    def __getattr__(self, name):
        return getattr(self._inner, name)


def _planner_ref() -> str | None:
    """`computer.planner_model` from config.yaml (plans + reads), or None."""
    try:
        from jarviscopilot_cli.config import load_config
        ref = str(((load_config() or {}).get("computer") or {}).get("planner_model") or "").strip()
        return ref or None
    except Exception:
        return None


def _with_values(step: dict, values: dict) -> dict:
    """A step whose text uses ``{name}`` gets the value a read step found."""
    text = step.get("text")
    if not text or "{" not in text:
        return step
    return {**step, "text": re.sub(r"\{([a-z0-9_]+)\}", lambda m: values.get(m.group(1), m.group(0)), text)}


def run(goal, steps, cfg: Config, *, device, device_name="", progress=None, should_stop=None,
        decide=None, fallback=None, mac=None, plan=None, app=None, read=None, allow_copy=False) -> Result:
    read = read or _decide_mod.read_value
    decide = decide or _decide_mod.decide
    fallback = fallback or _decide_mod.fallback_step
    plan = plan or _decide_mod.plan_steps
    mac = mac or _mac_mod
    started = time.monotonic()
    out = Result("done", device_name=device_name)
    # Planning and reading are text work: a fast model there saves ~20 s a task (Terra 9 s/call,
    # Celeris-1 0.3 s, live 2026-11-18); `computer.planner_model` in config.yaml, else as before.
    planner = _planner_ref() or cfg.fallback_ref
    out.timing = {"plan_ms": 0, "decide_ms": 0, "hands_ms": 0, "total_ms": 0}
    mac = _Timed(mac, out.timing)  # every look and move on the computer counts as hands

    def can(skill: str, feature: str) -> bool:
        # Old jc-clients reject arguments they don't know: only what this device advertises.
        try:
            return bool(getattr(mac, "supports", None) and mac.supports(device, skill, feature))
        except Exception:
            return False

    can_surface, can_clicks = can("ui_look", "surface"), can("ui_do", "clicks")
    kinds = []
    if can_surface and hasattr(mac, "surface_kinds"):
        try:
            kinds = list(mac.surface_kinds(device) or [])
        except Exception:
            kinds = []

    # Plan from his words first (no screenshot: faster), and skip the first look
    # when the first step opens an app or a page anyway.
    if steps is None:
        t_plan = time.monotonic()
        try:
            on_pc = getattr(mac, "os_of", None) is not None and mac.os_of(device) == "windows"
        except Exception:
            on_pc = False
        # Live: on the PC the plan opened "System Settings" and "Finder" — it must know the computer.
        extra = {"computer": "Windows PC"} if on_pc else {}
        planned = plan(planner, goal, None, instructions=cfg.instructions, **extra)
        out.timing["plan_ms"] = int((time.monotonic() - t_plan) * 1000)
        steps, out.say = planned["steps"], planned.get("say") or ""
        if not steps and planned.get("error"):
            # Live: with the planning model down, acting on "the goal as one step" clicked around in
            # whatever app was in front. Stop and say why.
            out.status, out.reason = "error", f"Couldn't plan the steps (the planning model failed: {planned['error']})."
            out.timing["total_ms"] = int((time.monotonic() - started) * 1000)
            return out
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
            out.timing["total_ms"] = int((time.monotonic() - started) * 1000)
            return out
    # The task stays on its app: if he switches to another app mid-task, the
    # looks keep reading this one (presses work in the background).
    anchor = look.get("app")
    out.steps = steps   # the same list: steps added on the way (a launcher's Play) show in the result
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

    skip_until = 0
    for at, step in enumerate(steps):
        if at < skip_until:
            continue  # pressed in a batch with the step before
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
            value = read(planner, look, goal, step)
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
            launched = res.get("launched")
            look = nxt if nxt and nxt.get("ok", True) else _look_after_open(mac, device, step["app"], launched)
            if not look.get("ok", True):
                out.status, out.reason = "error", look.get("error") or f"could not see {step['app']}"
                break
            anchor = look.get("app") or launched or step["app"]
            if res.get("launcher") and not any("play" in str(s.get("do") or "").lower() for s in steps[at + 1:]):
                # A game opens in its launcher (Battle.net, Steam…): a person then clicks Play (live 2026-11-20).
                game = res.get("game") or step["app"]
                steps.insert(at + 1, {"do": f"click the Play button for {game} in {launched or 'the launcher'}"})
                history.append(f"{launched or 'the launcher'} is open on {game}; next: click Play")
            if _open_only(step):
                history.append(f"step done: {step.get('do')}")
                continue  # "open Calculator": opening it was the whole step
        strikes, last_key, repeats, relooked, refusals = 0, None, 0, False, 0
        see_next = False
        last_unlanded = False
        # A step about the menu bar, a menu-bar item, the Dock or notifications looks at that surface.
        step_surface = surface_for(step, anchor) if can_surface else None
        if step_surface and kinds and step_surface not in kinds:
            step_surface = None  # this computer can't read that one (the PC has no menu bar)

        def relook():
            if step_surface:
                return mac.look(device, app=anchor if step_surface == "menubar" else None, surface=step_surface)
            return mac.look(device, app=anchor)

        if step_surface or look.get("surface"):
            fresh = relook()
            if fresh.get("ok"):
                look = fresh
            elif step_surface:  # never decide this step on a look of some other window
                out.status, out.reason = "stuck", f"Couldn't read the {step_surface}: {fresh.get('error') or 'no answer'}"
                break
        # Named buttons in a row (2, 3, ×, 4, =): pressed in one trip, one look at the end.
        run_ = batch_run(steps, at, look) if can_clicks and not step_surface else []
        if run_ and not (should_stop and should_stop()):
            t = time.monotonic()
            action = {"action": "clicks", "elements": [e for _, e in run_]}
            res = mac.act(device, action, look.get("look_id"))
            done = len(run_) if res.get("ok") else int(res.get("done") or 0)
            each = int((time.monotonic() - t) * 1000) // max(done, 1)
            for i, element in run_[:done]:
                record({"action": "click", "element": element}, {"ok": True, "via": res.get("via") or "batch"},
                       _decide_mod.Move({"action": "click", "element": element}, None, "match", 0), each)
                history.append(f"step done: {steps[i].get('do')}")
            if not res.get("ok"):
                can_clicks = False  # this computer won't batch: one at a time from here
                if res.get("device"):
                    out.status, out.reason = "error", res.get("error") or "the Mac stopped answering"
                    break
            if done:
                nxt = res.get("look") if isinstance(res.get("look"), dict) else None
                look = nxt if nxt and nxt.get("ok", True) else mac.look(device, app=anchor)
                skip_until = at + done
                continue
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
            # After a fast-model move that changed nothing, the screenshot model picks the next one: the target
            # likely isn't a labeled element (live 2026-11-20: three "click group" in Battle.net; Play was a pixel).
            move = decide(cfg.decision_ref, look, goal, step, history, instructions=cfg.instructions,
                          plan=steps, at=at) if cfg.decision_ref and not see_next else None
            see_next = False
            out.timing["decide_ms"] += (move.ms or 0) if move else 0
            # "done" before any move on this step is often wrong (a pressed ×
            # leaves no trace): only the fallback can confirm it.
            early_done = (move is not None and move.action.get("action") == "done"
                          and (len(out.actions) == moves_before or last_unlanded))
            if (move is None or early_done or move.action.get("action") == "stuck"
                    or (move.confidence or 0) < cfg.min_conf):
                first = move
                move = fallback(cfg.fallback_ref, look, goal, step, history, instructions=cfg.instructions,
                                plan=steps, at=at) if cfg.fallback_ref else first
                if cfg.fallback_ref and move is not None and move is not first:
                    out.timing["decide_ms"] += move.ms or 0
                if move is None or move.action.get("action") == "stuck":
                    strikes += 1
                    why = (move.why if move else "") or (first.why if first else "") or "no way forward"
                    if strikes >= 2:
                        out.status, out.reason = "stuck", f"Step “{step.get('do')}”: {why}"
                        break
                    history.append(f"unsure ({why}); looking again")
                    time.sleep(0.4)
                    fresh = relook()
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
            refused = _blocked(action, allow_copy)
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
                fresh = relook()
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
                    busy = next((w for w in ("using the Mac", "using the PC") if w in str(res.get("error"))), None)
                    out.status, out.reason = "stuck", (
                        f"You're {busy} right now, so I stopped instead of typing into it."
                        if busy else
                        f"{anchor or 'The app'} isn't in front (another app is in use), so I stopped instead of "
                        "typing into it.")
                    break
                continue
            last_unlanded = res.get("landed") == "no"  # (the client sends it with ok False on a refusal)
            if last_unlanded:
                history.append("the move didn't land")
            if action.get("action") == "open_app":
                anchor = res.get("launched") or action.get("app") or anchor
            new_look = res.get("look") if isinstance(res.get("look"), dict) else None
            if new_look is None or not new_look.get("ok", True):
                new_look = relook()
            key = json.dumps(action, sort_keys=True)
            unchanged = new_look.get("sig") == look.get("sig")
            repeats = repeats + 1 if (key == last_key and unchanged) else 0
            last_key = key
            if unchanged:
                history.append("nothing changed on screen")
                # A fast-model click on something vague (an unlabeled group, a missing number, a pixel) that changed
                # nothing: the screenshot model picks the next move.
                see_next = move.by == "decision" and bool(cfg.fallback_ref) and _vague_target(action, look)
            if new_look.get("ok", True):
                look = new_look
            sig = look.get("sig")
            visits[sig] = visits.get(sig, 0) + 1
            if sig and visits[sig] >= 3 and not unchanged:
                out.status, out.reason = "stuck", ("Going in circles between the same screens on step "
                                                   f"“{step.get('do')}”; stopped (the screen shows where it got to).")
                break
            if res.get("ok") and not last_unlanded and not (unchanged and see_next) and ((field is not None and not step.get("text"))
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
    out.timing["total_ms"] = int((time.monotonic() - started) * 1000)
    logger.info("Computer task: total=%sms plan=%sms decide=%sms hands=%sms moves=%s", out.timing["total_ms"],
                out.timing["plan_ms"], out.timing["decide_ms"], out.timing["hands_ms"], len(out.actions))
    return out
