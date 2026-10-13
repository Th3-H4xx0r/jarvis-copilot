"""Which Computer node a turn uses, and the Router → Computer pre-step.

``conversation_loop`` binds every turn: the harness Computer node wired to this
turn's node (or none, which means defaults), the turn's own model (the fallback
when the node names none) and how to tell the user asked to stop.
``computer_first`` runs the fast loop before any model call when a Route sent
the turn straight to a Computer node.
"""
from __future__ import annotations

import json
import logging
import threading
import uuid
from collections import OrderedDict
from dataclasses import dataclass
from typing import Callable, Optional

from agent.computer import loop as _loop

logger = logging.getLogger(__name__)

TOOL_NAME = "computer_do"
_MAX = 2000
_lock = threading.Lock()
_bound: "OrderedDict[str, Binding]" = OrderedDict()


@dataclass
class Binding:
    node: Optional[dict]
    own_ref: Optional[str]
    should_stop: Optional[Callable[[], bool]] = None


def bind(task_id, node, *, own_ref=None, should_stop=None) -> None:
    if not task_id:
        return
    with _lock:
        _bound[task_id] = Binding(node if isinstance(node, dict) else None, own_ref, should_stop)
        _bound.move_to_end(task_id)
        while len(_bound) > _MAX:
            _bound.popitem(last=False)


def bound(task_id) -> Optional[Binding]:
    with _lock:
        return _bound.get(task_id or "")


def reset_for_tests() -> None:
    with _lock:
        _bound.clear()


def config_for(node, own_ref) -> _loop.Config:
    from agent.computer.decide import pick_decision_ref
    node = node or {}
    try:
        max_actions = max(1, int(node.get("max_steps") or 30))
    except (TypeError, ValueError):
        max_actions = 30
    return _loop.Config(decision_ref=pick_decision_ref(str(node.get("model") or "").strip() or None),
                        fallback_ref=str(node.get("fallback_model") or "").strip() or own_ref,
                        max_actions=max_actions, instructions=str(node.get("instructions") or "").strip())


def clean_steps(steps) -> Optional[list]:
    if not isinstance(steps, list):
        return None
    out = [{k: str(s[k]).strip() for k in ("do", "text", "app") if str(s.get(k) or "").strip()}
           for s in steps if isinstance(s, dict) and str(s.get("do") or "").strip()]
    return out or None


def run_task(goal, steps, task_id, app=None) -> tuple:
    """``(Result, None)`` or ``(None, error)``: find the Mac, run the loop (on ``app`` when named)."""
    from agent.computer import mac
    device, name, err = mac.find_mac(task_id)
    if err:
        return None, err
    b = bound(task_id) or Binding(None, None)
    result = _loop.run(goal, clean_steps(steps), config_for(b.node, b.own_ref), device=device, device_name=name,
                       should_stop=b.should_stop, app=str(app or "").strip() or None)
    return result, None


def tool_result(result: _loop.Result):
    """The tool result: the summary, plus the final screenshot as an image envelope —
    the agent turns it into image parts or a text summary for its own model."""
    text = result.summary()
    from agent.computer.decide import data_url
    url = data_url(result.look or {})
    if url:
        return {"_multimodal": True, "text_summary": text,
                "content": [{"type": "text", "text": text}, {"type": "image_url", "image_url": {"url": url}}]}
    return json.dumps({"ok": result.status == "done", "status": result.status, "summary": text},
                      ensure_ascii=False)


def computer_first(agent, messages: list, user_text, task_id) -> Optional[str]:
    """Run a Route → Computer turn's fast loop before any model call.

    Done → the tool call, its result and the closing line are appended and the
    line is returned (the turn needs no model call). Stuck → the tool call and
    its result are appended and None is returned (the stuck node's model takes
    over). Not asked for the Mac / no Mac → nothing appended, None."""
    from agent import mac_browser_gate
    if not mac_browser_gate.allowed(task_id):
        return None
    goal = mac_browser_gate._text(user_text).strip()
    if not goal:
        return None
    call_id = f"call_computer_{uuid.uuid4().hex[:12]}"
    cb = getattr(agent, "tool_progress_callback", None)
    if cb:
        try:
            cb("tool.started", TOOL_NAME, goal[:80], {"goal": goal})
        except Exception:
            pass
    result, err = run_task(goal, None, task_id)
    if cb:
        try:
            cb("tool.completed", TOOL_NAME, None, None, duration=None,
               is_error=bool(err) or (result is not None and result.status != "done"))
        except Exception:
            pass
    if err:
        logger.info("Computer first: skipped (%s)", err)
        return None
    messages.append({"role": "assistant", "content": "", "tool_calls": [{
        "id": call_id, "type": "function",
        "function": {"name": TOOL_NAME, "arguments": json.dumps({"goal": goal}, ensure_ascii=False)}}]})
    content = tool_result(result)
    to_model = getattr(agent, "_tool_result_content_for_active_model", None)
    if callable(to_model):  # image parts or a text summary, whatever this agent's model takes
        content = to_model(TOOL_NAME, content)
    from agent.tool_dispatch_helpers import make_tool_result_message
    messages.append(make_tool_result_message(TOOL_NAME, content, call_id))
    if result.status == "done":
        from agent.computer.decide import closing_line, needs_reading
        b = bound(task_id) or Binding(None, None)
        say = ""
        if needs_reading(goal):  # an answer to read off the screen (a sum, what's playing…)
            say = closing_line(config_for(b.node, b.own_ref).fallback_ref, goal, result.look)
        if not say:  # an action: say what was done, no extra model call
            last = (result.actions or [{}])[-1].get("did") or ""
            app = (result.look or {}).get("app") or ""
            say = (f"Done — {last}" + (f" ({app})" if app else "") + ".") if last else "Done."
        messages.append({"role": "assistant", "content": say})
        return say
    return None
