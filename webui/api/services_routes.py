"""Pure HTTP dispatcher for the service pills and crypto/portfolio (``/api/services``).

:func:`handle_services_request` takes the method, the path after ``/api/services``,
the parsed JSON body and (for tests) a hub, and returns ``(status, payload)``;
``routes.py`` writes it with ``j(handler, payload, status=status)``. The hub
(``jarvis_services.loop.ServicesHub``) is started at boot by ``server.py`` and
publishes ``services`` / ``portfolio`` topics on the device bridge.

Contract (``<path>`` is what follows ``/api/services``)::

    GET  ""                       -> 200 {"services": [snapshot…], "pending": [id…], "ts"}
    GET  /<id>/detail             -> 200 detail (re-read when older than 60 s) | 404
    POST /<id>/action {kind, target, confirmed?, requested_at?}
                                  -> 200 {ok, result, error, confirm, detail}
                                     409 refused (not offered / stale / needs ``confirmed``)
                                     502 the service API failed · 400 bad body · 404 unknown id
    GET  /config                  -> 200 {services, exchanges, crypto, wallets, networks} (``has_key`` only)
    POST /config {service|exchange|crypto…}
                                  -> 200 same as GET + {"ok": true} · 400 {"error"}
    GET  /portfolio               -> 200 {"crypto": board|null, "portfolio": board|null, "ts"}
    POST /portfolio/wallets {op: add|remove, network, address, label?}
                                  -> 200 {ok, wallets, holdings?} · 400 · 404

No endpoint ever returns a secret.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import logging
import threading
import time
from urllib.parse import urlsplit

log = logging.getLogger(__name__)

SERVICES_PATH_PREFIX = "/api/services"

_HUB = None
_HUB_LOCK = threading.Lock()


def _publish(topic: str, data: dict) -> None:
    from api.device_bridge import publish
    publish(topic, data)


def _notify(title: str, body: str, data: dict) -> None:
    # The same visible APNs banner coding notifications use.
    from api.coding_routes import _push_device_alert
    _push_device_alert(title, body)


def default_hub():
    """The process-wide hub, its keys and settings in the server's own home.

    Pinned once: the poller thread carries no profile cookie, so a per-request
    home would save settings in one profile while polling another."""
    global _HUB
    with _HUB_LOCK:
        if _HUB is None:
            from api.providers import _write_env_file
            from jarviscopilot_constants import get_hermes_home
            from jarvis_services import default_services
            from jarvis_services.config import ServicesConfig
            from jarvis_services.loop import ServicesHub
            home = get_hermes_home()
            _HUB = ServicesHub(default_services(),
                               ServicesConfig(home_fn=lambda: home, write_env=_write_env_file),
                               publish=_publish, notify=_notify)
        return _HUB


def start() -> None:
    """Start polling (idle until a service is configured)."""
    default_hub().start()


def _err(status: int, message: str) -> tuple[int, dict]:
    return status, {"error": message}


def _action(hub, service_id: str, body: dict) -> tuple[int, dict]:
    kind, target = body.get("kind"), body.get("target")
    confirmed = body.get("confirmed", False)
    requested_at = body.get("requested_at")
    if not isinstance(kind, str) or not kind or not isinstance(target, str) or not target or len(target) > 512:
        return _err(400, "kind and target are required")
    if not isinstance(confirmed, bool):
        return _err(400, "confirmed must be true or false")
    if requested_at is not None and (isinstance(requested_at, bool) or not isinstance(requested_at, (int, float))):
        return _err(400, "requested_at must be a number (epoch seconds)")
    out = hub.action(service_id, kind, target, confirmed=confirmed, requested_at=requested_at)
    if out["result"] is None:
        return 409, out
    return (200 if out["ok"] else 502), out


def handle_services_request(method: str, path: str, body, *, hub=None) -> tuple[int, dict]:
    method = (method or "").upper()
    body = body if isinstance(body, dict) else {}
    p = (urlsplit(path or "").path or "").rstrip("/")
    try:
        hub = hub or default_hub()
        from jarvis_services import admin
        if p == "":
            if method != "GET":
                return _err(405, "method not allowed")
            return 200, {"services": hub.snapshots(), "pending": hub.pending(), "ts": time.time()}
        if p == "/config":
            if method == "GET":
                return 200, admin.config_payload(hub)
            if method == "POST":
                try:
                    return 200, {**admin.update_config(hub, body), "ok": True}
                except ValueError as e:
                    return _err(400, str(e))
            return _err(405, "method not allowed")
        if p == "/portfolio":
            if method != "GET":
                return _err(405, "method not allowed")
            return 200, {**hub.portfolio(), "ts": time.time()}
        if p == "/mail/send":
            if method != "POST":
                return _err(405, "method not allowed")
            from jarvis_services import mail_send
            try:
                out = mail_send.send(hub.http, hub.config.load(), to=body.get("to"),
                                     subject=body.get("subject"), text=body.get("text"))
            except ValueError as e:
                return _err(400, str(e))
            return (200 if out["ok"] else 502), out
        if p == "/portfolio/wallets":
            if method != "POST":
                return _err(405, "method not allowed")
            try:
                return 200, admin.update_wallets(hub, body)
            except ValueError as e:
                return _err(400, str(e))
            except KeyError:
                return _err(404, "wallet not found")
        parts = p.lstrip("/").split("/")
        if len(parts) == 2 and parts[1] in ("detail", "action"):
            service_id, what = parts
            try:
                hub.service(service_id)
            except KeyError:
                return _err(404, "unknown service")
            if what == "detail":
                if method != "GET":
                    return _err(405, "method not allowed")
                return 200, hub.detail(service_id)
            if method != "POST":
                return _err(405, "method not allowed")
            return _action(hub, service_id, body)
        return _err(404, "not found")
    except Exception as e:  # noqa: BLE001 — a bug here must answer 500, not drop the request
        log.exception("services: %s %s failed", method, path)
        return _err(500, f"services: {e.__class__.__name__}")
