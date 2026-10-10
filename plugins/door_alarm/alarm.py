"""The security alarm itself — pure logic, no I/O. The service persists ``snapshot()`` after every
change and carries out the returned effects (siren, pushes, phone ring, Pod page, prompts).

States: disarmed · arming (exit delay) · armed_away · armed_home · entry (entry delay) · triggered.
Deadlines are wall-clock times, so a restart resumes them (or fires at once if one passed).
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

DEFAULTS = {"exit_delay": 60, "entry_delay": 30, "siren_duration": 180}
BOUNDS = {"exit_delay": (0, 300), "entry_delay": (0, 300), "siren_duration": (10, 900)}
ARMED = ("armed_away", "armed_home")


@dataclass
class Effect:
    kind: str     # siren_on siren_off push_entry push_triggered push_info ring_phone stop_ring pod_alert note prompt
    data: dict = field(default_factory=dict)


class ArmRefused(Exception):
    def __init__(self, open_contacts: list[dict]) -> None:
        names = ", ".join(c.get("name") or c.get("id") for c in open_contacts)
        super().__init__(f"{names} {'is' if len(open_contacts) == 1 else 'are'} open. Close it or bypass it to arm.")
        self.open_contacts = open_contacts


def clamp_settings(settings: dict) -> dict:
    out = dict(DEFAULTS)
    for key, (lo, hi) in BOUNDS.items():
        if key in (settings or {}):
            try:
                out[key] = max(lo, min(hi, int(settings[key])))
            except (TypeError, ValueError):
                pass
    return out


class Alarm:
    def __init__(self, settings: dict, contacts: Callable[[], list[dict]], clock: Callable[[], float] = time.time,
                 state: Optional[dict] = None) -> None:
        self.settings = clamp_settings(settings)
        self.contacts = contacts
        self.clock = clock
        s = state or {}
        self.state: str = s.get("state") if s.get("state") in ("disarmed", "arming", "armed_away", "armed_home",
                                                              "entry", "triggered") else "disarmed"
        self.mode: Optional[str] = s.get("mode")
        self.deadline: Optional[float] = s.get("deadline")
        self.contact: Optional[str] = s.get("contact")
        self.contact_name: Optional[str] = s.get("contact_name")
        self.siren_until: Optional[float] = s.get("siren_until")
        self.since: float = s.get("since") or self.clock()
        self.triggered_at: Optional[float] = s.get("triggered_at")
        self.bypass: list[str] = list(s.get("bypass") or [])

    # ── views ──

    @property
    def siren_on(self) -> bool:
        return self.state == "triggered" and self.siren_until is not None

    def snapshot(self) -> dict:
        return {"state": self.state, "mode": self.mode, "deadline": self.deadline, "contact": self.contact,
                "contact_name": self.contact_name, "siren_until": self.siren_until, "since": self.since,
                "triggered_at": self.triggered_at, "bypass": self.bypass}

    def public(self) -> dict:
        left = None
        if self.deadline is not None and self.state in ("arming", "entry"):
            left = max(0, math.ceil(self.deadline - self.clock()))
        deadline = self.deadline if self.state in ("arming", "entry") else None
        return {"state": self.state, "mode": self.mode, "seconds_left": left, "deadline": deadline,
                "siren_until": self.siren_until, "contact": self.contact,
                "contact_name": self.contact_name, "siren_on": self.siren_on, "since": self.since,
                "triggered_at": self.triggered_at, "bypass": self.bypass, "settings": dict(self.settings)}

    def _set(self, state: str) -> None:
        self.state = state
        self.since = self.clock()

    # ── commands ──

    def arm(self, mode: str, bypass: list[str] | tuple = ()) -> list[Effect]:
        if mode not in ("away", "home"):
            raise ValueError("Arm 'away' or 'home'.")
        if self.state in ("entry", "triggered"):
            raise ValueError("The alarm is going off — disarm it first.")
        bypass = [str(b) for b in bypass or []]
        contacts = self.contacts()
        if not contacts:
            raise ValueError("No doors yet: open each door once so the hub reports it, then arm.")
        watched = [c for c in contacts if mode == "away" or c.get("active_home", True)]
        blocking = [c for c in watched if c.get("open") is True and c["id"] not in bypass]
        if blocking:
            raise ArmRefused(blocking)
        self.mode, self.bypass, self.contact, self.contact_name = mode, bypass, None, None
        self.siren_until = self.triggered_at = None
        if mode == "away" and self.settings["exit_delay"] > 0:
            self._set("arming")
            self.deadline = self.clock() + self.settings["exit_delay"]
        else:
            self._set("armed_away" if mode == "away" else "armed_home")
            self.deadline = None
        return [Effect("note", {"text": f"Armed {mode}" + (f" (bypassing {', '.join(bypass)})" if bypass else ""),
                                "state": True})]

    def arm_now(self) -> list[Effect]:
        """Skip the rest of the exit delay: armed away at once."""
        if self.state != "arming":
            raise ValueError("Arm now only works while the exit delay is counting down.")
        self._set("armed_away")
        self.deadline = None
        return [Effect("note", {"text": "Armed away", "state": True})]

    def cancel_arming(self) -> list[Effect]:
        """Stop an Away arming during its exit delay (nothing is watched yet). Once armed, turning it
        off is a disarm, which needs Face ID."""
        if self.state != "arming":
            raise ValueError("There's no arming to cancel.")
        self._set("disarmed")
        self.mode = self.deadline = None
        self.bypass = []
        return [Effect("note", {"text": "Arming cancelled", "state": True})]

    def disarm(self) -> list[Effect]:
        if self.state == "disarmed":
            return []
        effects: list[Effect] = []
        if self.state == "triggered":
            # Always, even after the siren timed out: that timeout's write may not have reached the hub.
            effects += [Effect("siren_off"), Effect("stop_ring")]
        self._set("disarmed")
        self.mode = self.deadline = self.contact = self.contact_name = self.siren_until = self.triggered_at = None
        self.bypass = []
        effects.append(Effect("note", {"text": "Disarmed", "state": True}))
        return effects

    def silence(self) -> list[Effect]:
        if self.state != "triggered":
            return []
        self.siren_until = None
        return [Effect("siren_off"), Effect("stop_ring")]

    # ── events ──

    def door_opened(self, contact: dict) -> list[Effect]:
        effects = self._alarm_effects(contact)
        prompt = (contact.get("on_open_prompt") or "").strip()
        if prompt:
            effects.append(Effect("prompt", {"prompt": prompt, "contact": contact["id"], "name": contact.get("name")}))
        return effects

    def _alarm_effects(self, contact: dict) -> list[Effect]:
        name = contact.get("name") or contact["id"]
        if self.state == "disarmed":
            return [Effect("push_info", {"name": name, "contact": contact["id"]})] if contact.get("notify_disarmed") else []
        if self.state == "arming":
            return []
        if self.state == "triggered":
            self.siren_until = self.clock() + self.settings["siren_duration"]
            return [Effect("siren_on"), Effect("note", {"text": f"{name} opened again while the alarm is going off"})]
        if contact["id"] in self.bypass:
            return []
        if self.mode == "home" and not contact.get("active_home", True):
            return []
        if self.state == "entry":
            return self._trigger(contact) if contact.get("instant") else []
        # armed_away / armed_home
        if contact.get("instant") or self.settings["entry_delay"] == 0:
            return self._trigger(contact)
        self._set("entry")
        self.deadline = self.clock() + self.settings["entry_delay"]
        self.contact, self.contact_name = contact["id"], name
        return [Effect("push_entry", {"name": name, "contact": contact["id"], "seconds": self.settings["entry_delay"]})]

    def _trigger(self, contact: Optional[dict]) -> list[Effect]:
        if contact:
            self.contact, self.contact_name = contact["id"], contact.get("name") or contact["id"]
        self._set("triggered")
        self.triggered_at = self.clock()
        self.deadline = None
        self.siren_until = self.clock() + self.settings["siren_duration"]
        data = {"name": self.contact_name, "contact": self.contact, "mode": self.mode}
        return [Effect("siren_on"), Effect("push_triggered", data), Effect("ring_phone", data),
                Effect("pod_alert", data), Effect("note", {"text": f"ALARM: {self.contact_name} opened", "state": True, **data})]

    def tick(self) -> list[Effect]:
        now = self.clock()
        if self.state == "arming" and self.deadline is not None and now >= self.deadline:
            self._set("armed_away")
            self.deadline = None
            return [Effect("note", {"text": "Armed away", "state": True})]
        if self.state == "entry" and self.deadline is not None and now >= self.deadline:
            return self._trigger(None)
        if self.state == "triggered" and self.siren_until is not None and now >= self.siren_until:
            self.siren_until = None
            return [Effect("siren_off")]
        return []

    def update_settings(self, changes: dict[str, Any]) -> dict:
        merged = dict(self.settings)
        merged.update({k: v for k, v in (changes or {}).items() if k in DEFAULTS})
        self.settings = clamp_settings(merged)
        return dict(self.settings)
