"""On/off and settings of every Power integration, kept in its own registry space.

Each Power integration owns a registry space (normally its id) holding one
``power`` document::

    {"enabled": bool, "settings": {...}, "changed_at": float, "changed_by": str,
     "paused_jobs": [job ids], "error": str | None}

The registry is SQLite/WAL under the profile's home, so the webui and the gateway
read the same state. The document is written once at first boot (seeded from
:meth:`PowerIntegration.seed_enabled`) and never re-seeded.
"""
from __future__ import annotations

import hashlib
import json
import logging
import threading
import time
from typing import Any, Optional

from jarvis_power import discovery

logger = logging.getLogger(__name__)

POWER_DOC = "jarvis_power"
# The key the first deploy used. A user's own integration may keep a "power" document
# (watts, a UPS…), so only a power-state-shaped one in a Power space is ours to move.
LEGACY_DOC = "power"
_CACHE_TTL = 2.0
_lock = threading.RLock()
_space_ids: dict[str, str] = {}
_snapshot: Optional[tuple[float, dict[str, bool]]] = None


def _reg():
    from jarvis_registry.store import shared
    return shared()


def reset_cache() -> None:
    global _snapshot
    with _lock:
        _snapshot = None
        _space_ids.clear()


def _looks_like_state(body) -> bool:
    return isinstance(body, dict) and "enabled" in body and "changed_by" in body


def _has_power_doc(space_id: str) -> bool:
    reg = _reg()
    if not reg.exists(space_id):
        return False
    space = reg.open(space_id)
    return _looks_like_state(space.get(POWER_DOC)) or _looks_like_state(space.get(LEGACY_DOC))


def space_id_for(integration_id: str) -> str:
    """The registry space that holds this integration's state.

    Its id, unless a space someone else made already has that id — then
    ``power-<id>``. Once a power document exists the answer never changes.
    """
    with _lock:
        cached = _space_ids.get(integration_id)
        if cached:
            return cached
        prefixed = f"power-{integration_id}"
        if _has_power_doc(integration_id):
            chosen = integration_id
        elif _has_power_doc(prefixed):
            chosen = prefixed
        else:
            p = discovery.integrations().get(integration_id)
            taken = _reg().exists(integration_id)
            chosen = integration_id if (not taken or (p is not None and p.adopt_space)) else prefixed
            return chosen                    # not cached until its doc exists
        _space_ids[integration_id] = chosen
        return chosen


def is_power_space(space_id: str) -> bool:
    try:
        reg = _reg()
        return reg.exists(space_id) and _looks_like_state(reg.open(space_id).get(POWER_DOC))
    except Exception:
        return False


def power_space_ids() -> set[str]:
    out = set()
    for integration_id in discovery.integrations():
        sid = space_id_for(integration_id)
        if is_power_space(sid):
            out.add(sid)
    return out


def ensure_all() -> None:
    """Give every Power integration its space and, the first time only, its state."""
    for p in discovery.integrations().values():
        try:
            _ensure(p)
        except Exception:
            logger.exception("power: could not set up %s", p.id)
    reset_cache()


def _ensure(p) -> None:
    sid = space_id_for(p.id)
    space = _reg().space(sid, name=p.name, description=p.summary, icon=p.icon)
    if _looks_like_state(space.get(POWER_DOC)):
        return
    legacy = space.get(LEGACY_DOC)
    if _looks_like_state(legacy):                 # first deploy's key: move it
        space.put(POWER_DOC, legacy, description="Power integration state (on/off, settings)")
        space.delete_document(LEGACY_DOC)
        return
    try:
        enabled = bool(p.seed_enabled())
    except Exception:
        logger.exception("power: seed_enabled failed for %s; using its default", p.id)
        enabled = bool(p.default_enabled)
    space.put(POWER_DOC, {"enabled": enabled, "settings": {}, "changed_at": time.time(),
                          "changed_by": "seed", "paused_jobs": [], "error": None},
              description="Power integration state (on/off, settings)")


def doc(integration_id: str) -> dict:
    """The stored power document (empty dict when there is none yet)."""
    sid = space_id_for(integration_id)
    reg = _reg()
    if not reg.exists(sid):
        return {}
    space = reg.open(sid)
    body = space.get(POWER_DOC)
    if not _looks_like_state(body):
        legacy = space.get(LEGACY_DOC)
        body = legacy if _looks_like_state(legacy) else None
    return dict(body) if isinstance(body, dict) else {}


def _write(integration_id: str, **fields: Any) -> dict:
    global _snapshot
    with _lock:
        body = doc(integration_id)
        if not body:
            p = discovery.get(integration_id)
            _ensure(p)
            body = doc(integration_id)
        body.update(fields)
        _reg().open(space_id_for(integration_id)).put(POWER_DOC, body)
        _snapshot = None
        return body


def snapshot() -> dict[str, bool]:
    """Every integration's on/off. Cached for a moment: this runs on every request.

    The cache holds stored values only; an integration not yet seeded is worked out
    each time from its own config (see :func:`_unseeded`), so it follows that config
    until the webui seeds it.
    """
    global _snapshot
    now = time.monotonic()
    with _lock:
        cached = _snapshot[1] if _snapshot is not None and now - _snapshot[0] < _CACHE_TTL else None
    if cached is None:
        cached = {}
        for integration_id in discovery.integrations():
            try:
                body = doc(integration_id)
                cached[integration_id] = bool(body.get("enabled", True)) if body else None
            except (Exception, SystemExit):      # a broken home lookup may sys.exit()
                cached[integration_id] = True    # never switch a feature off because a read failed
        with _lock:
            _snapshot = (now, cached)
    found = discovery.integrations()
    return {i: (v if v is not None else _unseeded(found[i])) for i, v in cached.items() if i in found}


def snapshot_fresh() -> dict[str, bool]:
    """Like :func:`snapshot` but read now (the manager acts on it)."""
    global _snapshot
    with _lock:
        _snapshot = None
    return snapshot()


def _unseeded(p) -> bool:
    """Before the webui has seeded it (another process booted first): what it will seed."""
    try:
        return bool(p.seed_enabled())
    except (Exception, SystemExit):
        return bool(p.default_enabled)


def is_on(integration_id: str) -> bool:
    """Whether it's on. Unknown ids and unreadable state count as on."""
    try:
        return snapshot().get(integration_id, True)
    except (Exception, SystemExit):
        return True


def version() -> str:
    """Changes whenever any integration's on/off, change time or error changes."""
    parts = []
    for integration_id in sorted(discovery.integrations()):
        body = doc(integration_id)
        parts.append([integration_id, body.get("enabled"), body.get("changed_at"),
                      body.get("error")])
    return hashlib.sha1(json.dumps(parts, sort_keys=True).encode()).hexdigest()[:16]


def write_enabled(integration_id: str, enabled: bool, by: str, **extra: Any) -> dict:
    return _write(integration_id, enabled=bool(enabled), changed_at=time.time(),
                  changed_by=by, **extra)


def stored_settings(integration_id: str) -> dict:
    return dict(doc(integration_id).get("settings") or {})


def store_settings(integration_id: str, changes: dict) -> None:
    merged = {**stored_settings(integration_id), **changes}
    _write(integration_id, settings=merged)


def record_error(integration_id: str, message: Optional[str]) -> None:
    if doc(integration_id).get("error") == message:
        return
    _write(integration_id, error=message)
