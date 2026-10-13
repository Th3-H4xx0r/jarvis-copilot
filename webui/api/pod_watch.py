"""Jarvis Pod status for whoever is looking at it.

The phone's Devices tab used to fetch the device list and ask every Pod for its
status every 15 s while the tab was mounted — and the tab stays mounted all night
because the app is never suspended, so the phone's radio woke every 15 s until
morning (2026-10-13). Now the phone subscribes to the ``pods`` topic while the tab
is really on screen, and this watcher asks the Pods instead: only while someone
subscribes, and it pushes a status only when it changed.
"""
from __future__ import annotations

import logging
import threading
import time

from api import device_bridge

logger = logging.getLogger(__name__)

POLL_S = 15.0
_POD_AGENT = "JarvisPod/"

_lock = threading.Lock()
_running = False
_last: dict[str, dict] = {}


def _pod_ids() -> list[str]:
    from api.pairing import list_devices

    connected = set(device_bridge.connected_device_ids())
    return [str(d.get("id")) for d in list_devices()
            if str(d.get("user_agent") or "").startswith(_POD_AGENT) and d.get("id") in connected]


def poll_once(pods=None, invoke=None, publish=None) -> dict:
    """Ask each connected Pod for its status; push the ones that changed. Returns them."""
    pods = _pod_ids() if pods is None else pods
    invoke = invoke or device_bridge.invoke_skill
    publish = publish or device_bridge.publish
    changed: dict[str, dict] = {}
    for pod_id in pods:
        try:
            reply = invoke(pod_id, "pod_status", {}, timeout=10.0)
        except Exception:
            logger.debug("pod_watch: pod_status on %s raised", pod_id, exc_info=True)
            continue
        status = reply.get("result") if isinstance(reply, dict) and reply.get("ok") else None
        if not isinstance(status, dict):
            continue  # a pod that didn't answer keeps what the phone already shows
        with _lock:
            if _last.get(pod_id) == status:
                continue
            _last[pod_id] = status
        changed[pod_id] = status
    if changed:
        publish("pods", {"statuses": changed})
    return changed


def _run() -> None:
    global _running
    try:
        while device_bridge.subscribers("pods"):
            try:
                poll_once()
            except Exception:
                logger.warning("pod_watch poll failed", exc_info=True)
            time.sleep(POLL_S)
    finally:
        with _lock:
            _running = False
            # The next viewer starts from nothing, so it gets every pod's status once.
            _last.clear()
        # Someone subscribed between the last check and here: their ensure() saw us running.
        if device_bridge.subscribers("pods"):
            ensure()


def ensure() -> bool:
    """Start the watcher if someone wants ``pods`` and it isn't running. True if started."""
    global _running
    if not device_bridge.subscribers("pods"):
        return False
    with _lock:
        if _running:
            return False
        _running = True
    threading.Thread(target=_run, name="pod-watch", daemon=True).start()
    return True


def _on_subscribe(_device_id: str, topics: dict) -> None:
    if "pods" in topics:
        ensure()


def _on_registry_change() -> None:
    # A device connected or went away: a Pod may have joined or left the list.
    device_bridge.publish("pods", {"what": ["list"]})


def install() -> None:
    """Called once at server start."""
    device_bridge.on_subscribe(_on_subscribe)
    device_bridge.on_registry_change(_on_registry_change)
