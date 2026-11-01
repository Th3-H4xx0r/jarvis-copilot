"""Insights → Costs: what every service Jarvis uses is costing, with history.

GET  /api/costs?days=N                 overview (agent.costs.report.overview)
GET  /api/costs/service?id=X&days=N    one service's detail
POST /api/costs/connect      {service, fields: {key: value}}   save billing-API keys → .env, refresh
POST /api/costs/disconnect   {service}   remove the billing-only keys this page added (plan
                             price and history stay)
POST /api/costs/subscription {service?, name?, amount_usd, interval, plan?, since?}
                             a plan price for a service, or (no service) a custom subscription;
                             amount_usd null clears it
POST /api/costs/budget       {monthly_usd}   null/0 clears
POST /api/costs/refresh      {service?}      run the collector now

A saved key is never sent back. The collector runs in a daemon thread every 3 hours
(``install``) — HTTP and SQL only, no model calls.
"""
from __future__ import annotations

import logging
import re
import threading
import time
from typing import Any, Dict, Optional
from urllib.parse import parse_qs

from api.helpers import bad, j

logger = logging.getLogger(__name__)

_INTERVAL_S = 3 * 3600
_FIRST_RUN_DELAY_S = 60
_REFRESH_WAIT_S = 45
_SECRET_RE = re.compile(r"^\S{8,512}$")
_TEXT_RE = re.compile(r"^[^\r\n]{1,200}$")


_loop_started = False
_loop_lock = threading.Lock()


def _days(parsed) -> int:
    try:
        return min(max(int(parse_qs(parsed.query).get("days", ["30"])[0]), 1), 365)
    except (TypeError, ValueError):
        return 30


def _service_exists(service_id: str) -> bool:
    from agent.costs import catalog
    from agent.costs.store import get_store
    return bool(catalog.get(service_id)) or service_id in get_store().all_service_configs()


def _run_collect(service: Optional[str] = None, wait: float = _REFRESH_WAIT_S) -> Dict[str, Any]:
    """Run the collector off the request thread; stop waiting after ``wait`` seconds
    (the run carries on and the next GET shows its result)."""
    from agent.costs.collector import collect
    box: Dict[str, Any] = {}

    def run() -> None:
        try:
            box["result"] = collect(service)
        except Exception as exc:  # collect() isolates providers; this guards against bugs
            logger.warning("costs: collector run failed", exc_info=True)
            box["result"] = {"ok": False, "error": str(exc)[:300]}

    t = threading.Thread(target=run, name="costs-refresh", daemon=True)
    t.start()
    t.join(wait)
    return box.get("result") or {"ok": True, "pending": True}


def handle_costs_get(handler, parsed) -> bool:
    if parsed.path == "/api/costs":
        from agent.costs.report import overview
        j(handler, overview(_days(parsed)))
        return True
    if parsed.path == "/api/costs/service":
        from agent.costs.report import service_detail
        sid = (parse_qs(parsed.query).get("id", [""])[0] or "").strip()
        detail = service_detail(sid, _days(parsed)) if sid else None
        if detail is None:
            bad(handler, "unknown service", 404)
        else:
            j(handler, detail)
        return True
    return False


def handle_costs_post(handler, parsed, body) -> bool:
    if not parsed.path.startswith("/api/costs/"):
        return False
    body = body if isinstance(body, dict) else {}
    action = parsed.path[len("/api/costs/"):]
    try:
        if action == "connect":
            return _connect(handler, body)
        if action == "disconnect":
            return _disconnect(handler, body)
        if action == "subscription":
            return _subscription(handler, body)
        if action == "budget":
            from agent.costs.settings import set_budget
            j(handler, {"ok": True, "monthly_usd": set_budget(body.get("monthly_usd"))})
            return True
        if action == "refresh":
            sid = str(body.get("service") or "").strip() or None
            if sid and not _service_exists(sid):
                bad(handler, "unknown service")
                return True
            j(handler, _run_collect(sid))
            return True
    except ValueError as exc:  # SettingsError carries a user-facing message
        bad(handler, str(exc))
        return True
    return False


def _connect(handler, body: Dict[str, Any]) -> bool:
    from agent.costs import catalog
    from agent.costs.report import service_detail
    sid = str(body.get("service") or "").strip()
    entry = catalog.get(sid)
    if entry is None:
        bad(handler, "unknown service")
        return True
    fields = body.get("fields") if isinstance(body.get("fields"), dict) else {}
    specs = {f["key"]: f for f in entry.get("fields", [])}
    updates: Dict[str, Optional[str]] = {}
    for key, raw in fields.items():
        spec = specs.get(key)
        if spec is None or not spec.get("env"):
            bad(handler, f"unknown field {key!r}")
            return True
        if raw is None or (isinstance(raw, str) and not raw.strip()):
            continue  # blank keeps what's saved
        if not isinstance(raw, str):
            bad(handler, f"{spec['label']} must be text")
            return True
        value = raw.strip()
        pattern = _SECRET_RE if spec.get("kind") == "secret" else _TEXT_RE
        if not pattern.match(value):
            bad(handler, f"That doesn't look like a valid {spec['label']}.")
            return True
        updates[spec["env"]] = value
    if not updates:
        bad(handler, "Nothing to save.")
        return True
    from api.providers import _get_hermes_home, _write_env_file
    try:
        _write_env_file(_get_hermes_home() / ".env", updates)
    except Exception:
        logger.warning("costs: saving %s keys failed", sid, exc_info=True)
        j(handler, {"error": "could not save the key"}, status=500)
        return True
    # A scheduled run holding the collector means this sync can't start yet: say so
    # ("pending") rather than reporting a key nobody has checked as connected.
    result = _run_collect(sid, wait=25)
    j(handler, {"ok": True, "pending": bool(result.get("pending")),
                "sync": (result.get("services") or {}).get(sid),
                "detail": service_detail(sid, 30)})
    return True


def _disconnect(handler, body: Dict[str, Any]) -> bool:
    from agent.costs import catalog
    from agent.costs.store import get_store
    sid = str(body.get("service") or "").strip()
    if not _service_exists(sid):
        bad(handler, "unknown service")
        return True
    entry = catalog.get(sid) or {}
    # Only keys this page alone uses (catalog ``billing_only``). A service's main key
    # (ElevenLabs, Browserbase…) also runs that service, so it's removed in Settings.
    removable = {f["env"]: None for f in entry.get("fields", []) if f.get("billing_only")}
    if removable:
        from api.providers import _get_hermes_home, _write_env_file
        try:
            _write_env_file(_get_hermes_home() / ".env", removable)
        except Exception:
            logger.warning("costs: removing %s keys failed", sid, exc_info=True)
            j(handler, {"error": "could not remove the key"}, status=500)
            return True
        get_store().clear_sync(sid)
    j(handler, {"ok": True, "removed_keys": len(removable)})
    return True


def _subscription(handler, body: Dict[str, Any]) -> bool:
    from agent.costs.settings import add_custom, clear_subscription, set_subscription
    sid = str(body.get("service") or "").strip()
    amount = body.get("amount_usd")
    interval = str(body.get("interval") or "month")
    since = str(body.get("since") or "").strip() or None
    if sid:
        if not _service_exists(sid):
            bad(handler, "unknown service")
            return True
        if amount is None or amount == "":
            clear_subscription(sid)
            j(handler, {"ok": True, "service": sid, "cleared": True})
            return True
        cfg = set_subscription(sid, amount, interval=interval, plan=body.get("plan"), since=since)
        j(handler, {"ok": True, "service": sid, "subscription": cfg})
        return True
    new_id = add_custom(str(body.get("name") or ""), amount, interval=interval,
                        category=body.get("category"), since=since)
    j(handler, {"ok": True, "service": new_id})
    return True


def _loop() -> None:
    from agent.costs.collector import collect
    time.sleep(_FIRST_RUN_DELAY_S)
    while True:
        try:
            result = collect()
            failed = [k for k, v in (result.get("services") or {}).items() if not v.get("ok")]
            if failed:
                logger.info("costs: collected; failing: %s", ", ".join(failed))
        except Exception:
            logger.warning("costs: scheduled collection failed", exc_info=True)
        time.sleep(_INTERVAL_S)


def install() -> None:
    """Start the background collector once per process."""
    global _loop_started
    with _loop_lock:
        if _loop_started:
            return
        _loop_started = True
    threading.Thread(target=_loop, name="costs-collector", daemon=True).start()
