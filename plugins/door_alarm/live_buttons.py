"""What the phone's live buttons show for the door alarm — pure, no I/O.

When what a door button shows changes (the state, the siren, a new deadline), the service tells the
phone (hidden skill ``live_state``), refreshes the Control Center tiles (APNs ``widgets`` push) and
moves the Lock Screen card / Dynamic Island (Live Activity pushes, ``ButtonActivityAttributes``).

``button_state`` is the Swift ``ButtonLiveState`` as JSON, key for key (camelCase). Its dates are
what ActivityKit's default ``JSONDecoder`` reads (``.deferredToDate``): a Double of seconds since
2001-01-01 UTC — NOT Unix time (``apple_date``).
"""
from __future__ import annotations

from typing import Any, Optional

SOURCE = "door"
#: 2001-01-01T00:00:00Z in Unix seconds — Foundation's reference date.
APPLE_EPOCH = 978307200.0
#: States with a card up (something counting down or going off).
ACTIVE = ("arming", "entry", "triggered")
ATTRIBUTES_TYPE = "ButtonActivityAttributes"
ATTRIBUTES = {"source": SOURCE, "buttonID": "", "name": "Door alarm", "symbol": "lock.shield"}
#: How long a card shows its result ("Armed Away") before it goes.
DISMISS_AFTER = 5


def apple_date(ts: Optional[float]) -> Optional[float]:
    """Unix seconds → seconds since 2001-01-01, how Swift's default JSONDecoder reads a ``Date``."""
    return None if ts is None else float(ts) - APPLE_EPOCH


def key(alarm: dict) -> tuple:
    """What a door button's look depends on: a change here is worth telling the phone about."""
    state = alarm.get("state")
    deadline = alarm.get("deadline") if state in ("arming", "entry") else None
    return state, alarm.get("mode"), deadline, bool(alarm.get("siren_on"))


def _state(id_: str, title: str, symbol: str, caption: Optional[str] = None, alert: bool = False,
           started: Optional[float] = None, ends: Optional[float] = None) -> dict:
    out: dict[str, Any] = {"id": id_, "title": title, "symbol": symbol, "alert": alert}
    if caption:
        out["caption"] = caption
    if started is not None:
        out["startedAt"] = apple_date(started)
    if ends is not None:
        out["endsAt"] = apple_date(ends)
    return out


def button_state(alarm: dict) -> dict:
    """The ``ButtonLiveState`` for the alarm (``alarm`` = DoorService.state()["alarm"]): what a
    press does now. Same ids and symbols as the app's own resolver (ButtonStates.swift)."""
    state, mode = alarm.get("state"), alarm.get("mode")
    name = alarm.get("contact_name") or "A door"
    if state == "arming":
        return _state("door.arming", "Stop arming", "stop.circle.fill", "Home in" if mode == "home" else "Away in",
                      started=alarm.get("since"), ends=alarm.get("deadline"))
    if state == "entry":
        return _state("door.entry", "Disarm", "lock.open.fill", f"{name} opened", alert=True,
                      started=alarm.get("since"), ends=alarm.get("deadline"))
    if state == "triggered":
        siren = bool(alarm.get("siren_on"))
        caption = f"Alarm — {alarm['contact_name']}" if alarm.get("contact_name") else "Alarm going off"
        return _state("door.siren" if siren else "door.triggered", "Silence" if siren else "Disarm",
                      "speaker.slash.fill" if siren else "lock.open.fill", caption, alert=True,
                      started=alarm.get("triggered_at") or alarm.get("since"))
    if state in ("armed_away", "armed_home"):
        home = state == "armed_home"
        return _state(f"door.{state}", "Disarm", "lock.open.fill", "Armed Home" if home else "Armed Away")
    return _state("door.disarmed", "Disarmed", "shield.slash")


def content(state: dict, finished: bool = False, result: Optional[str] = None) -> dict:
    """``ButtonActivityAttributes.ContentState``."""
    out: dict[str, Any] = {"state": state, "finished": finished}
    if result:
        out["result"] = result
    return out


def result(before: str, after: str) -> str:
    """What the card says as it goes."""
    if (before, after) == ("arming", "disarmed"):
        return "Arming cancelled"
    return {"armed_away": "Armed Away", "armed_home": "Armed Home"}.get(after, "Disarmed")


def start_alert(alarm: dict) -> dict:
    """The (silent) alert a push-to-start must carry."""
    state = alarm.get("state")
    if state == "arming":
        body = "Arming Home" if alarm.get("mode") == "home" else "Arming Away"
    elif state == "entry":
        body = f"{alarm.get('contact_name') or 'A door'} opened"
    else:
        body = "Alarm going off"
    return {"title": "Door alarm", "body": body}


def stale_after(alarm: dict, now: float) -> int:
    """Seconds until the card counts as stale: just past its countdown, else an hour."""
    deadline = alarm.get("deadline") if alarm.get("state") in ("arming", "entry") else None
    if deadline:
        return max(30, int(deadline - now) + 30)
    return 3600
