"""One scheduled run, from reaching the device to pushing what matters.

Deliberately dull: fetch, store, score, check thresholds, write prose, record.
Nothing here decides a number, and nothing raises — a run that could not reach
the device says so and scores what the server already holds.
"""
from __future__ import annotations

import argparse
import json
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
        zone = tz or _zone_of(store) or "UTC"
        day = source.fetch_day(local_date(now, _offset_of(store, zone)), zone)
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

    for alert in alerts:
        store.log_alert(alert.to_json(day.date))
    if alerts:
        notify(alerts, space_id, settings)

    out = {
        "space": space_id,
        "trigger": trigger,
        "scored_date": day.date,
        "stale": stale,
        "scores": {name: score.to_json() for name, score in scores.items()},
        "analysis": analysis,
        "alerts": [a.to_json(day.date) for a in alerts],
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
            "duration_ms": out["duration_ms"],
        }
    )
    return out


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


def push_alerts(alerts, space_id: str, settings: dict) -> None:
    """Send what fired. Held alerts wait for the quiet hours to end."""
    due = [a for a in alerts if not a.hold_until]
    if not due:
        return
    title = "Health alert" if len(due) == 1 else f"{len(due)} health alerts"
    body = " ".join(a.message for a in due)[:300]
    try:
        from api import push  # webui's iOS push helper

        push.send_to_all(title=title, body=body, thread=space_id)
    except Exception:
        # A missing push path must not fail a run; the alert is already stored.
        pass


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Run one wearable health analysis.")
    parser.add_argument("--space", required=True, help="registry space id, e.g. wearable-ring-b6ce93c4")
    parser.add_argument("--device", required=True, help="device id the skills are invoked on")
    parser.add_argument("--kind", default="ring")
    parser.add_argument("--trigger", default="cron")
    args = parser.parse_args(argv)

    from .sources import source_for

    out = run(args.space, source_for(args.kind, args.device), trigger=args.trigger)
    print(json.dumps(out, indent=2, default=str))
    return 0 if not out.get("error") else 1


if __name__ == "__main__":
    sys.exit(main())
