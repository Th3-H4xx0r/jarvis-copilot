"""The merged Agents tab's conversation layer, wired into the webui.

One row per agent conversation (``agent/agent_conversations.py``), fed by:

* every hook the tracker ingests (``on_hook``, the tracker's observer);
* each machine's roster of live sessions (``agent_roster`` device events, and
  this server's own ``claude agents --json`` on a slow heartbeat);
* the Mac's sleep / wake / reconnect (``device_sleeping``, ``agent_hello``,
  disconnects) through ``agent/agent_presence.py``;
* the Mac's live transcript copy (``agent_transcript_chunk``).

It answers the Agents tab's list (``list_payload``), the chat
(``messages``), and runs hand-offs and messages through
``agent/agent_handoff.py``. Updates go out on the ``agents_list`` bridge topic
(coalesced per subscriber) instead of the phone polling.
"""
from __future__ import annotations

import base64
import logging
import os
import threading
import time
from typing import Callable, Optional

from agent import transcript_mirror as tm
from agent.agent_conversations import Conversations, ckey_for
from agent.agent_delivery import Deliveries
from agent.agent_handoff import HANDOFF_AGENTS, Handoff
from agent.agent_presence import Presence
from agent.agent_roster import apply_roster

log = logging.getLogger(__name__)

TITLE_MAX = 120
_SERVER_ROSTER_EVERY = 60.0
_TICK_EVERY = 5.0
_WAITING = ("approval", "question")
_WORKING = ("working", "thinking")
_REVERSE_EVENTS = ("Stop", "PostToolUse", "UserPromptSubmit", "SubagentStop", "StopFailure")
_TYPABLE_TERMS = ("vscode", "iterm.app")


def short_title(title) -> Optional[str]:
    """One line, whitespace collapsed, at most ``TITLE_MAX`` characters."""
    if not title:
        return None
    line = next((ln for ln in str(title).splitlines() if ln.strip()), "")
    line = " ".join(line.split())
    if not line:
        return None
    return line if len(line) <= TITLE_MAX else line[:TITLE_MAX - 1].rstrip() + "…"


class _NoCodex:
    def available(self):
        return False, "Codex support isn't installed on the server"

    def start(self, *_a, **_k):
        raise RuntimeError("Codex support isn't installed on the server")

    send = stop = start


class AgentsCore:
    def __init__(self, store, *, send_frame: Callable[[str, dict], bool],
                 device_name: Callable[[str], str] = lambda _d: "",
                 alert_phones: Optional[Callable] = None, claude=None, codex=None,
                 project_synced: Optional[Callable[[dict], bool]] = None,
                 publish: Optional[Callable[[str, dict], None]] = None,
                 tracker: Optional[Callable[[], object]] = None,
                 start_sync: Optional[Callable[[str, str, str], None]] = None,
                 clock=time.time) -> None:
        self.store = store
        self._send_frame = send_frame
        self._device_name = device_name
        self._alert = alert_phones
        self._publish_cb = publish
        self._start_sync = start_sync or _start_folder_sync
        self._clock = clock
        if tracker is None:
            from agent.agent_tracking import tracker as _tracker
            tracker = _tracker
        self._tracker = tracker
        if claude is None:
            from agent.server_runtime import ClaudeRuntime
            claude = ClaudeRuntime()
        self.claude = claude
        self.codex = codex if codex is not None else _NoCodex()
        self.conv = Conversations(store, clock=clock)
        self.deliveries = Deliveries(store, clock=clock)
        self.presence = Presence(store, self.conv, clock=clock, push=self._push_paused)
        self.handoff = Handoff(self.conv, self.presence, self.claude, self.codex, self.deliveries,
                               send_frame=send_frame,
                               project_synced=project_synced or self._project_synced, clock=clock)
        self._last_server_roster = 0.0
        self._last_tick = 0.0
        self._msg_cache: dict = {}
        self._lock = threading.RLock()

    # ── hooks (the tracker's observer) ───────────────────────────────────
    def on_hook(self, device_id, agent, payload, session) -> None:
        sid = str((payload or {}).get("session_id") or "")
        if not sid:
            return
        event = payload.get("hook_event_name") or ""
        owner = device_id or "server"
        ckey = ckey_for(agent, sid)
        with self._lock:
            row = self.conv.get(ckey)
            if row and row.get("owner") not in (None, owner) and row.get("status") in ("live", "moving"):
                return  # a stale copy on the machine it left; its hooks refuse it there
            if event == "UserPromptSubmit":
                self.deliveries.on_prompt(ckey, payload.get("prompt") or "")
            if event == "SessionEnd" or session is None:
                if row is not None and row.get("status") == "live":
                    self.conv.mark(ckey, "ended")
                    self._changed()
                return
            fields = {"agent": agent, "session_id": sid, "owner": owner,
                      "state": session.get("state"), "key": session.get("key"),
                      "last_event_at": self._clock()}
            if row is None or row.get("status") != "live":
                fields.update(status="live", ended_at=None)
            cwd = payload.get("cwd") or session.get("cwd") or ""
            if cwd and (row is None or row.get("owner") == owner):
                fields["cwd"] = cwd
            term = session.get("terminal") or {}
            if term:
                fields["run"] = dict((row or {}).get("run") or {}, terminal=term)
            if not (row or {}).get("title") and event == "UserPromptSubmit":
                title = short_title(payload.get("prompt"))
                if title:
                    fields["title"] = title
            new_project = not (row or {}).get("project_id") and cwd
            if new_project:
                fields["project_id"] = self._project_for(cwd, device_id)
            self.conv.upsert(ckey, **fields)
            moved_here = owner == "server" and (row or {}).get("moved_from")
        if new_project and device_id and fields.get("project_id"):
            self._maybe_auto_sync(fields["project_id"], device_id, cwd)
        if moved_here and event in _REVERSE_EVENTS:
            self.handoff.push_reverse(ckey)
        self._changed()

    # ── device events ────────────────────────────────────────────────────
    def on_roster(self, device_id, data) -> None:
        agents = tuple(data.get("agents") or ("claude", "codex"))
        self._apply_roster(device_id, data.get("entries") or [], agents)

    def on_sleeping(self, device_id, data) -> None:
        if data.get("entries"):
            self.on_roster(device_id, data)
        self.presence.on_sleep(device_id, self._name(device_id))
        self._changed()

    def on_hello(self, device_id, _data=None) -> None:
        self.presence.on_connect(device_id, self._name(device_id))
        self._ensure_syncs(device_id)
        self.handoff.on_device_connect(device_id)
        self._send_frame(device_id, {"type": "agent_roster_request"})
        self._changed()

    def on_disconnect(self, device_id) -> None:
        self.presence.on_disconnect(device_id, self._name(device_id))

    def on_chunk(self, device_id, data) -> None:
        ckey = str(data.get("ckey") or "")
        agent, _, sid = ckey.partition("|")
        if not sid:
            return
        with self._lock:
            row = self.conv.get(ckey)
            if row is None:
                cwd = data.get("cwd") or ""
                row = self.conv.upsert(ckey, agent=agent, session_id=sid, owner=device_id,
                                       status="live", cwd=cwd,
                                       project_id=self._project_for(cwd, device_id) if cwd else None)
            if row.get("owner") != device_id:
                self._send_frame(device_id, {"type": "agent_transcript_ack", "ckey": ckey,
                                             "ok": False, "size": 0, "reason": "not_owner"})
                return
            upd = {}
            if not row.get("server_cwd"):
                upd["server_cwd"] = tm.server_cwd_for(row.get("cwd") or data.get("cwd") or sid)
            if data.get("codex_rel") and not row.get("codex_rel"):
                upd["codex_rel"] = data["codex_rel"]
            if upd:
                row = self.conv.upsert(ckey, **upd)
            try:
                raw = base64.b64decode(data.get("data_b64") or "")
            except (ValueError, TypeError):
                raw = b""
            ok, size = tm.append_chunk(row, int(data.get("offset") or 0), raw)
        self._send_frame(device_id, {"type": "agent_transcript_ack", "ckey": ckey, "ok": ok,
                                     "size": size})
        if ok:
            self._changed()

    def on_need(self, device_id, data) -> None:
        row = self.conv.get(str(data.get("ckey") or ""))
        if row and row.get("owner") == "server" and row.get("moved_from") == device_id:
            self.handoff._send_sync(device_id, row, then="merge")

    def on_merge_done(self, device_id, data) -> None:
        self.handoff.on_merge_done(device_id, str(data.get("ckey") or ""), bool(data.get("ok")),
                                   then=data.get("then"),
                                   fork_session_id=data.get("fork_session_id"),
                                   error=str(data.get("error") or ""))
        self._changed()

    def on_continue_mac(self, device_id, data) -> None:
        """The Mac island's "Bring back" on a session that moved to the server."""
        ckey = str(data.get("ckey") or "")
        row = self.conv.get(ckey)
        if row and row.get("moved_from") == device_id:
            self.handoff.continue_on_mac(ckey)
            self._changed()

    def on_delivery(self, _device_id, data) -> None:
        self.handoff.on_device_delivery(str(data.get("delivery_id") or ""),
                                        str(data.get("state") or ""), data.get("reason"))
        self._changed()

    # ── periodic ─────────────────────────────────────────────────────────
    def tick(self) -> None:
        now = self._clock()
        if now - self._last_tick < _TICK_EVERY:
            return
        self._last_tick = now
        self.presence.tick()
        live_here = [r for r in self.conv.by_owner("server") if r.get("status") == "live"
                     and (r.get("run") or {}).get("kind") == "background"]
        if live_here and now - self._last_server_roster >= _SERVER_ROSTER_EVERY:
            self.server_roster()

    def server_roster(self) -> None:
        self._last_server_roster = self._clock()
        try:
            entries = self.claude.roster()
        except Exception:  # noqa: BLE001
            return
        self._apply_roster("server", entries, ("claude",), keep_unlisted=("headless",))

    # ── reading ──────────────────────────────────────────────────────────
    def list_payload(self, now: Optional[float] = None) -> dict:
        now = self._clock() if now is None else now
        tsess = {}
        tr = self._tracker()
        if tr is not None:
            for s in tr.sessions():
                tsess[(s.get("agent"), s.get("session_id"))] = s
        convs = [self._present(r, tsess.get((r.get("agent"), r.get("session_id"))))
                 for r in self.conv.list_visible(now)]
        convs.sort(key=lambda c: (c["status"] != "live", -(c.get("last_event_at") or 0)))
        needs = [c for c in convs if c["status"] == "live" and c["state"] in _WAITING]
        groups: dict = {}
        for c in convs:
            if c in needs:
                continue
            pid = c.get("project_id") or ("cwd:" + (c.get("cwd") or ""))
            g = groups.setdefault(pid, {"id": c.get("project_id"), "name": c.get("project") or "",
                                        "sessions": [], "last": 0.0})
            g["sessions"].append(c)
            g["last"] = max(g["last"], c.get("last_event_at") or 0)
        projects = sorted(groups.values(), key=lambda g: -g["last"])
        for g in projects:
            g.pop("last", None)
        card = self.presence.card()
        if card:
            by = {c["ckey"]: c for c in convs}
            card = dict(card, sessions=[
                {"ckey": k, "title": (by.get(k) or {}).get("title") or "",
                 "project": (by.get(k) or {}).get("project") or "",
                 "was": (by.get(k) or {}).get("state") or "idle",
                 "agent": (by.get(k) or {}).get("agent") or "claude"}
                for k in card["sessions"]])
        return {"card": card, "needs_you": needs, "projects": projects,
                "usage": tr.usage() if tr is not None else None,
                "usage_codex": tr.usage("codex") if tr is not None else None, "ts": now}

    def messages(self, ckey: str, *, after: int = 0, before: Optional[int] = None,
                 limit: Optional[int] = None) -> Optional[dict]:
        row = self.conv.get(ckey)
        if row is None:
            return None
        from agent.coding_transcript_read import slice_messages
        path = tm.path_for(row)
        try:
            st = path.stat()
            sig = (str(path), st.st_size, st.st_mtime_ns)
        except OSError:
            return {"messages": [], "total": 0, "start": 0, "context": None}
        cached = self._msg_cache.get(ckey)
        if cached is None or cached[0] != sig:
            text = path.read_text(encoding="utf-8", errors="replace")
            if row.get("agent") == "codex":
                from agent.codex_transcript_read import parse_codex_rollout_text
                msgs = parse_codex_rollout_text(text)
            else:
                from agent.coding_transcript_read import parse_transcript_text
                msgs = parse_transcript_text(text)
            self._msg_cache[ckey] = cached = (sig, msgs)
        return slice_messages(cached[1], after, before, limit, lite=True)

    # ── actions ──────────────────────────────────────────────────────────
    def stop(self, ckey: str) -> dict:
        row = self.conv.get(ckey)
        if row is None:
            return {"ok": False, "reason": "no_session", "error": "That session is gone."}
        if row.get("owner") == "server":
            self.handoff._stop_server_run(row)
            self.conv.mark(ckey, "ended")
            self._changed()
            return {"ok": True}
        sent = self._send_frame(row["owner"], {
            "type": "agent_stop_local", "ckey": ckey, "agent": row.get("agent"),
            "session_id": row.get("session_id"), "run": row.get("run") or {}})
        if not sent:
            return {"ok": False, "reason": "owner_offline", "error": "The Mac is asleep or offline."}
        return {"ok": True, "pending": True}

    def resume(self, ckey: str, where: str) -> dict:
        row = self.conv.get(ckey)
        if row is None:
            return {"ok": False, "reason": "no_session", "error": "That session is gone."}
        if row.get("status") != "ended":
            return {"ok": False, "reason": "not_ended", "error": "It's still running."}
        if where == "server":
            return self.handoff.continue_on_server(ckey)
        device = row.get("owner") if row.get("owner") != "server" else (
            row.get("moved_from") or row.get("origin_device_id"))
        if not device or self.presence.state(device) != "online":
            return {"ok": False, "reason": "mac_offline", "error": "The Mac is asleep or offline."}
        sent = self._send_frame(device, {
            "type": "agent_resume_local", "ckey": ckey, "agent": row.get("agent"),
            "session_id": row.get("session_id"), "cwd": row.get("origin_cwd") or row.get("cwd"),
            "terminal": (row.get("run") or {}).get("terminal") or {}})
        return {"ok": bool(sent)} if sent else {"ok": False, "reason": "mac_offline",
                                                 "error": "The Mac is asleep or offline."}

    def launch(self, body: dict) -> dict:
        where = str(body.get("where") or "server")
        agent = str(body.get("agent") or "claude")
        cwd = os.path.expanduser(str(body.get("cwd") or "").strip())
        if not cwd:
            return {"ok": False, "reason": "no_cwd", "error": "Pick a folder."}
        if where == "server":
            if not os.path.isabs(cwd):
                return {"ok": False, "reason": "bad_cwd", "error": "Use a full path."}
            os.makedirs(cwd, exist_ok=True)
            try:
                if agent == "codex":
                    self.codex.start(cwd, prompt=body.get("prompt"))
                else:
                    self.claude.ensure_trusted(cwd)
                    self.claude.start(cwd, prompt=body.get("prompt"), model=body.get("model"),
                                      permission_mode=body.get("permission_mode"))
            except Exception as exc:  # noqa: BLE001
                return {"ok": False, "reason": "start_failed", "error": str(exc)}
            self.server_roster()
            self._changed()
            return {"ok": True}
        if self.presence.state(where) != "online":
            return {"ok": False, "reason": "mac_offline", "error": "The Mac is asleep or offline."}
        sent = self._send_frame(where, {
            "type": "agent_launch", "cwd": cwd, "agent": agent, "model": body.get("model"),
            "permission_mode": body.get("permission_mode"), "prompt": body.get("prompt")})
        return {"ok": True} if sent else {"ok": False, "reason": "mac_offline",
                                          "error": "The Mac is asleep or offline."}

    def dismiss(self, device_id: str, ckeys=None) -> None:
        self.presence.dismiss(device_id, ckeys)
        self._changed()

    def terminal_argv(self, ckey: str) -> Optional[tuple]:
        row = self.conv.get(ckey)
        run = (row or {}).get("run") or {}
        if not row or row.get("owner") != "server" or run.get("kind") != "background" \
                or not run.get("bg_id"):
            return None
        return self.claude.attach_argv(run["bg_id"]), row.get("cwd") or os.path.expanduser("~")

    # ── project sync ─────────────────────────────────────────────────────
    def set_project_sync(self, project_id: str, on: bool) -> None:
        """The project's sync switch. Off is remembered: auto-sync never turns
        a project back on that Pranav switched off."""
        from agent.agent_sync_policy import SWITCHED_OFF_SETTING
        off = set(self.store.get_setting(SWITCHED_OFF_SETTING, []) or [])
        off.discard(project_id) if on else off.add(project_id)
        self.store.set_setting(SWITCHED_OFF_SETTING, sorted(off))
        self.store.update_project(project_id, sync_enabled=bool(on))
        if on:
            p = self.store.get_project(project_id) or {}
            if p.get("device_id") and p.get("repo_path"):
                self._sync_folder(p["device_id"], p.get("sync_desktop_path") or p["repo_path"])

    def _maybe_auto_sync(self, project_id: str, device_id: str, cwd: str) -> None:
        from agent.agent_sync_policy import SWITCHED_OFF_SETTING, should_auto_sync
        try:
            p = self.store.get_project(project_id) or {}
            off = set(self.store.get_setting(SWITCHED_OFF_SETTING, []) or [])
            ok, why = should_auto_sync(dict(p, id=project_id), cwd,
                                       home=_device_home(cwd), switched_off=off)
            if not ok:
                return
            self.store.update_project(project_id, sync_enabled=True, sync_desktop_path=cwd)
            self._sync_folder(device_id, cwd)
        except Exception:  # noqa: BLE001
            log.warning("auto sync for %s failed", cwd, exc_info=True)

    def _ensure_syncs(self, device_id: str) -> None:
        """On connect: keep every synced project of this Mac with live sessions syncing."""
        seen = set()
        for r in self.conv.by_owner(device_id):
            pid = r.get("project_id")
            if not pid or pid in seen or r.get("status") not in ("live", "asleep", "offline"):
                continue
            seen.add(pid)
            p = self.store.get_project(pid) or {}
            if p.get("sync_enabled") and (p.get("sync_desktop_path") or p.get("repo_path")):
                self._sync_folder(device_id, p.get("sync_desktop_path") or p["repo_path"])

    def _sync_folder(self, device_id: str, local: str) -> None:
        try:
            self._start_sync(device_id, local, tm.server_cwd_for(local))
        except Exception:  # noqa: BLE001
            log.warning("starting the sync of %s failed", local, exc_info=True)

    # ── internals ────────────────────────────────────────────────────────
    def _apply_roster(self, owner, entries, agents, keep_unlisted=()) -> None:
        with self._lock:
            changed = apply_roster(self.conv, owner, entries, self._clock(), agents=agents,
                                   keep_kinds=keep_unlisted)
            for ckey in changed:
                row = self.conv.get(ckey) or {}
                upd = {}
                if not row.get("project_id") and row.get("cwd"):
                    upd["project_id"] = self._project_for(
                        row["cwd"], None if owner == "server" else owner)
                if row.get("title") and short_title(row["title"]) != row["title"]:
                    upd["title"] = short_title(row["title"])
                if upd:
                    self.conv.upsert(ckey, **upd)
        if changed:
            self._changed()

    def _present(self, row: dict, ts: Optional[dict]) -> dict:
        ts = ts or {}
        owner, status = row.get("owner"), row.get("status") or "live"
        run = row.get("run") or {}
        term = run.get("terminal") or {}
        state = (ts.get("state") or row.get("state") or "idle") if status == "live" else status
        project = self._project_name(row)
        agent = row.get("agent") or "claude"
        typable = owner == "server" or str(term.get("term_program") or "").lower() in _TYPABLE_TERMS \
            or bool(term.get("iterm"))
        return {
            "ckey": row["ckey"], "key": ts.get("key") or row.get("key"), "agent": agent,
            "session_id": row.get("session_id"),
            "title": short_title(row.get("title")) or project or os.path.basename(row.get("cwd") or ""),
            "project_id": row.get("project_id"), "project": project, "cwd": row.get("cwd") or "",
            "owner": owner, "owner_name": "Server" if owner == "server" else self._name(owner),
            "status": status, "state": state, "step": ts.get("step"), "pending": ts.get("pending"),
            "turn_summary": ts.get("turn_summary"), "model": ts.get("model"),
            "last_event_at": row.get("last_event_at") or row.get("updated_at"),
            "terminal_app": term.get("term_program") or "",
            "can_continue_server": agent in HANDOFF_AGENTS and owner != "server"
            and status in ("asleep", "offline", "ended"),
            "can_continue_mac": owner == "server" and bool(row.get("moved_from")) and status == "live",
            "can_resume": status == "ended",
            "can_send": status == "live" and (typable or state in _WORKING),
            "can_terminal": owner == "server" and run.get("kind") == "background" and status == "live",
            "moved_from": row.get("moved_from"),
            "moved_from_name": self._name(row["moved_from"]) if row.get("moved_from") else "",
        }

    def _project_for(self, cwd: str, device_id) -> Optional[str]:
        try:
            return self.store.get_or_create_project_for_path(
                repo_path=cwd, host="desktop" if device_id else "server", device_id=device_id)
        except Exception:  # noqa: BLE001
            log.debug("project for %s failed", cwd, exc_info=True)
            return None

    def _project_name(self, row: dict) -> str:
        pid = row.get("project_id")
        if pid:
            try:
                p = self.store.get_project(pid)
                if p and p.get("name"):
                    return p["name"]
            except Exception:  # noqa: BLE001
                pass
        return os.path.basename((row.get("origin_cwd") or row.get("cwd") or "").rstrip("/"))

    def _project_synced(self, row: dict) -> bool:
        pid = row.get("project_id")
        try:
            p = self.store.get_project(pid) if pid else None
        except Exception:  # noqa: BLE001
            p = None
        return bool(p and p.get("sync_enabled"))

    def _name(self, device_id) -> str:
        try:
            return self._device_name(device_id) or "Mac"
        except Exception:  # noqa: BLE001
            return "Mac"

    def _push_paused(self, p: dict) -> None:
        if self._alert is None:
            return
        n, name = int(p.get("count") or 0), p.get("device_name") or "Your Mac"
        sleep = p.get("kind") == "sleep"
        title = f"{name} went to sleep" if sleep else f"{name} went offline"
        body = f"{n} session{'s' if n != 1 else ''} paused"
        try:
            self._alert(title, body, data={"kind": "mac_paused", "device_id": p.get("device_id")},
                        category="MAC_SLEPT" if sleep else "MAC_OFFLINE")
        except Exception:  # noqa: BLE001
            log.warning("Mac-paused push failed", exc_info=True)

    def _changed(self) -> None:
        if self._publish_cb is None:
            return
        try:
            self._publish_cb("agents_list", self.list_payload())
        except Exception:  # noqa: BLE001
            log.debug("agents_list publish failed", exc_info=True)


def _device_home(cwd: str) -> str:
    """The Mac's home folder for a Mac path (/Users/<name>), for the never-sync-home rule."""
    parts = (cwd or "").split("/")
    return "/".join(parts[:3]) if len(parts) >= 3 and parts[1] in ("Users", "home") else ""


def _start_folder_sync(device_id: str, local: str, server_cwd: str) -> None:
    """Start (or reuse) the Mutagen sync of a Mac folder with its server copy."""
    from api.coding_desktop import start_sync_for_launch
    os.makedirs(server_cwd, exist_ok=True)
    start_sync_for_launch(device_id, session_id="project:" + os.path.basename(local), cwd=server_cwd,
                          sync={"enabled": True, "remote_path": local, "device": device_id})


_CORE: Optional[AgentsCore] = None


def set_core(core: Optional[AgentsCore]) -> None:
    global _CORE
    _CORE = core


def core() -> Optional[AgentsCore]:
    return _CORE


def start(store) -> AgentsCore:
    """Build the process-wide core with the real bridge, push and runtimes."""
    from api import device_bridge
    try:
        from api.push import alert_phones
    except Exception:  # noqa: BLE001
        alert_phones = None
    try:
        from agent.codex_server_runtime import CodexRuntime
        codex = CodexRuntime()
    except Exception:  # noqa: BLE001
        codex = _NoCodex()
    c = AgentsCore(store, send_frame=device_bridge.send_frame,
                   device_name=device_bridge.device_name, alert_phones=alert_phones,
                   codex=codex, publish=device_bridge.publish)
    set_core(c)
    for name, fn in (("agent_roster", c.on_roster), ("device_sleeping", c.on_sleeping),
                     ("agent_transcript_chunk", c.on_chunk), ("agent_transcript_need", c.on_need),
                     ("agent_merge_done", c.on_merge_done), ("agent_delivery", c.on_delivery),
                     ("agent_continue_mac", c.on_continue_mac)):
        device_bridge.on_device_event(name, fn)
    device_bridge.on_device_disconnect(c.on_disconnect)
    try:
        c.handoff.recover()
    except Exception:  # noqa: BLE001
        log.warning("hand-off recovery failed", exc_info=True)
    return c
