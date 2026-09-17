"""One scheduled run, from reaching the device to pushing what matters.

Deliberately dull: fetch, store, score, check thresholds, write prose, record.
Nothing here decides a number, and nothing raises — a run that could not reach
the device says so and scores what the server already holds.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from datetime import timedelta
from typing import Callable, Optional

from .analysis import write_analysis
from .baselines import baseline_from
from .metrics import parse_instant, utc_now
from .rules import evaluate
from .scoring import activity_score, band, body_score, health_score, recovery_score, sleep_score
from .sources import SourceUnreachable
from .store import HealthStore

logger = logging.getLogger(__name__)


def local_date(now_utc: str, utc_offset: int) -> str:
    """The wearer's calendar day at this instant — the key a day is stored under."""
    return (parse_instant(now_utc) + timedelta(seconds=utc_offset)).strftime("%Y-%m-%d")


def run(
    space_id: str,
    source,
    trigger: str = "cron",
    now: Optional[str] = None,
    tz: Optional[str] = None,
    call: Optional[Callable[..., object]] = None,
    notify: Optional[Callable[..., None]] = None,
) -> dict:
    started = time.monotonic()
    now = now or utc_now()
    store = HealthStore(space_id)
    settings = store.settings()
    notify = notify or push_alerts

    if not settings.get("enabled", True):
        return {"skipped": "disabled", "space": space_id}

    stale = False
    day = None
    try:
        # No date: the phone answers with its own local day, which is the only
        # place that knows it. A stored zone is only a fallback for display.
        zone = tz or _zone_of(store) or "UTC"
        day = source.fetch_day(None, zone)
        store.put_day(day)
    except SourceUnreachable as exc:
        stale = True
        day = store.newest_day()
        if day is None:
            store.log_run({"trigger": trigger, "skipped": "unreachable", "error": str(exc)})
            return {"skipped": "unreachable", "error": str(exc), "space": space_id}

    history = store.recent_days(14)
    baseline = baseline_from(history)
    store.put_baseline(baseline)

    sleep = sleep_score(day, baseline)
    recovery = recovery_score(day, baseline)
    body = body_score(day, baseline)
    activity = activity_score(day, settings.get("goals") or {})
    scores = {"sleep": sleep, "recovery": recovery, "body": body, "activity": activity}
    scores["health"] = health_score(scores)

    # Anything held from a night-time run goes out first, now that it is morning.
    released = _release_held(store, settings, now, day, notify)
    alerts = evaluate(day, scores, baseline, settings, now, store.fired_today(day.date), stale=stale)
    analysis = write_analysis(day, scores, baseline, settings, call=call)

    payload = {
        **{name: score.to_json() for name, score in scores.items()},
        "analysis": analysis,
        "date": day.date,
        "timezone": day.timezone,
        "utc_offset": day.utc_offset,
        "generated_at": now,
        "stale": stale,
        "synced_at": day.synced_at,
        "baseline_days": baseline.days_used,
        "model": settings.get("model") or "",
    }
    store.put_scores(day.date, payload)

    due = [a for a in alerts if not a.hold_until]
    held = [a for a in alerts if a.hold_until]
    for alert in alerts:
        record = alert.to_json(day.date)
        record["delivered"] = alert.hold_until is None
        store.log_alert(record)
    store.hold_alerts([a.to_json(day.date) for a in held])
    if due:
        notify(due, space_id, settings)

    out = {
        "space": space_id,
        "trigger": trigger,
        "scored_date": day.date,
        "stale": stale,
        "scores": {name: score.to_json() for name, score in scores.items()},
        "analysis": analysis,
        "alerts": [a.to_json(day.date) for a in alerts],
        "held": [a.to_json(day.date) for a in held],
        "released": released,
        "duration_ms": int((time.monotonic() - started) * 1000),
    }
    store.log_run(
        {
            "trigger": trigger,
            "scored_date": day.date,
            "stale": stale,
            "health": payload["health"]["value"],
            "band": band(scores["health"].value),
            "alerts": [a.rule for a in alerts],
            "released": [a.get("rule") for a in released],
            "duration_ms": out["duration_ms"],
        }
    )
    return out


def _release_held(store: HealthStore, settings: dict, now: str, day, notify) -> list[dict]:
    """Push whatever was held overnight, once the quiet hours have passed.

    Without this a held alert is stored, suppressed by the one-per-day rule on
    the next run, and never seen — which is most body alerts, because the ticks
    that first read last night's data land inside the quiet window.
    """
    from .rules import in_quiet_hours

    if in_quiet_hours(now, settings, day):
        return []
    held = store.take_held_alerts()
    if not held:
        return []

    class _Held:
        def __init__(self, record: dict) -> None:
            self.rule = record.get("rule", "")
            self.message = record.get("message", "")
            self.hold_until = None

    # The run's own notifier, so a release is delivered — and observed — exactly
    # the way a fresh alert is.
    notify([_Held(record) for record in held], store.space_id, settings)
    for record in held:
        store.log_alert({**record, "delivered": True, "released": True})
    return held


def _zone_of(store: HealthStore) -> Optional[str]:
    day = store.newest_day()
    return day.timezone if day else None


def _offset_of(store: HealthStore, zone: str) -> int:
    day = store.newest_day()
    if day:
        return day.utc_offset
    from .metrics import utc_offset_for

    try:
        return utc_offset_for(utc_now()[:10], zone)
    except Exception:
        return 0


def push_alerts(alerts, space_id: str, settings: dict) -> int:
    """Send what fired to every paired phone. Returns how many got it.

    Failures are logged rather than swallowed: an alert nobody receives is the
    whole feature not working, and the silence is what hid it before.
    """
    due = [a for a in alerts if not getattr(a, "hold_until", None)]
    if not due:
        return 0
    title = "Health alert" if len(due) == 1 else f"{len(due)} health alerts"
    body = " ".join(a.message for a in due)[:300]

    try:
        from api import push as push_mod
        from api.pairing import list_devices
    except Exception as exc:
        logger.warning("health: no push path available (%s); alerts are stored only", exc)
        return 0

    sent = 0
    for device in list_devices() or []:
        token = (device.get("push_token") or "").strip()
        kind = (device.get("push_kind") or "").strip().lower()
        if not token or kind != "apns":
            continue
        if not (device.get("kind") or "").strip().lower().startswith("mobile"):
            continue
        try:
            result = push_mod.send(kind, token, {"type": "health", "space": space_id},
                                   alert={"title": title, "body": body})
            if result.get("ok"):
                sent += 1
            else:
                logger.warning("health: push refused for %s: %s", device.get("id"), result.get("error"))
        except Exception as exc:
            logger.warning("health: push failed for %s: %s", device.get("id"), exc)
    if not sent:
        logger.warning("health: %d alert(s) fired but no phone received them", len(due))
    return sent


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Run one wearable health analysis.")
    parser.add_argument("--space", required=True, help="registry space id, e.g. wearable-ring-b6ce93c4")
    parser.add_argument("--device", required=True, help="the phone the skills are invoked on")
    parser.add_argument("--wearable", default="", help="the wearable's own id, if it differs")
    parser.add_argument("--kind", default="ring")
    parser.add_argument("--trigger", default="cron")
    args = parser.parse_args(argv)

    from .sources import source_for

    out = run(args.space, source_for(args.kind, args.device, args.wearable or args.device),
              trigger=args.trigger)
    print(json.dumps(out, indent=2, default=str))
    return 0 if not out.get("error") else 1


if __name__ == "__main__":
    sys.exit(main())
