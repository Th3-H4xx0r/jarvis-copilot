"""What clients see of Power integrations: rows for /api/power, cards, card/page UI.

Integration code is never trusted to be fast: status lines and card states are
time-boxed, and a slow or failing one shows its last good value plus an error
instead of holding up the whole tab.
"""
from __future__ import annotations

import concurrent.futures
import logging
import threading
from typing import Any, Callable, Optional

from jarvis_power import discovery, state
from jarvis_power.base import PowerError

logger = logging.getLogger(__name__)

STATUS_TIMEOUT = 1.0
_pool = concurrent.futures.ThreadPoolExecutor(max_workers=8, thread_name_prefix="power-api")
_last: dict[tuple, Any] = {}
_last_lock = threading.Lock()


def _timeboxed(key: tuple, fn: Callable[[], Any], timeout: float, fallback: Any):
    """``(value, error)``. On a timeout or exception: the last good value and why."""
    future = _pool.submit(fn)
    try:
        value = future.result(timeout=timeout)
    except concurrent.futures.TimeoutError:
        with _last_lock:
            return _last.get(key, fallback), "Took too long to answer"
    except Exception as exc:
        logger.warning("power: %s failed: %s", key, exc)
        with _last_lock:
            return _last.get(key, fallback), str(exc) or type(exc).__name__
    with _last_lock:
        _last[key] = value
    return value, None


def settings_values(p) -> dict:
    """Current values for its form; a secret is only whether it's set."""
    try:
        stored = p.read_settings() or {}
    except Exception:
        logger.warning("power: read_settings failed for %s", p.id, exc_info=True)
        stored = {}
    out: dict[str, Any] = {}
    for s in p.settings:
        value = stored.get(s.key, s.default)
        out[s.key] = {"set": bool(value)} if s.kind == "secret" else value
    return out


def row(integration_id: str) -> dict:
    p = discovery.get(integration_id)
    body = state.doc(integration_id)
    status, _err = _timeboxed(("status", p.id), p.status_line, STATUS_TIMEOUT, "")
    try:
        ui = p.ui() or {}
    except Exception:
        ui = {}
    presentations = ui.get("presentations") or {}
    return {
        "id": p.id,
        "name": p.name,
        "icon": p.icon,
        "summary": p.summary,
        "enabled": bool(body.get("enabled", True)) if body else True,
        "protected": p.protected,
        "status_line": status or "",
        "error": body.get("error"),
        "settings_schema": [s.schema() for s in p.settings],
        "settings": settings_values(p),
        "surfaces": list(p.surfaces),
        "links": [{"platform": link.platform, "target": link.target, "label": link.label}
                  for link in p.links],
        "native": {k: sorted(v) for k, v in dict(p.native).items()},
        "has_card": "card" in presentations,
        "has_page": "page" in presentations,
        "space": state.space_id_for(p.id),
    }


def rows() -> dict:
    return {"version": state.version(),
            "integrations": [row(i) for i in discovery.integrations()]}


def _ui_version(ui: dict) -> int:
    v = ui.get("version", 1)
    return v if isinstance(v, int) and not isinstance(v, bool) else 1


def ui(integration_id: str, timeout: float = 20.0) -> dict:
    p = discovery.get(integration_id)
    tree = p.ui() or {}
    st, err = _timeboxed(("state", p.id), p.state, timeout, {})
    return {"space": state.space_id_for(p.id), "version": _ui_version(tree),
            "definition": {"presentations": tree.get("presentations") or {}} if tree else None,
            "state": st or {}, "error": err}


def run_action(integration_id: str, name: str, event: Optional[dict] = None) -> dict:
    p = discovery.get(integration_id)
    tree = p.ui() or {}
    out = {"ok": False, "state": {}, "toast": None, "error": None, "version": _ui_version(tree)}
    if name not in p.actions:
        out["error"] = f"{p.name} has no action {name!r}"
        return out
    if not state.is_on(p.id):
        out["error"] = f"{p.name} is switched off"
        return out
    try:
        result = p.action(name, dict(event or {})) or {}
    except PowerError as exc:
        out["error"] = str(exc)
        return out
    except Exception as exc:
        logger.exception("power: action %s.%s failed", p.id, name)
        out["error"] = str(exc) or type(exc).__name__
        return out
    if result.get("error"):
        out["error"] = str(result["error"])
        return out
    new_state = result.get("state")
    if new_state is None:
        new_state, _ = _timeboxed(("state", p.id), p.state, 20.0, {})
    else:
        with _last_lock:
            _last[("state", p.id)] = new_state
    out.update(ok=True, state=new_state or {}, toast=result.get("toast"))
    return out


def cards(per_card_timeout: float, budget: float = 8.0) -> list[dict]:
    """Every Power integration with a card, its state loaded within the time budget."""
    import time

    deadline = time.monotonic() + budget
    out = []
    for p in discovery.integrations().values():
        tree = p.ui() or {}
        card = (tree.get("presentations") or {}).get("card")
        if card is None:
            continue
        remaining = max(0.05, min(per_card_timeout, deadline - time.monotonic()))
        if state.is_on(p.id):
            st, err = _timeboxed(("state", p.id), p.state, remaining, {})
        else:
            with _last_lock:
                st, err = _last.get(("state", p.id), {}), None
        out.append({"id": p.id, "name": p.name, "icon": p.icon, "version": _ui_version(tree),
                    "card": card, "state": st or {}, "error": err})
    return out
