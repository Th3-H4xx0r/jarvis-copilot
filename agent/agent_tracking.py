"""Server-side tracking of coding-agent sessions from their hooks.

Every host's hook events end up here: a Mac's arrive as ``agent_hook`` device
events (jc-client forwards what ``jc-hook`` sends it), the server's own come
from its local hook socket. They feed the shared engine
(``agent/agent_engine_shim.py`` — the same file jc-client runs), and this
module turns the engine's effects into the rest of Jarvis:

* the Agents conversation layer (``webui/api/agents_core.py``) hears about
  every hook through the observer;
* the ``agents`` bridge topic carries the compact session list to the phone
  and the Mac (the bridge coalesces per subscriber);
* finished / needs-you / error go to the existing notification matrix;
* finished turns are recorded for the weekly recap.

Hooks are the only source of session state.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Callable, Optional

from agent import agent_engine_shim as engine_mod

log = logging.getLogger(__name__)

_PERSIST_EVERY = 2.0            # write a busy session at most this often
_ACTIVITY = {"working": "working", "thinking": "working",
             "approval": "waiting", "question": "waiting"}
#: "Claude finished" rings the phone only for a turn that ran at least this long.
FINISHED_MIN_SECONDS = 60


def _turn_seconds(session: dict) -> float:
    turn = session.get("turn") or {}
    start = turn.get("started_at")
    end = turn.get("ended_at") or session.get("last_event_at")
    try:
        return float(end) - float(start)
    except (TypeError, ValueError):
        return 0.0


_NOTIFY_EVENT = {"stop": "stop", "approval": "notification", "notification": "notification",
                 "question": "notification", "error": "error"}
_COMMAND_TOOLS = ("Bash", "mcp__ide__executeCode")

def _activity(state: str) -> str:
    return _ACTIVITY.get(state, "idle")


class AgentTracker:
    def __init__(self, store, publish: Optional[Callable[[str, dict], None]] = None,
                 notify: Optional[Callable[[str, Optional[dict], str], None]] = None,
                 live_push: Optional[Callable[[], None]] = None,
                 phone_approvals: Optional[Callable[[], bool]] = None,
                 observer: Optional[Callable[[Optional[str], str, dict, Optional[dict]], None]] = None,
                 clock=time.time) -> None:
        self.store = store
        self._publish_cb = publish
        self._notify_cb = notify
        self._live_push_cb = live_push
        # While on, a relayed request reaches the phone as its own actionable
        # push, so the matrix "needs you" banner would be a second buzz.
        self._phone_approvals = phone_approvals or (lambda: False)
        # The Agents conversation layer (webui/api/agents_core.py): told about every
        # hook with the session as it stands after it (None once it ended).
        self._observer = observer
        self._clock = clock
        self._lock = threading.RLock()
        self.engine = engine_mod.Engine(clock=clock)
        self._activity: dict[str, str] = {}    # engine key -> working | waiting | idle
        self._devices: dict[str, Optional[str]] = {}  # engine key -> device_id
        self._last_hook: dict[str, float] = {}
        self._persisted: dict[str, float] = {}
        self._usage: dict = {}  # agent -> plan usage (claude from the status line, codex from app-server)
        self._restore()

    # ── reading ──────────────────────────────────────────────────────────
    def sessions(self, device_id: Optional[str] = None) -> list[dict]:
        with self._lock:
            out = []
            for s in self.engine.sessions():
                if device_id is not None and self._devices.get(s["key"]) != device_id:
                    continue
                out.append(self._compact(s))
            return out

    def session(self, key: str) -> Optional[dict]:
        with self._lock:
            s = self.engine.session(key)
            if s is None:
                return None
            s["device_id"] = self._devices.get(key)
            return s

    def usage(self, agent: str = "claude") -> Optional[dict]:
        with self._lock:
            u = self._usage.get(agent)
            return dict(u) if u else None

    # ── writing ──────────────────────────────────────────────────────────
    def ingest(self, device_id: Optional[str], kind: str, agent: str, payload: dict) -> list:
        if not isinstance(payload, dict):
            return []
        if kind == "statusline":
            self._take_usage(device_id, payload, agent)
            return []
        host = device_id or "server"
        now = self._clock()
        with self._lock:
            effects = self.engine.ingest(host, agent, payload,
                                         kind=kind if kind in ("permission", "ask") else "event")
            key = engine_mod.session_key(host, agent, str(payload.get("session_id") or ""),
                                         str(payload.get("cwd") or ""))
            session = self.engine.session(key)
            if session is not None:
                self._last_hook[key] = now
                self._devices[key] = device_id
            changed = self._apply(effects, device_id)
            if session is not None:
                self._persist(key, force=bool(effects))
            snapshot = dict(session) if session is not None else None
        if self._observer is not None:
            try:
                self._observer(device_id, agent, payload, snapshot)
            except Exception:  # noqa: BLE001
                log.warning("agent conversation observer failed", exc_info=True)
        if changed:
            self._live_push()
        self._publish()
        return effects

    def settle(self, key: str, fingerprint: Optional[str] = None) -> None:
        with self._lock:
            effects = self.engine.settle(key, fingerprint)
            changed = self._apply(effects, self._devices.get(key))
            self._persist(key, force=True)
        if changed:
            self._live_push()
        if effects:
            self._publish()

    def record_decision(self, key: str, kind: str, decision: str) -> None:
        """An approval or answer someone gave (for the weekly recap)."""
        with self._lock:
            session = self.engine.session(key) or {}
        parts = key.split("|")
        try:
            self.store.insert_agent_decision(
                key=key, agent=session.get("agent") or (parts[1] if len(parts) > 1 else None),
                project=session.get("project"), kind=kind, decision=decision, at=self._clock())
        except Exception:  # noqa: BLE001
            log.debug("agent decision record failed", exc_info=True)

    def sweep(self) -> list:
        with self._lock:
            effects = self.engine.sweep()
            changed = self._apply(effects, None)
            for e in effects:
                if e.get("key") and e["kind"] != "ended":
                    self._persist(e["key"], force=True)
        if changed:
            self._live_push()
        if effects:
            self._publish()
        return effects

    def on_device_gone(self, device_id: str) -> None:
        """The device stayed offline past the grace window: its sessions are gone."""
        if not device_id:
            return
        with self._lock:
            keys = [k for k, d in self._devices.items() if d == device_id]
            for key in keys:
                self.engine.drop(key)
                self._forget(key)
        if keys:
            self._live_push()
            self._publish()

    # ── internals ────────────────────────────────────────────────────────
    def _restore(self) -> None:
        try:
            rows = self.store.list_agent_sessions()
        except Exception:  # noqa: BLE001
            log.debug("agent session restore failed", exc_info=True)
            return
        snap = {}
        for r in rows:
            if not isinstance(r.get("data"), dict):
                continue
            snap[r["key"]] = r["data"]
            self._devices[r["key"]] = r.get("device_id")
            self._last_hook[r["key"]] = float(r.get("last_hook_at") or 0)
        self.engine.restore({"v": 1, "sessions": snap})
        for key, data in snap.items():
            self._activity[key] = _activity(str(data.get("state") or ""))

    def _forget(self, key: str) -> None:
        self._activity.pop(key, None)
        self._devices.pop(key, None)
        self._last_hook.pop(key, None)
        self._persisted.pop(key, None)
        try:
            self.store.delete_agent_session(key)
        except Exception:  # noqa: BLE001
            pass

    def _persist(self, key: str, force: bool = False) -> None:
        session = self.engine.session(key)
        if session is None:
            return
        now = self._clock()
        if not force and now - self._persisted.get(key, 0) < _PERSIST_EVERY:
            return
        self._persisted[key] = now
        try:
            self.store.upsert_agent_session(
                key=key, host=session["host"], device_id=self._devices.get(key),
                agent=session["agent"], session_id=session["session_id"], cwd=session["cwd"],
                state=session["state"], data=session,
                last_hook_at=self._last_hook.get(key, now))
        except Exception:  # noqa: BLE001
            log.debug("agent session persist failed", exc_info=True)

    def _apply(self, effects: list, device_id) -> bool:
        changed = False
        for e in effects:
            kind, key, session = e.get("kind"), e.get("key"), e.get("session")
            if not key or session is None:
                continue
            if kind == "state":
                act = _activity(session["state"])
                if self._activity.get(key) != act:
                    self._activity[key] = act
                    changed = True
            elif kind == "notify":
                if session.get("agent") == "jarvis":
                    continue  # Jarvis notifies about its own replies already
                if e.get("event") == "stop" and _turn_seconds(session) < FINISHED_MIN_SECONDS:
                    continue  # a quick reply; you're probably right there
                pend = session.get("pending") or {}
                if e.get("event") in ("approval", "question") and pend.get("fingerprint") \
                        and not pend.get("from_notification") and self._phone_approvals():
                    continue
                event = _NOTIFY_EVENT.get(e.get("event") or "")
                if event and self._notify_cb is not None:
                    try:
                        self._notify_cb(event, self._notice(key, session),
                                        session.get("cwd") or "")
                    except Exception:  # noqa: BLE001
                        log.debug("agent notify failed", exc_info=True)
            elif kind == "turn_done":
                self._record_turn(session)
            elif kind == "ended":
                self._forget(key)
                changed = True
        return changed

    def _notice(self, key: str, session: dict) -> dict:
        """What a notification names: the session, its project and its title (from
        the Agents conversation record when there is one)."""
        agent, sid = session.get("agent") or "claude", session.get("session_id") or ""
        conv = None
        try:
            conv = self.store.get_conversation(f"{agent}|{sid}") if sid else None
        except Exception:  # noqa: BLE001
            conv = None
        return {"id": key, "key": key, "agent": agent, "session_id": sid,
                "cwd": session.get("cwd") or "", "project": session.get("project") or "",
                "project_id": (conv or {}).get("project_id"), "title": (conv or {}).get("title")}

    def _record_turn(self, session) -> None:
        turn = session.get("turn") or {}
        actions = turn.get("actions") or []
        files = turn.get("files") or []
        try:
            self.store.insert_agent_turn(
                key=session["key"], host=session.get("host"), agent=session.get("agent"),
                project=session.get("project"), cwd=session.get("cwd"),
                started_at=turn.get("started_at") or self._clock(),
                ended_at=turn.get("ended_at") or self._clock(),
                actions=len(actions), files=len({f.get("path") for f in files}),
                added=sum(int(f.get("added") or 0) for f in files),
                removed=sum(int(f.get("removed") or 0) for f in files),
                commands=sum(1 for a in actions if a.get("tool") in _COMMAND_TOOLS),
                failed=sum(1 for a in actions if a.get("failed")),
                outcome=session.get("state"))
        except Exception:  # noqa: BLE001
            log.debug("agent turn record failed", exc_info=True)

    def _take_usage(self, device_id, payload, agent: str = "claude") -> None:
        limits = payload.get("rate_limits")
        if not isinstance(limits, dict) or not limits:
            return
        agent = agent or "claude"
        with self._lock:
            prev = self._usage.get(agent) or {}
            # Several Macs and sessions report out of order: never step back.
            current = {k: prev[k] for k in ("five_hour", "seven_day") if prev.get(k)}
            merged = engine_mod.merge_rate_limits(current, limits)
            if merged is None and prev:
                return
            merged = merged or current
            u = {"five_hour": merged.get("five_hour"), "seven_day": merged.get("seven_day"),
                 "source": device_id or "server", "updated_at": self._clock()}
            plan = payload.get("plan") if isinstance(payload.get("plan"), str) else prev.get("plan")
            if plan:
                u["plan"] = plan
            self._usage[agent] = u

    def _compact(self, s: dict) -> dict:
        turn = s.get("turn") or {}
        files = turn.get("files") or []
        pend = s.get("pending")
        return {
            "key": s["key"], "host": s["host"], "agent": s["agent"],
            "session_id": s["session_id"], "cwd": s["cwd"], "project": s["project"],
            "integration": s.get("integration"),
            "state": s["state"], "step": s["step"], "steps": s["steps"][-6:],
            "subagents": s["subagents"], "compactions": s["compactions"], "model": s["model"],
            "terminal": s["terminal"], "started_at": s["started_at"],
            "last_event_at": s["last_event_at"],
            "device_id": self._devices.get(s["key"]),
            "pending": None if not pend else {
                k: pend.get(k) for k in ("kind", "tool", "summary", "fingerprint", "questions")
                if pend.get(k) is not None},
            "turn_summary": {
                "prompt": (turn.get("prompt") or "")[:300],
                "actions": len(turn.get("actions") or []), "files": len(files),
                "added": sum(int(f.get("added") or 0) for f in files),
                "removed": sum(int(f.get("removed") or 0) for f in files),
                "final": (turn.get("final") or "")[:400],
                "started_at": turn.get("started_at"), "ended_at": turn.get("ended_at"),
            } if turn else None,
        }

    def _publish(self) -> None:
        if self._publish_cb is None:
            return
        try:
            self._publish_cb("agents", {"sessions": self.sessions(), "ts": self._clock()})
        except Exception:  # noqa: BLE001
            log.debug("agents topic publish failed", exc_info=True)

    def _live_push(self) -> None:
        if self._live_push_cb is None:
            return
        try:
            self._live_push_cb()
        except Exception:  # noqa: BLE001
            log.debug("agent live push failed", exc_info=True)


_TRACKER: Optional[AgentTracker] = None
_TRACKER_LOCK = threading.Lock()


def set_tracker(tr: Optional[AgentTracker]) -> None:
    global _TRACKER
    with _TRACKER_LOCK:
        _TRACKER = tr


def tracker() -> Optional[AgentTracker]:
    return _TRACKER


def lead_summary():
    """The most urgent live agent session, for the coding Live Activity, or None."""
    tr = _TRACKER
    if tr is None:
        return None
    for s in tr.sessions():
        if s["state"] == "idle":
            continue
        pend = s.get("pending") or {}
        turn = s.get("turn_summary") or {}
        return {"agent": s["agent"], "project": s["project"], "state": s["state"],
                "step": s["step"], "fingerprint": pend.get("fingerprint") or "",
                "kind": "question" if pend.get("kind") == "question" else
                        ("approval" if pend.get("kind") == "approval" else ""),
                "since": turn.get("started_at") or s["started_at"], "key": s["key"]}
    return None
