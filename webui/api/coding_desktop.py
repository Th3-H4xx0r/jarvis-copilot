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

import logging
import queue
import threading
import time

log = logging.getLogger(__name__)

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
                 rows: int = 24, cols: int = 80):
        self.session_id = str(session_id)
        self.device_id = str(device_id)
        self.term_id = str(term_id)
        self._bridge = bridge
        self.workspace = ""  # parity field; the real cwd lives on the device
        self.rows = rows
        self.cols = cols
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

    def on_exit(self, code) -> None:
        self.proc.set_exit(code)
        self.closed.set()
        self.put_output("terminal_closed", {"exit_code": self.proc.poll()})

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
        # We do NOT send coding_term_close here so the session survives a tab
        # close; the session lifecycle (stop/delete) sends the close frame.
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
                    rows: int = 24, cols: int = 80) -> DesktopTerminalFeed:
        """Create (or return) the feed for ``term_id`` and replay buffered output.

        Registers the feed in api.terminal's registry under ``session_id`` so the
        existing SSE/input/resize/close routes drive it.
        """
        from api import terminal as term_mod

        with self._lock:
            feed = self._feeds.get(term_id)
            if feed is None:
                feed = DesktopTerminalFeed(
                    session_id=session_id, device_id=device_id, term_id=term_id,
                    bridge=self, rows=rows, cols=cols)
                self._feeds[term_id] = feed
                # Replay any output that arrived before the viewer attached.
                for chunk in self._replay.pop(term_id, []):
                    feed.on_output(chunk)
                if term_id in self._pending_exit:
                    feed.on_exit(self._pending_exit.pop(term_id))
        term_mod.register_terminal(session_id, feed)
        return feed

    def feed_for(self, term_id: str) -> DesktopTerminalFeed | None:
        with self._lock:
            return self._feeds.get(term_id)

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
        feed.on_exit(code)

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


def start_sync_for_launch(device_id: str, *, session_id: str, cwd: str,
                          sync: dict | None,
                          bridge: DesktopBridge | None = None):
    """Open a MutagenSyncSession for a session that opted into syncing.

    The desktop runs Mutagen between its LOCAL folder (``sync['remote_path']`` —
    the path on the user's machine) and the server session's cwd
    (``remote_path`` on the Mutagen ``jc-hermes`` ssh alias). Returns the session
    (or None when sync is off).
    """
    if not sync:
        return None
    if not (sync.get("enabled") or sync.get("device") or sync.get("remote_path")):
        return None
    bridge = bridge or get_desktop_bridge()
    sync_id = "sync-" + session_id
    ignore = sync.get("ignore") if isinstance(sync.get("ignore"), list) else None
    local_path = sync.get("remote_path") or cwd  # the DESKTOP's folder
    session = MutagenSyncSession(
        sync_id=sync_id, device_id=device_id, local_path=local_path,
        remote_path=cwd, bridge=bridge, ignore=ignore)
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


def stop_sync_for_session(session_id: str, *, bridge: DesktopBridge | None = None) -> None:
    """Stop the file sync for a session that's being deleted/stopped — tell the
    desktop to terminate its Mutagen sync + poller so the tray count drops
    immediately (the reconcile-on-reconnect is the backstop). Never raises."""
    if not session_id:
        return
    try:
        bridge = bridge or get_desktop_bridge()
    except Exception:
        return
    sync_id = "sync-" + str(session_id)
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


def sync_status(session_id: str, sync_config=None) -> dict:
    """Sync status for the WebUI: device, online/offline, status, progress.

    ``status`` is one of: off | disconnected | idle | opening | syncing | synced
    | error. ``total``/``done`` drive the progress bar while ``syncing``.
    """
    import json as _json

    out = {"enabled": False, "device": None, "device_online": False,
           "status": "off", "direction": None, "total": 0, "done": 0,
           "conflicts": 0, "last_sync_at": None, "error": None}
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
    try:
        sess = get_desktop_bridge().sync_for("sync-" + session_id)
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
# A desktop device periodically scans its live ``claude`` tmux sessions and
# pushes a ``coding_discover`` frame listing them. The server upserts each as a
# first-class coding-session row (host='desktop', external=1, source starts with
# 'discovered-tmux') grouped under an auto-created project keyed by the session's
# cwd, and reconciles ones that vanished to status='stopped' (kept for history).
#
# Per-device tombstones: when a user deletes a discovered session we record its
# tmux_name here so the next push doesn't resurrect it. The delete path calls
# ``dismiss_discovered`` (exposed for that wiring).
_DISMISSED_DISCOVERED: dict[str, set] = {}
_DISMISSED_LOCK = threading.Lock()


def dismiss_discovered(device_id: str, tmux_name: str) -> None:
    """Tombstone a (device_id, tmux_name) so ``ingest_discovered`` won't recreate
    it on the next push (called from the session-delete path)."""
    if not device_id or not tmux_name:
        return
    with _DISMISSED_LOCK:
        _DISMISSED_DISCOVERED.setdefault(str(device_id), set()).add(str(tmux_name))


def _is_dismissed(device_id: str, tmux_name: str) -> bool:
    with _DISMISSED_LOCK:
        return str(tmux_name) in _DISMISSED_DISCOVERED.get(str(device_id), set())


def ingest_discovered(device_id: str, sessions: list, *, store=None) -> int:
    """Upsert a desktop device's live ``claude`` tmux sessions as coding-session
    rows and reconcile ones that disappeared.

    For each incoming ``{kind:'tmux', tmux_name, cwd, title, last_activity}``:
      * group it under a project auto-created for its cwd (the repo_path key, per
        (cwd, device_id) — we have no git on the server for the device's path),
      * upsert a row matched by (device_id, tmux_name): an existing row is
        updated (status='running', title, last_activity_at, project_id,
        external=1); otherwise a new external 'discovered-tmux' row is created.
    Any existing discovered row for this device NOT in the incoming set is marked
    status='stopped' (kept, not deleted, for history). Dismissed (user-deleted)
    tmux_names are skipped so they're not resurrected.

    Never raises — logs and continues on per-item errors. Returns the number of
    rows upserted (created or updated)."""
    store = store or _resolve_store()
    if store is None:
        return 0
    sessions = sessions or []

    # Existing discovered rows for this device, indexed by tmux_name. We only
    # ever touch rows this ingest owns (external + source startswith
    # 'discovered-tmux') so we never disturb Jarvis-launched sessions.
    existing: dict = {}
    try:
        for row in store.list_sessions(device_id=device_id):
            src = (row.get("source") or "")
            if src.startswith("discovered-tmux") and row.get("external"):
                name = row.get("tmux_name")
                if name:
                    existing[name] = row
    except Exception as exc:  # noqa: BLE001
        log.warning("coding_discover[%s]: list_sessions failed: %s",
                    device_id, exc)
        existing = {}

    seen: set = set()
    upserted = 0
    for sess in sessions:
        try:
            if not isinstance(sess, dict):
                continue
            if (sess.get("kind") or "tmux") != "tmux":
                continue
            tmux_name = (sess.get("tmux_name") or "").strip()
            if not tmux_name:
                continue
            if _is_dismissed(device_id, tmux_name):
                # User deleted this one — don't resurrect it.
                continue
            seen.add(tmux_name)
            cwd = sess.get("cwd") or ""
            title = sess.get("title") or tmux_name
            last_activity = sess.get("last_activity")
            pid = store.get_or_create_project_for_path(
                repo_path=cwd, host="desktop", device_id=device_id)
            row = existing.get(tmux_name)
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
                store.update_session(row["id"], **fields)
            else:
                sid = store.create_session(
                    project_id=pid, host="desktop", cwd=cwd, branch=None,
                    tmux_name=tmux_name, source="discovered-tmux", title=title,
                    device_id=device_id, external=True, status="running")
                if last_activity is not None:
                    # create_session doesn't accept last_activity_at — set it now.
                    store.update_session(sid, last_activity_at=last_activity)
            upserted += 1
        except Exception as exc:  # noqa: BLE001
            log.warning("coding_discover[%s]: skipped a session: %s",
                        device_id, exc)
            continue

    # Reconcile: any discovered row we own that wasn't in this push has vanished
    # from the device — mark it stopped (keep the row for history).
    for name, row in existing.items():
        if name in seen:
            continue
        try:
            if (row.get("status") or "") != "stopped":
                store.update_session(row["id"], status="stopped")
        except Exception as exc:  # noqa: BLE001
            log.warning("coding_discover[%s]: reconcile stop failed for %s: %s",
                        device_id, name, exc)
    return upserted


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
            # A desktop session with no explicit sync block still wants a sync
            # of its cwd — synthesize a minimal "enabled" config so
            # start_sync_for_launch opens it.
            if sync is None and (session.get("host") or "").lower() == "desktop":
                sync = {"enabled": True}
            if not sync:
                continue
            session_id = session.get("id")
            cwd = session.get("cwd") or ""
            if not session_id or not cwd:
                continue
            active_sync_ids.append("sync-" + str(session_id))
            opened = start_sync_for_launch(
                device_id, session_id=session_id, cwd=cwd, sync=sync,
                bridge=bridge)
            if opened is not None:
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
        ok = bridge.send_term_open(device_id, term_id=term_id, cwd=cwd,
                                   argv=launch_argv)
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
