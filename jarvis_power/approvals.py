"""Face ID approvals for changes to protected Power integrations.

Switching a protected integration off (from any device, or by Jarvis) and a
settings change Jarvis may only make with Face ID wait here until the iPhone signs
``jarvis-power|<command>|<approval id>|<ts>`` with its Face ID key — the same shared
approver the car, door alarm, vault and security advisor use. The change itself is
bound to the approval id on the server, so the phone approves exactly what was
asked and it runs once. Commands are ``off:<id>`` and ``settings:<id>``.
"""
from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

logger = logging.getLogger(__name__)

DOMAIN = "jarvis-power"
_lock = threading.Lock()
_changes: dict[str, dict] = {}
_approvals = None
_approver = None


def notifier(item: dict) -> None:
    """Tell the phone an approval is waiting. The webui replaces this at boot."""


def _store():
    global _approvals
    if _approvals is None:
        from plugins.toyota.approver import Approvals

        class PowerApprovals(Approvals):
            def create(self, command: str, source: str = "Jarvis") -> dict:
                return super().create(command, source)

        _approvals = PowerApprovals(titles=_Titles(), label="power")
    return _approvals


class _Titles(dict):
    """``off:<id>`` → "Switch off <Name>", ``settings:<id>`` → "Change <Name> settings"."""

    def get(self, command, default=None):
        from jarvis_power import discovery
        verb, _, integration_id = str(command).partition(":")
        p = discovery.integrations().get(integration_id)
        name = p.name if p else integration_id
        if verb == "off":
            return f"Switch off {name}"
        if verb == "settings":
            return f"Change {name} settings"
        return default


def _verifier():
    global _approver
    if _approver is None:
        from plugins.toyota.approver import approver
        _approver = approver()
    return _approver


def reset(approver=None) -> None:
    """Forget every waiting approval (tests pass a fake approver)."""
    global _approvals, _approver
    with _lock:
        _changes.clear()
    _approvals = None
    _approver = approver


def create(command: str, change: dict, source: str = "Jarvis") -> dict:
    """Ask for Face ID. ``change`` is what runs on approval:
    ``{"kind": "enabled"|"settings", "id", "value", "by"}``."""
    item = _store().create(command, source=source)
    with _lock:
        live = {a["id"] for a in _store().pending()}
        for key in [k for k in _changes if k not in live]:
            del _changes[key]
        _changes[item["id"]] = dict(change)
    try:
        notifier(item)
    except Exception:
        logger.warning("power: could not tell the phone about approval %s", item["id"])
    return item


def pending() -> list[dict]:
    return _store().pending()


def approve(approval_id: str, body: dict) -> dict:
    """Verify the phone's Face ID signature, then apply the bound change exactly once."""
    from plugins.toyota.approver import ApprovalError

    item = _store().peek(approval_id)
    _verifier().verify(item["command"], approval_id, body.get("ts"), body.get("signature"),
                       domain=DOMAIN)
    with _lock:
        change = _changes.pop(approval_id, None)
    _store().take(approval_id)               # raises "gone" if answered meanwhile
    if change is None:
        raise ApprovalError("That approval has expired or was already answered.", "gone")
    from jarvis_power import switch
    if change["kind"] == "enabled":
        switch.apply_enabled(change["id"], change["value"], by=change.get("by", "app"))
    else:
        switch.apply_settings(change["id"], change["value"])
    from jarvis_power import api
    return {"ok": True, "row": api.row(change["id"])}


def deny(approval_id: str) -> dict:
    _store().take(approval_id)
    with _lock:
        _changes.pop(approval_id, None)
    return {"ok": True}
