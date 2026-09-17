"""The Colmi ring as a health source.

It speaks the `ring_*` device skills, which run on the phone the ring is paired
to — the phone is the radio, so an unreachable phone means an unreachable ring,
and that is reported as such rather than as a day with nothing in it.
"""
from __future__ import annotations

from typing import Any, Callable, Optional

from ..bridge import invoke as bridge_invoke
from ..metrics import (
    HealthDay,
    Series,
    SleepSession,
    local_midnight_utc,
    utc_now,
    utc_offset_for,
)
from . import SourceUnreachable

#: `ring_get_history` takes at most 30 days in one call.
HISTORY_CHUNK = 30


class RingSource:
    kind = "ring"

    def __init__(self, device_id: str, invoke: Optional[Callable[..., dict]] = None) -> None:
        self.device_id = device_id
        self._invoke = invoke or bridge_invoke

    # ── plumbing ────────────────────────────────────────────────────────────
    def _call(self, skill: str, args: Optional[dict] = None, timeout: float = 30) -> dict:
        reply = self._invoke(self.device_id, skill, args or {}, timeout) or {}
        if not reply.get("ok"):
            return {}
        result = reply.get("result")
        return result if isinstance(result, dict) else {}

    def _call_or_raise(self, skill: str, args: Optional[dict] = None, timeout: float = 30) -> dict:
        reply = self._invoke(self.device_id, skill, args or {}, timeout) or {}
        if not reply.get("ok"):
            raise SourceUnreachable(reply.get("error") or f"{skill} failed")
        result = reply.get("result")
        return result if isinstance(result, dict) else {}

    # ── HealthSource ────────────────────────────────────────────────────────
    def identity(self) -> dict[str, Any]:
        status = self._call("ring_get_status", timeout=20)
        return {
            "kind": self.kind,
            "device_id": self.device_id,
            "name": status.get("name") or status.get("model") or "Ring",
            "model": status.get("model") or "",
            "firmware": status.get("firmware_version") or "",
        }

    def eligible(self) -> bool:
        return True

    def battery(self) -> dict[str, Any]:
        status = self._call("ring_get_status", timeout=20)
        return {"percent": status.get("battery_percent"), "charging": bool(status.get("charging"))}

    def fetch_day(self, date: str, tz: str) -> HealthDay:
        """Bring the ring up to date over BLE, then read the day back."""
        # Connecting is best effort: the link may already be up, and the sync
        # below is the real test of whether the ring answered.
        self._invoke(self.device_id, "wearables_connect", {"device_id": self.device_id}, 20)
        self._call_or_raise("ring_sync", {"days": 0}, timeout=60)
        raw = self._call_or_raise("ring_get_day", {"date": date}, timeout=30)
        return self._day_from(raw or {"date": date}, date, tz)

    def backfill(self, days: int) -> list[HealthDay]:
        out: list[HealthDay] = []
        remaining = max(1, days)
        while remaining > 0:
            chunk = min(HISTORY_CHUNK, remaining)
            history = self._call("ring_get_history", {"days": chunk}, timeout=90)
            rows = history.get("days") or []
            for row in rows:
                date = row.get("date")
                if not date:
                    continue
                tz = row.get("timezone") or "UTC"
                summary = row.get("summary") or {}
                day = HealthDay(
                    date=date,
                    timezone=tz,
                    utc_offset=utc_offset_for(date, tz) if tz != "UTC" else 0,
                    activity={k: v for k, v in summary.items() if k in ("steps", "active_minutes", "kilocalories")},
                    synced_at=utc_now(),
                    source=self.kind,
                )
                out.append(day)
            if len(rows) < chunk:
                break
            remaining -= chunk
        return out

    # ── mapping ─────────────────────────────────────────────────────────────
    def _day_from(self, raw: dict, date: str, tz: str) -> HealthDay:
        return day_from_ring_json(raw, date, tz)


def day_from_ring_json(raw: dict, date: str, tz: str) -> HealthDay:
    """The ring skills' day JSON as a HealthDay.

    Module-level because the phone pushes this exact shape straight to the
    server, and both paths must agree on what it means.
    """
    midnight = local_midnight_utc(date, tz)

    def series(payload: Any, default_interval: int) -> Optional[Series]:
        if not isinstance(payload, dict):
            return None
        values = payload.get("values")
        if not isinstance(values, list) or not values:
            return None
        return Series(
            start=midnight,
            interval_minutes=int(payload.get("interval_minutes") or default_interval),
            values=[float(v or 0) for v in values],
        )

    sessions = []
    for night in raw.get("sleep") or []:
        if not isinstance(night, dict):
            continue
        stages = [
            (int(s.get("stage", 0)), int(s.get("minutes", 0)))
            for s in (night.get("stages") or [])
            if isinstance(s, dict)
        ]
        sessions.append(
            SleepSession(start=night.get("start", ""), end=night.get("end", ""), stages=stages)
        )

    return HealthDay(
        date=date,
        timezone=tz,
        utc_offset=utc_offset_for(date, tz),
        sleep=sessions,
        heart_rate=series(raw.get("heart_rate"), 5),
        hrv=series(raw.get("hrv"), 30),
        stress=series(raw.get("stress"), 30),
        spo2=_spo2(raw.get("spo2"), midnight),
        temperature=series(raw.get("temperature"), 60),
        activity=dict(raw.get("activity") or {}),
        measurements=list(raw.get("measurements") or []),
        battery={
            "percent": raw.get("battery_percent"),
            "charging": bool(raw.get("charging")),
        },
        synced_at=utc_now(),
        source="ring",
    )

def _spo2(payload: Any, midnight: str) -> Optional[Series]:
        """The ring reports SpO₂ as hourly min/max; a score wants one number."""
        if not isinstance(payload, dict):
            return None
        if isinstance(payload.get("values"), list) and payload["values"]:
            return Series(start=midnight, interval_minutes=60, values=[float(v or 0) for v in payload["values"]])
        lows = payload.get("min") or []
        highs = payload.get("max") or []
        if not lows and not highs:
            return None
        pairs = list(zip(lows, highs)) if lows and highs else [(v, v) for v in (lows or highs)]
        values = [((float(lo) + float(hi)) / 2 if lo and hi else float(lo or hi or 0)) for lo, hi in pairs]
        return Series(start=midnight, interval_minutes=60, values=values)
