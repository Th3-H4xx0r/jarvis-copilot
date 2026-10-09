"""Sign in with Toyota — through Home Assistant's own sign-in flow for the Toyota integration.

The email and password go to that flow once and are never stored or logged here. The integration
keeps only tokens (it drops the password before saving) and refreshes them itself. Signing in to
an account Home Assistant already has updates it in place: that is also "Sign in again" after
Toyota signs the integration out.
"""
from __future__ import annotations

import logging
from typing import Any

from plugins.toyota.car import clear_map_cache
from plugins.toyota.entities import DOMAIN
from plugins.toyota.ha import HAClient, HAError

log = logging.getLogger(__name__)

FLOWS = "/api/config/config_entries/flow"
HANDLERS = "/api/config/config_entries/flow_handlers"
STEP_PASSWORD, STEP_CODE = "user", "otp"
# The integration's timed car wakes; "0" = "Cloud updates only", so nothing drains the 12 V battery.
WAKE_OPTION, CLOUD_ONLY = "automatic_wake_interval", "0"

MESSAGES = {
    "not_logged_in": "Toyota didn't accept that email and password.",
    "otp_not_logged_in": "That code didn't work. Use the newest code Toyota sent.",
    "sso_account": ("This Toyota account signs in with Apple, Google or Facebook. In the Toyota app, "
                    "tap Forgot password to set a password, then sign in here with that email and password."),
    "reauth_wrong_account": "That's a different Toyota account from the one already signed in.",
    "unknown": "Toyota sign-in didn't work. Try again.",
}
_DONE_ABORTS = {"reauth_successful", "already_configured"}


class SignInError(Exception):
    """Sign-in can't go on; the message is for Pranav."""


class ToyotaAccount:
    def __init__(self, ha: HAClient) -> None:
        self.ha = ha

    async def state(self) -> dict[str, Any]:
        try:
            if not await self._installed():
                return {"state": "not_installed"}
            entry = await self._entry()
            if entry is None:
                return {"state": "signed_out"}
            known = {"email": entry.get("title")}
            if await self._reauth_pending():
                return {"state": "reauth", **known}
            if entry.get("state") == "loaded":
                return {"state": "signed_in", **known}
            reason = entry.get("reason") or "Toyota isn't answering; Home Assistant keeps trying."
            return {"state": "unavailable", "reason": str(reason), **known}
        except HAError as exc:
            return {"state": "ha_unreachable", "reason": str(exc)}

    async def sign_in(self, email: Any, password: Any) -> dict[str, Any]:
        email = str(email or "").strip()
        password = "" if password is None else str(password)
        if not email or not password:
            raise SignInError("Enter your Toyota email and password.")
        if not await self._installed():
            raise SignInError("Toyota isn't set up in Home Assistant yet.")
        # Toyota signed the integration out: Home Assistant holds a re-auth flow for the account,
        # and a second flow for it would be refused — answer that one instead.
        flows = await self._flows_or_none()
        reauth = next((f for f in flows if (f.get("context") or {}).get("source") == "reauth"
                       and f.get("flow_id") and f.get("step_id") == STEP_PASSWORD), None)
        if reauth is not None:
            answer = await self.ha.post(f"{FLOWS}/{reauth['flow_id']}",
                                        {"username": email, "password": password}, timeout=60)
            return await self._next(answer)
        await self._drop_unfinished_sign_ins(flows)
        flow = await self.ha.post(FLOWS, {"handler": DOMAIN, "show_advanced_options": False})
        if not isinstance(flow, dict) or flow.get("step_id") != STEP_PASSWORD or not flow.get("flow_id"):
            return await self._next(flow)
        answer = await self.ha.post(f"{FLOWS}/{flow['flow_id']}",
                                    {"username": email, "password": password}, timeout=60)
        return await self._next(answer)

    async def submit_code(self, flow_id: Any, code: Any) -> dict[str, Any]:
        flow_id = str(flow_id or "").strip()
        code = str(code or "").strip()
        if not flow_id or not flow_id.replace("-", "").replace("_", "").isalnum():
            raise SignInError("Start again: sign in with your email and password.")
        if not code:
            raise SignInError("Enter the code Toyota sent you.")
        try:
            answer = await self.ha.post(f"{FLOWS}/{flow_id}", {"code": code}, timeout=60)
        except HAError as exc:
            if exc.status == 404:
                raise SignInError("That sign-in expired. Start again with your email and password.") from exc
            raise
        return await self._next(answer)

    async def sign_out(self) -> dict[str, Any]:
        entry = await self._entry()
        if entry is not None:
            await self.ha.delete(f"/api/config/config_entries/entry/{entry['entry_id']}")
        clear_map_cache()
        return {"ok": True}

    async def _next(self, answer: Any) -> dict[str, Any]:
        if not isinstance(answer, dict):
            raise SignInError(MESSAGES["unknown"])
        kind = answer.get("type")
        if kind == "form":
            error = (answer.get("errors") or {}).get("base")
            if error:
                raise SignInError(MESSAGES.get(error, MESSAGES["unknown"]))
            if answer.get("step_id") == STEP_CODE and answer.get("flow_id"):
                return {"step": "code", "flow_id": answer["flow_id"]}
            raise SignInError(MESSAGES["unknown"])
        if kind == "create_entry":
            return await self._signed_in((answer.get("result") or {}).get("entry_id"))
        if kind == "abort":
            reason = answer.get("reason")
            if reason in _DONE_ABORTS:
                return await self._signed_in(None)
            raise SignInError(MESSAGES.get(reason, f"Toyota sign-in stopped ({reason})."))
        raise SignInError(MESSAGES["unknown"])

    async def _installed(self) -> bool:
        return DOMAIN in (await self.ha.get(HANDLERS) or [])

    async def _entry(self) -> dict | None:
        entries = await self.ha.get(f"/api/config/config_entries/entry?domain={DOMAIN}") or []
        entries = [e for e in entries if isinstance(e, dict) and e.get("entry_id")]
        return entries[0] if entries else None

    async def _flows(self) -> list[dict]:
        return [f for f in await self.ha.flows_in_progress() if f.get("handler") == DOMAIN]

    async def _reauth_pending(self) -> bool:
        return any((f.get("context") or {}).get("source") == "reauth" for f in await self._flows())

    async def _flows_or_none(self) -> list[dict]:
        try:
            return await self._flows()
        except HAError:
            return []

    async def _drop_unfinished_sign_ins(self, flows: list[dict]) -> None:
        """Abandoned sign-ins from earlier tries go; Home Assistant's own re-auth prompt stays."""
        for flow in flows:
            if (flow.get("context") or {}).get("source") == "user" and flow.get("flow_id"):
                try:
                    await self.ha.delete(f"{FLOWS}/{flow['flow_id']}")
                except HAError:
                    log.debug("Couldn't drop an unfinished Toyota sign-in")

    async def _signed_in(self, entry_id: Any) -> dict[str, Any]:
        """Done — and on every way here (new entry, re-auth, existing entry), no timed car wakes."""
        clear_map_cache()
        out: dict[str, Any] = {"step": "done"}
        if not await self._cloud_updates_only(entry_id):
            out["warning"] = ("Signed in, but Home Assistant didn't take 'Cloud updates only'; it may "
                              "wake the car every few hours. Set it in the Toyota integration's options.")
        return out

    async def _cloud_updates_only(self, entry_id: Any) -> bool:
        try:
            if not entry_id:
                entry = await self._entry()
                entry_id = entry and entry.get("entry_id")
            if not entry_id:
                return False
            form = await self.ha.post("/api/config/config_entries/options/flow", {"handler": entry_id})
            done = await self.ha.post(f"/api/config/config_entries/options/flow/{form['flow_id']}",
                                      {WAKE_OPTION: CLOUD_ONLY})
            if isinstance(done, dict) and done.get("type") == "create_entry":
                return True
            log.warning("Toyota signed in, but 'Cloud updates only' was refused: %s", done)
        except (HAError, KeyError, TypeError) as exc:
            log.warning("Toyota signed in, but setting 'Cloud updates only' failed: %s", exc)
        return False
