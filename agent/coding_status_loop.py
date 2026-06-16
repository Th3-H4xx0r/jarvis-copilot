"""Background poll that detects the live ``activity_state`` of SERVER-HOST
coding sessions from their tmux pane and writes it to the store.

Server-host only: desktop-host sessions are classified Mac-side and reported via
the discovery push (``desktop_client/jc_client/coding_discover.py`` →
``webui/api/coding_desktop.ingest_discovered``). The loop clock/sleep are
injectable for tests; per-row errors are swallowed so one bad session can't kill
the tick. Mirrors ``agent/coding_scheduler_loop.py`` and the ``gateway_watcher``
daemon-thread pattern.

Activation (last-mile, in ``webui/server.py main()`` after ``start_watcher()``)::

    from agent.coding_status_loop import start_status_loop
    from tools.coding_session_tool import _mgr
    _status_thread, _status_stop = start_status_loop(_mgr())
    # ... and in finally: _status_stop.set()
"""
from __future__ import annotations

import threading
import time

from agent.coding_activity_state import classify_pane

# Lifecycle statuses for which a live activity_state is meaningful. A stopped /
# errored session has no live pane to classify.
_LIVE_STATUSES = {"running", "starting", "idle"}

# ── reap stale DISCOVERED (Mac) sessions from the live fleet ──────────────────
# A discovered-tmux row is only retired (status->stopped) by ingest_discovered's
# reconcile when the Mac sends a NEW push that omits it — which never comes if the
# Mac is gone. So a disconnected Mac's sessions used to linger forever at
# status='running' (the disconnect handler only nulls activity_state), showing in
# the iOS Live Activity as dead gray "idle". This per-tick reap retires them once
# their owning device has been disconnected past a grace window.

# Disconnected at least this long → retire. Must exceed the 5s discovery cadence
# AND the 12s activity_state dot-null grace, so a brief WS blip (or a hermes
# restart the device reconnects through) never reaps+revives.
REAP_GRACE = 45.0

# device_id -> monotonic time we FIRST observed the device absent. Lazily started
# in the sweep and cleared the moment the device is connected again, so ONE
# mechanism gives both the blip grace and the post-restart grace: right after a
# restart every not-yet-reconnected device is freshly stamped, so nothing reaps
# until the real devices have had REAP_GRACE seconds to reconnect (clearing it).
_device_gone_since: dict[str, float] = {}


def _connected_device_ids() -> list:
    """Live set of device_ids with a current WS bridge connection. Lazy webui
    import so this agent module never hard-depends on the webui layer; returns []
    if unavailable (tests inject their own)."""
    try:
        from api.device_bridge import connected_device_ids
        return connected_device_ids()
    except Exception:
        return []


def should_reap_discovered(row, *, connected, gone_since, now,
                           grace=REAP_GRACE) -> bool:
    """Pure: should this row be retired from the live fleet because its Mac is
    gone? True iff it's a LIVE ``discovered-tmux`` row whose owning device is not
    in ``connected`` and has been clocked absent at least ``grace`` seconds.
    ``gone_since`` is None until we've first observed the device absent (→ never
    reap on the first sighting, which is what gives the grace its head start)."""
    if not str(row.get("source") or "").startswith("discovered-tmux"):
        return False
    if row.get("status") not in _LIVE_STATUSES:
        return False
    if (row.get("device_id") or "") in connected:
        return False
    if gone_since is None:
        return False
    return (now - gone_since) >= grace


def reap_disconnected_discovered(store, *, rows=None, connected_ids=None,
                                 now=None, gone_since=None) -> int:
    """Retire DISCOVERED (Mac) sessions whose owning device has been disconnected
    past the grace window: ``status->stopped``, ``activity_state->None`` (the row
    is KEPT as resumable history). Restart-robust — recomputed each tick from the
    live connection set, not a one-shot timer; self-healing — a reconnecting Mac's
    next discovery push revives still-alive rows to 'running'. Fires a WebUI SSE
    notify when it retired anything. Returns the count. All deps injectable."""
    if connected_ids is None:
        connected_ids = _connected_device_ids()
    if now is None:
        now = time.monotonic()
    if gone_since is None:
        gone_since = _device_gone_since
    connected = set(connected_ids)
    # Clear the gone-clock for every currently-connected device — covers devices
    # with no live row this tick, so a stale clock can't later reap a brief blip
    # with zero grace.
    for d in [d for d in gone_since if d in connected]:
        gone_since.pop(d, None)
    try:
        rows = rows if rows is not None else store.list_sessions()
    except Exception:
        return 0
    reaped = 0
    for row in rows:
        try:
            if not str(row.get("source") or "").startswith("discovered-tmux"):
                continue
            if row.get("status") not in _LIVE_STATUSES:
                continue
            dev = row.get("device_id") or ""
            if dev in connected:
                continue
            since = gone_since.get(dev)
            if since is None:
                gone_since[dev] = now  # start the grace clock; never reap yet
                continue
            if should_reap_discovered(row, connected=connected,
                                      gone_since=since, now=now):
                store.update_session(row["id"], status="stopped",
                                     activity_state=None)
                reaped += 1
        except Exception:
            continue
    if reaped:
        # A reap should reach the WebUI instantly (the per-tick LA push is driven
        # by run_loop's on_tick). Lazy + best-effort so the loop never depends on
        # the webui layer being importable.
        try:
            from api import coding_events
            coding_events.notify()
        except Exception:
            pass
    return reaped


def _notify_server_transition(store, row, prev, state) -> None:
    """Fire a settings-gated coding notification for a SERVER-host activity_state
    edge — the server has no plugin ``jc-client`` hook to do it (that's the Mac
    path), so the poll must. Edges that matter:
      • ``* -> waiting`` = Claude NEEDS INPUT (a prompt appeared)  -> ``notification``
      • ``working -> idle`` = the turn FINISHED                    -> ``stop``
    Other transitions (e.g. ``-> working``, first-seen ``-> idle``) don't ping.
    Sends mobile push + WebUI toast via the shared dispatch, AND Telegram directly
    (the shared dispatch leaves Telegram to the Mac's notify.sh hook, which never
    runs on the server). Never raises."""
    if state == "waiting" and prev != "waiting":
        event = "notification"
    elif state == "idle" and prev == "working":
        event = "stop"
    else:
        return
    try:
        from api import coding_routes as cr
    except Exception:
        return
    cwd = row.get("cwd") or ""
    try:
        cr._dispatch_coding_notifications(store, event=event, row=row, cwd=cwd)
    except Exception:
        pass
    # Telegram: the shared dispatch deliberately skips it (the Mac notify.sh hook
    # owns Telegram for Mac sessions). A server session has no such hook, so send
    # it here — gated by the same Code Master telegram channel toggle.
    try:
        ekey = cr._EVENT_NOTIFY_KEY.get(event)
        chans = cr._coding_settings(store)["events"].get(ekey, {})
        if chans.get("telegram"):
            title, label = cr._coding_alert_text(store, row, event)
            cr._send_coding_telegram(f"{title} — {label}")
    except Exception:
        pass


def run_status_tick(manager, *, classify=classify_pane) -> int:
    """Classify each live server-host session's pane and persist
    ``activity_state`` when it changed. Returns the count updated.

    Skips desktop-host sessions (classified Mac-side) and any non-live session.
    Every per-row failure (tmux gone, capture error) is swallowed.
    """
    try:
        rows = manager.store.list_sessions()
    except Exception:
        return 0
    capture = getattr(manager.driver, "capture_pane", None)
    if not callable(capture):
        return 0  # a driver without pane capture (e.g. a future host) → no-op
    run = getattr(manager.driver, "_run", None)
    updated = 0
    for row in rows:
        try:
            if row.get("host") != "server":
                continue
            if row.get("status") not in _LIVE_STATUSES:
                continue
            tmux_name = row.get("tmux_name")
            if not tmux_name:
                continue
            # REAP a server session whose tmux is GONE. Otherwise capture_pane
            # returns "" → classifies "idle", so a dead session shows a fake
            # "running/idle" with a dead terminal AND the resume idempotency would
            # happily reuse it. Distinguish a NORMAL end from a failed launch:
            #   • was running/idle (it had come alive) → STOPPED — a clean quit
            #     (you ctrl-C'd claude). No scary red "Error" badge, and the UI
            #     routes it to the ended panel instead of re-attaching the dead
            #     tmux on a loop (the infinite-reload glitch).
            #   • was still "starting" (never came alive — e.g. a resume-to-server
            #     where claude couldn't run) → ERROR, to show the truth.
            if callable(run):
                try:
                    res = run(["tmux", "has-session", "-t", tmux_name])
                    if getattr(res, "returncode", 0) != 0:
                        new_status = ("stopped"
                                      if row.get("status") in ("running", "idle")
                                      else "error")
                        manager.store.update_session(row["id"], status=new_status,
                                                     activity_state=None)
                        updated += 1
                        continue
                except Exception:
                    pass
            state = classify(capture(tmux_name=tmux_name))
            prev = row.get("activity_state")
            if state != prev:
                manager.store.update_session(row["id"], activity_state=state)
                updated += 1
                # SERVER-HOST notifications. A Mac session pings the user
                # (finished / needs-input) via the plugin's jc-client hook, but
                # jc-client isn't installed on the server — so a web-UI-driven
                # SERVER session would never notify. Drive the SAME settings-gated
                # dispatch from this poll on the real transition edges. Server-only
                # (the loop already skips desktop rows) + edge-triggered, so it
                # can't double-fire with the Mac hook path or spam.
                _notify_server_transition(manager.store, row, prev, state)
        except Exception:
            continue
    if updated:
        # A poll-detected change (a session whose hook didn't fire, or a
        # correction) should also reach the WebUI instantly, not on its next
        # 5s browser poll. Lazy + best-effort so the loop never depends on the
        # webui layer being importable.
        try:
            from api import coding_events
            coding_events.notify()
        except Exception:
            pass
    return updated


# ── server disk-guard ────────────────────────────────────────────────────────
# A runaway sync (or anything) filling the server root partition cascades into
# pip / edge / sqlite failures. Every Nth status tick we check free space and, at
# the critical threshold, BLOCK new syncs + tell every device to terminate its
# Mutagen syncs + GC leaked staging. Pure thresholds live in agent.coding_disk_guard.
_disk_guard_state = {"blocked": False}


def _disk_guard_target() -> str:
    """The path whose partition the guard watches — the coding projects root (where
    syncs + staging write), matching start_sync_for_launch's own free-space check.
    Falls back to '/' if that path/import is unavailable."""
    import os
    try:
        from api import coding_desktop as cd
        root = cd._server_projects_root()
        return root if os.path.isdir(root) else "/"
    except Exception:
        return "/"


def _default_set_block(block: bool, reason: str) -> None:
    """(Re-)assert the process-wide new-sync block flag. Cheap; called EVERY guard
    tick so the flag's TTL stays fresh while the disk is full (and self-expires if
    the guard ever stops)."""
    from api import coding_desktop as cd

    cd.set_sync_blocked(block, reason)


def _default_terminate_device_syncs() -> None:
    """Tell the connected desktop to terminate all its Mutagen syncs (authoritative
    empty active set). Run ONCE on the ok->blocked transition, not every tick."""
    from api import coding_desktop as cd

    try:
        dev = cd.resolve_desktop_device_id()
        if dev:
            cd.get_desktop_bridge().send_sync_reconcile(dev, [])
    except Exception:
        pass


def _default_gc_staging(cfg, *, now=None) -> int:
    """Remove LEAKED Mutagen staging dirs under the server's ~/.mutagen/staging.

    SAFETY: only runs when the sync system is FULLY IDLE — zero active bridge syncs
    AND zero running synced sessions. A live transfer's staging-root mtime is
    frozen at Initialize time (Mutagen writes into prefix SUBdirs), so an mtime
    test alone would misclassify a slow/large in-progress stage as stale and delete
    it mid-transfer (data corruption). With zero active syncs, ALL staging is
    definitionally orphaned (the real 15G-leak scenario), so it's safe to reap;
    the mtime threshold stays as a secondary guard against a just-started sync."""
    import os
    import shutil
    import time as _t

    # Idle gate — if ANY sync is or could be active, never touch staging.
    try:
        from api import coding_desktop as cd
        bridge = cd.get_desktop_bridge()
        if getattr(bridge, "_syncs", None):
            return 0
        store = cd._resolve_store()
        if store is not None:
            for s in (store.list_sessions(status="running") or []):
                if cd._session_is_synced(s):
                    return 0
    except Exception:
        return 0  # can't prove idle → do NOT delete anything

    root = os.path.expanduser("~/.mutagen/staging")
    if not os.path.isdir(root):
        return 0
    entries = []
    for name in os.listdir(root):
        p = os.path.join(root, name)
        try:
            entries.append((p, os.path.getmtime(p)))
        except OSError:
            continue
    from agent.coding_disk_guard import stale_staging_dirs

    stale = stale_staging_dirs(entries, now if now is not None else _t.time(), cfg)
    removed = 0
    for p in stale:
        try:
            shutil.rmtree(p, ignore_errors=True)
            removed += 1
        except Exception:
            continue
    return removed


def _default_disk_notify(state: str, du) -> None:
    try:
        from api import coding_events
        coding_events.notify()
    except Exception:
        pass


def run_disk_guard(manager=None, *, disk_usage=None, now=None, cfg=None,
                   set_block=None, terminate_syncs=None, gc_staging=None,
                   notify=None, state=None) -> str:
    """One disk-guard pass. Returns ``ok`` | ``warn`` | ``critical``. All side-
    effecting deps are injectable so the policy is unit-testable without disk."""
    import shutil

    from agent import coding_disk_guard

    cfg = cfg or coding_disk_guard.DiskGuardConfig.from_env()
    st = state if state is not None else _disk_guard_state
    du = (disk_usage or (lambda: shutil.disk_usage(_disk_guard_target())))()
    klass = coding_disk_guard.classify(du.used, du.total, cfg)
    was_blocked = st.get("blocked", False)
    block = coding_disk_guard.should_block_new_syncs(
        du.free, du.used, du.total, cfg, currently_blocked=was_blocked)
    st["blocked"] = block
    reason = f"server disk {coding_disk_guard.used_pct(du.used, du.total):.0f}% full"
    # (Re-)assert the block flag EVERY tick so its TTL stays fresh while blocked and
    # self-expires if this guard ever stops; clearing on recovery is also a no-op
    # write. Cheap.
    try:
        (set_block or _default_set_block)(block, reason)
    except Exception:
        pass
    # Terminate existing device syncs ONCE on the ok->blocked transition (expensive;
    # not every tick).
    if block and not was_blocked:
        try:
            (terminate_syncs or _default_terminate_device_syncs)()
        except Exception:
            pass
    if klass in ("warn", "critical"):
        try:
            (notify or _default_disk_notify)(klass, du)
        except Exception:
            pass
    if klass == "critical":
        try:
            (gc_staging or _default_gc_staging)(cfg, now=now)
        except Exception:
            pass
    return klass


def run_loop(manager, *, stop, interval: float = 4.0,
             sleep_fn=time.sleep, classify=classify_pane, on_tick=None,
             disk_guard=run_disk_guard, disk_guard_every: int = 8) -> None:
    """Tick until ``stop()`` is truthy. ``sleep_fn`` injectable for tests.
    ``on_tick(manager)`` runs after each status tick (used to push the Live
    Activity update); its errors are swallowed. Every ``disk_guard_every`` ticks
    the server disk-guard runs (set ``disk_guard=None`` to disable)."""
    tick = 0
    while not stop():
        try:
            run_status_tick(manager, classify=classify)
            # Retire DISCOVERED (Mac) sessions whose owning device is gone, so the
            # Live Activity fleet drops them instead of showing dead gray "idle"
            # rows forever. Runs every tick, decoupled from run_status_tick (so it
            # works even on a host whose driver lacks pane capture). on_tick's LA
            # push then reflects the retirement.
            reap_disconnected_discovered(manager.store)
            if on_tick is not None:
                on_tick(manager)
            if disk_guard is not None and tick % max(1, disk_guard_every) == 0:
                disk_guard(manager)
        except Exception:
            pass
        tick += 1
        sleep_fn(interval)


def start_status_loop(manager, *, interval: float = 4.0):
    """Start the poll on a daemon thread. Returns ``(thread, stop_event)``;
    call ``stop_event.set()`` to stop it. Each tick also pushes a Live Activity
    update (via APNs) when the coding content-state changed."""
    stop_event = threading.Event()

    def _on_tick(mgr):
        # Rebuild + push the coding Live Activity content-state (reflects BOTH
        # server-host status changes and desktop discovery changes in the store).
        # Deduped + no-op when APNs/tokens are absent, so it's cheap.
        try:
            from agent.coding_la_push import push_coding_update
            from agent.coding_usage import get_usage
            push_coding_update(mgr.store, usage=get_usage(mgr.store))
        except Exception:
            pass

    t = threading.Thread(
        target=run_loop, args=(manager,),
        kwargs={"stop": stop_event.is_set, "interval": interval,
                "on_tick": _on_tick},
        daemon=True, name="coding-status")
    t.start()
    return t, stop_event
