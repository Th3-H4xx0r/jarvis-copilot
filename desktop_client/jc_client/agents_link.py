"""jc-client's side of the merged Agents tab.

Ties the pieces together and to the server:

* every hook (``on_hook``) updates the roster (terminal context, Codex process
  ids) and pokes the live transcript copy;
* a prompt or tool call in a session asks the moved-gate first (``gate_answer``);
* sleep flushes the transcripts and tells the server what was running; wake
  holds the gate until the server says what moved;
* frames from the server: roster requests, transcript acks, what moved, merges,
  reopening a session here, launching / stopping one, and phone messages with
  an honest delivery report.

Server frames run on a small worker pool, never on the WebSocket read loop.
"""
from __future__ import annotations

import logging
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Optional

from jc_client.agent_roster import RosterAgent
from jc_client.local_runtime import LocalRuntime
from jc_client.moved_gate import MovedGate
from jc_client.power_watch import PowerWatch
from jc_client.transcript_shipper import TranscriptShipper

log = logging.getLogger(__name__)

FRAME_TYPES = frozenset({"agent_roster_request", "agent_transcript_ack", "agent_moved",
                         "agent_transcript_sync", "agent_transcript_tail", "agent_resume_local",
                         "agent_launch", "agent_stop_local"})
# Handled one at a time, in arrival order (see AgentsLink.handle_frame).
_ORDERED = frozenset({"agent_transcript_ack", "agent_transcript_sync", "agent_transcript_tail",
                      "agent_moved", "agent_resume_local"})
_SHIPPED_AGENTS = ("claude", "codex")
_STOP_QUEUE_AGENTS = ("claude", "claude-desktop")
_WORKING = ("working", "thinking")
_TERM_KEYS = (("term_program", "term_program"), ("iterm_session_id", "iterm"),
              ("term_session_id", "term_session"), ("bundle_id", "bundle_id"))


class AgentsLink:
    def __init__(self, forward_up: Callable[[dict], None], *, vscode=None,
                 queue: Optional[Callable[[], object]] = None,
                 instructions_on: Callable[[], bool] = lambda: True,
                 runtime: Optional[LocalRuntime] = None, inline: bool = False,
                 power_thread: bool = True,
                 ui_broadcast: Optional[Callable[[dict], None]] = None) -> None:
        self._up = forward_up
        self.vscode = vscode
        self._queue = queue
        self._instructions_on = instructions_on
        self.roster = RosterAgent(forward_up)
        self.shipper = TranscriptShipper(forward_up)
        self.gate = MovedGate()
        self.runtime = runtime or LocalRuntime(vscode=vscode)
        self.power = PowerWatch(self.on_sleep, self.on_wake)
        if power_thread:
            self.power.start()
        self._pids: dict = {}
        self._ui = ui_broadcast
        self._moved: dict = {}   # ckey -> what the Mac app shows ("On server", Bring back)
        # Two lanes: transcript frames (acks, sync parts, tails, what moved) must be
        # handled in the order they came, so they share one worker; slow ones
        # (typing, launching, reopening) run beside them and never hold them up.
        self._pool = None if inline else ThreadPoolExecutor(max_workers=2,
                                                             thread_name_prefix="jc-agents")
        self._serial = None if inline else ThreadPoolExecutor(max_workers=1,
                                                               thread_name_prefix="jc-agents-seq")

    def close(self) -> None:
        self.power.close()
        self.roster.close()
        for pool in (self._pool, self._serial):
            if pool is not None:
                pool.shutdown(wait=False, cancel_futures=True)

    # ── hooks ────────────────────────────────────────────────────────────
    def on_hook(self, kind: str, agent: str, payload: dict) -> None:
        sid = str(payload.get("session_id") or "")
        if not sid or kind == "statusline":
            return
        event = payload.get("hook_event_name") or ""
        ckey = f"{agent}|{sid}"
        terminal = {dst: payload[src] for src, dst in _TERM_KEYS if payload.get(src)}
        pid = payload.get("agent_pid")
        if pid:
            self._pids[ckey] = pid
        self.roster.note_hook(agent, sid, pid=pid, cwd=str(payload.get("cwd") or ""),
                              terminal=terminal, ended=event == "SessionEnd")
        if event in ("SessionStart", "SessionEnd"):
            self.roster.trigger(event)
        path = payload.get("transcript_path")
        if agent in _SHIPPED_AGENTS and path:
            self.shipper.watch(ckey, agent, str(path), cwd=str(payload.get("cwd") or ""),
                               codex_rel=self._codex_rel(str(path)) if agent == "codex" else None)
        else:
            self.shipper.poke(ckey)

    def gate_answer(self, agent: str, payload: dict) -> dict:
        decision, reason = self.gate.check(agent, str(payload.get("session_id") or ""))
        return {"decision": "block", "reason": reason} if decision == "block" else {}

    # ── connection and power ─────────────────────────────────────────────
    def on_connected(self) -> None:
        self.shipper.set_online(True)
        self.roster.trigger("connect")

    def on_disconnected(self) -> None:
        self.shipper.set_online(False)

    def on_sleep(self) -> None:
        self.shipper.flush_all(3.0)
        try:
            entries = self.roster.scan_now(send=False)
        except Exception:  # noqa: BLE001
            entries = []
        self._event("device_sleeping", {"entries": entries,
                                        "agents": list(getattr(self.roster, "last_agents",
                                                               ["claude", "codex"]))})

    def on_wake(self) -> None:
        self.gate.hold_until_confirmed(10.0)
        # A short sleep can keep the socket, so no reconnect (and no hello) would
        # follow: say it, so the server marks this Mac awake and answers with
        # what moved (which releases the gate).
        self._event("agent_hello", {"v": 1, "wake": True})
        self.roster.trigger("wake")

    # ── frames from the server ───────────────────────────────────────────
    def handle_frame(self, frame: dict) -> None:
        if self._pool is None:
            self._dispatch(frame)
            return
        lane = self._serial if frame.get("type") in _ORDERED else self._pool
        lane.submit(self._safe_dispatch, frame)

    def _safe_dispatch(self, frame: dict) -> None:
        try:
            self._dispatch(frame)
        except Exception:  # noqa: BLE001
            log.warning("agents frame %s failed", frame.get("type"), exc_info=True)

    def _dispatch(self, frame: dict) -> None:
        t = frame.get("type")
        ckey = str(frame.get("ckey") or "")
        if t == "agent_roster_request":
            self.roster.trigger("server")
        elif t == "agent_transcript_ack":
            self.shipper.on_ack(ckey, bool(frame.get("ok")), int(frame.get("size") or 0),
                                reason=frame.get("reason"))
        elif t == "agent_moved":
            self.gate.set_moved(frame.get("ckeys") or [])
            self._moved = {d.get("ckey"): {k: d.get(k) for k in ("ckey", "agent", "title", "project")}
                           for d in frame.get("sessions") or [] if d.get("ckey")}
            self._push_moved()
        elif t == "agent_transcript_sync":
            self.shipper.apply_sync(frame)
        elif t == "agent_transcript_tail":
            self.shipper.apply_tail(frame)
        elif t == "agent_resume_local":
            self.gate.discard(ckey)
            if self._moved.pop(ckey, None) is not None:
                self._push_moved()
            agent, sid = str(frame.get("agent") or "claude"), str(frame.get("session_id") or "")
            stale = self._pids.get(ckey) or self._stale_pid(agent, sid)
            via = self.runtime.resume_in_terminal(
                agent, sid, str(frame.get("cwd") or os.path.expanduser("~")),
                frame.get("terminal") or {}, stale_pid=stale)
            log.info("reopened %s on this Mac via %s", ckey, via)
            self.roster.trigger("resume")
        elif t == "agent_launch":
            self.runtime.launch_bg(str(frame.get("cwd") or ""), agent=str(frame.get("agent") or "claude"),
                                   model=frame.get("model"),
                                   permission_mode=frame.get("permission_mode"),
                                   prompt=frame.get("prompt"))
            self.roster.trigger("launch")
        elif t == "agent_stop_local":
            run = frame.get("run") or {}
            if run.get("kind") == "background" and run.get("bg_id"):
                self.runtime.stop_bg(run["bg_id"])
            elif run.get("pid"):
                self.runtime.stop_pid(run["pid"])
            self.roster.trigger("stop")
        elif t == "agent_instruction":
            self._deliver(frame)

    def _deliver(self, frame: dict) -> None:
        did = frame.get("delivery_id")
        agent, sid = str(frame.get("agent") or "claude"), str(frame.get("session_id") or "")
        text = str(frame.get("text") or "")
        if not self._instructions_on():
            return self._report(did, "failed", "Turn on \"Instructions from the phone\" in "
                                               "Code Master settings first")
        run = frame.get("run") or {}
        terminal = frame.get("terminal") or run.get("terminal") or {}
        if frame.get("state") in ("approval", "question"):
            # Its terminal shows a menu: typing would answer it. Only ever after the turn.
            if agent in _STOP_QUEUE_AGENTS and self._queue:
                self._queue().add(sid, text)
                return self._report(did, "queued", None)
            return self._report(did, "failed", "It's waiting on an approval or a question: "
                                               "answer that first.")
        if frame.get("state") in _WORKING and agent in _STOP_QUEUE_AGENTS and self._queue:
            self._queue().add(sid, text)
            return self._report(did, "queued", None)
        from jc_client.instruction_delivery import type_into
        ok, why = type_into(terminal, text, pid=run.get("pid") or self._pids.get(f"{agent}|{sid}"),
                            vscode=self.vscode)
        if ok:
            return self._report(did, "sent", None)
        return self._report(did, "failed", f"Jarvis can't type into this session's terminal ({why}). "
                                           "Type it there, or send it while it's working.")

    def _stale_pid(self, agent: str, sid: str):
        """The process still running this conversation's old copy here. Claude's
        hooks carry no pid, so it's looked up by session id in Claude's own list
        (a background copy is stopped outright)."""
        try:
            entries = self.roster.scan_now(send=False)
        except Exception:  # noqa: BLE001
            return None
        for e in entries or []:
            if e.get("agent") != agent or e.get("session_id") != sid:
                continue
            if e.get("kind") == "background" and e.get("bg_id"):
                stop = getattr(self.runtime, "stop_bg", None)
                if stop is not None:
                    try:
                        stop(e["bg_id"])
                    except Exception:  # noqa: BLE001
                        log.warning("stopping the stale background copy failed", exc_info=True)
                return None
            if e.get("pid"):
                return e["pid"]
        return None

    def moved_sessions(self) -> list:
        return list(self._moved.values())

    def _push_moved(self) -> None:
        if self._ui is not None:
            try:
                self._ui({"type": "moved", "sessions": self.moved_sessions()})
            except Exception:  # noqa: BLE001
                pass

    def _report(self, did, state, reason) -> None:
        if did:
            self._event("agent_delivery", {"delivery_id": did, "state": state, "reason": reason})

    def _event(self, name: str, data: dict) -> None:
        self._up({"type": "event", "name": name, "data": data})

    @staticmethod
    def _codex_rel(path: str) -> Optional[str]:
        root = Path.home() / ".codex" / "sessions"
        try:
            return Path(path).resolve().relative_to(root.resolve()).as_posix()
        except (ValueError, OSError):
            return None
