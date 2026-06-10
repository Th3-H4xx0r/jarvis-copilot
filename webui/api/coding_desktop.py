"""Server side of a DESKTOP-host coding session, driven over the device bridge.

When a coding session is launched with ``host='desktop'`` the tmux+claude
process runs on the user's paired desktop client (jc-client), not on the Jarvis
server. This module is the webui-process glue that:

  1. tells the desktop to start that tmux+claude (``coding_term_open``),
  2. streams the desktop PTY into the WebUI's live terminal (the existing
     ``/api/terminal/{output,input,resize,close}`` SSE machinery), and
  3. drives the bidirectional file sync (initial reconcile + incremental
     deltas).

Topology / frames
-----------------
The device-bridge connection registry lives in *this* (webui) process, so the
send path is in-process (``device_bridge.send_frame``) — no REST hop like the
agent-side chrome tools need. Frames (mirroring jc_client's CodingTermManager /
CodingSyncAgent):

  Terminal   S->D  coding_term_open  {term_id, cwd, argv, env}
                   coding_term_input {term_id, data}
                   coding_term_resize{term_id, rows, cols}
                   coding_term_close {term_id}
             D->S  coding_term_output{term_id, data}
                   coding_term_exit  {term_id, code}

  Sync       S->D  coding_sync_start {sync_id, local_path, remote_path, ignore}
                   coding_sync_stop  {sync_id}
             D->S  coding_sync_status{sync_id, status, conflicts, done, total, error}
                   coding_sync_error {sync_id, op, error}
                   coding_sync_authorize_key {pubkey}
        (the actual file bytes flow over the separate WS<->TCP relay + SSH +
         Mutagen on the desktop — they never touch this control bridge)

Design for testability
-----------------------
Every class takes an injectable *transport* — anything with
``send(device_id, frame) -> bool``. Tests pass a FakeBridge that records sent
frames and lets the test inject inbound frames (via ``DesktopBridge.on_frame``).
No real WebSocket, tmux, claude, or filesystem watcher is touched by the unit
tests; only the on-disk sync apply touches a tmp directory.
"""
from __future__ import annotations

import base64
import gzip
import hashlib
import logging
import os
import queue
import threading
import time
import uuid

log = logging.getLogger(__name__)

# Where a resumed (discovered) session's mirror checkout lives ON THE SERVER.
# Overridable via env so deployments can relocate it; defaults to ~/codingprojects.
# Referenced through ``_server_projects_root()`` so tests can monkeypatch it.
SERVER_PROJECTS_ROOT = os.path.expanduser("~/codingprojects")


def _server_projects_root() -> str:
    """Server-side root dir under which a resumed session's mirror checkout is
    created (``<root>/<basename(device_cwd)>``). Env ``JC_CODING_PROJECTS_ROOT``
    wins; otherwise the module-level ``SERVER_PROJECTS_ROOT`` (monkeypatchable)."""
    return os.environ.get("JC_CODING_PROJECTS_ROOT") or SERVER_PROJECTS_ROOT


# Disk-guard kill-switch: the status-loop disk guard sets this when the server disk
# is critically full so NO new sync can start (existing ones are paused separately).
# Process-local; cleared when the disk recovers. Read by ``start_sync_for_launch``.
# The disk guard re-stamps ``at`` every tick (~30s) while blocked; ``sync_blocked``
# self-expires a block older than the TTL so a dead/hung guard thread can't block
# syncs FOREVER (fail-open after the guard stops asserting).
_SYNC_BLOCK = {"blocked": False, "reason": "", "at": 0.0}
_SYNC_BLOCK_TTL = 180.0  # seconds; ~6 guard ticks


def sync_blocked() -> bool:
    if not _SYNC_BLOCK["blocked"]:
        return False
    if (time.monotonic() - float(_SYNC_BLOCK.get("at", 0.0))) > _SYNC_BLOCK_TTL:
        return False  # stale → the guard stopped re-asserting; fail open
    return True


def set_sync_blocked(blocked: bool, reason: str = "") -> None:
    _SYNC_BLOCK["blocked"] = bool(blocked)
    _SYNC_BLOCK["reason"] = reason or ""
    _SYNC_BLOCK["at"] = time.monotonic()

# ── transport seam ───────────────────────────────────────────────────────────


class _RealTransport:
    """Default transport: the in-process device-bridge send path."""

    def send(self, device_id: str, frame: dict) -> bool:
        from api import device_bridge

        return device_bridge.send_frame(device_id, frame)


# ── desktop terminal feed (TerminalSession-compatible) ───────────────────────


class _FakeProc:
    """Minimal Popen stand-in so the SSE route's ``term.proc.poll()`` works."""

    def __init__(self):
        self._code = None

    def set_exit(self, code):
        self._code = 0 if code is None else int(code)

    def poll(self):
        return self._code


class DesktopTerminalFeed:
    """A TerminalSession-compatible object whose PTY lives on the desktop.

    Output is fed by inbound ``coding_term_output`` frames; ``feed_write`` /
    ``feed_resize`` / ``feed_close`` emit the matching S->D frames. It is
    registered in ``api.terminal``'s ``_TERMINALS`` registry under the coding
    *session id* so the existing /api/terminal/{output,input,resize,close}
    routes drive it unchanged (those routes dispatch to the ``feed_*`` methods
    when present — see api/terminal.py).
    """

    # Bound the buffered output so a chatty session can't grow memory without
    # bound before a viewer attaches. Mirrors TerminalSession's queue cap.
    _MAX_QUEUE = 2000

    def __init__(self, *, session_id, device_id, term_id, bridge,
                 rows: int = 24, cols: int = 80, detach_closes_term: bool = False):
        self.session_id = str(session_id)
        self.device_id = str(device_id)
        self.term_id = str(term_id)
        self._bridge = bridge
        self.workspace = ""  # parity field; the real cwd lives on the device
        self.rows = rows
        self.cols = cols
        # ADOPTED (discovered-tmux) sessions: the desktop PTY is a throwaway tmux
        # CLIENT (`tmux attach-session`) attached to the user's existing session,
        # so on viewer detach we close it (kills only that attach client; the
        # tmux session + claude survive). LAUNCHED desktop sessions own their PTY,
        # so a detach must NOT close it (a tab-close shouldn't kill claude).
        self.detach_closes_term = bool(detach_closes_term)
        # Set when the underlying tmux/claude is gone (an unsolicited exit on an
        # adopted feed) so the bridge can reconcile the row + the UI can show the
        # "session ended" panel rather than a dead terminal.
        self.ended = False
        self.output: queue.Queue = queue.Queue(maxsize=self._MAX_QUEUE)
        self.closed = threading.Event()
        self.proc = _FakeProc()
        self.reader = None  # parity with TerminalSession.reader (unused here)

    # --- read surface the SSE route uses ------------------------------------

    def is_alive(self) -> bool:
        return not self.closed.is_set()

    def put_output(self, event: str, payload: dict) -> None:
        try:
            self.output.put_nowait((event, payload))
        except queue.Full:
            # Drop the oldest chunk to stay responsive (same policy as
            # TerminalSession.put_output).
            try:
                self.output.get_nowait()
            except queue.Empty:
                pass
            try:
                self.output.put_nowait((event, payload))
            except queue.Full:
                pass

    # --- inbound device frames ----------------------------------------------

    def on_output(self, data: str) -> None:
        if data:
            self.put_output("output", {"text": data})

    def on_exit(self, code, *, reason: str | None = None) -> None:
        self.proc.set_exit(code)
        self.closed.set()
        if reason == "ended":
            self.ended = True
        # ``reason`` tells the web/mobile viewer WHY the live stream ended so it
        # can react: "ended" -> the tmux/claude is gone, show the relaunch panel;
        # "disconnected" -> the Mac dropped its WS (tmux survives), show reconnect;
        # "" / None -> a plain detach (legacy banner).
        self.put_output("terminal_closed",
                        {"exit_code": self.proc.poll(), "reason": reason or ""})

    # --- feed_* overrides used by api.terminal write/resize/close ------------

    def feed_write(self, data: str) -> None:
        self._bridge.send_term_input(self.device_id, self.term_id, str(data or ""))

    def feed_resize(self, rows: int, cols: int) -> None:
        self.rows = max(8, min(int(rows or self.rows or 24), 80))
        self.cols = max(20, min(int(cols or self.cols or 80), 240))
        self._bridge.send_term_resize(self.device_id, self.term_id,
                                      self.rows, self.cols)

    def feed_close(self) -> None:
        # Detach the viewer; the desktop tmux+claude keeps running (parity with
        # the server-host "attach" terminal, which detaches rather than kills).
        # For an ADOPTED session, also close the throwaway attach-client PTY so it
        # doesn't linger as a phantom tmux client (the user's tmux+claude survive,
        # since we attach a SEPARATE client, not the original). For a LAUNCHED
        # session we do NOT send the close (a tab-close must not kill claude — the
        # session lifecycle (stop/delete) sends the close frame).
        if self.detach_closes_term:
            try:
                self._bridge.send_term_close(self.device_id, self.term_id)
            except Exception:  # noqa: BLE001
                pass
        self.closed.set()


# ── the bridge helper ────────────────────────────────────────────────────────


class DesktopBridge:
    """Server-side helper that sends coding frames to a device and routes the
    device's replies back to the right terminal feed / sync session.

    Single instance per webui process (``get_desktop_bridge()``). It owns the
    process-wide inbound coding-frame handler registered with the device bridge.
    Routing is by ``term_id`` (terminal frames) / ``sync_id`` (sync frames)
    carried inside each frame.
    """

    # Per-term replay buffer cap (chars) so a viewer attaching after launch
    # still sees recent scrollback. Bounded to protect memory.
    _REPLAY_CAP = 64 * 1024

    # Hard cap on a reassembled transcript (decoded, pre-gunzip bytes). A
    # discovered Mac transcript that exceeds this is dropped with an error rather
    # than buffered without bound — resume then proceeds with a soft warning.
    _TRANSCRIPT_CAP = 64 * 1024 * 1024

    def __init__(self, transport=None):
        self._transport = transport or _RealTransport()
        self._lock = threading.RLock()
        # term_id -> DesktopTerminalFeed
        self._feeds: dict[str, DesktopTerminalFeed] = {}
        # term_id -> list[str] replay buffer (output seen before a feed attached)
        self._replay: dict[str, list[str]] = {}
        # term_id -> int exit code seen before a feed attached
        self._pending_exit: dict[str, int] = {}
        # sync_id -> DesktopSyncSession
        self._syncs: dict = {}
        # req_id -> {"event":Event, "chunks":{seq:bytes}, "eof":bool,
        #            "error":str|None, "total":int} — in-flight transcript pulls.
        self._transcript_waiters: dict[str, dict] = {}

    # --- registration with the device bridge --------------------------------

    def install(self) -> None:
        """Register this instance as the device bridge's coding-frame handler."""
        from api import device_bridge

        device_bridge.set_coding_frame_handler(self.on_frame)

    # --- outbound terminal frames -------------------------------------------

    def send_term_open(self, device_id: str, *, term_id: str, cwd: str,
                       argv: list, env: dict | None = None) -> bool:
        return self._transport.send(device_id, {
            "type": "coding_term_open",
            "term_id": term_id,
            "cwd": cwd,
            "argv": list(argv),
            "env": dict(env or {}),
        })

    def send_term_input(self, device_id: str, term_id: str, data: str) -> bool:
        return self._transport.send(device_id, {
            "type": "coding_term_input", "term_id": term_id, "data": data,
        })

    def send_term_resize(self, device_id: str, term_id: str,
                         rows: int, cols: int) -> bool:
        return self._transport.send(device_id, {
            "type": "coding_term_resize", "term_id": term_id,
            "rows": int(rows), "cols": int(cols),
        })

    def send_term_close(self, device_id: str, term_id: str) -> bool:
        with self._lock:
            self._feeds.pop(term_id, None)
            self._replay.pop(term_id, None)
            self._pending_exit.pop(term_id, None)
        return self._transport.send(device_id, {
            "type": "coding_term_close", "term_id": term_id,
        })

    # --- terminal feed lifecycle --------------------------------------------

    def attach_feed(self, *, session_id: str, device_id: str, term_id: str,
                    rows: int = 24, cols: int = 80,
                    detach_closes_term: bool = False,
                    fresh: bool = False) -> DesktopTerminalFeed:
        """Create (or return) the feed for ``term_id`` and replay buffered output.

        Registers the feed in api.terminal's registry under ``session_id`` so the
        existing SSE/input/resize/close routes drive it. ``detach_closes_term``
        marks an ADOPTED throwaway attach-client PTY (closed on viewer detach).

        ``fresh`` (set by a brand-new adopt) drops a stale CLOSED feed and clears
        any buffered exit/replay from a previous, now-dead attach — so a
        relaunched/still-alive session attaches cleanly and a truly-gone one
        re-signals "ended" via a NEW exit frame instead of an instantly-replayed
        stale one (which made every reopen flash detached forever).
        """
        from api import terminal as term_mod

        with self._lock:
            feed = self._feeds.get(term_id)
            if feed is not None and fresh and feed.closed.is_set():
                self._feeds.pop(term_id, None)
                feed = None
            if fresh:
                self._replay.pop(term_id, None)
                self._pending_exit.pop(term_id, None)
            if feed is None:
                feed = DesktopTerminalFeed(
                    session_id=session_id, device_id=device_id, term_id=term_id,
                    bridge=self, rows=rows, cols=cols,
                    detach_closes_term=detach_closes_term)
                self._feeds[term_id] = feed
                # Replay any output that arrived before the viewer attached.
                for chunk in self._replay.pop(term_id, []):
                    feed.on_output(chunk)
                if term_id in self._pending_exit:
                    feed.on_exit(self._pending_exit.pop(term_id),
                                 reason="ended" if detach_closes_term else None)
        term_mod.register_terminal(session_id, feed)
        return feed

    def feed_for(self, term_id: str) -> DesktopTerminalFeed | None:
        with self._lock:
            return self._feeds.get(term_id)

    def on_device_disconnect(self, device_id: str) -> None:
        """A desktop dropped its WS. Most drops are brief relay blips, so we
        DEBOUNCE: the terminal feeds close with a SOFT ``reconnecting`` reason
        (the mobile shows "reconnecting…" and auto-retries instead of an
        alarming "disconnected"), and we RETAIN the sessions' last-known
        activity_state, only escalating to "gone" if no discovery frame arrives
        within the grace window. The device's tmux+claude keep running."""
        device_id = str(device_id or "")
        if not device_id:
            return
        with self._lock:
            feeds = [f for f in self._feeds.values()
                     if f.device_id == device_id and not f.closed.is_set()]
        for feed in feeds:
            try:
                # Reconnectable detach, NOT a session end → reason=reconnecting
                # (the UI auto-retries; we must NOT reconcile to stopped).
                feed.on_exit(None, reason="reconnecting")
            except Exception:  # noqa: BLE001
                pass
        # Schedule the real "gone" escalation; KEEP activity_state for now so a
        # quick reconnect never flaps the dot. note_device_reconnect (called on
        # the next discovery frame) cancels it.
        with _RECONNECT_LOCK:
            gen = _RECONNECTING.get(device_id, 0) + 1
            _RECONNECTING[device_id] = gen
        timer = threading.Timer(
            _RECONNECT_GRACE, _escalate_device_gone, (device_id, gen))
        timer.daemon = True
        timer.start()

    # --- outbound sync frames -----------------------------------------------

    def send_sync_start(self, device_id: str, *, sync_id: str, local_path: str,
                        remote_path: str, ignore: list | None = None) -> bool:
        """Tell the desktop to start a Mutagen sync for this session: its LOCAL
        folder (``local_path``) <-> the server's session cwd (``remote_path``,
        reached over the WS<->TCP relay's ssh alias)."""
        return self._transport.send(device_id, {
            "type": "coding_sync_start", "sync_id": sync_id,
            "local_path": local_path, "remote_path": remote_path,
            "ignore": list(ignore or []),
        })

    def send_sync_stop(self, device_id: str, sync_id: str) -> bool:
        with self._lock:
            self._syncs.pop(sync_id, None)
        return self._transport.send(device_id, {
            "type": "coding_sync_stop", "sync_id": sync_id,
        })

    def send_sync_reconcile(self, device_id: str, active_sync_ids: list) -> bool:
        """Tell the desktop the AUTHORITATIVE set of syncs that should be running
        right now (one per live coding session). The desktop terminates any
        Mutagen sync + status poller NOT in this set — cleaning up orphans left
        by deleted/stopped sessions (including deletes that happened while the
        client was offline, or stale Mutagen sessions after a client restart).
        This is what keeps the tray's "Sync: N active" count honest."""
        active = [str(s) for s in (active_sync_ids or [])]
        with self._lock:
            for sid in list(self._syncs.keys()):
                if sid not in active:
                    self._syncs.pop(sid, None)
        return self._transport.send(device_id, {
            "type": "coding_sync_reconcile", "active": active,
        })

    # --- outbound discovery frames ------------------------------------------

    def send_discover_request(self, device_id: str) -> bool:
        """Ask a device to scan its live ``claude`` tmux sessions and push a
        ``coding_discover`` frame now (used on reconnect + the Refresh button)."""
        return self._transport.send(device_id, {
            "type": "coding_discover_request",
        })

    # --- transcript request/response (resume-to-server) ---------------------

    def request_transcript(self, device_id: str, *, claude_session_id: str,
                           cwd: str, timeout: float = 30.0) -> bytes | None:
        """Pull a discovered session's transcript bytes FROM the device, synchronously.

        Sends ``coding_transcript_get`` (req_id/claude_session_id/cwd) and blocks
        up to ``timeout`` for the device to stream back one or more
        ``coding_transcript_data`` frames. Each frame carries a base64 chunk of
        the GZIPPED transcript under ``content_b64`` keyed by ``seq``; the final
        frame sets ``eof:true`` (or ``ok:false``+``error`` on failure).

        Returns the RAW (gunzipped) transcript bytes, or ``None`` on timeout,
        device-offline, device error, oversize, or a corrupt stream. Always
        cleans up the waiter; never blocks past ``timeout``.
        """
        req_id = uuid.uuid4().hex
        waiter = {"event": threading.Event(), "chunks": {}, "eof": False,
                  "error": None, "total": 0}
        with self._lock:
            self._transcript_waiters[req_id] = waiter
        try:
            ok = self._transport.send(device_id, {
                "type": "coding_transcript_get",
                "req_id": req_id,
                "claude_session_id": claude_session_id,
                "cwd": cwd,
            })
            if not ok:
                return None  # device not connected
            if not waiter["event"].wait(timeout):
                log.warning("coding_transcript[%s]: timed out after %.0fs",
                            req_id, timeout)
                return None
            with self._lock:
                err = waiter["error"]
                # Snapshot under the lock so a late/duplicate device frame can't
                # mutate the chunk map while we reassemble it.
                chunks = dict(waiter["chunks"])
            if err:
                log.warning("coding_transcript[%s]: device error: %s",
                            req_id, err)
                return None
            if not chunks:
                return None
            ordered = b"".join(chunks[i] for i in sorted(chunks))
            try:
                return gzip.decompress(ordered)
            except Exception as exc:  # noqa: BLE001 — corrupt/partial stream
                log.warning("coding_transcript[%s]: gunzip failed: %s",
                            req_id, exc)
                return None
        finally:
            with self._lock:
                self._transcript_waiters.pop(req_id, None)

    def push_transcript(self, device_id: str, *, claude_session_id: str,
                        cwd: str, raw: bytes) -> bool:
        """Push transcript bytes TO the device (inverse of ``request_transcript``):
        it writes them to its ``<projects>/<encode(cwd)>/<claude_session_id>.jsonl``
        so a later local ``claude --resume`` on the Mac sees this side's turns.
        Used ONLY at session close (one-shot), never during live running. Streams
        ``coding_transcript_put`` frames (gzip+base64, ``seq``-ordered, final
        ``eof``). Returns True only if every chunk was accepted. Never raises."""
        try:
            payload = base64.b64encode(gzip.compress(raw or b"")).decode("ascii")
        except Exception:  # noqa: BLE001
            return False
        chunk = 256 * 1024
        total = len(payload)
        req_id = uuid.uuid4().hex
        seq = pos = 0
        ok_all = True
        while True:
            piece = payload[pos:pos + chunk]
            pos += chunk
            eof = pos >= total
            try:
                ok = self._transport.send(device_id, {
                    "type": "coding_transcript_put", "req_id": req_id,
                    "claude_session_id": claude_session_id, "cwd": cwd,
                    "seq": seq, "eof": eof, "content_b64": piece,
                })
            except Exception:  # noqa: BLE001
                ok = False
            ok_all = ok_all and bool(ok)
            seq += 1
            if eof:
                break
        return ok_all

    def register_sync(self, session) -> None:
        with self._lock:
            self._syncs[session.sync_id] = session

    def sync_for(self, sync_id: str):
        with self._lock:
            return self._syncs.get(sync_id)

    # --- inbound frame routing (called from the bridge pump thread) ---------

    def on_frame(self, device_id: str, frame: dict) -> None:
        t = frame.get("type")
        if t == "coding_term_output":
            self._route_term_output(frame)
        elif t == "coding_term_exit":
            self._route_term_exit(frame)
        elif t == "coding_sync_authorize_key":
            self._authorize_sync_key(frame.get("pubkey") or "")
        elif t in ("coding_sync_status", "coding_sync_error"):
            self._route_sync(frame)
        elif t == "coding_discover":
            self._route_discover(device_id, frame)
        elif t == "coding_transcript_data":
            self._route_transcript_data(frame)

    def _route_transcript_data(self, frame: dict) -> None:
        """Accumulate a transcript chunk for the matching in-flight request.

        Runs on the bridge pump thread. Appends ``base64.b64decode(content_b64)``
        under ``chunks[seq]``, enforces the size cap, and on ``eof`` (or an
        ``ok:false``/``error`` frame) signals the waiting request thread. Frames
        for an unknown/already-finished req_id are ignored."""
        req_id = frame.get("req_id")
        if not req_id:
            return
        # Device-reported failure short-circuits everything.
        if frame.get("ok") is False or frame.get("error"):
            err = str(frame.get("error") or "transcript fetch failed")
            with self._lock:
                waiter = self._transcript_waiters.get(req_id)
                if waiter is None:
                    return  # unknown or already timed-out request
                waiter["error"] = err
                waiter["event"].set()
            return
        # Decode the chunk OUTSIDE the lock (CPU), then mutate ALL waiter state
        # UNDER the lock — so a late/duplicate frame can never grow the chunk map
        # while request_transcript is snapshotting it for reassembly (which would
        # raise "dict changed size during iteration").
        content_b64 = frame.get("content_b64") or ""
        try:
            chunk = base64.b64decode(content_b64) if content_b64 else b""
        except Exception as exc:  # noqa: BLE001
            with self._lock:
                waiter = self._transcript_waiters.get(req_id)
                if waiter is not None:
                    waiter["error"] = f"bad base64 chunk: {exc}"
                    waiter["event"].set()
            return
        try:
            seq = int(frame.get("seq"))
            seq_explicit = True
        except (TypeError, ValueError):
            seq = -1
            seq_explicit = False
        eof = bool(frame.get("eof"))
        with self._lock:
            waiter = self._transcript_waiters.get(req_id)
            if waiter is None:
                return  # unknown or already timed-out request
            if not seq_explicit:
                seq = len(waiter["chunks"])
            waiter["total"] += len(chunk)
            if waiter["total"] > self._TRANSCRIPT_CAP:
                waiter["error"] = (
                    f"transcript exceeded {self._TRANSCRIPT_CAP} byte cap")
                waiter["chunks"].clear()
                waiter["event"].set()
                return
            if chunk:
                waiter["chunks"][seq] = chunk
            if eof:
                waiter["eof"] = True
                waiter["event"].set()

    def _route_discover(self, device_id: str, frame: dict) -> None:
        """Ingest a device's pushed live ``claude`` tmux sessions.

        SECURITY: the authoritative device id is ``device_id`` — the id of the
        WS this frame arrived on (set at pairing/auth time by the device bridge),
        NOT the ``device_id`` the frame self-reports. A device must never be able
        to write (or reconcile-to-stopped) ANOTHER device's discovered rows by
        claiming a different id in the payload. We therefore always key off the
        connection id; the frame's self-reported value is only consulted as a
        fallback when the connection id is somehow blank (it never is in
        practice), and even then must not be allowed to forge a foreign id."""
        did = (device_id or "").strip() or (frame.get("device_id") or "").strip()
        try:
            ingest_discovered(did, frame.get("sessions") or [])
        except Exception as exc:  # never raise into the bridge pump thread
            log.warning("coding_discover ingest failed for %s: %s", did, exc)

    def _route_term_output(self, frame: dict) -> None:
        term_id = frame.get("term_id")
        data = frame.get("data") or ""
        with self._lock:
            feed = self._feeds.get(term_id)
            if feed is None:
                # No viewer yet — buffer (bounded) for replay on attach.
                buf = self._replay.setdefault(term_id, [])
                buf.append(data)
                total = sum(len(c) for c in buf)
                while total > self._REPLAY_CAP and len(buf) > 1:
                    total -= len(buf.pop(0))
                return
        feed.on_output(data)

    def _route_term_exit(self, frame: dict) -> None:
        term_id = frame.get("term_id")
        code = frame.get("code")
        with self._lock:
            feed = self._feeds.get(term_id)
            if feed is None:
                self._pending_exit[term_id] = 0 if code is None else int(code)
                return
        # An UNSOLICITED exit on an ADOPTED discovered feed means the user's tmux
        # session ended (they quit claude / killed the pane). A clean viewer detach
        # never reaches here — the client suppresses the exit frame for a close WE
        # initiated. So treat it as "ended": tell the viewer (reason) AND flip the
        # discovered row to stopped now, instead of waiting up to ~5s for the next
        # discovery push to reconcile it (the window where the old UI re-attached
        # to a dead target and got stuck on the detached banner).
        ended = bool(getattr(feed, "detach_closes_term", False))
        feed.on_exit(code, reason="ended" if ended else None)
        if ended:
            self._reconcile_session_ended(feed.session_id)

    def _reconcile_session_ended(self, session_id: str) -> None:
        """Flip a discovered session whose live tmux just ended to ``stopped`` (and
        clear its live ``activity_state``) so the UI shows the "session ended"
        panel immediately instead of re-attaching to a dead target. Scoped to
        discovered rows — LAUNCHED sessions are owned by the manager's lifecycle.
        Best-effort; never raises into the bridge pump thread."""
        try:
            store = _resolve_store()
            if store is None:
                return
            row = store.get_session(session_id)
            if row is None:
                return
            # Only an adopted discovered-TMUX row owns a live attach feed; never
            # touch a discovered-TRANSCRIPT row (those are never reconciled to
            # stopped) or a launched/server row (manager owns its lifecycle).
            if (row.get("source") or "") != "discovered-tmux":
                return
            if row.get("status") != "stopped":
                store.update_session(session_id, status="stopped",
                                     activity_state=None)
        except Exception:  # noqa: BLE001
            pass

    def _authorize_sync_key(self, pubkey: str) -> None:
        """Add the desktop's sync SSH public key to the server's authorized_keys
        so Mutagen (over the WS<->TCP relay) can connect. Idempotent + defensive
        — a bad key or fs error must never break the bridge."""
        try:
            from agent.sync_authorized_keys import add_authorized_key
            res = add_authorized_key(pubkey)
            if res.get("error"):
                log.warning("coding_sync_authorize_key rejected: %s", res["error"])
            elif res.get("added"):
                log.info("coding_sync: authorized desktop sync key -> %s",
                         res.get("path"))
        except Exception as exc:  # noqa: BLE001
            log.warning("coding_sync_authorize_key failed: %s", exc)

    def _route_sync(self, frame: dict) -> None:
        sync = self.sync_for(frame.get("sync_id"))
        if sync is None:
            return
        t = frame.get("type")
        if t == "coding_sync_status":
            sync.on_status(frame)
        elif t == "coding_sync_error":
            sync.on_error(frame.get("op") or "", frame.get("error") or "",
                          frame.get("relpath"))


# ── sync session (server side of the synced tunnel) ──────────────────────────


class MutagenSyncSession:
    """Server-side state for ONE coding session's Mutagen sync.

    The actual file sync runs on the DESKTOP (Mutagen over the WS<->TCP relay).
    This object only (a) tells the desktop to start/stop the sync and (b) holds
    the latest status the desktop pushes back, for the WebUI sync panel. It owns
    no transfer logic — that is Mutagen's job now.

    ``local_path``  = the desktop's working folder to sync.
    ``remote_path`` = the server session's cwd (where claude runs).
    """

    # Re-send coding_sync_start if the desktop never reports status (handshake
    # lost to a reconnect); generous so a slow initial scan isn't restarted.
    _REOPEN_STALE_SECS = 45.0

    def __init__(self, *, sync_id, device_id, local_path, remote_path, bridge,
                 ignore=None):
        self.sync_id = str(sync_id)
        self.device_id = str(device_id)
        self.local_path = str(local_path or "")
        self.remote_path = str(remote_path or "")
        self.bridge = bridge
        self.ignore = list(ignore) if ignore else None
        # status surfaced to the WebUI:
        #   opening | syncing | synced | conflicts | error
        self.status = "opening"
        self.direction = None  # parity field (Mutagen is bidirectional)
        self.conflicts = 0
        self.healed = 0
        self.done = 0
        self.total = 0
        self.last_sync_at = None
        self.error = None
        self._last_open_at = 0.0

    def open(self) -> bool:
        """Tell the desktop to (re)start the Mutagen sync for this session."""
        self.status = "opening"
        self._last_open_at = time.time()
        ok = self.bridge.send_sync_start(
            self.device_id, sync_id=self.sync_id, local_path=self.local_path,
            remote_path=self.remote_path, ignore=self.ignore)
        log.info("coding_sync[%s] start -> device=%s local=%s remote=%s sent=%s",
                 self.sync_id, self.device_id, self.local_path,
                 self.remote_path, ok)
        return ok

    def reopen_if_stale(self, now=None) -> bool:
        """Re-send coding_sync_start if we've been stuck waiting to connect for
        too long (the start frame was lost to a reconnect, or Mutagen's ssh
        through the relay never came up). Fires while 'opening' OR 'connecting'."""
        if self.status not in ("opening", "connecting"):
            return False
        if now is None:
            now = time.time()
        if self._last_open_at and (now - self._last_open_at) < self._REOPEN_STALE_SECS:
            return False
        log.info("coding_sync[%s] re-start: no status after %.0fs",
                 self.sync_id, now - (self._last_open_at or now))
        self.open()
        return True

    def on_status(self, frame: dict) -> None:
        """The desktop pushed a coding_sync_status frame parsed from Mutagen."""
        status = str(frame.get("status") or "").strip() or self.status
        self.status = status
        self.conflicts = int(frame.get("conflicts") or 0)
        self.healed = int(frame.get("healed") or 0)
        self.done = int(frame.get("done") or 0)
        self.total = int(frame.get("total") or 0)
        self.error = frame.get("error")
        if status == "synced":
            self.last_sync_at = time.time()

    def on_error(self, op: str, error: str, relpath=None) -> None:
        self.error = f"{op}: {error}" + (f" ({relpath})" if relpath else "")
        self.status = "error"
        log.warning("coding_sync[%s] desktop error op=%s: %s",
                    self.sync_id, op, error)

    def close(self) -> None:
        try:
            self.bridge.send_sync_stop(self.device_id, self.sync_id)
        except Exception:
            pass


# ── process-wide singleton + driver wiring ───────────────────────────────────

_BRIDGE = None
_BRIDGE_LOCK = threading.Lock()


def get_desktop_bridge() -> DesktopBridge:
    """The webui process's DesktopBridge (installs the device-bridge handler on
    first use)."""
    global _BRIDGE
    with _BRIDGE_LOCK:
        if _BRIDGE is None:
            _BRIDGE = DesktopBridge()
            try:
                _BRIDGE.install()
            except Exception:
                # device_bridge import may fail in some contexts; the bridge is
                # still usable for outbound sends if a transport is wired later.
                pass
        return _BRIDGE


# Pairing ``kind``s that can NEVER run Mutagen file sync. Only MOBILE apps are
# excluded: they hold a live device-bridge WebSocket too (notifications /
# phone-control), so "connected to the bridge" alone isn't proof of a desktop
# agent. NOTE: a desktop jc-client registers with kind=='desktop' OR — very
# commonly — the DEFAULT kind=='browser' (only the mobile app flips its kind
# after pairing), so 'browser'/'' must NOT be excluded here. Actual web
# browsers never hold a device-bridge WS, so they're filtered out by the
# bridge_connected requirement, not by kind.
NON_SYNC_KINDS = frozenset({"mobile-ios", "mobile-android", "mobile"})


def is_sync_capable_kind(kind: str | None) -> bool:
    """True unless ``kind`` is a known mobile pairing (which can't run Mutagen
    even though it holds a device-bridge WS)."""
    return (kind or "").strip().lower() not in NON_SYNC_KINDS


def _connected_sync_capable() -> list:
    """Connected device ids that can actually run Mutagen sync (desktop
    jc-clients), in a stable order. Excludes mobile/browser pairings even though
    they hold a bridge WS."""
    try:
        from api import device_bridge

        connected = list(device_bridge.connected_device_ids())
    except Exception:
        return []
    if not connected:
        return []
    try:
        from api.pairing import list_devices

        kind_of = {d.get("id"): (d.get("kind") or "") for d in list_devices()}
    except Exception:
        kind_of = {}
    return [cid for cid in connected if is_sync_capable_kind(kind_of.get(cid))]


def resolve_desktop_device_id(preferred: str | None = None) -> str | None:
    """device_id of a connected jc-client DESKTOP (sync-capable) device, else None.

    A device qualifies only if it holds a live device-bridge WS AND is not a
    mobile/browser pairing (those hold a bridge too but can't run Mutagen). The
    explicitly-chosen ``preferred`` device (by id or name) wins when it's both
    connected and sync-capable.
    """
    capable = _connected_sync_capable()
    if not capable:
        return None
    capable_set = set(capable)
    # 1. honour the explicitly-chosen device (by id or name) if it's connected
    #    AND sync-capable (never resolve a chosen mobile device to itself).
    if preferred:
        if preferred in capable_set:
            return preferred
        try:
            from api.pairing import list_devices

            for d in list_devices():
                if d.get("id") in capable_set and (
                        d.get("id") == preferred
                        or (d.get("name") or "") == preferred
                        or (d.get("device_name") or "") == preferred):
                    return d["id"]
        except Exception:
            pass
    # 2. prefer a relay-capable connected device (still must be sync-capable)
    try:
        from api import device_bridge

        caps = device_bridge.relay_capable_devices()
        if caps and caps[0].get("device_id") in capable_set:
            return caps[0]["device_id"]
    except Exception:
        pass
    # 3. fall back to the first connected sync-capable (desktop) jc-client
    return capable[0]


class _BridgeRunResult:
    """CompletedProcess-shaped result so CodingSessionManager's rc check works."""

    def __init__(self, returncode: int, stderr: str = ""):
        self.returncode = returncode
        self.stderr = stderr


def make_bridge_run(device_id: str, bridge: DesktopBridge | None = None):
    """Return a ``bridge_run(argv)`` closure for a DesktopDriver bound to one
    device.

    The manager calls ``driver._run(argv)`` for three kinds of argv (all
    constructed identically to LocalDriver):

      * ``tmux new-session -d -s <name> -c <cwd> <claude-argv...>``  -> launch:
        send ``coding_term_open`` carrying (term_id=<name>, cwd, argv=<claude>).
        The desktop runs tmux+claude and streams ``coding_term_output``.
      * ``tmux send-keys -t <name> ...``                              -> message:
        translate to ``coding_term_input`` against term_id=<name>.
      * ``tmux kill-session -t <name>``                               -> stop:
        send ``coding_term_close`` for term_id=<name>.

    Anything else is sent verbatim as a best-effort and reported as success so a
    new tmux sub-command doesn't hard-fail the manager.
    """
    bridge = bridge or get_desktop_bridge()

    def _run(argv):
        argv = list(argv or [])
        try:
            return _dispatch_tmux_argv(bridge, device_id, argv)
        except Exception as exc:  # never raise into the manager's launch path
            return _BridgeRunResult(1, str(exc))

    return _run


def repo_sync_id(device_id: str, local_path: str, remote_path: str) -> str:
    """Deterministic sync id for a repo file-sync, keyed by the FOLDER-PAIR
    (device + local folder + remote folder) rather than the session.

    A repo's working dir is per-PROJECT, not per-session — so every coding
    session that syncs the same ``(device, local, remote)`` triple shares ONE
    Mutagen sync instead of each spinning up its own (which is what left N
    overlapping ``jc-sync-cs-*`` syncs fighting over the same two directories)."""
    key = "\x00".join((str(device_id or ""), str(local_path or ""),
                       str(remote_path or "")))
    return "sync-" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]


def _row_repo_sync_id(row: dict, sync_config=None) -> str | None:
    """The repo_sync_id for a session ROW (device + the desktop folder from its
    sync_config + the server cwd), or None if the row has no usable sync."""
    import json as _json
    cfg = {}
    raw = sync_config if sync_config is not None else (row.get("sync_config") or "")
    if isinstance(raw, dict):
        cfg = raw
    elif raw:
        try:
            cfg = _json.loads(raw) or {}
        except Exception:
            cfg = {}
    if not (cfg.get("enabled") or cfg.get("device") or cfg.get("remote_path")):
        return None
    device_id = (row.get("device_id") or "").strip() or (cfg.get("device") or "").strip()
    cwd = row.get("cwd") or ""
    local_path = cfg.get("remote_path") or cwd
    if not (device_id and cwd):
        return None
    return repo_sync_id(device_id, local_path, cwd)


def start_sync_for_launch(device_id: str, *, session_id: str, cwd: str,
                          sync: dict | None,
                          bridge: DesktopBridge | None = None):
    """Open a MutagenSyncSession for a session that opted into syncing.

    The desktop runs Mutagen between its LOCAL folder (``sync['remote_path']`` —
    the path on the user's machine) and the server session's cwd
    (``remote_path`` on the Mutagen ``jc-hermes`` ssh alias). Returns the session
    (or None when sync is off).

    The sync is keyed by the FOLDER-PAIR (``repo_sync_id``), so sibling sessions
    on the same project reuse the one sync instead of opening duplicates.
    """
    if not sync:
        return None
    if not (sync.get("enabled") or sync.get("device") or sync.get("remote_path")):
        return None
    bridge = bridge or get_desktop_bridge()
    ignore = sync.get("ignore") if isinstance(sync.get("ignore"), list) else None
    local_path = sync.get("remote_path") or cwd  # the DESKTOP's folder
    # ── SAFEGUARDS: never start a runaway/misconfigured/disk-unsafe sync. ──
    # Validate the endpoints (reject $HOME / system dirs / a Mac path used as the
    # server dest / a server path outside the allowed roots). The Mac-side
    # allowed-root + tree-size checks run on the CLIENT (it can stat the tree).
    try:
        from agent.coding_sync_safety import (
            SyncSafetyConfig, validate_endpoints_for_server_gate)
        ok, why = validate_endpoints_for_server_gate(
            local_path, cwd, SyncSafetyConfig.from_env())
    except Exception:  # never let the guard import/logic crash a launch
        ok, why = True, ""
    if not ok:
        log.warning("coding sync REFUSED (%s): local=%r server=%r",
                    why, local_path, cwd)
        return None
    if sync_blocked():
        log.warning("coding sync blocked by disk guard: %s", _SYNC_BLOCK.get("reason"))
        return None
    try:
        import shutil as _shutil
        from agent.coding_disk_guard import DiskGuardConfig
        floor = DiskGuardConfig.from_env().min_free_bytes
        target = cwd if os.path.isdir(cwd) else _server_projects_root()
        if _shutil.disk_usage(target).free < floor:
            log.warning("coding sync refused: server free space below floor (%d)", floor)
            return None
    except Exception:  # disk path missing (e.g. unit tests) → don't block
        pass
    sync_id = repo_sync_id(device_id, local_path, cwd)
    # If a healthy sync for this exact folder-pair already exists (a sibling
    # session opened it), reuse it — don't open a duplicate Mutagen session.
    existing = bridge.sync_for(sync_id)
    if existing is not None and existing.status not in ("error", "disconnected"):
        return existing
    session = MutagenSyncSession(
        sync_id=sync_id, device_id=device_id, local_path=local_path,
        remote_path=cwd, bridge=bridge, ignore=ignore)
    # NOTE: the conversation transcript (<csid>.jsonl, under ~/.claude/projects)
    # is deliberately NOT synced continuously — two live claude processes would
    # conflict, and a running claude never re-reads its transcript anyway. It is
    # reconciled ONLY at session open/close (see reconcile_session_transcript).
    bridge.register_sync(session)
    session.open()  # coding_sync_start -> desktop runs Mutagen, pushes status
    return session


def start_sync_for_session(*, session_id: str, cwd: str, sync: dict | None,
                           bridge: DesktopBridge | None = None):
    """Open a file sync for a session that opted in — works for ANY host
    (server OR desktop), resolving the device chosen in the sync config.

    Returns the DesktopSyncSession, or None when sync is off OR no matching
    desktop client (jc-client) is currently connected to sync with.
    """
    if not sync:
        return None
    if not (sync.get("enabled") or sync.get("device") or sync.get("remote_path")):
        return None
    device_id = resolve_desktop_device_id(preferred=sync.get("device"))
    if not device_id:
        return None  # chosen device isn't a connected jc-client
    return start_sync_for_launch(device_id, session_id=session_id, cwd=cwd,
                                 sync=sync, bridge=bridge)


def stop_sync_for_session(session_id: str, *, store=None,
                          bridge: DesktopBridge | None = None) -> None:
    """Stop the file sync for a session being deleted/stopped — UNLESS a sibling
    session still shares its folder-pair sync.

    The repo sync is keyed by the folder-pair (``repo_sync_id``) and shared by
    every session on that project, so we must NOT terminate it while another
    RUNNING session still needs it. Only when this is the last session on the
    pair do we tell the desktop to stop the Mutagen sync. Never raises."""
    if not session_id:
        return
    try:
        bridge = bridge or get_desktop_bridge()
    except Exception:
        return
    store = store or _resolve_store()
    row = store.get_session(session_id) if store is not None else None
    sync_id = _row_repo_sync_id(row) if row else None
    if sync_id is None:
        # No folder-pair info (no row / no sync) — fall back to the legacy id so
        # a pre-existing per-session sync still gets cleaned up.
        sync_id = "sync-" + str(session_id)
    else:
        # Keep the shared sync alive if ANOTHER running session uses the pair.
        try:
            for other in (store.list_sessions(status="running") or []):
                if other.get("id") == session_id:
                    continue
                if _row_repo_sync_id(other) == sync_id:
                    return  # a sibling still needs this sync — leave it running
        except Exception:  # noqa: BLE001
            pass
    sess = bridge.sync_for(sync_id)
    if sess is not None:
        try:
            sess.close()  # sends coding_sync_stop to its device + deregisters
        except Exception:
            pass
        return
    # No live session object (e.g. after a webui restart): still tell whatever
    # desktop is connected to stop it, so a delete cleans up the orphan now.
    try:
        device_id = resolve_desktop_device_id()
        if device_id:
            bridge.send_sync_stop(device_id, sync_id)
    except Exception:
        pass


def _transcript_meta(row) -> dict | None:
    """Pull ``{csid, device_cwd, device}`` from a session row's sync_config, or
    None if the row doesn't carry transcript-reconcile metadata."""
    import json as _json
    raw = (row.get("sync_config") or "").strip() if row else ""
    if not raw:
        return None
    try:
        cfg = _json.loads(raw) or {}
    except Exception:
        return None
    tx = cfg.get("transcript") if isinstance(cfg.get("transcript"), dict) else None
    if not (tx and tx.get("csid") and tx.get("device_cwd")):
        return None
    return {"csid": str(tx["csid"]), "device_cwd": str(tx["device_cwd"]),
            "device": (cfg.get("device") or "").strip()}


def reconcile_session_transcript_async(session_id: str) -> None:
    """Fire-and-forget ``reconcile_session_transcript`` on a daemon thread.

    Used by the STOP route so the request thread returns immediately instead of
    blocking up to ``timeout`` on the device round-trip — a blocked request
    thread also holds an nginx edge connection slot, which under load starves the
    global slot budget and 503s OTHER requests. Nothing depends on the push
    completing synchronously at stop, so it's safe to detach."""
    threading.Thread(
        target=reconcile_session_transcript, args=(session_id,),
        daemon=True, name="tx-reconcile-" + str(session_id)[:8]).start()


def reconcile_session_transcript(session_id: str, *, store=None,
                                 bridge: DesktopBridge | None = None,
                                 timeout: float = 12.0) -> str:
    """ONE-SHOT, newest-wins reconcile of a session's transcript between the
    server and its device.

    Called at session OPEN (resume/restart) and CLOSE (stop) — NEVER during live
    running: two live claude processes would diverge, and a running claude never
    re-reads its transcript anyway. Whichever side has MORE turns (JSONL lines)
    wins; the staler side is overwritten, so neither side's longer history is
    ever clobbered. Returns a short status string; never raises into the caller.

    ``timeout`` bounds the device transcript pull (default 12s, not 30) so a
    slow/flaky device can't pin the caller's thread + an edge slot for long.
    """
    try:
        store = store or _resolve_store()
        bridge = bridge or get_desktop_bridge()
        if store is None:
            return "no-store"
        row = store.get_session(session_id)
        meta = _transcript_meta(row)
        if meta is None:
            return "no-transcript"
        device_id = (row.get("device_id") or "").strip() or meta["device"] \
            or (resolve_desktop_device_id() or "")
        if not device_id:
            return "no-device"
        csid = meta["csid"]
        device_cwd = meta["device_cwd"]
        server_cwd = row.get("cwd") or ""
        from agent.coding_session_capture import (
            claude_projects_dir, encode_project_dir)

        server_path = (claude_projects_dir() / encode_project_dir(server_cwd)
                       / f"{csid}.jsonl")
        try:
            server_bytes = server_path.read_bytes()
        except OSError:
            server_bytes = b""
        try:
            device_bytes = bridge.request_transcript(
                device_id, claude_session_id=csid, cwd=device_cwd, timeout=timeout)
        except Exception:  # noqa: BLE001
            device_bytes = None
        s_lines = server_bytes.count(b"\n")
        # device offline/failed -> -1 so a non-empty server still pushes out
        d_lines = device_bytes.count(b"\n") if device_bytes is not None else -1
        if d_lines > s_lines:
            try:
                server_path.parent.mkdir(parents=True, exist_ok=True)
                server_path.write_bytes(device_bytes)
                return f"pulled device->server ({d_lines}>{s_lines})"
            except Exception as exc:  # noqa: BLE001
                return f"pull-write-failed: {exc}"
        if s_lines > d_lines:
            ok = bridge.push_transcript(device_id, claude_session_id=csid,
                                        cwd=device_cwd, raw=server_bytes)
            return f"pushed server->device ({s_lines}>{d_lines}) ok={ok}"
        return f"in-sync ({s_lines} lines)"
    except Exception as exc:  # noqa: BLE001
        log.debug("reconcile_session_transcript[%s] failed: %s", session_id, exc)
        return f"error: {exc}"


def sync_status(session_id: str, sync_config=None, cwd: str | None = None) -> dict:
    """Sync status for the WebUI: device, online/offline, status, progress.

    ``status`` is one of: off | disconnected | idle | opening | syncing | synced
    | error. ``total``/``done`` drive the progress bar while ``syncing``.

    ``cwd`` (the session's server cwd) lets us resolve the shared FOLDER-PAIR
    sync (``repo_sync_id``); without it we fall back to the legacy per-session id.
    """
    import json as _json

    out = {"enabled": False, "device": None, "device_online": False,
           "status": "off", "direction": None, "total": 0, "done": 0,
           "conflicts": 0, "healed": 0, "last_sync_at": None, "error": None}
    cfg = {}
    if sync_config:
        try:
            cfg = (_json.loads(sync_config) if isinstance(sync_config, str)
                   else dict(sync_config))
        except Exception:
            cfg = {}
    if not cfg.get("enabled"):
        return out
    out["enabled"] = True
    out["device"] = cfg.get("device")
    out["device_online"] = bool(resolve_desktop_device_id(preferred=cfg.get("device")))
    sid = None
    if cwd:
        sid = _row_repo_sync_id({"cwd": cwd, "device_id": ""}, sync_config=cfg)
    try:
        bridge = get_desktop_bridge()
        sess = bridge.sync_for(sid) if sid else None
        if sess is None:  # legacy fallback (pre folder-pair keying)
            sess = bridge.sync_for("sync-" + session_id)
    except Exception:
        sess = None
    # Surface last-known progress/direction from any session object we have, but
    # the STATUS must reflect device liveness first: if the desktop client is
    # gone, a left-over session still holding status="syncing" is stale — report
    # "disconnected" (not a frozen "Syncing…") so the panel says offline and the
    # next reconnect/Refresh re-reconciles.
    if sess is not None:
        # Self-heal a sync stuck waiting for the manifest (lost handshake): the
        # WebUI polls this every few seconds, so this re-opens within ~45s.
        if out["device_online"]:
            try:
                sess.reopen_if_stale()
            except Exception:
                pass
        out["direction"] = getattr(sess, "direction", None)
        out["total"] = int(getattr(sess, "total", 0) or 0)
        out["done"] = int(getattr(sess, "done", 0) or 0)
        out["conflicts"] = int(getattr(sess, "conflicts", 0) or 0)
        out["healed"] = int(getattr(sess, "healed", 0) or 0)
        out["last_sync_at"] = getattr(sess, "last_sync_at", None)
        out["error"] = getattr(sess, "error", None)
    if not out["device_online"]:
        out["status"] = "disconnected"
    elif sess is not None:
        out["status"] = getattr(sess, "status", "syncing") or "syncing"
    else:
        # configured, device online, but no live sync session yet
        out["status"] = "idle"
    return out


def _resolve_store():
    """The process-wide CodingSessionStore (via the cached server manager).

    Kept lazy + defensive so importing this module never drags in the manager /
    SQLite layer; resync_device falls back to None if the store is unavailable.
    """
    try:
        from api.coding_routes import default_manager

        return default_manager("server").store
    except Exception:
        try:
            from agent.coding_session_db import CodingSessionStore

            return CodingSessionStore()
        except Exception:
            return None


# ── discovered (device-side) coding-session ingest ───────────────────────────
#
# A desktop device periodically scans its live ``claude`` tmux sessions AND its
# ``~/.claude`` transcript history, and pushes a ``coding_discover`` frame listing
# both. Two item kinds arrive in the same frame's ``sessions`` list:
#
#   {kind:'tmux',       tmux_name, cwd, title, last_activity}
#       -> a LIVE, drivable claude tmux session. Upserted host='desktop',
#          external=1, source='discovered-tmux', status='running', keyed by
#          (device_id, tmux_name). Vanished tmux rows reconcile to 'stopped'.
#
#   {kind:'transcript', claude_session_id, cwd, summary, last_activity, live}
#       -> a claude SESSION HISTORY (resumable via ``claude --resume``). Upserted
#          host='desktop', external=1, source='discovered-transcript', keyed by
#          (device_id, claude_session_id). status='running' when ``live`` else
#          'idle' (idle = resumable history). Transcript rows are HISTORY: they
#          are NEVER stopped/deleted when absent from a push (a user may prune
#          ~/.claude). The tmux reconcile (mark-absent-stopped) is scoped to
#          discovered-tmux rows ONLY and must not touch transcript rows.
#
# Both group under an auto-created project keyed by (cwd, device_id).
#
# Dedup: a live tmux item and a transcript item can describe the SAME underlying
# session (same cwd; the transcript carrying the claude_session_id the tmux is
# running). We prefer the DRIVABLE tmux row and SKIP a transcript with live=true
# whose cwd already has a discovered-tmux row in THIS batch — so we don't create a
# confusing idle/running duplicate of a session the user can already drive.
#
# Per-device tombstones: when a user deletes a discovered session we record its
# key here so the next push doesn't resurrect it. tmux items are tombstoned by
# tmux_name; transcript items by claude_session_id. The delete path calls
# ``dismiss_discovered`` (exposed for that wiring).
_DISMISSED_DISCOVERED: dict[str, set] = {}

# Last captured pane tail for a WAITING discovered session, keyed
# (device_id, tmux_name). The device only ships the tail while a prompt is
# live; GET /api/coding/session/<id>/prompt parses options out of it for the
# mobile chat view's "needs input" modal. In-memory on purpose: it is a live
# snapshot, meaningless across a restart.
_WAITING_TAILS: dict[tuple, str] = {}


def get_waiting_tail(row) -> str | None:
    """The live waiting-prompt pane tail for a discovered session row."""
    return _WAITING_TAILS.get(((row.get("device_id") or "").strip(),
                               (row.get("tmux_name") or "").strip()))


# Live spinner/status line ("✳ Zesting… (50s · ↑ 2.0k tokens)") per WORKING
# discovered session, shipped by the device scan — the chat view's thinking
# bubble shows it instead of a generic "Working…". In-memory: live snapshot.
_STATUS_LINES: dict[tuple, str] = {}


def get_status_line(row) -> str | None:
    """The live working status line for a discovered session row."""
    return _STATUS_LINES.get(((row.get("device_id") or "").strip(),
                              (row.get("tmux_name") or "").strip()))


# Transcript-cache invalidation for realtime chat. A csid is "dirty" when an
# activity transition / turn boundary means the Mac transcript almost certainly
# has new content the cached parse predates — the /messages handler re-pulls
# immediately for a dirty csid instead of waiting out the staleness floor.
_DIRTY_CSIDS: set[str] = set()
_DIRTY_LOCK = threading.Lock()


def mark_transcript_dirty(csid) -> None:
    """Flag a session's cached transcript as stale (call on turn boundaries)."""
    c = str(csid or "").strip()
    if not c:
        return
    with _DIRTY_LOCK:
        _DIRTY_CSIDS.add(c)


def take_transcript_dirty(csid) -> bool:
    """Consume + clear the dirty flag for a csid (True if it was dirty)."""
    c = str(csid or "").strip()
    if not c:
        return False
    with _DIRTY_LOCK:
        if c in _DIRTY_CSIDS:
            _DIRTY_CSIDS.discard(c)
            return True
    return False


# Reconnect debounce. A desktop WS drop is USUALLY a brief relay blip, not a
# real disconnect — so we RETAIN each session's last-known activity_state and
# only escalate to "gone" (null the state) if the device hasn't sent a fresh
# discovery frame within the grace window. This kills the visible
# active→disconnected→working flap on Mac sessions.
_RECONNECT_GRACE = 12.0
_RECONNECTING: dict[str, int] = {}   # device_id -> generation of pending drop
_RECONNECT_LOCK = threading.Lock()


def note_device_reconnect(device_id) -> None:
    """A live frame/connection from a device cancels any pending 'gone'
    escalation (the scheduled timer sees a stale generation and no-ops)."""
    d = str(device_id or "").strip()
    if not d:
        return
    with _RECONNECT_LOCK:
        if d in _RECONNECTING:
            _RECONNECTING.pop(d, None)


def _escalate_device_gone(device_id: str, gen: int) -> None:
    """Grace elapsed with no reconnect — NOW clear the live activity_state of
    this device's discovered sessions so the UIs stop showing a ghost
    working/waiting. The lifecycle ``status`` is left untouched (the next
    discovery push on reconnect reconciles it)."""
    with _RECONNECT_LOCK:
        if _RECONNECTING.get(device_id) != gen:
            return  # reconnected (or superseded) within grace — no flap
        _RECONNECTING.pop(device_id, None)
    try:
        store = _resolve_store()
        if store is None:
            return
        changed = False
        for row in store.list_sessions(device_id=device_id):
            if (row.get("source") == "discovered-tmux"
                    and row.get("activity_state") is not None):
                store.update_session(row["id"], activity_state=None)
                changed = True
        if changed:
            _push_la_and_notify(store)
    except Exception:  # noqa: BLE001
        pass


_DISMISSED_LOCK = threading.Lock()


def dismiss_discovered(device_id: str, key: str) -> None:
    """Tombstone a (device_id, key) so ``ingest_discovered`` won't recreate it on
    the next push (called from the delete / stop / resume-retire paths). ``key`` is
    the tmux_name for a discovered-tmux row, or the claude_session_id for a
    discovered-transcript row."""
    if not device_id or not key:
        return
    with _DISMISSED_LOCK:
        _DISMISSED_DISCOVERED.setdefault(str(device_id), set()).add(str(key))


def clear_dismissed(device_id: str = "") -> None:
    """Drop tombstones so dismissed/stopped discovered sessions can be re-found.
    The Rescan button calls this (for the device) — the recovery path after a Stop
    or Resume hid a discovered session the user now wants back."""
    with _DISMISSED_LOCK:
        if device_id:
            _DISMISSED_DISCOVERED.pop(str(device_id), None)
        else:
            _DISMISSED_DISCOVERED.clear()


def _is_dismissed(device_id: str, key: str) -> bool:
    with _DISMISSED_LOCK:
        return str(key) in _DISMISSED_DISCOVERED.get(str(device_id), set())


def _push_la_and_notify(store) -> None:
    """Best-effort INSTANT fan-out after a discovery ingest changed a live state:
    rebuild + APNs-push the coding Live Activity and nudge the WebUI SSE so the
    Dynamic Island / browser reflect a Mac session going working/idle/stopped (or
    a freshly-relaunched session appearing) immediately, instead of waiting up to
    the next 4s status-loop tick. Deduped + a no-op when APNs/tokens are absent."""
    try:
        from agent.coding_la_push import push_coding_update
        from agent.coding_usage import get_usage
        push_coding_update(store, usage=get_usage(store))
    except Exception:  # noqa: BLE001 — never let a push failure break ingest
        pass
    try:
        from api import coding_events
        coding_events.notify()
    except Exception:  # noqa: BLE001
        pass


def ingest_discovered(device_id: str, sessions: list, *, store=None) -> int:
    """Upsert a desktop device's discovered ``claude`` sessions and reconcile.

    The push carries two item kinds in ``sessions`` (see the module header):

    ``{kind:'tmux', tmux_name, cwd, title, last_activity}`` -> a LIVE tmux:
      * group under a project auto-created for its cwd (per (cwd, device_id)),
      * upsert a row matched by (device_id, tmux_name) with source
        'discovered-tmux', external=1, status='running'.
      Any discovered-tmux row NOT in this push is reconciled to 'stopped' (kept
      for history).

    ``{kind:'transcript', claude_session_id, cwd, summary, last_activity, live}``
    -> a resumable HISTORY:
      * group under the same per-(cwd, device_id) project,
      * upsert a row matched by (device_id, claude_session_id) with source
        'discovered-transcript', external=1, status='running' if ``live`` else
        'idle'.
      Transcript rows are HISTORY: they are NEVER stopped/deleted when absent
      from a push (the user may prune ~/.claude). The tmux 'stopped' reconcile is
      scoped to discovered-tmux rows ONLY — it never touches transcript rows.

    Dedup: a transcript with ``live=true`` whose cwd already has a discovered-tmux
    row IN THIS BATCH is SKIPPED — we keep the drivable tmux row and avoid a
    duplicate idle/running view of a session the user can already drive.

    Dismissed (user-deleted) keys are skipped so they're not resurrected:
    tmux items by tmux_name, transcript items by claude_session_id.

    Never raises — logs and continues on per-item errors. Returns the number of
    rows upserted (created or updated)."""
    store = store or _resolve_store()
    if store is None:
        return 0
    # A discovery frame means the device is alive — cancel any pending "gone"
    # escalation from a recent WS blip (keeps a brief reconnect from flapping).
    note_device_reconnect(device_id)
    sessions = sessions or []

    # SAFEGUARD: never DISCOVER a claude session running in a home/system directory
    # (e.g. a `claude` launched from $HOME). Such a session isn't a project — it
    # auto-created a bogus "pranavkrishna" project that resurrected on every 5s push
    # no matter how often the user deleted it, and (pre-fix) auto-synced the whole
    # home dir. Filtering it here keeps it out of the UI/project tree entirely.
    try:
        from agent.coding_sync_safety import is_dangerous_path as _dangerous_cwd
    except Exception:  # noqa: BLE001
        _dangerous_cwd = lambda _p: False  # noqa: E731

    # Default a DISCOVERED session's project to sync-ON with the device cwd as the
    # desktop path — so the UI shows sync on by default and the server has a mirror
    # target for resume-to-server. Only set on CREATE (never clobber a user's later
    # toggle): pre-scan existing (repo_path, device_id) keys; a project already in
    # this set keeps whatever sync settings it has.
    existing_project_keys: set = set()
    # Repo paths of IGNORED (soft-deleted) projects — discovery must NOT resurrect
    # a session whose folder belongs to one the user deleted/ignored.
    ignored_cwds: set = set()
    try:
        for _p in store.list_projects():
            existing_project_keys.add(
                (_p.get("repo_path"), (_p.get("device_id") or "")))
            if _p.get("ignored"):
                ignored_cwds.add(_p.get("repo_path"))
    except Exception:  # noqa: BLE001 — never block ingest on project bookkeeping
        existing_project_keys = set()
        ignored_cwds = set()

    def _project_for_discovered_cwd(cwd: str) -> str:
        pid = store.get_or_create_project_for_path(
            repo_path=cwd, host="desktop", device_id=device_id)
        key = (cwd, device_id or "")
        if key not in existing_project_keys:
            existing_project_keys.add(key)  # don't re-set within this batch
            try:
                store.update_project(pid, sync_enabled=True,
                                     sync_desktop_path=cwd)
            except Exception:  # noqa: BLE001
                pass
        return pid

    # Existing discovered rows for this device. tmux rows indexed by tmux_name,
    # transcript rows by claude_session_id. We only ever touch rows this ingest
    # owns (external + source startswith 'discovered-') so Jarvis-launched
    # sessions are never disturbed. The two scopes are kept separate so the tmux
    # 'stopped' reconcile can't reach a transcript history row.
    existing_tmux: dict = {}
    existing_transcript: dict = {}
    try:
        for row in store.list_sessions(device_id=device_id):
            src = (row.get("source") or "")
            if not row.get("external"):
                continue
            if src.startswith("discovered-tmux"):
                name = row.get("tmux_name")
                if name:
                    existing_tmux[name] = row
            elif src.startswith("discovered-transcript"):
                csid = row.get("claude_session_id")
                if csid:
                    existing_transcript[csid] = row
    except Exception as exc:  # noqa: BLE001
        log.warning("coding_discover[%s]: list_sessions failed: %s",
                    device_id, exc)
        existing_tmux = {}
        existing_transcript = {}

    seen_tmux: set = set()
    # cwds that have a LIVE tmux item in THIS batch — a transcript with live=true
    # under one of these is the same drivable session, so we skip it (dedup).
    live_tmux_cwds: set = set()
    # claude_session_ids already owned by a discovered-TMUX row (a live tmux the
    # device reports together with its claude session id). The desktop may keep
    # listing that same csid as a transcript history item — possibly live=false —
    # so we MUST dedup it against the drivable tmux row by csid (cwd-only dedup is
    # both too narrow — it misses idle re-reports — and brittle to cwd drift).
    # Seed from pre-existing discovered-tmux rows; rows created in THIS batch are
    # added as we go.
    tmux_owned_csids: set = {
        (r.get("claude_session_id") or "").strip()
        for r in existing_tmux.values()
        if (r.get("claude_session_id") or "").strip()
    }
    upserted = 0
    # Did this ingest change a LIVE state (new/revived/stopped tmux row, or an
    # activity_state transition)? If so we fan out an instant LA/WebUI push at the
    # end so the Dynamic Island / browser don't lag the Mac by up to 4s.
    live_changed = False

    # First pass over tmux items so live_tmux_cwds is fully populated before any
    # transcript dedup decision (push order is not guaranteed).
    for sess in sessions:
        try:
            if not isinstance(sess, dict):
                continue
            if (sess.get("kind") or "tmux") != "tmux":
                continue
            tmux_name = (sess.get("tmux_name") or "").strip()
            if not tmux_name:
                continue
            cwd = sess.get("cwd") or ""
            if _dangerous_cwd(cwd):
                continue  # a claude in $HOME/system dir is not a project — skip
            if cwd in ignored_cwds:
                continue  # the user ignored/deleted this project — don't resurrect
            # NORMALIZED like the client's _norm_cwd: the transcript pass dedups
            # live transcripts against this set, and the client computed `live`
            # with normalized cwds — a trailing-slash mismatch would mint a
            # duplicate "running" transcript row that no poller ever clears.
            live_tmux_cwds.add(cwd.strip().rstrip("/") or cwd)
            if _is_dismissed(device_id, tmux_name):
                # User deleted this one — don't resurrect it.
                continue
            seen_tmux.add(tmux_name)
            title = sess.get("title") or tmux_name
            last_activity = sess.get("last_activity")
            # The cwd's newest transcript id (added by the device so an OFFLINE
            # Mac session can still be resumed on the server). Owning it here also
            # lets the transcript pass dedup the live-transcript copy of it.
            csid = (sess.get("claude_session_id") or "").strip()
            # Live working/waiting/idle classified Mac-side (None = capture
            # failed / old client → leave any known state unchanged, don't wipe).
            act = sess.get("activity_state")
            tail = sess.get("pane_tail")
            if act == "waiting" and isinstance(tail, str) and tail.strip():
                _WAITING_TAILS[(device_id, tmux_name)] = tail[-2000:]
            elif act in ("working", "idle"):
                _WAITING_TAILS.pop((device_id, tmux_name), None)
            sline = sess.get("status_line")
            if act == "working" and isinstance(sline, str) and sline.strip():
                _STATUS_LINES[(device_id, tmux_name)] = sline.strip()[:160]
            elif act in ("waiting", "idle"):
                _STATUS_LINES.pop((device_id, tmux_name), None)
            pid = _project_for_discovered_cwd(cwd)
            row = existing_tmux.get(tmux_name)
            if row is not None:
                # Reparent to the (possibly new) cwd's project AND move the row's
                # own cwd with it — a tmux session can be re-created under the
                # same name in a different folder; leaving the stale cwd would
                # split the row from its project's repo_path. Only apply
                # last_activity_at when the device actually reported one, so a
                # push that omits it doesn't wipe a previously-known value.
                fields = dict(status="running", title=title, cwd=cwd,
                              project_id=pid, external=1)
                if last_activity is not None:
                    fields["last_activity_at"] = last_activity
                if csid:  # never wipe a known csid with an empty re-report
                    fields["claude_session_id"] = csid
                if act is not None:
                    fields["activity_state"] = act
                    if act != (row.get("activity_state") or None):
                        live_changed = True
                        # Turn boundary → the Mac transcript likely grew; let
                        # the next chat poll re-pull instead of waiting it out.
                        mark_transcript_dirty(csid)
                elif (row.get("cwd") or "") != cwd:
                    # Reparented (same tmux name re-created in a new folder)
                    # with no fresh classification: the old folder's state
                    # (e.g. "waiting") must not show up under the new project.
                    fields["activity_state"] = None
                if (row.get("status") or "") != "running":
                    live_changed = True  # a stopped/errored row came back to life
                store.update_session(row["id"], **fields)
            else:
                sid = store.create_session(
                    project_id=pid, host="desktop", cwd=cwd, branch=None,
                    tmux_name=tmux_name, source="discovered-tmux", title=title,
                    device_id=device_id, external=True, status="running",
                    claude_session_id=csid or None)
                if last_activity is not None:
                    # create_session doesn't accept last_activity_at — set it now.
                    store.update_session(sid, last_activity_at=last_activity)
                if act is not None:
                    store.update_session(sid, activity_state=act)
                live_changed = True  # a brand-new live session appeared
                mark_transcript_dirty(csid)
            if csid:
                tmux_owned_csids.add(csid)  # so the transcript pass dedups it
            upserted += 1
        except Exception as exc:  # noqa: BLE001
            log.warning("coding_discover[%s]: skipped a tmux session: %s",
                        device_id, exc)
            continue

    # Second pass: transcript (resumable history) items.
    for sess in sessions:
        try:
            if not isinstance(sess, dict):
                continue
            if sess.get("kind") != "transcript":
                continue
            csid = (sess.get("claude_session_id") or "").strip()
            if not csid:
                continue
            if _is_dismissed(device_id, csid):
                # User deleted this one — don't resurrect it.
                continue
            cwd = sess.get("cwd") or ""
            if _dangerous_cwd(cwd):
                continue  # a transcript from $HOME/system dir is not a project
            if cwd in ignored_cwds:
                continue  # the user ignored/deleted this project — don't resurrect
            live = bool(sess.get("live"))
            # Dedup (A): this transcript's claude_session_id is already owned by a
            # discovered-TMUX row (a live tmux the device reports with its csid).
            # The desktop still lists that csid as transcript history (possibly
            # live=false), so skip it to avoid a duplicate idle/running "history"
            # copy of a session the user is already driving. Keyed on csid
            # (robust), independent of cwd/live.
            if csid in tmux_owned_csids:
                continue
            # Dedup (B): a LIVE transcript whose cwd already has a tmux item this
            # batch is the same drivable session — prefer the tmux row, skip this.
            if live and (cwd.strip().rstrip("/") or cwd) in live_tmux_cwds:
                continue
            from pathlib import Path as _P
            title = sess.get("summary") or (_P(cwd).name if cwd else "") or csid
            last_activity = sess.get("last_activity")
            status = "running" if live else "idle"
            pid = _project_for_discovered_cwd(cwd)
            row = existing_transcript.get(csid)
            if row is not None:
                # activity_state=None: transcript rows are HISTORY — no poller
                # ever classifies them, so any state a mis-matched hook once
                # wrote (e.g. "waiting") would otherwise stick forever.
                fields = dict(status=status, title=title, cwd=cwd,
                              project_id=pid, external=1, activity_state=None)
                if last_activity is not None:
                    fields["last_activity_at"] = last_activity
                store.update_session(row["id"], **fields)
            else:
                sid = store.create_session(
                    project_id=pid, host="desktop", cwd=cwd, branch=None,
                    tmux_name=None, source="discovered-transcript", title=title,
                    device_id=device_id, external=True, status=status,
                    claude_session_id=csid)
                if last_activity is not None:
                    store.update_session(sid, last_activity_at=last_activity)
            upserted += 1
        except Exception as exc:  # noqa: BLE001
            log.warning("coding_discover[%s]: skipped a transcript: %s",
                        device_id, exc)
            continue

    # Reconcile: any discovered-TMUX row we own that wasn't in this push has
    # vanished from the device — mark it stopped (keep the row for history).
    # NOTE: transcript rows are deliberately NOT reconciled here — they're
    # persistent history and must survive being absent from a push.
    for name, row in existing_tmux.items():
        if name in seen_tmux:
            continue
        try:
            if (row.get("status") or "") != "stopped":
                store.update_session(row["id"], status="stopped")
                live_changed = True
        except Exception as exc:  # noqa: BLE001
            log.warning("coding_discover[%s]: reconcile stop failed for %s: %s",
                        device_id, name, exc)
    if live_changed:
        _push_la_and_notify(store)
    return upserted


def resume_discovered_to_server(session_id: str, *, manager,
                                bridge: DesktopBridge | None = None,
                                store=None) -> dict:
    """Resume a DISCOVERED (Mac) session as a brand-new session ON THE SERVER.

    The discovered session's conversation lives only on the user's Mac (its
    ``<csid>.jsonl`` transcript under the Mac's ``~/.claude``). To continue it on
    the Jarvis server (never on the Mac), we:

      1. Load the row; require a DISCOVERED source with a ``claude_session_id``
         (else ``ValueError``). Read ``device_cwd = row['cwd']`` and the row's
         ``device_id`` (falling back to a resolved connected desktop).
      2. Mirror dir ``server_cwd = <SERVER_PROJECTS_ROOT>/<basename(device_cwd)>``
         and ``os.makedirs`` it.
      3. Pull the transcript bytes from the device over the bridge
         (``request_transcript``) and write them to the SERVER's
         ``claude_projects_dir()/encode_project_dir(server_cwd)/<csid>.jsonl`` so
         ``claude --resume <csid>`` (run in ``server_cwd``) finds them. If the
         pull fails we continue anyway and surface a soft ``warning`` — resume can
         still partially work / the user can re-message.
      4. Launch on the SERVER via ``manager`` (a host='server' LocalDriver
         manager): ``claude --resume <csid>`` in ``server_cwd``, with sync ON
         (server_cwd <-> device_cwd) and in the SAME project as the discovered
         row (``project_id`` threaded through). The manager's own ``sync_starter``
         opens the Mutagen sync against the device for the NEW session id, and the
         launch gets the per-session ``.mcp.json`` (venv-python MCP) for free.
      5. Retire the old discovered row: mark it ``stopped`` AND tombstone its csid
         so the next discovery push doesn't resurrect it as a dup of the new
         server session. The server session is now the live one.

    Returns ``{"ok": True, "session": <new server row>, "warning": <opt>}``.

    Raises ``KeyError`` if ``session_id`` is unknown, ``ValueError`` if the row
    isn't a resumable discovered session, ``RuntimeError`` if the store is
    unavailable.
    """
    bridge = bridge or get_desktop_bridge()
    store = store or _resolve_store()
    if store is None:
        raise RuntimeError("coding session store unavailable")

    # 1. load + validate the discovered row
    row = store.get_session(session_id)
    if row is None:
        raise KeyError(session_id)
    if not (row.get("source") or "").startswith("discovered"):
        raise ValueError("only discovered sessions can be resumed to the server")
    claude_session_id = (row.get("claude_session_id") or "").strip()
    if not claude_session_id:
        raise ValueError("session has no claude_session_id to resume")
    device_cwd = row.get("cwd") or ""
    device_id = (row.get("device_id") or "").strip() \
        or (resolve_desktop_device_id() or "")
    if not device_id:
        raise ValueError("no desktop device connected to resume from")

    # 2. server-side mirror dir
    base = os.path.basename(os.path.normpath(device_cwd)) if device_cwd else ""
    server_cwd = os.path.join(_server_projects_root(), base or claude_session_id)
    os.makedirs(server_cwd, exist_ok=True)

    # 2b. IDEMPOTENCY: if a server session for this transcript already exists (a
    # prior resume, or one resurrected because the Mac's discovered row keeps being
    # re-pushed), REUSE it instead of launching another. Without this, every
    # resume click/re-trigger spawned a brand-new "hello" server session — the
    # runaway duplication the user hit. Match by the resumed conversation (claude
    # session id, incl. the one recorded in sync_config.transcript) or, as a
    # deterministic fallback, the server mirror cwd.
    existing = _existing_server_resume(store, claude_session_id,
                                       device_cwd=device_cwd)
    if existing is not None:
        # retire the discovered origin so it stops offering "resume" for a session
        # that already lives on the server.
        _retire_discovered_origin(store, session_id, device_id, claude_session_id)
        return {"ok": True, "session": existing, "reused": True}

    # 3. pull the transcript from the device + write it where claude --resume looks
    warning = None
    data = None
    try:
        data = bridge.request_transcript(
            device_id, claude_session_id=claude_session_id,
            cwd=device_cwd, timeout=30)
    except Exception as exc:  # noqa: BLE001 — never fail the resume on a pull error
        warning = f"transcript fetch raised: {exc}"
        data = None
    # NOTE: ``data is not None`` (not ``if data``) — request_transcript returns
    # ``b""`` for a VALID-but-empty transcript and ``None`` only on a real failure
    # (timeout / offline / device error / corrupt stream). Treating the empty
    # round-trip as a failure would surface a misleading warning and skip the
    # write, so distinguish them explicitly.
    if data is not None:
        try:
            from agent.coding_session_capture import (
                claude_projects_dir, encode_project_dir)

            dest = (claude_projects_dir() / encode_project_dir(server_cwd)
                    / f"{claude_session_id}.jsonl")
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
        except Exception as exc:  # noqa: BLE001
            warning = f"could not write transcript on the server: {exc}"
    elif warning is None:
        warning = ("could not fetch the session transcript from the device; "
                   "resuming with whatever Claude can recover locally")

    # 4. launch on the SERVER with --resume + sync ON (server_cwd <-> device_cwd).
    #    Passing ``sync`` makes the manager's sync_starter open the Mutagen sync
    #    for the NEW session id, so no separate start call is needed.
    sync = {"enabled": True, "device": device_id, "remote_path": device_cwd,
            # Metadata for the OPEN/CLOSE-only transcript reconcile (NOT a live
            # sync): names the csid + the Mac's cwd so reconcile_session_transcript
            # can pull/push <csid>.jsonl at resume/restart/stop. Persisted in
            # sync_config so it survives across reconnects.
            "transcript": {"csid": claude_session_id, "device_cwd": device_cwd}}
    # Keep the resumed server session grouped with its discovered origin: thread
    # the old row's project_id through so it lands in the SAME project (which was
    # auto-created for this cwd/device and already defaults sync-ON), instead of
    # spawning a separate server-only project for the mirror checkout.
    new = manager.launch(
        cwd=server_cwd, title=row.get("title"), initial_prompt=None, model=None,
        project_id=row.get("project_id"), resume_session_id=claude_session_id,
        sync=sync)

    # 5. retire the old discovered row (stopped + tombstoned so it can't dup).
    _retire_discovered_origin(store, session_id, device_id, claude_session_id)

    out = {"ok": True, "session": new}
    if warning:
        out["warning"] = warning
    return out


def _existing_server_resume(store, claude_session_id: str, device_cwd: str = ""):
    """A running/starting server session that already represents THIS resumed
    origin, or None — so a repeated "Resume on server" REUSES it instead of
    spawning another dead/dup session.

    Primary key is the STABLE ``device_cwd`` (the Mac folder this resume mirrors,
    stored in sync_config.transcript.device_cwd): one server session per Mac
    folder. This survives csid churn — a discovered-tmux row's claude_session_id
    is stamped with the cwd's NEWEST transcript uuid, which changes every time the
    user re-runs claude there, so a csid-only key missed the twin and launched a
    new session every click (the runaway loop). The csid (column OR
    transcript.csid) is kept as a fast path. We no longer fall back to the SERVER
    cwd (two Mac folders sharing a basename collapse to one server cwd)."""
    import json as _json
    csid = (claude_session_id or "").strip()
    dcwd = (device_cwd or "").strip()
    if not csid and not dcwd:
        return None
    try:
        rows = store.list_sessions() or []
    except Exception:  # noqa: BLE001
        return None
    for s in rows:
        if (s.get("host") or "server") != "server":
            continue
        if (s.get("status") or "") not in ("running", "starting", "idle"):
            continue
        if csid and (s.get("claude_session_id") or "") == csid:
            return s
        raw = (s.get("sync_config") or "").strip()
        if not raw:
            continue
        try:
            tr = (_json.loads(raw) or {}).get("transcript") or {}
        except Exception:  # noqa: BLE001
            continue
        if csid and (tr.get("csid") or "") == csid:
            return s
        if dcwd and (tr.get("device_cwd") or "") == dcwd:
            return s  # STABLE key — survives csid churn
    return None


def _retire_discovered_origin(store, session_id, device_id, claude_session_id) -> None:
    """Mark the discovered row stopped + tombstone BOTH its csid (transcript) AND
    its tmux_name (live tmux) so neither a transcript re-push nor the still-alive
    Mac tmux can resurrect it once it has been resumed to the server. Without the
    tmux_name tombstone the discovered origin reappears every 5s and the user sees
    the discovered session AND the new server session (the confusing dup). Recovery:
    the Rescan button clears tombstones."""
    tmux_name = ""
    try:
        row = store.get_session(session_id)
        if row:
            tmux_name = (row.get("tmux_name") or "").strip()
    except Exception:  # noqa: BLE001
        pass
    try:
        store.update_session(session_id, status="stopped")
    except Exception:  # noqa: BLE001
        pass
    for ident in (claude_session_id, tmux_name):
        if ident:
            try:
                dismiss_discovered(device_id, ident)
            except Exception:  # noqa: BLE001
                pass


def adopt_discovered_tmux(session_id: str, *, bridge: DesktopBridge | None = None,
                          store=None, rows: int = 24, cols: int = 80) -> dict:
    """ATTACH web/phone to a discovered LIVE Mac ``claude`` tmux session — ONE
    process, perfectly in sync (no fork, unlike resume-to-server).

    Tells the desktop to open a PTY that ``tmux attach-session``-attaches to the
    user's already-running tmux, then wires a :class:`DesktopTerminalFeed` so the
    existing ``/api/terminal/*`` SSE/input/resize routes stream it. The attach is
    a SEPARATE tmux client (not ``-d``), so the Mac's own terminal stays attached
    too; ``window-size latest`` makes the pane follow the most-recent client so a
    small phone viewport doesn't shrink the Mac's view.

    Returns ``{"ok": True, "running": bool}`` on success, or
    ``{"ok": False, "offline": True}`` when no desktop client is connected (the
    caller should offer resume-to-server instead). Never raises.
    """
    bridge = bridge or get_desktop_bridge()
    store = store or _resolve_store()
    if store is None:
        return {"ok": False, "error": "store unavailable"}
    row = store.get_session(session_id)
    if row is None:
        raise KeyError(session_id)
    if not (row.get("source") or "").startswith("discovered"):
        raise ValueError("only discovered sessions can be adopted")
    tmux_name = (row.get("tmux_name") or "").strip()
    if not tmux_name:
        raise ValueError("session has no tmux session to attach to")
    device_id = (row.get("device_id") or "").strip() \
        or (resolve_desktop_device_id() or "")
    if not device_id:
        return {"ok": False, "offline": True}
    term_id = tmux_name
    cwd = row.get("cwd") or ""
    # `attach-session` attaches to the user's EXISTING tmux. NOT `-D`, so the Mac's
    # own terminal stays attached (co-viewing). The chained `; set-option -g
    # window-size latest` sizes the pane to the most-recently-active client, so a
    # small phone viewport doesn't shrink the Mac's view. The `;` is a literal
    # argv element — tmux's command separator (the desktop execs argv directly, no
    # shell). We deliberately do NOT use `new-session -A` (attach-OR-create): once
    # the user quits claude and the tmux session is gone, `-A` would silently spawn
    # an EMPTY shell and mask that the session ended; plain `attach-session` exits
    # non-zero ("can't find session") which the client reports as coding_term_exit,
    # letting us surface a clean "ended" state + offer relaunch.
    # `=name` = tmux EXACT-match target: the Mac's session names are numeric, and
    # a bare numeric target can fuzzy-resolve (window index / name prefix) to a
    # DIFFERENT session — attaching the user's phone to the wrong claude.
    argv = ["tmux", "attach-session", "-t", f"={tmux_name}",
            ";", "set-option", "-g", "window-size", "latest"]
    ok = bridge.send_term_open(device_id, term_id=term_id, cwd=cwd, argv=argv, env={})
    if not ok:
        return {"ok": False, "offline": True}
    feed = bridge.attach_feed(session_id=session_id, device_id=device_id,
                              term_id=term_id, rows=rows, cols=cols,
                              detach_closes_term=True, fresh=True)
    return {"ok": True, "running": feed.is_alive()}


def _session_is_synced(session: dict) -> bool:
    """A session participates in file sync if it's a desktop host OR it carries a
    non-empty ``sync_config`` (the persisted launch ``sync`` dict)."""
    if (session.get("host") or "").lower() == "desktop":
        return True
    return bool((session.get("sync_config") or "").strip())


def resync_device(device_id: str, *, store=None,
                  bridge: DesktopBridge | None = None) -> int:
    """Re-open the file sync for every still-running synced session on reconnect.

    Called (best-effort, off-thread) when a desktop device registers/reconnects.
    For each running coding session that is host='desktop' or carries a
    ``sync_config``, we re-open a :class:`DesktopSyncSession` against ``device_id``
    — which re-sends ``coding_sync_open`` so the desktop replies with its current
    manifest and the manifest-diff reconcile inherently re-checks whether any
    files need re-syncing. Re-opening reuses the deterministic ``sync-<session_id>``
    id, so a prior session object for the same id is simply replaced.

    Returns the number of sessions re-opened. Never raises.
    """
    if not device_id:
        return 0
    store = store or _resolve_store()
    if store is None:
        return 0
    bridge = bridge or get_desktop_bridge()
    try:
        running = store.list_sessions(status="running")
    except Exception:
        return 0

    import json as _json

    reopened = 0
    active_sync_ids = []  # the authoritative set the desktop should be running
    for session in running:
        try:
            if not _session_is_synced(session):
                continue
            sync = None
            raw = (session.get("sync_config") or "").strip()
            if raw:
                try:
                    parsed = _json.loads(raw)
                    if isinstance(parsed, dict):
                        sync = parsed
                except Exception:
                    sync = None
            # SAFEGUARD: a session syncs ONLY when it carries an EXPLICIT sync
            # config. We used to synthesize {"enabled": True} for any desktop-host
            # session with no config — that auto-synced discovered tmux sessions
            # (incl. one whose cwd was $HOME), which is exactly how the runaway
            # whole-home-dir sync got created. Discovered sessions now default OFF;
            # only a deliberately-configured project sync runs.
            if not sync:
                continue
            session_id = session.get("id")
            cwd = session.get("cwd") or ""
            if not session_id or not cwd:
                continue
            opened = start_sync_for_launch(
                device_id, session_id=session_id, cwd=cwd, sync=sync,
                bridge=bridge)
            if opened is not None:
                # The sync is keyed by the folder-pair, so sibling sessions
                # collapse to ONE id here (a set) — the desktop then runs one
                # Mutagen sync per project, not one per session.
                if opened.sync_id not in active_sync_ids:
                    active_sync_ids.append(opened.sync_id)
                reopened += 1
        except Exception:
            # Never let one bad session abort the rest (or the reconnect).
            continue
    # Tell the desktop the authoritative active set so it terminates any orphan
    # Mutagen sync / poller left over from deleted or stopped sessions. Sent
    # unconditionally (even when empty) so a device whose every synced session
    # was deleted gets its leftovers cleaned up and the tray count goes to 0.
    try:
        bridge.send_sync_reconcile(device_id, active_sync_ids)
    except Exception:
        pass
    # Ask the (re)connecting device to re-report its live claude tmux sessions so
    # discovered rows are re-upserted + reconciled. Best-effort.
    try:
        bridge.send_discover_request(device_id)
    except Exception:
        pass
    return reopened


def make_on_launched(device_id: str, bridge: DesktopBridge | None = None):
    """Return an ``on_launched(session_id, cwd, tmux_name, sync)`` closure bound
    to one device — kicks off the file sync after a successful launch."""
    bridge = bridge or get_desktop_bridge()

    def _on_launched(*, session_id, cwd, tmux_name, sync):
        try:
            start_sync_for_launch(device_id, session_id=session_id, cwd=cwd,
                                  sync=sync, bridge=bridge)
        except Exception:
            pass

    return _on_launched


def _dispatch_tmux_argv(bridge: DesktopBridge, device_id: str,
                        argv: list) -> _BridgeRunResult:
    if not argv or argv[0] != "tmux":
        return _BridgeRunResult(1, f"unexpected non-tmux argv: {argv[:1]}")
    sub = argv[1] if len(argv) > 1 else ""

    if sub == "new-session":
        term_id, cwd, launch_argv = _parse_new_session(argv)
        if not term_id:
            return _BridgeRunResult(1, "could not parse tmux new-session argv")
        # Run claude inside a REAL, attachable tmux session on the Mac — NOT a bare
        # PTY child of jc-client. Previously we stripped the tmux wrapper and sent
        # only the claude argv, so a "launch/relaunch on device" never created a
        # tmux session: it was invisible in the user's own terminal (`tmux ls`
        # empty) and only viewable in the WebUI. `new-session -A` = attach-or-create
        # (no `-d`, so the relay PTY attaches + streams to the WebUI), and the same
        # named session is attachable from the Mac via `tmux attach -t <name>`.
        full = ["tmux", "new-session", "-A", "-s", term_id]
        if cwd:
            full += ["-c", cwd]
        full += list(launch_argv or [])
        ok = bridge.send_term_open(device_id, term_id=term_id, cwd=cwd, argv=full)
        return _BridgeRunResult(0 if ok else 1,
                                "" if ok else "desktop client not connected")

    if sub == "send-keys":
        term_id, data, is_enter = _parse_send_keys(argv)
        payload = "\r" if is_enter else (data or "")
        ok = bridge.send_term_input(device_id, term_id, payload)
        return _BridgeRunResult(0 if ok else 1,
                                "" if ok else "desktop client not connected")

    if sub == "kill-session":
        term_id = _flag_value(argv, "-t")
        ok = bridge.send_term_close(device_id, term_id)
        return _BridgeRunResult(0 if ok else 1,
                                "" if ok else "desktop client not connected")

    # Unknown tmux subcommand — best-effort success (don't break the manager).
    return _BridgeRunResult(0)


def _flag_value(argv: list, flag: str) -> str | None:
    try:
        i = argv.index(flag)
        return argv[i + 1]
    except (ValueError, IndexError):
        return None


def _parse_new_session(argv: list):
    """Pull (term_id, cwd, launch_argv) out of a LocalDriver tmux_new_argv.

    Shape: ``tmux new-session -d -s <name> -c <cwd> <launch_argv...>`` — the
    launch argv is everything after the ``-c <cwd>`` pair (LocalDriver builds it
    in exactly this order). Robust to flag order via index lookup, then takes
    the tail after the last recognised option value.
    """
    term_id = _flag_value(argv, "-s")
    cwd = _flag_value(argv, "-c") or ""
    # launch argv = everything after the -c <cwd> pair (matches LocalDriver's
    # fixed construction order: -d -s NAME -c CWD <launch...>).
    launch_argv: list = []
    if "-c" in argv:
        ci = argv.index("-c")
        launch_argv = argv[ci + 2:]
    return term_id, cwd, launch_argv


def _parse_send_keys(argv: list):
    """(term_id, literal_text, is_enter) from a LocalDriver send_message argv.

    Two shapes:
      ['tmux','send-keys','-t',NAME,'-l','--',TEXT]   -> literal text
      ['tmux','send-keys','-t',NAME,'Enter']          -> submit
    """
    term_id = _flag_value(argv, "-t")
    if "--" in argv:
        di = argv.index("--")
        text = argv[di + 1] if di + 1 < len(argv) else ""
        return term_id, text, False
    if argv and argv[-1] == "Enter":
        return term_id, "", True
    # Fallback: last token is the payload.
    return term_id, (argv[-1] if argv else ""), False
