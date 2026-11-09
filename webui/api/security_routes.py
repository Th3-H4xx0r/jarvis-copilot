"""HTTP API for the Security page: ``/api/security/*`` (Security Advisor).

``handle_security_request(method, path, body, query, host_signed, actor, ...)`` returns
``(status, payload)``. Reads are open to any authenticated caller (Jarvis's read-only tools
use the host-signed loopback). Every change — settings, undo, alert answers — needs a
paired device's session (``actor.session_kind == "paired"``), never ``host_signed`` or a
password-only session; Block and Allow also need a Face ID signature
(``plugins/toyota/approver.py``, domain ``jarvis-security``, command ``"<action>:<id>"``)::

    GET  /status                       -> {state, open_alerts, blocks, last_event, sources, chain_ok}
    GET  /events?since=&kind=&outcome=&limit=&after_id=   -> {events: [{id, ts, source, kind,
                                          title (plain words), actor (one line), actor_info,
                                          detail, outcome}]}
    GET  /alerts?status=               -> {alerts: [...]}
    GET  /blocks                       -> {blocks: [{ip, reason, created, until, event_id}]}
    GET  /digests                      -> {digests: [{id, day, created, text, data}]}
    GET  /settings                     -> {settings, model: {provider, model}, models, rules}
    POST /alerts/<id>/resolve {action: block|allow|dismiss, nonce?, ts?, signature?}
    POST /blocks/<ip>/undo
    POST /settings {settings?: {...partial}, model?: {provider, model}}
"""
from __future__ import annotations

import logging
import time
from datetime import datetime, timezone
from urllib.parse import unquote

logger = logging.getLogger(__name__)

ALLOW_DAYS = 7
DOMAIN = "jarvis-security"


def _iso(ts) -> str | None:
    try:
        return datetime.fromtimestamp(float(ts), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OverflowError):
        return None


def _q(query: dict, key: str, default: str = "") -> str:
    v = (query or {}).get(key)
    if isinstance(v, list):
        v = v[0] if v else default
    return str(v if v is not None else default).strip()


def _actor_line(actor: dict) -> str:
    actor = actor or {}
    parts = [actor.get("ip"), actor.get("device_name") or actor.get("device_id"),
             actor.get("user") and f"user {actor['user']}", actor.get("sender_id"),
             actor.get("platform")]
    return " · ".join(str(p) for p in parts if p)


def _event_out(e) -> dict:
    from plugins.security_advisor.labels import title_for
    return {"id": e.id, "ts": e.ts, "source": e.source, "kind": e.kind,
            "title": title_for(e.kind, e.actor, e.detail),
            "actor": _actor_line(e.actor), "actor_info": e.actor, "detail": e.detail,
            "outcome": e.outcome}


def _alert_out(a: dict) -> dict:
    out = dict(a)
    out["ip"] = (a.get("actor") or {}).get("ip") or ""
    return out


def _models() -> list:
    """The models the other pickers offer (web + phone), flattened."""
    try:
        from api.config import get_available_models, picker_catalog
        out = []
        for g in picker_catalog(get_available_models()).get("groups") or []:
            provider = g.get("provider_id") or g.get("provider") or ""
            for m in g.get("models") or []:
                mid = m.get("id") if isinstance(m, dict) else m
                if mid:
                    label = m.get("label") if isinstance(m, dict) else mid
                    out.append({"provider": provider, "model": str(mid), "label": label or str(mid)})
        return out
    except Exception:
        logger.debug("security: model list unavailable", exc_info=True)
        return []


def _save_model(model: dict) -> None:
    provider = str((model or {}).get("provider") or "").strip()
    name = str((model or {}).get("model") or "").strip()
    if not provider or not name or len(provider) > 64 or len(name) > 200:
        raise ValueError("model needs a provider and a model")
    from jarviscopilot_cli.config import read_raw_config, save_config
    cfg = read_raw_config()
    aux = cfg.get("auxiliary") if isinstance(cfg.get("auxiliary"), dict) else {}
    task = aux.get("security_advisor") if isinstance(aux.get("security_advisor"), dict) else {}
    task.update({"provider": provider, "model": name})
    aux["security_advisor"] = task
    cfg["auxiliary"] = aux
    save_config(cfg)


def _settings_payload(models: bool = True) -> dict:
    from plugins.security_advisor import rules, settings, triage
    current = settings.load()
    disabled = set(current.get("disabled_rules") or [])
    provider, model = triage.resolve_model()
    return {
        "settings": current,
        "model": {"provider": provider, "model": model},
        "models": _models() if models else [],
        "rules": [{"id": r["name"], "title": r["description"], "enabled": r["name"] not in disabled}
                  for r in rules.RULES],
    }


def _block_refusal(ip: str, log) -> str | None:
    """Why ``ip`` must never be blocked by hand (his networks or devices), or None."""
    from plugins.security_advisor.rules import is_protected_ip
    from plugins.security_advisor.service import SESSION_TRUST_DAYS, ip_had_session
    if is_protected_ip(ip):
        return (f"{ip} is loopback, your home network, link-local or Tailscale, "
                "so it can't be blocked.")
    if ip_had_session(log, ip):
        return (f"{ip} signed in to Jarvis with a valid session in the last "
                f"{SESSION_TRUST_DAYS} days, so blocking it could lock you out.")
    return None


def _forbid(msg: str = "Only a paired device can change the Security Advisor."):
    return 403, {"ok": False, "error": msg, "code": "forbidden"}


def handle_security_request(method, path, body, query, host_signed=False, actor=None,
                            log=None, blocklist=None, approver=None):
    from security.blocklist import default_blocklist
    from security.events import default_log, emit
    log = log or default_log()
    blocklist = blocklist or default_blocklist()
    actor = actor or {}
    body = body if isinstance(body, dict) else {}
    path = (path or "/").split("?", 1)[0].rstrip("/") or "/"

    if method == "GET":
        if path == "/status":
            from plugins.security_advisor.service import SecurityService, snapshot
            running = SecurityService._instance
            if running is not None and running.log is log:
                return 200, running.status()
            return 200, snapshot(log, blocklist)
        if path == "/events":
            kinds = [k for k in _q(query, "kind").split(",") if k] or None
            try:
                limit = min(max(int(_q(query, "limit", "200") or 200), 1), 500)
                after_id = int(_q(query, "after_id", "0") or 0)
            except ValueError:
                return 400, {"ok": False, "error": "limit and after_id must be numbers"}
            events = log.query(since=_q(query, "since") or None, kinds=kinds,
                               outcome=_q(query, "outcome") or None, limit=limit, after_id=after_id)
            return 200, {"events": [_event_out(e) for e in events]}
        if path == "/alerts":
            return 200, {"alerts": [_alert_out(a) for a in
                                    log.list_alerts(status=_q(query, "status") or None)]}
        if path == "/blocks":
            return 200, {"blocks": [{"ip": b["ip"], "reason": b.get("reason") or "",
                                     "created": _iso(b.get("created")), "until": _iso(b.get("expires")),
                                     "event_id": b.get("event_id")} for b in blocklist.active()]}
        if path == "/digests":
            return 200, {"digests": log.list_digests()}
        if path == "/settings":
            return 200, _settings_payload()
        return 404, {"ok": False, "error": "not found"}

    if method != "POST":
        return 405, {"ok": False, "error": "method not allowed"}
    # Every change comes from one of his paired devices: never the agent's host-signed
    # loopback, never a password-only browser session.
    if host_signed or actor.get("session_kind") != "paired":
        return _forbid()
    who = actor.get("device_name") or actor.get("device_id") or actor.get("ip") or "session"

    if path == "/settings":
        from plugins.security_advisor import settings
        patch = body.get("settings") if ("settings" in body or "model" in body) else body
        extra = set(body) - {"settings", "model"} if patch is not body else set()
        if extra:
            return 400, {"ok": False, "error": f"unknown field: {sorted(extra)[0]}"}
        if patch is not None and not isinstance(patch, dict):
            return 400, {"ok": False, "error": "settings must be an object"}
        if "exceptions" in (patch or {}):
            # Only an alert's Face ID–signed Allow may add an exception.
            return 400, {"ok": False, "error": "exceptions are set from an alert's Allow button"}
        try:
            if patch:
                settings.save(patch)
            if body.get("model"):
                _save_model(body["model"])
        except ValueError as e:
            return 400, {"ok": False, "error": str(e)}
        emit("device", "advisor.changed", actor, action="settings",
             keys=sorted((patch or {}).keys()), model=bool(body.get("model")))
        return 200, {"ok": True, **_settings_payload(models=False)}

    parts = path.strip("/").split("/")
    if len(parts) == 3 and parts[0] == "blocks" and parts[2] == "undo":
        ip = unquote(parts[1])
        removed = blocklist.unblock(ip)
        emit("device", "advisor.changed", actor, action="unblock", ip=ip)
        return 200, {"ok": True, "removed": removed}

    if len(parts) == 3 and parts[0] == "alerts" and parts[2] == "resolve":
        try:
            alert_id = int(parts[1])
        except ValueError:
            return 404, {"ok": False, "error": "no such alert"}
        alert = log.get_alert(alert_id)
        if alert is None:
            return 404, {"ok": False, "error": "no such alert"}
        action = str(body.get("action") or "")
        if action not in ("block", "allow", "dismiss"):
            return 400, {"ok": False, "error": "action must be block, allow or dismiss"}
        ip = (alert.get("actor") or {}).get("ip") or ""
        if action in ("block", "allow"):
            from plugins.toyota.approver import ApprovalError
            if approver is None:
                from plugins.toyota.approver import approver as _approver
                approver = _approver()
            try:
                approver.verify(f"{action}:{alert_id}", body.get("nonce"), body.get("ts"),
                                body.get("signature"), domain=DOMAIN)
            except ApprovalError as e:
                return 403, {"ok": False, "error": str(e), "code": e.code}
        from plugins.security_advisor import settings
        if action == "block":
            if not ip:
                return 400, {"ok": False, "error": "this alert has no IP address to block"}
            refusal = _block_refusal(ip, log)
            if refusal:
                return 409, {"ok": False, "error": refusal, "code": "protected"}
            ttl = int(settings.load().get("block_ttl_hours", 24)) * 3600
            blocklist.block(ip, reason=f"Blocked from alert: {alert['title']}", ttl_s=ttl,
                            event_id=alert.get("event_id"))
            status = "blocked"
        elif action == "allow":
            if ip:
                exceptions = dict(settings.load().get("exceptions") or {})
                exceptions[ip] = time.time() + ALLOW_DAYS * 86400
                settings.save({"exceptions": exceptions})
                blocklist.unblock(ip)
            status = "allowed"
        else:
            status = "dismissed"
        updated = log.resolve_alert(alert_id, status, by=str(who))
        emit("device", "advisor.changed", actor, action=action, alert_id=alert_id, ip=ip)
        return 200, {"ok": True, "alert": _alert_out(updated)}

    return 404, {"ok": False, "error": "not found"}


def route(req) -> bool:
    """Mounted at /api/security (api/mounts.py)."""
    from security.netid import actor_for
    status, payload = handle_security_request(
        req.method, req.sub, req.body, req.query, host_signed=req.host_signed,
        actor=actor_for(req.handler))
    return req.reply(status, payload)
