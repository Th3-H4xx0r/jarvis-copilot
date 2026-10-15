"""Server-side tracking of coding-agent sessions from their hooks.

Every host's hook events end up here: a Mac's arrive as ``agent_hook`` device
events (jc-client forwards what ``jc-hook`` sends it), the server's own come
from its local hook socket. They feed the shared engine
(``agent/agent_engine_shim.py`` — the same file jc-client runs), and this
module turns the engine's effects into the rest of Jarvis:

* the ``coding_sessions`` row for the session (joined by tmux name, then by
  Claude session id, else created) gets ``activity_state`` + ``status``, so a
  ``claude`` started in Terminal / iTerm / VS Code is a live row, not history;
* the ``agents`` bridge topic carries the compact session list to the phone
  and the Mac (the bridge coalesces per subscriber);
* finished / needs-you / error go to the existing notification matrix;
* finished turns are recorded for the weekly recap.

Hooks are the source of truth: ``hook_fresh`` tells the pane scraper and the
discovery ingest to leave a row alone while its hooks are talking.
"""
from __future__ import annotations

import logging
import os
import threading
import time
from typing import Callable, Optional

from agent import agent_engine_shim as engine_mod

log = logging.getLogger(__name__)

HOOK_FRESH = 30 * 60.0          # a hook this recent owns the row's state
_PERSIST_EVERY = 2.0            # write a busy session at most this often
_LIVE_STATUSES = ("running", "starting", "idle")
_ACTIVITY = {"working": "working", "thinking": "working",
             "approval": "waiting", "question": "waiting"}
_NOTIFY_EVENT = {"stop": "stop", "approval": "notification", "notification": "notification",
                 "question": "notification", "error": "error"}
_COMMAND_TOOLS = ("Bash", "mcp__ide__executeCode")

try:
    from agent.coding_sync_safety import is_dangerous_path as _dangerous_cwd
except Exception:  # noqa: BLE001
    def _dangerous_cwd(_path):
        return False


def _activity(state: str) -> str:
    return _ACTIVITY.get(state, "idle")


class AgentTracker:
    def __init__(self, store, publish: Optional[Callable[[str, dict], None]] = None,
                 notify: Optional[Callable[[str, Optional[dict], str], None]] = None,
                 live_push: Optional[Callable[[], None]] = None,
                 is_dismissed: Optional[Callable[[str, str], bool]] = None,
                 clock=time.time) -> None:
        self.store = store
        self._publish_cb = publish
        self._notify_cb = notify
        self._live_push_cb = live_push
        self._is_dismissed = is_dismissed or (lambda _d, _k: False)
        self._clock = clock
        self._lock = threading.RLock()
        self.engine = engine_mod.Engine(clock=clock)
        self._rows: dict[str, str] = {}        # engine key -> coding_sessions.id
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
            s["coding_session_id"] = self._rows.get(key)
            s["device_id"] = self._devices.get(key)
            return s

    def hook_fresh(self, coding_session_id: str) -> bool:
        if not coding_session_id:
            return False
        now = self._clock()
        with self._lock:
            for key, rid in self._rows.items():
                if rid == coding_session_id and now - self._last_hook.get(key, 0) < HOOK_FRESH \
                        and self.engine.session(key) is not None:
                    return True
        return False

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
                self._join(key, device_id, payload, session)
            changed = self._apply(effects, device_id)
            if session is not None:
                self._persist(key, force=bool(effects))
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
                session = self.engine.drop(key)
                if session is not None:
                    self._end_row(key, session)
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
            if r.get("coding_session_id"):
                self._rows[r["key"]] = r["coding_session_id"]
            self._devices[r["key"]] = r.get("device_id")
            self._last_hook[r["key"]] = float(r.get("last_hook_at") or 0)
        self.engine.restore({"v": 1, "sessions": snap})

    def _forget(self, key: str) -> None:
        self._rows.pop(key, None)
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
                coding_session_id=self._rows.get(key), state=session["state"], data=session,
                last_hook_at=self._last_hook.get(key, now))
        except Exception:  # noqa: BLE001
            log.debug("agent session persist failed", exc_info=True)

    def _candidate_rows(self, device_id):
        try:
            if device_id:
                return self.store.list_sessions(device_id=device_id)
            return [r for r in self.store.list_sessions()
                    if (r.get("host") or "server") == "server"]
        except Exception:  # noqa: BLE001
            return []

    def _join(self, key, device_id, payload, session) -> None:
        """Find (or create) the coding_sessions row this session belongs to."""
        known = self._rows.get(key)
        event = payload.get("hook_event_name")
        if known and event not in ("SessionStart", "UserPromptSubmit"):
            return
        csid = session.get("session_id") or ""
        tmux = (session.get("terminal") or {}).get("tmux") or ""
        rows = self._candidate_rows(device_id)
        row = None
        if tmux:
            row = next((r for r in rows if r.get("tmux_name") == tmux
                        and (r.get("status") in _LIVE_STATUSES)), None)
        if row is None and csid:
            hits = [r for r in rows if (r.get("claude_session_id") or "") == csid]
            hits.sort(key=lambda r: r.get("source") == "discovered-transcript")
            row = hits[0] if hits else None
        if row is None and known:
            row = next((r for r in rows if r.get("id") == known), None)
        if row is None:
            row = self._create_row(device_id, session)
            if row is None:
                return
        fields = {}
        src = row.get("source") or ""
        if csid and (row.get("claude_session_id") or "") != csid and (
                src == "discovered-tmux" or not row.get("claude_session_id")):
            fields["claude_session_id"] = csid
        if src in ("discovered-transcript", "hook") and row.get("status") != "running":
            fields["status"] = "running"
        if fields:
            try:
                self.store.update_session(row["id"], **fields)
            except Exception:  # noqa: BLE001
                log.debug("agent row update failed", exc_info=True)
        self._rows[key] = row["id"]

    def _create_row(self, device_id, session) -> Optional[dict]:
        cwd = session.get("cwd") or ""
        csid = session.get("session_id") or ""
        if not cwd or not csid or _dangerous_cwd(cwd):
            return None
        if device_id and self._is_dismissed(device_id, csid):
            return None
        host = "desktop" if device_id else "server"
        try:
            for p in self.store.list_projects():
                if p.get("ignored") and p.get("repo_path") == cwd and \
                        (p.get("device_id") or None) == (device_id or None):
                    return None
            pid = self.store.get_or_create_project_for_path(
                repo_path=cwd, host=host, device_id=device_id)
            rid = self.store.create_session(
                project_id=pid, host=host, cwd=cwd, branch=None, tmux_name=None,
                source="discovered-transcript" if device_id else "hook",
                title=session.get("project") or os.path.basename(cwd), device_id=device_id,
                external=True, status="running", claude_session_id=csid)
            return self.store.get_session(rid)
        except Exception:  # noqa: BLE001
            log.warning("agent row create failed", exc_info=True)
            return None

    def _row(self, key) -> Optional[dict]:
        rid = self._rows.get(key)
        if not rid:
            return None
        try:
            return self.store.get_session(rid)
        except Exception:  # noqa: BLE001
            return None

    def _apply(self, effects: list, device_id) -> bool:
        changed = False
        for e in effects:
            kind, key, session = e.get("kind"), e.get("key"), e.get("session")
            if not key or session is None:
                continue
            if kind == "state":
                row = self._row(key)
                if row is not None:
                    act = _activity(session["state"])
                    fields = {"last_activity_at": self._clock()}
                    if (row.get("activity_state") or None) != act:
                        fields["activity_state"] = act
                        changed = True
                    try:
                        self.store.update_session(row["id"], **fields)
                    except Exception:  # noqa: BLE001
                        pass
            elif kind == "notify":
                if session.get("agent") == "jarvis":
                    continue  # Jarvis notifies about its own replies already
                event = _NOTIFY_EVENT.get(e.get("event") or "")
                if event and self._notify_cb is not None:
                    try:
                        self._notify_cb(event, self._row(key), session.get("cwd") or "")
                    except Exception:  # noqa: BLE001
                        log.debug("agent notify failed", exc_info=True)
            elif kind == "turn_done":
                self._record_turn(session)
            elif kind == "ended":
                self._end_row(key, session)
                self._forget(key)
                changed = True
        return changed

    def _end_row(self, key, session) -> None:
        row = self._row(key)
        if row is None:
            return
        fields = {"activity_state": None}
        if (row.get("source") or "") in ("discovered-transcript", "hook"):
            fields["status"] = "idle"
        try:
            self.store.update_session(row["id"], **fields)
        except Exception:  # noqa: BLE001
            pass

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
        u = {"five_hour": limits.get("five_hour"), "seven_day": limits.get("seven_day"),
             "source": device_id or "server", "updated_at": self._clock()}
        if isinstance(payload.get("plan"), str):
            u["plan"] = payload["plan"]
        with self._lock:
            self._usage[agent or "claude"] = u

    def _compact(self, s: dict) -> dict:
        turn = s.get("turn") or {}
        files = turn.get("files") or []
        pend = s.get("pending")
        return {
            "key": s["key"], "host": s["host"], "agent": s["agent"],
            "session_id": s["session_id"], "cwd": s["cwd"], "project": s["project"],
            "state": s["state"], "step": s["step"], "steps": s["steps"][-6:],
            "subagents": s["subagents"], "compactions": s["compactions"], "model": s["model"],
            "terminal": s["terminal"], "started_at": s["started_at"],
            "last_event_at": s["last_event_at"], "coding_session_id": self._rows.get(s["key"]),
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


def hook_fresh(coding_session_id: str) -> bool:
    """True while hooks own this coding_sessions row's state (scrapers keep off)."""
    tr = _TRACKER
    return bool(tr and tr.hook_fresh(coding_session_id))
