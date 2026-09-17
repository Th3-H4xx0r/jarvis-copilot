"""What a day of wearable data is, in terms every source and score agrees on.

Times are UTC. A day *key* is a local calendar day, because sleep and steps are
bucketed by the wearer's day, so each day also carries the zone it was recorded
in — that is what makes a stored day readable from another timezone later.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Optional
from zoneinfo import ZoneInfo

# Sleep stages, matching the ring's own codes (RingSleepStage on iOS).
STAGE_AWAKE = 1
STAGE_DEEP = 2
STAGE_LIGHT = 3
STAGE_REM = 4

ASLEEP_STAGES = (STAGE_DEEP, STAGE_LIGHT, STAGE_REM)

#: Every optional metric a source may fill in, in the order a report reads them.
METRICS = ("sleep", "heart_rate", "hrv", "stress", "spo2", "temperature", "activity")


def utc_now() -> str:
    """Now, as the only timestamp format this package stores."""
    return _iso(datetime.now(timezone.utc))


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_instant(text: str) -> datetime:
    """A stored UTC instant back into a datetime."""
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def local_midnight_utc(date: str, tz: str) -> str:
    """The UTC instant at which `date` began in `tz`."""
    day = datetime.strptime(date, "%Y-%m-%d")
    return _iso(day.replace(tzinfo=ZoneInfo(tz)))


def utc_offset_for(date: str, tz: str) -> int:
    """Seconds east of UTC in `tz` on `date` — the offset in force that day."""
    day = datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=ZoneInfo(tz))
    return int((day.utcoffset() or timedelta()).total_seconds())


@dataclass
class Series:
    """Evenly spaced samples across one local day.

    `start` is that day's local midnight as a UTC instant, so a sample's absolute
    time is derivable without knowing how long the local day was — which matters
    on the two days a year when it is not 24 hours.
    """

    start: str
    interval_minutes: int
    values: list[float] = field(default_factory=list)

    def at(self, index: int) -> str:
        return _iso(parse_instant(self.start) + timedelta(minutes=index * self.interval_minutes))

    def nonzero(self) -> list[float]:
        """Samples the ring actually recorded; it writes zero for "no reading"."""
        return [v for v in self.values if v and v > 0]

    def minute_of_day(self, index: int) -> int:
        return index * self.interval_minutes

    def index_at_minute(self, minute: int) -> int:
        return int(minute // self.interval_minutes) if self.interval_minutes else 0


@dataclass
class SleepSession:
    start: str
    end: str
    stages: list[tuple[int, int]] = field(default_factory=list)

    def stage_minutes(self, stage: int) -> int:
        return sum(minutes for code, minutes in self.stages if code == stage)

    @property
    def asleep_minutes(self) -> int:
        return sum(minutes for code, minutes in self.stages if code in ASLEEP_STAGES)

    @property
    def time_in_bed_minutes(self) -> int:
        return sum(minutes for _, minutes in self.stages)

    @property
    def awake_minutes(self) -> int:
        return self.stage_minutes(STAGE_AWAKE)

    @property
    def awakenings(self) -> int:
        """Awake stretches, not awake minutes: one long stir is one waking."""
        return sum(1 for code, _ in self.stages if code == STAGE_AWAKE)

    @property
    def efficiency(self) -> float:
        total = self.time_in_bed_minutes
        return (self.asleep_minutes / total) if total else 0.0


@dataclass
class HealthDay:
    """One local day from one device. Every metric is optional."""

    date: str
    timezone: str
    utc_offset: int
    sleep: list[SleepSession] = field(default_factory=list)
    heart_rate: Optional[Series] = None
    hrv: Optional[Series] = None
    stress: Optional[Series] = None
    spo2: Optional[Series] = None
    temperature: Optional[Series] = None
    activity: dict[str, Any] = field(default_factory=dict)
    measurements: list[dict] = field(default_factory=list)
    battery: dict[str, Any] = field(default_factory=dict)
    synced_at: str = ""
    source: str = ""

    def has(self, metric: str) -> bool:
        value = getattr(self, metric, None)
        if isinstance(value, Series):
            return bool(value.nonzero())
        return bool(value)

    @property
    def main_sleep(self) -> Optional[SleepSession]:
        """The night this day is judged on: the longest session recorded."""
        return max(self.sleep, key=lambda s: s.asleep_minutes) if self.sleep else None


@dataclass
class Baseline:
    """Your own normal, as medians over a window of stored days."""

    hrv: Optional[float] = None
    resting_hr: Optional[float] = None
    bedtime_minute: Optional[float] = None
    sleep_minutes: Optional[float] = None
    temperature: Optional[float] = None
    days_used: int = 0
    #: Days that actually produced each value. A stored day is not a measured
    #: one — backfilled days carry steps and nothing else — so readiness counts
    #: the metric, not the file.
    hrv_days: int = 0
    resting_hr_days: int = 0
    window: int = 14

    #: Below this many days a baseline-relative score would be noise.
    READY_DAYS = 4

    @property
    def is_ready(self) -> bool:
        """Whether anything here is worth comparing a day against."""
        return max(self.hrv_days, self.resting_hr_days) >= self.READY_DAYS


def to_json(day: HealthDay) -> dict:
    return asdict(day)


def _series(raw: Any) -> Optional[Series]:
    if not isinstance(raw, dict):
        return None
    return Series(
        start=raw.get("start", ""),
        interval_minutes=int(raw.get("interval_minutes") or 0),
        values=list(raw.get("values") or []),
    )


def from_json(raw: dict) -> HealthDay:
    sessions = [
        SleepSession(
            start=s.get("start", ""),
            end=s.get("end", ""),
            stages=[(int(code), int(minutes)) for code, minutes in (s.get("stages") or [])],
        )
        for s in (raw.get("sleep") or [])
        if isinstance(s, dict)
    ]
    return HealthDay(
        date=raw.get("date", ""),
        timezone=raw.get("timezone") or "UTC",
        utc_offset=int(raw.get("utc_offset") or 0),
        sleep=sessions,
        heart_rate=_series(raw.get("heart_rate")),
        hrv=_series(raw.get("hrv")),
        stress=_series(raw.get("stress")),
        spo2=_series(raw.get("spo2")),
        temperature=_series(raw.get("temperature")),
        activity=dict(raw.get("activity") or {}),
        measurements=list(raw.get("measurements") or []),
        battery=dict(raw.get("battery") or {}),
        synced_at=raw.get("synced_at") or "",
        source=raw.get("source") or "",
    )
