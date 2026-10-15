"""Where a blocked approval or question waits for an answer.

The hook server hands every PermissionRequest and AskUserQuestion frame to
``Arbiter.submit`` with a ``reply`` callable bound to the waiting jc-hook. The
first valid decision wins — a click on the Mac island (local), or the phone
(server → ``agent_decision`` frame) — and it only ever answers the request it
was made for: decisions carry the request's fingerprint, and anything else is
ignored. A request also settles when it was answered somewhere else (the
tool ran, the turn ended, the hook went away) or after 115 s, in which case
Claude asks in the terminal. After coucou's ApprovalQueue / HookServer
(github.com/Louis-CFM/coucou, MIT).
"""
from __future__ import annotations

import itertools
import logging
import threading
import time
import uuid
from typing import Callable, Optional

try:
    from jc_client import agent_engine
except ImportError:  # loaded by file path on the server (agent/agent_engine_shim.py)
    from agent import agent_engine_shim as agent_engine

log = logging.getLogger(__name__)

_TURN_ENDERS = ("Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt")
_APPROVAL_DECISIONS = ("allow", "deny", "always", "ask")


def _input_key(inp) -> str:
    import json
    try:
        return json.dumps(inp or {}, sort_keys=True, separators=(",", ":"), default=str)
    except Exception:
        return ""


def _normalize_answers(questions, answers) -> dict:
    """Single-select answers are a string, multi-select a list (Claude Code's shape)."""
    out = {}
    multi = {q.get("question"): bool(q.get("multiSelect"))
             for q in questions or [] if isinstance(q, dict)}
    for question, value in (answers or {}).items():
        if multi.get(question):
            out[question] = list(value) if isinstance(value, (list, tuple)) else [str(value)]
        elif isinstance(value, (list, tuple)):
            out[question] = str(value[0]) if value else ""
        else:
            out[question] = str(value)
    return out


class Arbiter:
    MAX_PENDING = 5
    RELEASE_AFTER = 115.0

    def __init__(self, send_up: Callable[[dict], None], gate: Callable[[], bool],
                 on_settled: Optional[Callable[[str, str], None]] = None,
                 on_change: Optional[Callable[[], None]] = None,
                 clock=time.time, timer=threading.Timer) -> None:
        self._send_up = send_up
        self._gate = gate
        self._on_settled = on_settled
        self._on_change = on_change
        self._clock = clock
        self._timer = timer
        self._lock = threading.Lock()
        self._entries: dict[int, dict] = {}
        self._tokens = itertools.count(1)

    # ── reading ──────────────────────────────────────────────────────────
    def pending(self) -> list[dict]:
        with self._lock:
            entries = sorted(self._entries.values(), key=lambda e: e["at"])
            return [self._public(e) for e in entries]

    # ── a hook is waiting ────────────────────────────────────────────────
    def submit(self, kind, agent, payload, key, reply) -> Optional[int]:
        try:
            on = bool(self._gate())
        except Exception:
            on = False
        if not on:
            reply({"decision": "ask"})
            return None
        tool = str(payload.get("tool_name") or "Tool")
        inp = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
        if not payload.get("tool_use_id"):
            # Same stamp as the hook server's: identical asks stay distinct.
            payload["tool_use_id"] = "jc-" + uuid.uuid4().hex[:20]
        entry = {
            "kind": kind, "agent": agent, "key": key,
            "session_id": str(payload.get("session_id") or ""),
            "cwd": str(payload.get("cwd") or ""), "tool": tool,
            "tool_use_id": str(payload.get("tool_use_id") or ""),
            "input_key": _input_key(inp), "summary": agent_engine.step_label(tool, inp)
            if kind == "ask" else _summary(tool, inp),
            "command": str(inp.get("command") or ""),
            "questions": inp.get("questions") if kind == "ask" else None,
            "suggestions": payload.get("permission_suggestions") or [],
            "fingerprint": agent_engine.fingerprint(payload.get("session_id"),
                                                    payload.get("tool_use_id"), tool, inp),
            "at": self._clock(), "reply": reply,
        }
        with self._lock:
            if len(self._entries) >= self.MAX_PENDING:
                full = True
            else:
                full = False
                token = next(self._tokens)
                entry["token"] = token
                timer = self._timer(self.RELEASE_AFTER, self._release, args=(token,))
                timer.daemon = True
                entry["timer"] = timer
                self._entries[token] = entry
        if full:
            reply({"decision": "ask"})
            return None
        timer.start()
        self._up("agent_pending", self._public(entry))
        self._changed()
        return token

    # ── answers ──────────────────────────────────────────────────────────
    def decide(self, fingerprint, decision, message=None, answers=None) -> bool:
        decision = str(decision or "").lower()
        with self._lock:
            entry = next((e for e in self._entries.values() if e["fingerprint"] == fingerprint), None)
            if entry is None:
                return False
            if entry["kind"] == "ask" and decision not in ("answer", "ask"):
                return False
            if entry["kind"] != "ask" and decision not in _APPROVAL_DECISIONS:
                return False
            self._entries.pop(entry["token"], None)
        if decision == "answer":
            answer = {"decision": "answer",
                      "answers": _normalize_answers(entry["questions"], answers)}
        elif decision == "always":
            answer = {"decision": "always", "updated_permissions": entry["suggestions"]}
        elif decision == "deny" and message:
            answer = {"decision": "deny", "message": str(message)}
        else:
            answer = {"decision": decision}
        self._finish(entry, answer, "decided", decision)
        return True

    def observe(self, payload, key) -> None:
        """An ordinary hook event: maybe a waiting request was settled elsewhere."""
        event = payload.get("hook_event_name")
        if event in ("PostToolUse", "PostToolUseFailure"):
            tid = str(payload.get("tool_use_id") or "")
            tool = str(payload.get("tool_name") or "")
            ikey = _input_key(payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {})
            match = lambda e: e["key"] == key and (  # noqa: E731
                (tid and e["tool_use_id"] == tid) or (e["tool"] == tool and e["input_key"] == ikey))
        elif event in _TURN_ENDERS:
            match = lambda e: e["key"] == key  # noqa: E731
        else:
            return
        with self._lock:
            done = [e for e in self._entries.values() if match(e)]
            for e in done:
                self._entries.pop(e["token"], None)
        for e in done:
            self._finish(e, {"decision": "ask"}, "elsewhere", None)

    def peer_gone(self, token) -> None:
        with self._lock:
            entry = self._entries.pop(token, None) if token is not None else None
        if entry is not None:
            self._finish(entry, None, "gone", None)

    # ── internals ────────────────────────────────────────────────────────
    def _release(self, token) -> None:
        with self._lock:
            entry = self._entries.pop(token, None)
        if entry is not None:
            self._finish(entry, {"decision": "ask"}, "timeout", None)

    def _finish(self, entry, answer, reason, decision) -> None:
        try:
            entry["timer"].cancel()
        except Exception:
            pass
        if answer is not None:
            try:
                entry["reply"](answer)
            except Exception:
                log.debug("arbiter reply failed", exc_info=True)
        self._up("agent_settled", {"fingerprint": entry["fingerprint"], "key": entry["key"],
                                   "kind": entry["kind"], "reason": reason, "decision": decision})
        if self._on_settled is not None:
            try:
                self._on_settled(entry["key"], entry["fingerprint"])
            except Exception:
                log.debug("arbiter on_settled failed", exc_info=True)
        self._changed()

    def _public(self, e) -> dict:
        out = {k: e[k] for k in ("fingerprint", "kind", "agent", "key", "session_id", "cwd", "tool",
                                 "summary", "command", "at")}
        if e["kind"] == "ask":
            out["questions"] = e["questions"] or []
        else:
            out["can_always"] = bool(e["suggestions"])
        return out

    def _up(self, name, data) -> None:
        try:
            self._send_up({"type": "event", "name": name, "data": data})
        except Exception:
            log.debug("arbiter send_up failed", exc_info=True)

    def _changed(self) -> None:
        if self._on_change is not None:
            try:
                self._on_change()
            except Exception:
                log.debug("arbiter on_change failed", exc_info=True)


def _summary(tool, inp) -> str:
    for key in ("command", "file_path", "path", "url", "pattern", "query", "description", "prompt"):
        v = inp.get(key)
        if isinstance(v, str) and v.strip():
            return f"{tool}: {v.strip().splitlines()[0][:200]}"
    return tool
