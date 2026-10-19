"""APNs ``widgets`` push: makes iOS reload the Control Center controls (and widgets) now."""
import json

from api.push import apns


def test_widgets_topic_appends_push_type():
    assert apns.widgets_topic({"topic": "com.x.app"}) == "com.x.app.push-type.widgets"


def test_widgets_headers():
    h = apns._apns_widgets_headers({"topic": "com.x.app"}, "JWT", expiration=1234)
    assert h["authorization"] == "bearer JWT"
    assert h["apns-topic"] == "com.x.app.push-type.widgets"
    assert h["apns-push-type"] == "widgets"
    assert h["apns-priority"] == "10"
    assert h["apns-expiration"] == "1234"
    assert h["content-type"] == "application/json"


def test_widgets_body_is_content_changed_only():
    assert apns.build_widgets_body() == {"aps": {"content-changed": True}}


def _configured(monkeypatch, tmp_path, status=200, text=""):
    key = tmp_path / "k.p8"
    key.write_text("x")
    monkeypatch.setattr(apns, "_KEY_FILE", key)
    monkeypatch.setattr(apns, "_load_config", lambda: {"topic": "com.x.app", "use_sandbox": True})
    monkeypatch.setattr(apns, "_have_httpx", lambda: True)
    monkeypatch.setattr(apns, "_get_jwt", lambda cfg: "JWT")
    sent = {}

    class R:
        status_code = status

    R.text = text

    def post(url, headers, body, timeout):
        sent.update(url=url, headers=headers, body=body)
        return R()

    monkeypatch.setattr(apns, "_apns_post", post)
    return sent


def test_send_control_refresh_posts_a_widgets_push(monkeypatch, tmp_path):
    sent = _configured(monkeypatch, tmp_path)
    assert apns.send_control_refresh("tok123") == {"ok": True}
    assert sent["url"] == "https://api.sandbox.push.apple.com/3/device/tok123"
    assert sent["headers"]["apns-push-type"] == "widgets"
    assert sent["headers"]["apns-topic"] == "com.x.app.push-type.widgets"
    assert sent["headers"]["apns-priority"] == "10"
    assert json.loads(sent["body"]) == {"aps": {"content-changed": True}}


def test_send_control_refresh_reports_apns_errors(monkeypatch, tmp_path):
    _configured(monkeypatch, tmp_path, status=410, text='{"reason":"Unregistered"}')
    res = apns.send_control_refresh("tok123")
    assert res["ok"] is False and res["status"] == 410 and "Unregistered" in res["error"]


def test_send_control_refresh_without_a_key_is_graceful(monkeypatch, tmp_path):
    monkeypatch.setattr(apns, "_KEY_FILE", tmp_path / "missing.p8")
    res = apns.send_control_refresh("tok123")
    assert res["ok"] is False and "not configured" in res["error"]


def test_send_control_refresh_never_raises(monkeypatch, tmp_path):
    _configured(monkeypatch, tmp_path)

    def boom(*a, **k):
        raise RuntimeError("socket closed")

    monkeypatch.setattr(apns, "_apns_post", boom)
    res = apns.send_control_refresh("tok123")
    assert res["ok"] is False and "socket closed" in res["error"]
