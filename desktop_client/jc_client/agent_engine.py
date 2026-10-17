"""Shared coding-agent engine: hook events in, per-session state out.

One implementation, two hosts: jc-client runs it for the Mac island (local
truth, works with the server down) and the server loads this same file for the
phone (``agent/agent_engine_shim.py``), so the meaning of a state can't drift
between them. Pure Python, standard library only, no I/O: ``ingest`` and
``sweep`` return *effects* (notify, state, turn_done, ended) that the host
turns into pushes.

Session model and recovery rules after coucou's PillSessionRegistry /
TurnRecorder (github.com/Louis-CFM/coucou, MIT).
"""
from __future__ import annotations

import copy
import difflib
import hashlib
import json
import os
import time
from urllib.parse import urlsplit

FINISHED_HOLD = 5.0                 # finished shows this long, then idle
TURN_SILENCE = 30 * 60.0            # a turn this quiet lost its Stop
SESSION_SILENCE = 12 * 3600.0       # a session this quiet is gone
MAX_STEPS = 40
MAX_ACTIONS = 200
MAX_OUTPUT = 1500
MAX_PROMPT = 8000
MAX_FINAL = 12_000
MAX_SUMMARY = 600
MAX_DIFF_LINES_PER_FILE = 600
MAX_DIFF_LINES_PER_TURN = 4000
MAX_LINE_CHARS = 400

STATES = ("idle", "thinking", "working", "approval", "question", "ratelimit",
          "finished", "error")
_URGENCY = {"approval": 0, "question": 0, "error": 1, "ratelimit": 2,
            "working": 3, "thinking": 3, "finished": 4, "idle": 5}
_TOOL_EVENTS = ("PreToolUse", "PostToolUse", "PostToolUseFailure")


_SAME_WINDOW = 600.0   # resets_at within this of each other is the same window


def merge_rate_limits(current, incoming):
    """Plan usage from many status lines, without flicker.

    Every Claude session (and its subagents) reports its own last-seen
    snapshot several times a second, so reports arrive stale and out of order
    (17, 20, 19, 21…). Within one window usage only grows: keep the highest
    report per window, and move on only when a report's window resets later.
    Returns the merged limits, or None when nothing changed.
    """
    if not isinstance(incoming, dict):
        return None
    cur = current if isinstance(current, dict) else {}
    out = dict(cur)
    for name, w in incoming.items():
        if not isinstance(w, dict):
            continue
        try:
            used, reset = float(w["used_percentage"]), float(w["resets_at"])
        except (KeyError, TypeError, ValueError):
            continue
        old = out.get(name)
        if isinstance(old, dict):
            try:
                o_used, o_reset = float(old["used_percentage"]), float(old["resets_at"])
            except (KeyError, TypeError, ValueError):
                o_used = o_reset = None
            if o_reset is not None:
                if reset < o_reset - _SAME_WINDOW:
                    continue                                    # an older window
                if abs(reset - o_reset) <= _SAME_WINDOW and used <= o_used:
                    continue                                    # same window, not higher
        out[name] = dict(w)
    return out if out != cur else None


def session_key(host: str, agent: str, session_id: str, cwd: str) -> str:
    sid = session_id or ("cwd:" + (cwd or ""))
    return f"{host}|{agent}|{sid}"


def fingerprint(session_id, tool_use_id, tool, tool_input) -> str:
    blob = json.dumps([session_id or "", tool_use_id or "", tool or "", tool_input or {}],
                      sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(blob.encode()).hexdigest()[:32]


def _first_line(text, limit=120):
    line = str(text or "").strip().splitlines()[0] if str(text or "").strip() else ""
    return line if len(line) <= limit else line[: limit - 1] + "…"


def step_label(tool: str, tool_input) -> str:
    """Short, human label for a tool call (the island ticker / phone steps)."""
    tool = tool or "Tool"
    inp = tool_input if isinstance(tool_input, dict) else {}
    if tool.startswith("mcp__"):
        parts = tool.split("__")
        return f"{parts[1]}: {'__'.join(parts[2:])}" if len(parts) > 2 else tool
    if tool == "Bash":
        return "Bash: " + _first_line(inp.get("command"), 80)
    if tool in ("Read", "Edit", "MultiEdit", "Write", "NotebookEdit"):
        path = inp.get("file_path") or inp.get("notebook_path") or inp.get("path") or ""
        return f"{tool} {os.path.basename(str(path))}".strip()
    if tool in ("Grep", "Glob"):
        return "Search " + _first_line(inp.get("pattern"), 60)
    if tool == "WebFetch":
        return "Fetch " + (urlsplit(str(inp.get("url") or "")).hostname or "page")
    if tool == "WebSearch":
        return "Search the web: " + _first_line(inp.get("query"), 60)
    if tool in ("Task", "Agent"):
        return "Agent: " + _first_line(inp.get("description") or inp.get("prompt"), 60)
    if tool == "TodoWrite":
        return "Update todos"
    for key in ("command", "file_path", "path", "pattern", "url", "query", "description"):
        if inp.get(key):
            return f"{tool}: {_first_line(inp[key], 60)}"
    return tool


def _summary(tool, tool_input) -> str:
    inp = tool_input if isinstance(tool_input, dict) else {}
    for key in ("command", "file_path", "path", "pattern", "url", "query", "description", "prompt"):
        v = inp.get(key)
        if isinstance(v, str) and v.strip():
            return f"{tool}: {v.strip()[:MAX_SUMMARY]}"
    return tool or "Tool"


def _output(payload) -> str:
    text = ""
    if isinstance(payload.get("error"), str):
        text = payload["error"]
    else:
        resp = payload.get("tool_response")
        if isinstance(resp, dict):
            out = [str(resp.get(k) or "") for k in ("stdout", "stderr")]
            text = "\n".join(x for x in out if x)
            if not text and isinstance(resp.get("content"), str):
                text = resp["content"]
        elif isinstance(resp, str):
            text = resp
    text = text.strip()
    return text if len(text) <= MAX_OUTPUT else text[:MAX_OUTPUT] + "\n…"


def _lines(text):
    return str(text or "").splitlines()


def _cap_line(t):
    return t if len(t) <= MAX_LINE_CHARS else t[:MAX_LINE_CHARS] + "…"


def _hunks(old, new):
    """[(kind, text)] for old→new with 3 context lines; '@' marks a gap."""
    out = []
    first = True
    for raw in difflib.unified_diff(_lines(old), _lines(new), n=3, lineterm=""):
        if raw.startswith("---") or raw.startswith("+++"):
            continue
        if raw.startswith("@@"):
            if not first:
                out.append(("@", ""))
            first = False
            continue
        kind = raw[:1] if raw[:1] in "+- " else " "
        out.append((kind, raw[1:]))
    return out


def diff_from_tool(tool, tool_input, budget=MAX_DIFF_LINES_PER_FILE):
    """A file diff from Edit / MultiEdit / Write input (never reads the file)."""
    inp = tool_input if isinstance(tool_input, dict) else {}
    path = inp.get("file_path")
    if not isinstance(path, str) or not path:
        return None
    is_new = False
    if tool == "Edit":
        if not isinstance(inp.get("old_string"), str) or not isinstance(inp.get("new_string"), str):
            return None
        pairs = _hunks(inp["old_string"], inp["new_string"])
    elif tool == "MultiEdit":
        pairs = []
        for edit in inp.get("edits") or []:
            if not isinstance(edit, dict):
                continue
            o, n = edit.get("old_string"), edit.get("new_string")
            if not isinstance(o, str) or not isinstance(n, str):
                continue
            if pairs:
                pairs.append(("@", ""))
            pairs.extend(_hunks(o, n))
    elif tool == "Write":
        if not isinstance(inp.get("content"), str):
            return None
        pairs = [("+", t) for t in _lines(inp["content"])]
        is_new = True
    else:
        return None
    added = sum(1 for k, _ in pairs if k == "+")
    removed = sum(1 for k, _ in pairs if k == "-")
    limit = max(0, min(MAX_DIFF_LINES_PER_FILE, budget))
    kept = pairs[:limit]
    return {"path": path, "added": added, "removed": removed, "new": is_new,
            "lines": [{"k": k, "t": _cap_line(t)} for k, t in kept],
            "truncated": len(pairs) > len(kept)}


def _new_turn(now, prompt=""):
    return {"prompt": prompt, "actions": [], "files": [], "final": "",
            "started_at": now, "ended_at": None}


class Engine:
    """Per-host registry of live agent sessions. Not thread-safe: the host
    serialises calls (jc-client's hook thread, the server's event pool)."""

    def __init__(self, clock=time.time):
        self._clock = clock
        self._sessions: dict[str, dict] = {}

    # ── reading ──────────────────────────────────────────────────────────
    def session(self, key):
        s = self._sessions.get(key)
        return copy.deepcopy(s) if s else None

    def sessions(self):
        rows = sorted(self._sessions.values(),
                      key=lambda s: (_URGENCY.get(s["state"], 9), -s["last_event_at"]))
        return [copy.deepcopy(s) for s in rows]

    def snapshot(self):
        return {"v": 1, "sessions": copy.deepcopy(self._sessions)}

    def restore(self, snap):
        if isinstance(snap, dict) and isinstance(snap.get("sessions"), dict):
            self._sessions = copy.deepcopy(snap["sessions"])

    # ── writing ──────────────────────────────────────────────────────────
    def drop(self, key):
        """Forget one session (its host went away). Returns it, or None."""
        s = self._sessions.pop(key, None)
        return copy.deepcopy(s) if s else None

    def settle(self, key, fingerprint_=None):
        """A pending approval/question was answered (or dropped)."""
        s = self._sessions.get(key)
        if not s or not s.get("pending"):
            return []
        if fingerprint_ and s["pending"].get("fingerprint") != fingerprint_:
            return []
        s["pending"] = None
        if s["state"] in ("approval", "question"):
            s["state"] = "working"
        return [self._effect("state", s)]

    def ingest(self, host, agent, payload, kind="event"):
        if not isinstance(payload, dict):
            return []
        event = payload.get("hook_event_name") or ""
        if not event:
            return []
        now = self._clock()
        sid = str(payload.get("session_id") or "")
        cwd = str(payload.get("cwd") or "")
        key = session_key(host, agent, sid, cwd)

        if event == "SessionEnd":
            s = self._sessions.pop(key, None)
            return [self._effect("ended", s)] if s else []

        s = self._sessions.get(key)
        if s is None:
            s = self._new_session(key, host, agent, sid, cwd, now)
            self._sessions[key] = s
        self._absorb_context(s, payload)
        s["last_event_at"] = now
        before = (s["state"], (s.get("pending") or {}).get("fingerprint"))
        effects = []

        if kind == "permission":
            self._on_permission(s, payload, now, effects)
        elif kind == "ask":
            self._on_ask(s, payload, now, effects)
        else:
            handler = getattr(self, "_on_" + event, None)
            if handler is not None:
                handler(s, payload, now, effects)

        after = (s["state"], (s.get("pending") or {}).get("fingerprint"))
        if after != before:
            effects.insert(0, self._effect("state", s))
        return effects

    def sweep(self):
        now = self._clock()
        effects = []
        for key in list(self._sessions):
            s = self._sessions[key]
            silent = now - s["last_event_at"]
            if silent > SESSION_SILENCE:
                self._sessions.pop(key)
                effects.append(self._effect("ended", s))
                continue
            if s["state"] == "finished" and now - (s.get("finished_at") or now) >= FINISHED_HOLD:
                s["state"] = "idle"
                effects.append(self._effect("state", s))
            elif s["state"] in ("working", "thinking") and silent > TURN_SILENCE:
                s["state"] = "idle"
                s["pending"] = None
                effects.append(self._effect("state", s))
        return effects

    # ── internals ────────────────────────────────────────────────────────
    def _new_session(self, key, host, agent, sid, cwd, now):
        return {"key": key, "host": host, "agent": agent, "session_id": sid, "cwd": cwd,
                "project": os.path.basename(cwd.rstrip("/")) or "session",
                "terminal": {}, "model": "", "state": "idle", "step": "", "steps": [],
                "subagents": 0, "compactions": 0, "started_at": now, "last_event_at": now,
                "finished_at": None, "turn": None, "pending": None,
                "transcript_path": ""}

    def _absorb_context(self, s, p):
        term = s["terminal"]
        for src, dst in (("bundle_id", "bundle_id"), ("term_program", "term_program"),
                         ("iterm_session_id", "iterm"), ("term_session_id", "tab"),
                         ("entrypoint", "entrypoint")):
            if p.get(src):
                term[dst] = str(p[src])
        if p.get("transcript_path"):
            s["transcript_path"] = str(p["transcript_path"])
        model = p.get("model")
        if isinstance(model, dict):
            model = model.get("id") or model.get("display_name")
        if isinstance(model, str) and model:
            s["model"] = model
        if p.get("cwd") and not s["cwd"]:
            s["cwd"] = str(p["cwd"])
            s["project"] = os.path.basename(s["cwd"].rstrip("/")) or "session"
        if isinstance(p.get("jc_project"), str) and p["jc_project"].strip():
            s["project"] = p["jc_project"].strip()[:60]

    def _effect(self, kind, s, **extra):
        out = {"kind": kind, "key": s["key"] if s else None,
               "session": copy.deepcopy(s) if s else None}
        out.update(extra)
        return out

    def _step(self, s, text, now):
        if not text:
            return
        s["step"] = text
        s["steps"].append({"t": text, "at": now})
        if len(s["steps"]) > MAX_STEPS:
            del s["steps"][: len(s["steps"]) - MAX_STEPS]

    def _turn(self, s, now):
        if s["turn"] is None or s["turn"].get("ended_at") is not None:
            s["turn"] = _new_turn(now)
        return s["turn"]

    def _busy(self, s):
        """Working, unless a pending approval/question owns the state."""
        if s.get("pending") and s["state"] in ("approval", "question"):
            return
        s["state"] = "working"

    def _on_SessionStart(self, s, p, now, fx):
        if s["state"] not in ("approval", "question"):
            s["state"] = "idle"

    def _on_UserPromptSubmit(self, s, p, now, fx):
        prompt = str(p.get("prompt") or "")[:MAX_PROMPT]
        s["turn"] = _new_turn(now, prompt)
        s["pending"] = None
        s["state"] = "thinking"
        s["finished_at"] = None
        self._step(s, _first_line(prompt, 120), now)

    def _on_PreToolUse(self, s, p, now, fx):
        tool = str(p.get("tool_name") or "Tool")
        if tool == "AskUserQuestion":
            return  # the --ask hook owns question state
        inp = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
        turn = self._turn(s, now)
        if len(turn["actions"]) < MAX_ACTIONS:
            turn["actions"].append({"tool": tool, "summary": _summary(tool, inp), "output": "",
                                    "failed": False, "at": now, "file": None,
                                    "id": str(p.get("tool_use_id") or "")})
        self._busy(s)
        self._step(s, step_label(tool, inp), now)

    def _match_action(self, turn, p, tool, inp):
        tid = str(p.get("tool_use_id") or "")
        acts = turn["actions"]
        if tid:
            for a in reversed(acts):
                if a.get("id") == tid:
                    return a
        summary = _summary(tool, inp)
        for a in reversed(acts):
            if a["tool"] == tool and a["summary"] == summary and not a["output"] and a["file"] is None:
                return a
        if len(acts) < MAX_ACTIONS:
            acts.append({"tool": tool, "summary": summary, "output": "", "failed": False,
                         "at": self._clock(), "file": None, "id": tid})
            return acts[-1]
        return None

    def _settle_matching(self, s, p, tool, inp):
        pend = s.get("pending")
        if not pend or pend.get("kind") != "approval":
            return
        if pend.get("from_notification"):
            s["pending"] = None  # a tool ran, so the prompt we only heard about was answered
            return
        tid = str(p.get("tool_use_id") or "")
        same = (tid and tid == pend.get("tool_use_id")) or (
            pend.get("tool") == tool and pend.get("input_key") == _input_key(inp))
        if same:
            s["pending"] = None

    def _on_PostToolUse(self, s, p, now, fx, failed=False):
        tool = str(p.get("tool_name") or "Tool")
        if tool == "AskUserQuestion":
            if (s.get("pending") or {}).get("kind") == "question":
                s["pending"] = None
            s["state"] = "working"
            return
        inp = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
        self._settle_matching(s, p, tool, inp)
        turn = self._turn(s, now)
        act = self._match_action(turn, p, tool, inp)
        if act is not None:
            act["failed"] = failed
            act["output"] = _output(p)
            if not failed:
                used = sum(len(f["lines"]) for f in turn["files"])
                diff = diff_from_tool(tool, inp, budget=MAX_DIFF_LINES_PER_TURN - used)
                if diff is not None:
                    turn["files"].append(diff)
                    act["file"] = len(turn["files"]) - 1
        self._busy(s)
        if failed:
            self._step(s, "⚠ " + step_label(tool, inp) + " failed", now)

    def _on_PostToolUseFailure(self, s, p, now, fx):
        self._on_PostToolUse(s, p, now, fx, failed=True)

    def _on_permission(self, s, p, now, fx):
        tool = str(p.get("tool_name") or "Tool")
        inp = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
        s["pending"] = {"kind": "approval", "tool": tool, "summary": _summary(tool, inp),
                        "tool_use_id": str(p.get("tool_use_id") or ""), "input_key": _input_key(inp),
                        "fingerprint": fingerprint(s["session_id"], p.get("tool_use_id"), tool, inp),
                        "suggestions": p.get("permission_suggestions") or [], "at": now}
        s["state"] = "approval"
        self._step(s, "Needs approval: " + step_label(tool, inp), now)
        fx.append(self._effect("notify", s, event="approval"))

    def _on_ask(self, s, p, now, fx):
        inp = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
        qs = inp.get("questions") if isinstance(inp.get("questions"), list) else []
        s["pending"] = {"kind": "question", "tool": "AskUserQuestion", "questions": qs,
                        "tool_use_id": str(p.get("tool_use_id") or ""),
                        "fingerprint": fingerprint(s["session_id"], p.get("tool_use_id"),
                                                   "AskUserQuestion", inp), "at": now}
        s["state"] = "question"
        first = qs[0].get("question") if qs and isinstance(qs[0], dict) else "Claude has a question"
        self._step(s, _first_line(first, 120), now)
        fx.append(self._effect("notify", s, event="question"))

    def _on_Notification(self, s, p, now, fx):
        ntype = str(p.get("notification_type") or "")
        message = str(p.get("message") or "")
        lower = message.lower()
        if ntype in ("idle_prompt", "auth_success"):
            return
        if ntype == "permission_prompt" or (not ntype and "permission" in lower):
            if s.get("pending"):
                return
            s["pending"] = {"kind": "approval", "tool": "", "summary": _first_line(message, 200),
                            "fingerprint": "", "tool_use_id": "", "input_key": "", "at": now,
                            "from_notification": True}
            s["state"] = "approval"
            fx.append(self._effect("notify", s, event="notification"))
            return
        if ntype == "elicitation_dialog":
            s["state"] = "question"
            self._step(s, _first_line(message, 120), now)
            fx.append(self._effect("notify", s, event="question"))
            return
        if "rate limit" in lower or "usage limit" in lower:
            s["state"] = "ratelimit"
            self._step(s, _first_line(message, 120), now)
            return
        if not ntype and message.endswith("?"):
            s["state"] = "question"
            self._step(s, _first_line(message, 120), now)
            fx.append(self._effect("notify", s, event="question"))

    def _end_turn(self, s, now, final):
        turn = self._turn(s, now) if s["turn"] is None else s["turn"]
        if final:
            turn["final"] = final[:MAX_FINAL]
        turn["ended_at"] = now
        s["pending"] = None
        s["subagents"] = 0

    def _on_Stop(self, s, p, now, fx):
        final = str(p.get("last_assistant_message") or p.get("message") or "")
        self._end_turn(s, now, final)
        s["state"] = "finished"
        s["finished_at"] = now
        if final:
            self._step(s, _first_line(final, 120), now)
        fx.append(self._effect("notify", s, event="stop"))
        fx.append(self._effect("turn_done", s))

    def _on_StopFailure(self, s, p, now, fx):
        err = str(p.get("error") or p.get("message") or "")
        self._end_turn(s, now, "")
        s["state"] = "error"
        self._step(s, "⚠ " + (_first_line(err, 100) or "turn failed"), now)
        fx.append(self._effect("notify", s, event="error"))
        fx.append(self._effect("turn_done", s))

    def _on_Interrupt(self, s, p, now, fx):
        self._end_turn(s, now, "")
        s["state"] = "idle"

    def _on_SubagentStart(self, s, p, now, fx):
        s["subagents"] += 1
        self._step(s, "+ subagent", now)

    def _on_SubagentStop(self, s, p, now, fx):
        s["subagents"] = max(0, s["subagents"] - 1)
        self._step(s, "• subagent done", now)

    def _on_PreCompact(self, s, p, now, fx):
        self._step(s, "Compacting context…", now)

    def _on_PostCompact(self, s, p, now, fx):
        s["compactions"] += 1
        self._step(s, "Context compacted", now)


def _input_key(inp) -> str:
    try:
        return json.dumps(inp or {}, sort_keys=True, separators=(",", ":"), default=str)
    except Exception:
        return ""
