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
            # REAP a server session whose tmux is GONE (claude exited / failed to
            # start — e.g. a resume-to-server where claude couldn't run). Otherwise
            # capture_pane returns "" → classifies "idle", so a dead session shows a
            # fake "running/idle" with a dead terminal AND the resume idempotency
            # would happily reuse it. Mark it error so the UI shows the truth.
            if callable(run):
                try:
                    res = run(["tmux", "has-session", "-t", tmux_name])
                    if getattr(res, "returncode", 0) != 0:
                        manager.store.update_session(row["id"], status="error",
                                                     activity_state=None)
                        updated += 1
                        continue
                except Exception:
                    pass
            state = classify(capture(tmux_name=tmux_name))
            if state != row.get("activity_state"):
                manager.store.update_session(row["id"], activity_state=state)
                updated += 1
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
