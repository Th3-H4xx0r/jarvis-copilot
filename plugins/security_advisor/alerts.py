"""Phone alerts and the daily digest.

Pushes are rare on purpose: a repeat of the same alert within 30 minutes is
counted, not pushed; at most ``alert_cap_per_hour`` pushes go out per rolling
hour (the rest stay on the Security page and in the digest); during quiet hours
only blocks push.
"""
from __future__ import annotations

import logging
import time
from collections import Counter
from datetime import datetime, timedelta, timezone

logger = logging.getLogger(__name__)

DEDUP_WINDOW_S = 1800
CATEGORY = "SECURITY_ALERT"


def _default_push(title, body, **kw):
    from api.push import alert_phones
    return alert_phones(title, body, **kw)


def _default_settings():
    from plugins.security_advisor import settings
    return settings.load()


def deliver_chat_note(title: str, text: str) -> None:
    """Put the digest in Jarvis chat as its own cron-style session (like a cron job's output)."""
    from jarviscopilot_state import SessionDB
    db = SessionDB()
    sid = f"cron_security_digest_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    db.create_session(sid, "cron")
    try:
        db.set_session_title(sid, title)
    except Exception:
        pass
    db.append_message(sid, "assistant", text)
    db.end_session(sid, "cron_complete")


def _in_hours(hour: int, hours) -> bool:
    start, end = int(hours[0]), int(hours[1])
    if start == end:
        return False
    if start < end:
        return start <= hour < end
    return hour >= start or hour < end


class Notifier:
    def __init__(self, push=None, clock=time.time, settings=None, log=None,
                 summarize=None, deliver_chat=None):
        self.push = push or _default_push
        self.clock = clock
        self.settings = settings or _default_settings
        self.log = log
        self.summarize = summarize
        self.deliver_chat = deliver_chat
        self._last_push_by_key: dict[str, float] = {}
        self._push_times: list[float] = []
        self.suppressed: Counter = Counter()

    def notify(self, alert: dict) -> bool:
        """Push ``alert`` to the phones unless deduped, capped or quiet. True if pushed."""
        now = self.clock()
        key = alert.get("dedup_key") or f"alert:{alert.get('id')}"
        last = self._last_push_by_key.get(key)
        if last is not None and now - last < DEDUP_WINDOW_S:
            self.suppressed[key] += 1
            return False
        cfg = self.settings()
        is_block = alert.get("status") == "blocked"
        if not is_block and _in_hours(datetime.fromtimestamp(now).hour, cfg.get("quiet_hours") or [0, 0]):
            return False
        self._push_times = [t for t in self._push_times if now - t < 3600]
        if len(self._push_times) >= int(cfg.get("alert_cap_per_hour", 3)):
            return False
        self._last_push_by_key[key] = now
        if len(self._last_push_by_key) > 2000:
            self._last_push_by_key = {k: t for k, t in self._last_push_by_key.items()
                                      if now - t < DEDUP_WINDOW_S}
        self._push_times.append(now)
        try:
            self.push(alert.get("title") or "Security alert", alert.get("summary") or "",
                      data={"type": "security_alert", "alert_id": alert.get("id")},
                      category=CATEGORY, level="time-sensitive" if is_block else None)
        except Exception as e:
            logger.warning("security alert push failed: %s", e)
        return True

    # ── digest ────────────────────────────────────────────────────────────
    def digest(self, now: datetime) -> dict | None:
        """Build and deliver the day's digest once per day at ``digest_hour`` (local)."""
        if self.log is None:
            return None
        cfg = self.settings()
        if now.hour < int(cfg.get("digest_hour", 8)):
            return None
        day = now.date().isoformat()
        latest = self.log.list_digests(limit=1)
        if latest and latest[0]["day"] >= day:
            return None
        since = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
        events = self.log.query(since=since, limit=20000)
        counts = Counter(e.kind for e in events if e.outcome not in ("", "ignore"))
        cutoff = since
        alerts = self.log.list_alerts(limit=500)
        blocked = [a for a in alerts if a["status"] == "blocked" and a["created"] >= cutoff]
        still_open = [a for a in alerts if a["status"] == "open"]
        data = {
            "day": day,
            "counts": dict(sorted(counts.items())),
            "blocked": [{"id": a["id"], "title": a["title"]} for a in blocked],
            "open": [{"id": a["id"], "title": a["title"], "count": a["count"]} for a in still_open],
        }
        summary = ""
        if self.summarize is not None:
            try:
                summary = self.summarize(data) or ""
            except Exception:
                summary = ""
        lines = [summary] if summary else []
        total = sum(counts.values())
        lines.append(f"{total} events in the last 24 h; {len(blocked)} blocked; "
                     f"{len(still_open)} open alerts.")
        if counts:
            lines.append(", ".join(f"{k} {v}" for k, v in counts.most_common(8)))
        text = "\n".join(lines)
        digest_id = self.log.add_digest(day, text, data)
        title = "Security digest"
        try:
            self.push(title, text[:300], data={"type": "security_digest", "digest_id": digest_id},
                      category=CATEGORY, level=None)
        except Exception as e:
            logger.warning("security digest push failed: %s", e)
        if self.deliver_chat is not None:
            try:
                self.deliver_chat(f"{title} {day}", text)
            except Exception as e:
                logger.warning("security digest chat delivery failed: %s", e)
        return {"id": digest_id, "day": day, "text": text, "data": data}
