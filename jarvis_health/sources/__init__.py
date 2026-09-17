"""Device adapters. Everything above this line is device-agnostic."""
from __future__ import annotations

from typing import Any, Protocol, runtime_checkable

from ..metrics import HealthDay

#: Device kinds that report enough to be scored. The others get no integration.
ELIGIBLE_KINDS = {"ring"}


class SourceUnreachable(RuntimeError):
    """The device could not be reached — not the same as a day with no data."""


@runtime_checkable
class HealthSource(Protocol):
    kind: str

    def identity(self) -> dict[str, Any]:
        """Who this device is: kind, device_id, name, model, firmware."""

    def eligible(self) -> bool:
        """Whether this device reports enough to be worth scoring."""

    def fetch_day(self, date: str, tz: str) -> HealthDay:
        """One local day, freshly synced from the device."""

    def backfill(self, days: int) -> list[HealthDay]:
        """Whatever history the device's own store still holds."""

    def battery(self) -> dict[str, Any]:
        """Percent and charging state, if the device reports them."""


def source_for(kind: str, device_id: str) -> HealthSource:
    """The adapter for a device kind. New wearables register here."""
    if kind == "ring":
        from .ring import RingSource

        return RingSource(device_id)
    raise ValueError(f"no health source for {kind!r}")
