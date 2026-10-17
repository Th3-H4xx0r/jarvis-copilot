"""Coding housekeeping that runs for the life of the webui.

One small daemon thread, started from ``api.agent_hooks.start()``:

* every tick (4 s) it rebuilds the coding Live Activity content state and
  pushes it when it changed (``agent/coding_la_push.py`` dedupes and
  rate-limits, so an unchanged tick costs a local comparison);
* every 8th tick (~32 s) the server disk guard checks free space and, when the
  disk is critically full, blocks new Mutagen syncs, tells the Macs to stop
  theirs and removes leaked staging (thresholds live in
  ``agent/coding_disk_guard.py``).

The Claude plan-usage poller (``agent/coding_usage.py``, every 60 s) starts
alongside it.
"""
from __future__ import annotations

import logging
import threading
import time

log = logging.getLogger(__name__)

TICK_SECONDS = 4.0
DISK_GUARD_EVERY = 8          # ticks
USAGE_REFRESH_SECONDS = 60.0

_state: dict = {"stop": None, "usage_stop": None}


# ── server disk guard ────────────────────────────────────────────────────────
# A runaway sync (or anything) filling the server root partition cascades into
# pip / edge / sqlite failures. At the critical threshold we BLOCK new syncs,
# tell every device to terminate its Mutagen syncs and GC leaked staging.
_disk_guard_state = {"blocked": False}


def _disk_guard_target() -> str:
    """The partition the guard watches: the coding projects root (where syncs and
    staging write), matching start_sync_for_launch's own free-space check."""
    import os
    try:
        from api import coding_desktop as cd
        root = cd._server_projects_root()
        return root if os.path.isdir(root) else "/"
    except Exception:  # noqa: BLE001
        return "/"


def _default_set_block(block: bool, reason: str) -> None:
    """(Re-)assert the process-wide new-sync block flag. Called every guard pass so
    its TTL stays fresh while the disk is full (and self-expires if the guard stops)."""
    from api import coding_desktop as cd
    cd.set_sync_blocked(block, reason)


def _default_terminate_device_syncs() -> None:
    """Tell the connected desktop to terminate all its Mutagen syncs (an empty
    authoritative set). Run once on the ok->blocked transition."""
    from api import coding_desktop as cd
    try:
        dev = cd.resolve_desktop_device_id()
        if dev:
            cd.get_desktop_bridge().send_sync_reconcile(dev, [])
    except Exception:  # noqa: BLE001
        pass


def _default_gc_staging(cfg, *, now=None) -> int:
    """Remove LEAKED Mutagen staging dirs under the server's ~/.mutagen/staging.

    Only while the sync system is idle (no sync registered with the bridge): a live
    transfer's staging-root mtime is frozen at Initialize time, so an mtime test
    alone could delete a slow transfer mid-flight. With no active sync, all staging
    is orphaned; the mtime threshold stays as a guard against a just-started sync."""
    import os
    import shutil
    import time as _t

    try:
        from api import coding_desktop as cd
        if getattr(cd.get_desktop_bridge(), "_syncs", None):
            return 0
    except Exception:  # noqa: BLE001
        return 0  # can't prove idle -> never delete

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

    removed = 0
    for p in stale_staging_dirs(entries, now if now is not None else _t.time(), cfg):
        try:
            shutil.rmtree(p, ignore_errors=True)
            removed += 1
        except Exception:  # noqa: BLE001
            continue
    return removed


def _default_disk_notify(_state: str, _du) -> None:
    try:
        from api import coding_events
        coding_events.notify()
    except Exception:  # noqa: BLE001
        pass


def run_disk_guard(*, disk_usage=None, now=None, cfg=None, set_block=None,
                   terminate_syncs=None, gc_staging=None, notify=None, state=None) -> str:
    """One disk-guard pass. Returns ``ok`` | ``warn`` | ``critical``. Every
    side-effecting dependency is injectable so the policy is testable without disk."""
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
    try:
        (set_block or _default_set_block)(block, reason)
    except Exception:  # noqa: BLE001
        pass
    if block and not was_blocked:
        try:
            (terminate_syncs or _default_terminate_device_syncs)()
        except Exception:  # noqa: BLE001
            pass
    if klass in ("warn", "critical"):
        try:
            (notify or _default_disk_notify)(klass, du)
        except Exception:  # noqa: BLE001
            pass
    if klass == "critical":
        try:
            (gc_staging or _default_gc_staging)(cfg, now=now)
        except Exception:  # noqa: BLE001
            pass
    return klass


# ── the loop ─────────────────────────────────────────────────────────────────
def push_live_activity(store) -> None:
    """Rebuild + push the coding Live Activity when its content changed."""
    try:
        from agent.coding_la_push import push_coding_update
        from agent.coding_usage import get_usage
        push_coding_update(store, usage=get_usage(store))
    except Exception:  # noqa: BLE001
        log.debug("coding LA push failed", exc_info=True)


def run_loop(store, *, stop, interval: float = TICK_SECONDS, sleep_fn=time.sleep,
             on_tick=push_live_activity, disk_guard=run_disk_guard,
             disk_guard_every: int = DISK_GUARD_EVERY) -> None:
    """Tick until ``stop()`` is truthy: ``on_tick(store)`` every tick, the disk
    guard every ``disk_guard_every`` ticks (``disk_guard=None`` disables it)."""
    tick = 0
    while not stop():
        try:
            if on_tick is not None:
                on_tick(store)
            if disk_guard is not None and tick % max(1, disk_guard_every) == 0:
                disk_guard()
        except Exception:  # noqa: BLE001
            log.debug("coding housekeeping tick failed", exc_info=True)
        tick += 1
        sleep_fn(interval)


def start(store) -> None:
    """Start the usage poller and the housekeeping thread (idempotent)."""
    if _state["stop"] is not None:
        return
    try:
        from agent.coding_usage import start_refresher
        _thread, _state["usage_stop"] = start_refresher(store, interval=USAGE_REFRESH_SECONDS)
    except Exception as exc:  # noqa: BLE001
        print(f"[!!] WARNING: coding usage poller failed to start: {exc}", flush=True)
    stop_event = threading.Event()
    _state["stop"] = stop_event
    threading.Thread(target=run_loop, args=(store,),
                     kwargs={"stop": stop_event.is_set, "sleep_fn": stop_event.wait},
                     daemon=True, name="coding-housekeeping").start()


def stop() -> None:
    for key in ("stop", "usage_stop"):
        ev = _state.get(key)
        if ev is not None:
            ev.set()
        _state[key] = None
