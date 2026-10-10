"""The hub as the server knows it: every DP value, the door contacts, and both links' health.

Reports arrive from the ESP32 proxy (DP ids, local) and Tuya's cloud feed (codes). The same change
seen on both within ``DEDUPE_S`` counts once. Door contacts come from the "door" role:
- one contact per door DP (a bool or open/close enum) — open/closed state;
- or a single DP whose value names the sensor that fired (an enum/string/number of sensor ids) —
  each report is "that sensor opened", contacts are learned as they first appear.
A snapshot (a DP query after reconnect, a cloud status read) never invents an opening: it only
reports a door whose known state changed while nobody was listening (``missed``).
"""
from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, fields
from typing import Any, Callable, Optional

from plugins.door_alarm import schema
from plugins.door_alarm.store import DoorStore

DEDUPE_S = 30.0       # the same change from the OTHER link within this is one event (the cloud lags)
SAME_LINK_S = 1.0     # a repeat from the same link this fast is a duplicate frame, not a new opening
LATE_S = 120.0        # a report older than this (queued while a link was down) is history, not an alarm
OPEN_WORDS = {"open", "opened", "true", "1", "on", "alarm", "trigger", "triggered"}
CLOSE_WORDS = {"close", "closed", "false", "0", "off", "normal", "none"}

CONTACT_DEFAULTS = {"instant": False, "active_home": True, "notify_disarmed": False, "on_open_prompt": ""}


@dataclass
class Change:
    kind: str                 # door | value
    code: str
    value: Any
    contact: Optional[str] = None
    open: Optional[bool] = None
    source: str = ""
    t: float = 0.0
    missed: bool = False
    late: bool = False


def _dp_from_public(d: dict) -> schema.Dp:
    names = {f.name for f in fields(schema.Dp)}
    return schema.Dp(**{k: v for k, v in d.items() if k in names})


class Hub:
    def __init__(self, store: DoorStore, clock: Callable[[], float] = time.time) -> None:
        self.store = store
        self.clock = clock
        self.lock = threading.RLock()
        self.values: dict[str, dict] = {}
        self._recent: dict[tuple, float] = {}
        self._doors: dict[str, dict] = {}     # contact id -> {open, last_open, last_close}
        self.link = {"local": {"state": "unconfigured", "seen": None},
                     "cloud": {"state": "off", "seen": None, "online": None, "error": ""}}
        self.reload()
        self._seed_from_history()

    # ── configuration ──

    def reload(self) -> None:
        with self.lock:
            cfg = self.store.config()
            self.cfg = cfg
            self.dps = {int(d["id"]): _dp_from_public(d) for d in cfg.get("dps") or [] if "id" in d}
            self.by_code = {dp.code: dp for dp in self.dps.values()}
            roles = dict(cfg.get("roles") or schema.roles(self.dps, cfg.get("product_id")))
            # A product file written after setup (mapping roles with Pranav) wins without a re-pick.
            override = schema.product_file(cfg.get("product_id")).get("roles") or {}
            roles.update({k: [str(c) for c in v or []] for k, v in override.items()})
            self.roles = roles
            self.door_codes = [c for c in self.roles.get("door") or [] if c in self.by_code]
            self.open_values = cfg.get("open_values") or {}

    @property
    def configured(self) -> bool:
        return bool(self.cfg.get("dev_id"))

    def _by_value(self, code: str) -> bool:
        """True when this door DP's value names the sensor (not its open/closed state)."""
        kind = (self.cfg.get("door_kind") or {}).get(code)
        if kind in ("state", "by_value"):
            return kind == "by_value"
        dp = self.by_code.get(code)
        if dp is None or dp.type == "bool" or len(self.door_codes) > 1:
            return False
        if dp.type == "enum":
            words = {str(v).lower() for v in dp.range}
            return not words <= (OPEN_WORDS | CLOSE_WORDS)
        return dp.type in ("string", "raw", "value")

    def _is_open(self, code: str, value: Any) -> bool:
        if code in self.open_values:
            return value in self.open_values[code] or str(value).lower() in {str(v).lower() for v in self.open_values[code]}
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() in OPEN_WORDS

    # ── contacts ──

    def contacts(self) -> list[dict]:
        with self.lock:
            settings = self.cfg.get("contacts") or {}
            ids: list[tuple[str, str]] = []
            for n, code in enumerate(self.door_codes, 1):
                if self._by_value(code):
                    for value in (self.cfg.get("learned") or {}).get(code, []):
                        ids.append((f"{code}={value}", f"Sensor {len(ids) + 1}"))
                else:
                    dp = self.by_code[code]
                    default = dp.name if dp.name and dp.name != code else ("Door" if len(self.door_codes) == 1 else f"Door {n}")
                    ids.append((f"dp:{code}", default))
            out = []
            for cid, default_name in ids:
                own = settings.get(cid) or {}
                door = self._doors.get(cid) or {}
                out.append({"id": cid, "name": own.get("name") or default_name,
                            **{k: own.get(k, v) for k, v in CONTACT_DEFAULTS.items()},
                            "open": door.get("open"), "last_open": door.get("last_open"),
                            "last_close": door.get("last_close")})
            return out

    def contact(self, contact_id: str) -> Optional[dict]:
        return next((c for c in self.contacts() if c["id"] == contact_id), None)

    def open_contacts(self) -> list[dict]:
        return [c for c in self.contacts() if c.get("open") is True]

    def _learn(self, code: str, value: Any) -> None:
        learned = dict(self.cfg.get("learned") or {})
        seen = list(learned.get(code) or [])
        if str(value) not in seen:
            seen.append(str(value))
            learned[code] = seen
            self.cfg = self.store.update_config(learned=learned)

    def _seed_from_history(self) -> None:
        for event in reversed(self.store.events(limit=500)):
            if event.get("kind") != "door" or not event.get("contact"):
                continue
            door = self._doors.setdefault(event["contact"], {})
            if event.get("by_value") or "=" in event["contact"]:
                door["last_open"] = event.get("t")   # "this sensor fired": never an open/closed state
                continue
            door["open"] = event.get("open")
            door["last_open" if event.get("open") else "last_close"] = event.get("t")
            if event.get("open") is False:
                door["seen_close"] = True

    # ── reports ──

    def apply(self, reports: list[dict], source: str, snapshot: bool = False) -> list[Change]:
        now = self.clock()
        changes: list[Change] = []
        with self.lock:
            if source == "esp32":
                self.link["local"]["seen"] = now
            elif source == "cloud":
                self.link["cloud"]["seen"] = now
            for report in reports:
                code = report.get("code")
                if not code and report.get("dp_id") is not None:
                    try:
                        dp = self.dps.get(int(report["dp_id"]))
                    except (TypeError, ValueError):
                        dp = None
                    code = dp.code if dp else str(report["dp_id"])
                if not code:
                    continue
                value = report.get("value")
                at = self._report_time(report.get("t"), now)
                prev = self.values.get(code)
                self.values[code] = {"value": value, "t": at, "source": source}
                if code in self.door_codes:
                    change = self._door(code, value, source, now, snapshot)
                    if change:
                        change.t, change.late = at, now - at > LATE_S
                        changes.append(change)
                elif not snapshot and (prev is None or prev.get("value") != value):
                    changes.append(Change("value", code, value, source=source, t=at, late=now - at > LATE_S))
        for change in changes:
            self.store.append_event(self._event(change))
        return changes

    @staticmethod
    def _report_time(t: Any, now: float) -> float:
        """When the hub reported it (seconds; ms accepted), or now when the report carries no
        believable time (0, before 2001, more than a minute in the future)."""
        if isinstance(t, (int, float)) and not isinstance(t, bool):
            t = t / 1000.0 if t > 1e11 else float(t)
            if 1e9 < t <= now + 60:
                return min(t, now)
        return now

    def _door(self, code: str, value: Any, source: str, now: float, snapshot: bool) -> Optional[Change]:
        if not snapshot:
            key = (code, json.dumps(value, sort_keys=True, default=str))
            last = self._recent.get(key)
            if last is not None:
                at, link = last
                if (link != source and now - at < DEDUPE_S) or (link == source and now - at < SAME_LINK_S):
                    return None
            self._recent[key] = (now, source)
            for k, (at, _link) in list(self._recent.items()):
                if now - at > 120:
                    del self._recent[k]
        if self._by_value(code):
            if snapshot or value in (None, "", False):
                return None
            self._learn(code, value)
            contact = f"{code}={value}"
            door = self._doors.setdefault(contact, {})
            door["open"], door["last_open"] = None, now
            return Change("door", code, value, contact=contact, open=True, source=source, t=now)
        contact = f"dp:{code}"
        is_open = self._is_open(code, value)
        door = self._doors.setdefault(contact, {})
        known = door.get("open")
        if snapshot:
            door["open"] = is_open
            if known is None or known == is_open:
                return None
        elif not is_open and known is False:
            return None
        elif is_open and known is True and door.get("seen_close"):
            return None    # a sensor that reports closes too: "open" while open is nothing new
        if not is_open:
            door["seen_close"] = True
        door["open"] = is_open
        door["last_open" if is_open else "last_close"] = now
        return Change("door", code, value, contact=contact, open=is_open, source=source, t=now, missed=snapshot)

    def _event(self, change: Change) -> dict:
        if change.kind == "door":
            contact = self.contact(change.contact) or {}
            by_value = "=" in (change.contact or "")
            event = {"t": change.t, "kind": "door", "contact": change.contact, "name": contact.get("name"),
                     "open": None if by_value else change.open, "source": change.source, "missed": change.missed}
            if by_value:
                event["by_value"] = True
            if change.late:
                event["late"] = True
            return event
        return {"t": change.t, "kind": "dp", "code": change.code, "value": change.value, "source": change.source}

    # ── links ──

    def local_link(self, data: dict) -> None:
        with self.lock:
            local = self.link["local"]
            for key in ("state", "ip", "version", "rtt_ms", "rssi", "error"):
                if key in data:
                    local[key] = data[key]
            local["seen"] = self.clock()

    def cloud_link(self, state: str, error: str = "") -> None:
        with self.lock:
            self.link["cloud"].update({"state": state, "error": error})
            if state == "connected":
                self.link["cloud"]["seen"] = self.clock()

    def cloud_online(self, online: bool) -> None:
        with self.lock:
            self.link["cloud"]["online"] = online
            self.link["cloud"]["seen"] = self.clock()

    def local_alive(self, window: float = 75.0) -> bool:
        local = self.link["local"]
        return local.get("state") == "connected" and local.get("seen") is not None and self.clock() - local["seen"] < window

    def cloud_alive(self) -> bool:
        cloud = self.link["cloud"]
        return cloud.get("state") == "connected" and cloud.get("online") is not False

    def public(self) -> dict:
        with self.lock:
            cfg = self.cfg
            return {
                "configured": self.configured,
                "dev_id": cfg.get("dev_id"), "name": cfg.get("name"), "product_id": cfg.get("product_id"),
                "product_name": cfg.get("product_name"), "category": cfg.get("category"),
                "dps": [dp.public() for dp in self.dps.values()],
                "roles": self.roles,
                "values": {k: dict(v) for k, v in self.values.items()},
                "contacts": self.contacts(),
                "link": {"local": dict(self.link["local"]), "cloud": dict(self.link["cloud"]),
                         "local_alive": self.local_alive(), "cloud_alive": self.cloud_alive()},
            }
