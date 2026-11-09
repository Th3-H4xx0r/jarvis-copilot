"""Phone alerts: deduped, capped per hour, quiet at night; one digest a day."""
from datetime import datetime

from plugins.security_advisor.alerts import Notifier
from security.events import EventLog


def settings(**kw):
    base = {"alert_cap_per_hour": 3, "digest_hour": 8, "quiet_hours": [23, 7]}
    base.update(kw)
    return lambda: base


NOON = datetime(2026, 11, 8, 12, 0).timestamp()


def make(clock_at=NOON, **kw):
    pushes = []
    clock = [clock_at]
    n = Notifier(push=lambda title, body, **k: pushes.append((title, body, k)) or 1,
                 clock=lambda: clock[0], settings=settings(**kw))
    return n, pushes, clock


def alert(i=1, key="auth_burst:203.0.113.5", status="open"):
    return {"id": i, "title": "t", "summary": "s", "dedup_key": key, "status": status}


def test_dedup_and_hourly_cap():
    n, pushes, _ = make()
    sent = [n.notify(alert(i)) for i in range(50)]
    assert sent.count(True) == 1 and len(pushes) == 1
    assert n.suppressed["auth_burst:203.0.113.5"] == 49
    n2, pushes2, _ = make()
    for i in range(5):
        n2.notify(alert(i, key=f"k{i}"))
    assert len(pushes2) == 3


def test_cap_rolls_over_after_an_hour():
    n, pushes, clock = make()
    for i in range(3):
        n.notify(alert(i, key=f"k{i}"))
    clock[0] += 3601
    assert n.notify(alert(9, key="k9")) is True and len(pushes) == 4


def test_push_shape():
    n, pushes, _ = make()
    n.notify(alert(7, status="blocked"))
    title, body, kw = pushes[0]
    assert kw["category"] == "SECURITY_ALERT"
    assert kw["data"] == {"type": "security_alert", "alert_id": 7}
    assert kw["level"] == "time-sensitive"


def test_quiet_hours_only_blocks_push():
    n, pushes, _ = make(clock_at=datetime(2026, 11, 8, 2, 0).timestamp())
    assert n.notify(alert(1, key="a")) is False
    assert n.notify(alert(2, key="b", status="blocked")) is True
    assert len(pushes) == 1


def test_digest_once_per_day(tmp_path):
    log = EventLog(tmp_path / "e.db")
    e = log.append("host", "ssh.failed", {"ip": "203.0.113.9"}, {})
    log.set_outcome(e.id, "digest")
    chats = []
    n, pushes, _ = make()
    n.log = log
    n.summarize = lambda data: "Quiet day. 1 failed SSH login."
    n.deliver_chat = lambda title, text: chats.append((title, text))
    assert n.digest(datetime(2026, 11, 8, 7, 59)) is None          # before digest hour
    d = n.digest(datetime(2026, 11, 8, 8, 0))
    assert d and d["data"]["counts"] == {"ssh.failed": 1}
    assert "Quiet day" in d["text"]
    assert n.digest(datetime(2026, 11, 8, 20, 0)) is None          # once per day
    assert n.digest(datetime(2026, 11, 9, 8, 5)) is not None
    assert len(chats) == 2 and len(log.list_digests()) == 2
    assert pushes[0][2]["data"]["type"] == "security_digest"
