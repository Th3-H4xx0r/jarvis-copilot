"""What the Car page's routes and the toyota_* tools share."""
from __future__ import annotations

import asyncio
import concurrent.futures
from typing import Any, Awaitable

from plugins.toyota.account import ToyotaAccount
from plugins.toyota.car import SIGN_IN_FIRST, NotSignedIn, ToyotaCar
from plugins.toyota.ha import HAClient, HAError

_BLOCKED = {
    "not_installed": "The Toyota integration isn't installed in Home Assistant yet.",
    "signed_out": SIGN_IN_FIRST,
    "reauth": "Toyota signed Jarvis out. Sign in again on the Car page.",
}


def run(coro: Awaitable[Any]) -> Any:
    """Run a coroutine from sync code, whether or not this thread already has a loop."""
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, coro).result()


def blocked_reason(account: dict) -> str | None:
    """Why the car can't be used right now; None when signed in."""
    state = account.get("state")
    if state == "signed_in":
        return None
    return _BLOCKED.get(state) or account.get("reason") or "Toyota isn't available right now."


async def require_signed_in(ha: HAClient) -> None:
    reason = blocked_reason(await ToyotaAccount(ha).state())
    if reason:
        raise NotSignedIn(reason)


async def car_state(ha: HAClient) -> dict[str, Any]:
    """The account and, when signed in, the car's snapshot (or why it couldn't be read)."""
    account = await ToyotaAccount(ha).state()
    out: dict[str, Any] = {"account": account, "car": None}
    if account.get("state") != "signed_in":
        return out
    try:
        out["car"] = await ToyotaCar(ha).snapshot()
    except (NotSignedIn, HAError) as exc:
        out["error"] = str(exc)
    return out
