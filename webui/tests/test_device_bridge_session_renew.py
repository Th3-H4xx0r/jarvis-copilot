"""A board or PC link that stays up for weeks renews its 30-day session while it pings (review 2026-11-24: it
renewed only on connect, so a link up 30+ days got a 401 on its next reconnect and stayed offline)."""
from api import device_bridge


class Conn:
    session_cookie = "tok.sig"
    renewed_at = 0.0


def test_pings_renew_the_session_once_a_day(monkeypatch):
    renewed = []
    monkeypatch.setattr("api.auth.renew_session", lambda cookie: renewed.append(cookie) or True)
    c = Conn()
    device_bridge._renew_if_due(c, now=100_000.0)
    device_bridge._renew_if_due(c, now=100_000.0 + 3600)
    assert renewed == ["tok.sig"]
    device_bridge._renew_if_due(c, now=100_000.0 + 86_400 + 1)
    assert renewed == ["tok.sig", "tok.sig"]


def test_no_cookie_no_renewal(monkeypatch):
    renewed = []
    monkeypatch.setattr("api.auth.renew_session", lambda cookie: renewed.append(cookie) or True)
    c = Conn()
    c.session_cookie = ""
    device_bridge._renew_if_due(c, now=200_000.0)
    assert renewed == []
