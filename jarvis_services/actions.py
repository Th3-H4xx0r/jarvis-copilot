"""The only actions a client can ask for, and the rules a request must pass.

A request runs only if (coucou's rules) its kind is on this allowlist and belongs to
the service, it names an item that was offered in the latest detail for that service,
that offer and the request are under 5 minutes old, and, for an action that asks
first, the client says it confirmed. Nothing here moves money or sends an email.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

from typing import Optional

from jarvis_services.base import Action, ActionResult, Detail, Service, ServiceError

#: kind → asks for confirmation first.
ALLOWED = {
    "vercel.redeploy": False,
    "vercel.promote": True,
    "vercel.cancel": True,          # destructive
    "github.rerun": False,          # rerun-failed-jobs, failed runs only
    "github.approve": False,
    "github.merge": True,           # squash, never drafts (not offered on them)
    "n8n.activate": False,
    "n8n.deactivate": True,
    "n8n.retry": False,
}
MAX_AGE = 300


class Refused(Exception):
    """Not run. ``confirm`` is set when only the confirmation was missing."""

    def __init__(self, message: str, confirm: Optional[str] = None):
        super().__init__(message)
        self.message = message
        self.confirm = confirm


def check(service: Service, detail: Optional[Detail], kind: str, target: str, *, now: float,
          requested_at: Optional[float] = None, confirmed: bool = False) -> Action:
    if kind not in ALLOWED or kind not in service.actions or not kind.startswith(service.id + "."):
        raise Refused("This action isn't available.")
    if requested_at is not None and now - requested_at >= MAX_AGE:
        raise Refused("This request is too old. Try again.")
    if detail is None or now - detail.fetched_at >= MAX_AGE:
        raise Refused("This list is out of date. It was refreshed; try again.")
    action = detail.offered(kind, target)
    if action is None:
        raise Refused("This action isn't offered any more. The list was refreshed.")
    if (ALLOWED[kind] or action.confirm) and not confirmed:
        raise Refused("This action needs confirmation.", confirm=action.confirm or f"{action.title}?")
    return action


def perform(service: Service, http, cfg, action: Action, now: float) -> ActionResult:
    """Run an action that passed ``check``. Never raises."""
    try:
        message = service.perform(http, cfg, action.kind, action.target)
        return ActionResult(action.title, True, message, now)
    except ServiceError as e:
        return ActionResult(action.title, False, service.describe(e), now)
    except Exception as e:  # noqa: BLE001 — a bug in one action must not take the server down
        return ActionResult(action.title, False, f"Failed: {e.__class__.__name__}", now)
