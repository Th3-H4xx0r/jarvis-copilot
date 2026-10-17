"""Move a conversation between the Mac and the server, without losing a turn.

* **Continue on server** (the Mac is asleep or offline): resume the
  conversation on the server from its live transcript copy, as a Claude
  background session or a Codex thread, in the project's synced folder. A
  session that was mid-work is told to carry on.
* **Merge back** (the Mac reconnects): the Mac is told which of its sessions
  moved (its hooks then refuse prompts in the stale copies) and gets the
  server's transcript to merge into its own. New server turns keep following it
  as tails while the session stays on the server.
* **Continue on Mac**: stop the server run, merge, reopen it on the Mac.

Every step is recorded on the conversation (``moving`` + ``prev_status`` +
``moving_to``), so a webui restart mid-hand-off completes or rolls back in
``recover()`` instead of stranding it. Messages always go to the recorded
owner; an owner that isn't reachable is an honest failure.
"""
from __future__ import annotations

import base64
import logging
import os
import threading
import time
from typing import Callable, Optional

from agent import transcript_mirror as tm
from agent.agent_conversations import Conversations

log = logging.getLogger(__name__)

CARRY_ON = "Carry on from where you left off."
HANDOFF_AGENTS = ("claude", "codex")
_WORKING = ("working", "thinking")
# A Mac in these states isn't there to type into, whatever its rows say yet.
_MAC_GONE = ("disconnected", "asleep", "offline")
_CHUNK = 192 * 1024


def _fail(reason: str, error: str) -> dict:
    return {"ok": False, "reason": reason, "error": error}


class Handoff:
    def __init__(self, conv: Conversations, presence, claude, codex, deliveries, *,
                 send_frame: Callable[[str, dict], bool],
                 project_synced: Callable[[dict], bool] = lambda _row: True,
                 clock=time.time) -> None:
        self.conv = conv
        self.presence = presence
        self.claude = claude
        self.codex = codex
        self.deliveries = deliveries
        self._send_frame = send_frame
        self._project_synced = project_synced
        self._clock = clock
        # One sender at a time of a conversation's copy to its Mac, so the
        # "how far the Mac has" mark (mac_bytes) never goes backwards.
        self._mirror_lock = threading.RLock()

    # ── continue on server ───────────────────────────────────────────────
    def continue_on_server(self, ckey: str, *, confirm_offline: bool = False) -> dict:
        row = self.conv.get(ckey)
        if row is None:
            return _fail("no_session", "That session is gone.")
        if row.get("owner") == "server" and row.get("status") == "live":
            return {"ok": True, "owner": "server"}
        status = row.get("status")
        seen = status
        if status == "live" and row.get("owner") not in (None, "server") \
                and self.presence.state(row["owner"]) in _MAC_GONE:
            seen = "offline"   # dropped without a sleep notice, still in its grace period
        if seen not in ("asleep", "offline", "ended"):
            return _fail("owner_awake", "It's still running on the Mac.")
        if seen == "offline" and not confirm_offline:
            return _fail("confirm_offline", "The Mac went offline without sleeping, so it may "
                         "still be running this session. Continue anyway?")
        agent = row.get("agent") or "claude"
        if agent not in HANDOFF_AGENTS:
            return _fail("unsupported_agent", f"{agent.title()} sessions can't move to the server.")
        if agent == "codex":
            ok, why = self.codex.available()
            if not ok:
                return _fail("codex_unavailable", why)
        if row.get("owner") not in (None, "server") and not self._project_synced(row):
            return _fail("not_synced", "This project isn't synced to the server.")
        origin = row.get("owner") if row.get("owner") != "server" else row.get("moved_from")
        origin_cwd = row.get("origin_cwd") or row.get("cwd") or ""
        server_cwd = row.get("server_cwd") or (tm.server_cwd_for(origin_cwd)
                                               if origin else origin_cwd)
        probe = dict(row, server_cwd=server_cwd)
        if tm.size(probe) == 0:
            return _fail("no_transcript", "The server doesn't have this conversation yet.")
        # Atomic: of two callers (a double tap, phone + web), or a caller racing
        # the Mac waking up, exactly one moves it.
        if self.conv.transition(ckey, (status,), "moving", prev_status=status,
                                moving_to="server", server_cwd=server_cwd,
                                origin_cwd=origin_cwd, origin_run=row.get("run") or {}) is None:
            cur = self.conv.get(ckey) or {}
            if cur.get("owner") == "server" or cur.get("moving_to") == "server":
                return {"ok": True, "owner": "server", "pending": cur.get("status") == "moving"}
            return _fail("owner_awake", "It's running on the Mac again.")
        # Resume after a whole line, never onto a fragment the Mac didn't finish sending.
        mac_size = tm.trim_partial(probe)   # all of it came from the Mac: the Mac has it
        if mac_size == 0:
            self.conv.mark(ckey, status, moving_to=None)
            self._tell_moved(origin)
            return _fail("no_transcript", "The server doesn't have this conversation yet.")
        try:
            run = self._start_on_server(row, server_cwd)
        except Exception as exc:  # noqa: BLE001
            log.warning("continue on server failed for %s", ckey, exc_info=True)
            back = "live" if origin and self.presence.state(origin) == "online" else status
            self.conv.mark(ckey, back, moving_to=None)
            self._tell_moved(origin)
            return _fail("start_failed", f"The server couldn't start it: {exc}")
        self.conv.set_owner(ckey, "server", run)
        # Measured before the start: what the server's run writes from here on is
        # what the Mac doesn't have.
        self.conv.upsert(ckey, moved_from=origin, moved_at=self._clock(), moving_to=None,
                         cwd=server_cwd, mac_bytes=mac_size)
        self._tell_moved(origin)
        if row.get("state") in _WORKING:
            self.send(ckey, CARRY_ON)
        return {"ok": True, "owner": "server"}

    def _tell_moved(self, device_id) -> None:
        """A Mac that is up hears the hand-off's outcome now (its gate list)."""
        if device_id and device_id != "server" and self.presence.state(device_id) == "online":
            self._announce_moved(device_id)

    def _start_on_server(self, row: dict, cwd: str) -> dict:
        sid = row.get("session_id") or ""
        if (row.get("agent") or "claude") == "codex":
            return {"kind": "headless", "handle": self.codex.start(cwd, resume_session_id=sid)}
        self.claude.ensure_trusted(cwd)
        bg_origin = (row.get("run") or {}).get("kind") == "background"
        return {"kind": "background",
                "bg_id": self.claude.start(cwd, resume_session_id=sid, bg_origin=bg_origin)}

    # ── sending ──────────────────────────────────────────────────────────
    def send(self, ckey: str, text: str, now: bool = False) -> dict:
        did = self.deliveries.create(ckey, text)
        row = self.conv.get(ckey)
        state, reason = self._deliver(row, did, text, now=now)
        self.deliveries.mark(did, state, reason)
        return {"id": did, "state": state, "reason": reason}

    def _deliver(self, row: Optional[dict], did: str, text: str, now: bool = False) -> tuple:
        if row is None:
            return "failed", "no_session"
        owner, run = row.get("owner"), row.get("run") or {}
        if row.get("status") in ("ended", "moving"):
            return "failed", row.get("status")
        if row.get("state") in ("approval", "question"):
            # Its terminal shows the approval/question menu: typed text plus Enter
            # would pick the highlighted answer — an approval without Face ID.
            return "failed", "waiting"
        if owner == "server":
            try:
                if run.get("kind") == "headless":
                    self.codex.send(run.get("handle"), text)
                    return "delivered", None
                if not run.get("bg_id"):
                    return "failed", "no_runtime"
                busy = row.get("state") in _WORKING
                now = now and busy   # Ctrl+Enter only means something mid-turn
                bg = run["bg_id"]
                # Mid-turn the message waits in the attach client (queued, or
                # for the moment Send now takes), so the attach stays open.
                self.claude.send(bg, text, now=now,
                                 hold_until=(lambda: self._server_idle(bg)) if busy else None)
                return ("queued" if busy and not now else "sent"), None
            except Exception as exc:  # noqa: BLE001
                return "failed", str(exc) or "send_failed"
        if row.get("status") in ("asleep", "offline") or self.presence.state(owner) != "online":
            return "failed", "owner_offline"
        frame = {"type": "agent_instruction", "delivery_id": did, "ckey": row["ckey"],
                 "agent": row.get("agent") or "claude", "session_id": row.get("session_id"),
                 "cwd": row.get("cwd") or "", "text": text, "run": run,
                 "terminal": run.get("terminal") or {}, "state": row.get("state"),
                 "now": bool(now)}
        if not self._send_frame(owner, frame):
            return "failed", "owner_offline"
        return "sent", None

    def _server_idle(self, bg_id: str) -> bool:
        """True once the server session stopped working (or is gone): the
        message held in its attach client has gone in by then."""
        try:
            entry = next((e for e in self.claude.roster() if e.get("bg_id") == bg_id), None)
        except Exception:  # noqa: BLE001
            return False   # can't tell: keep holding (hold_max still ends it)
        return entry is None or entry.get("status") not in ("working", "running", "busy")

    def on_device_delivery(self, did: str, state: str, reason: Optional[str] = None) -> None:
        if state in ("queued", "failed", "sent", "delivered"):
            self.deliveries.mark(did, state, reason)

    # ── merge back ───────────────────────────────────────────────────────
    def on_device_connect(self, device_id: str) -> None:
        moved = self._announce_moved(device_id)
        for r in moved:
            # Only what the Mac doesn't have yet: every wake says hello.
            if r.get("owner") == "server" and tm.size(r) > int(r.get("mac_bytes") or 0):
                self._send_sync(device_id, r, then="merge")

    def _announce_moved(self, device_id: str) -> list:
        """Tell the Mac which of its sessions run on the server now — and those
        being moved there this moment, so its stale copy is blocked from the
        start. Always sent, even empty: the Mac's gate holds prompts after a
        wake until it hears."""
        moved = [r for r in self.conv.all()
                 if (r.get("moved_from") == device_id and r.get("owner") == "server")
                 or (r.get("owner") == device_id and r.get("status") == "moving"
                     and r.get("moving_to") == "server")]
        self._send_frame(device_id, {
            "type": "agent_moved", "ckeys": [r["ckey"] for r in moved],
            "sessions": [self._descr(r) for r in moved]})
        return moved

    def push_reverse(self, ckey: str) -> None:
        """New server turns of a moved session follow it to its Mac as tails."""
        row = self.conv.get(ckey)
        if not row or row.get("owner") != "server" or not row.get("moved_from"):
            return
        device = row["moved_from"]
        if self.presence.state(device) != "online":
            return
        with self._mirror_lock:
            row = self.conv.get(ckey) or row
            sent = int(row.get("mac_bytes") or 0)
            data = tm.read_from(row, sent)
            cut = data.rfind(b"\n") + 1
            if cut <= 0:
                return
            if self._send_frame(device, dict(self._descr(row), type="agent_transcript_tail",
                                             data_b64=base64.b64encode(data[:cut]).decode())):
                self.conv.upsert(ckey, mac_bytes=sent + cut)

    def _descr(self, row: dict) -> dict:
        origin = row.get("origin_cwd") or row.get("cwd") or ""
        return {"ckey": row["ckey"], "agent": row.get("agent") or "claude",
                "session_id": row.get("session_id"), "origin_cwd": origin,
                "codex_rel": row.get("codex_rel"),
                "title": (row.get("title") or os.path.basename(origin.rstrip("/")))[:120],
                "project": os.path.basename(origin.rstrip("/"))}

    def _send_sync(self, device_id: str, row: dict, then: str) -> bool:
        with self._mirror_lock:
            data = tm.read_from(row, 0)
            # The copy may be mid-write: only whole lines go; the rest follows as a tail.
            data = data[:data.rfind(b"\n") + 1]
            parts = max(1, -(-len(data) // _CHUNK))
            for i in range(parts):
                chunk = data[i * _CHUNK:(i + 1) * _CHUNK]
                if not self._send_frame(device_id, dict(
                        self._descr(row), type="agent_transcript_sync", part=i, parts=parts,
                        then=then, data_b64=base64.b64encode(chunk).decode())):
                    return False
            self.conv.upsert(row["ckey"], mac_bytes=len(data))
            return True

    # ── continue on Mac ──────────────────────────────────────────────────
    def continue_on_mac(self, ckey: str) -> dict:
        row = self.conv.get(ckey)
        if row is None:
            return _fail("no_session", "That session is gone.")
        device = row.get("moved_from") or row.get("origin_device_id")
        if row.get("status") == "moving":
            return _fail("moving", "It's already moving.")
        if row.get("owner") != "server" or not device:
            return _fail("not_on_server", "It isn't running on the server.")
        if self.presence.state(device) != "online":
            return _fail("mac_offline", "The Mac is asleep or offline.")
        self._stop_server_run(row)
        self.conv.mark(ckey, "moving", prev_status=row.get("status"), moving_to="mac")
        if not self._send_sync(device, self.conv.get(ckey), then="resume_local"):
            self.conv.mark(ckey, "ended", moving_to=None, error="The Mac went away mid-move.")
            return _fail("mac_offline", "The Mac went away mid-move.")
        return {"ok": True, "pending": True}

    def on_merge_done(self, device_id: str, ckey: str, ok: bool, then: Optional[str] = None,
                      fork_session_id: Optional[str] = None, error: str = "") -> None:
        row = self.conv.get(ckey)
        if row is None:
            return
        if fork_session_id:
            self.conv.upsert(ckey, mac_fork_session_id=fork_session_id)
        if then == "merge" and not ok:
            self.conv.upsert(ckey, mac_bytes=0)   # the next connect sends it again
            return
        if then != "resume_local" or row.get("status") != "moving":
            return
        if not ok:
            self.conv.mark(ckey, "ended", moving_to=None, error=error or "merge failed")
            return
        origin_run = row.get("origin_run") or {}
        self.conv.set_owner(ckey, device_id, {"kind": "interactive"})
        self.conv.upsert(ckey, moving_to=None, moved_from=None, cwd=row.get("origin_cwd") or "")
        self._send_frame(device_id, {
            "type": "agent_resume_local", "ckey": ckey, "agent": row.get("agent") or "claude",
            "session_id": row.get("session_id"), "cwd": row.get("origin_cwd") or "",
            "terminal": origin_run.get("terminal") or {}})

    def _stop_server_run(self, row: dict) -> None:
        run = row.get("run") or {}
        try:
            if run.get("kind") == "headless":
                self.codex.stop(run.get("handle"))
            elif run.get("bg_id"):
                self.claude.stop(run["bg_id"])
        except Exception:  # noqa: BLE001
            log.warning("stopping the server run of %s failed", row.get("ckey"), exc_info=True)

    # ── restart recovery ─────────────────────────────────────────────────
    def recover(self) -> bool:
        """Settle hand-offs a restart interrupted. False when Claude couldn't be
        asked what runs (try again later): a session caught mid-move may already
        run here, so it is never rolled back blind."""
        # A server Codex thread is a child of this process: a restart ended it.
        for r in self.conv.all():
            if r.get("owner") == "server" and r.get("status") == "live" \
                    and (r.get("run") or {}).get("kind") == "headless":
                self.conv.mark(r["ckey"], "ended")
        stuck = [r for r in self.conv.all() if r.get("status") == "moving"]
        if not stuck:
            return True
        try:
            live = {e.get("session_id"): e for e in self.claude.roster()}
        except Exception:  # noqa: BLE001
            live = None
        done = True
        for r in stuck:
            if r.get("moving_to") == "server":
                if live is None and (r.get("agent") or "claude") == "claude":
                    done = False
                    continue
                hit = (live or {}).get(r.get("session_id"))
                if hit and hit.get("bg_id"):
                    self.conv.set_owner(r["ckey"], "server",
                                        {"kind": "background", "bg_id": hit["bg_id"]})
                    self.conv.upsert(r["ckey"], moving_to=None,
                                     moved_from=r.get("owner") if r.get("owner") != "server"
                                     else r.get("moved_from"))
                else:
                    self.conv.mark(r["ckey"], r.get("prev_status") or "asleep", moving_to=None)
            else:
                self.conv.mark(r["ckey"], "ended", moving_to=None,
                               error="The move to the Mac was interrupted.")
        return done
