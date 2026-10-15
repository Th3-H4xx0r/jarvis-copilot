"""Sending one email through Resend, only when someone presses Send on the Mac
(the poller stays read-only)."""
from __future__ import annotations

import pytest

from jarvis_services import mail_send
from jarvis_services.config import ConfigView
from jarvis_services.testing import FakeHttp

KEY = "re_test_123"
CFG = ConfigView({"SERVICES_RESEND_API_KEY": KEY}, {"resend": {"from": "Pranav <me@example.com>"}}, environ={})


def test_sends_with_the_configured_sender():
    http = FakeHttp().add("POST", "https://api.resend.com/emails", {"id": "em_1"})
    out = mail_send.send(http, CFG, to="ada@example.com, bob@example.com", subject="Hi", text="Hello there")
    assert out == {"ok": True, "id": "em_1"}
    call = http.calls[0]
    assert call.headers["Authorization"] == f"Bearer {KEY}"
    assert call.json == {"from": "Pranav <me@example.com>", "to": ["ada@example.com", "bob@example.com"],
                         "subject": "Hi", "text": "Hello there"}


@pytest.mark.parametrize("kw, message", [
    ({"to": "", "subject": "s", "text": "t"}, "Who to"),
    ({"to": "not-an-address", "subject": "s", "text": "t"}, "not-an-address"),
    ({"to": ",".join(f"a{i}@x.com" for i in range(11)), "subject": "s", "text": "t"}, "10"),
    ({"to": "a@x.com", "subject": "", "text": "t"}, "subject"),
    ({"to": "a@x.com", "subject": "s", "text": ""}, "empty"),
    ({"to": "a@x.com", "subject": "s" * 999, "text": "t"}, "subject"),
])
def test_bad_input_is_refused_before_any_call(kw, message):
    http = FakeHttp()
    with pytest.raises(ValueError, match=message):
        mail_send.send(http, CFG, **kw)
    assert http.calls == []


def test_needs_a_key_and_a_sender():
    with pytest.raises(ValueError, match="key"):
        mail_send.send(FakeHttp(), ConfigView({}, {"resend": {"from": "me@example.com"}}, environ={}),
                       to="a@x.com", subject="s", text="t")
    with pytest.raises(ValueError, match="From"):
        mail_send.send(FakeHttp(), ConfigView({"SERVICES_RESEND_API_KEY": KEY}, {}, environ={}),
                       to="a@x.com", subject="s", text="t")


def test_a_resend_error_is_told_as_is():
    http = FakeHttp().add("POST", "https://api.resend.com/emails",
                          {"message": "The example.com domain is not verified."}, status=403)
    out = mail_send.send(http, CFG, to="a@x.com", subject="s", text="t")
    assert out["ok"] is False and "not verified" in out["error"]


def test_route_sends_and_refuses():
    import sys, os
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "webui"))
    from api.services_routes import handle_services_request

    class Hub:
        def __init__(self):
            self.http = FakeHttp().add("POST", "https://api.resend.com/emails", {"id": "em_9"})

            class Cfg:
                def load(self_inner):
                    return CFG
            self.config = Cfg()

    hub = Hub()
    status, body = handle_services_request("POST", "/mail/send",
                                           {"to": "a@x.com", "subject": "s", "text": "t"}, hub=hub)
    assert (status, body) == (200, {"ok": True, "id": "em_9"})
    status, body = handle_services_request("POST", "/mail/send", {"to": "", "subject": "s", "text": "t"}, hub=hub)
    assert status == 400 and "Who to" in body["error"]
    status, _ = handle_services_request("GET", "/mail/send", {}, hub=hub)
    assert status == 405
