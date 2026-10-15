from api.push import apns


def test_la_topic_appends_push_type():
    assert apns.la_topic({"topic": "com.x.app"}) == "com.x.app.push-type.liveactivity"


def test_apns_la_headers():
    h = apns._apns_la_headers({"topic": "com.x.app"}, "JWT", priority=10)
    assert h["authorization"] == "bearer JWT"
    assert h["apns-topic"] == "com.x.app.push-type.liveactivity"
    assert h["apns-push-type"] == "liveactivity"
    assert h["apns-priority"] == "10"


def test_build_la_aps_update():
    cs = {"mode": "coding", "sessionTotal": 3}
    aps = apns.build_la_aps(cs, event="update", stale_after=3600, now=1000)
    assert aps["event"] == "update"
    assert aps["timestamp"] == 1000
    assert aps["content-state"] == cs
    assert aps["stale-date"] == 1000 + 3600
    assert "dismissal-date" not in aps


def test_build_la_aps_end_has_dismissal():
    aps = apns.build_la_aps({}, event="end", dismissal_after=0, now=500)
    assert aps["event"] == "end"
    assert aps["dismissal-date"] == 500


def test_send_live_activity_no_key_is_graceful(monkeypatch, tmp_path):
    # No .p8 configured -> a clean error, never an exception.
    monkeypatch.setattr(apns, "_KEY_FILE", tmp_path / "missing.p8")
    res = apns.send_live_activity("abc", {"mode": "coding"})
    assert res["ok"] is False
    assert "not configured" in res["error"]


def test_build_la_aps_start_carries_the_push_to_start_fields():
    """Push-to-start (iOS 17.2+) names the attributes type and its values, and
    shows an alert; the extra fields can't clobber the core ones."""
    extra = {"attributes-type": "AgentActivityAttributes", "attributes": {"agent": "codex"},
             "alert": {"title": "Codex", "body": "api"}, "event": "update", "timestamp": 1}
    aps = apns.build_la_aps({"count": 1}, event="start", now=700, extra=extra)
    assert aps["event"] == "start" and aps["timestamp"] == 700
    assert aps["attributes-type"] == "AgentActivityAttributes"
    assert aps["attributes"] == {"agent": "codex"}
    assert aps["alert"]["title"] == "Codex"
    assert aps["content-state"] == {"count": 1}


def test_send_live_activity_posts_extra_and_dismissal(monkeypatch, tmp_path):
    key = tmp_path / "k.p8"
    key.write_text("x")
    monkeypatch.setattr(apns, "_KEY_FILE", key)
    monkeypatch.setattr(apns, "_load_config", lambda: {"topic": "com.x.app"})
    monkeypatch.setattr(apns, "_have_httpx", lambda: True)
    monkeypatch.setattr(apns, "_get_jwt", lambda cfg: "JWT")
    sent = {}

    class R:
        status_code = 200
        text = ""

    def post(url, headers, body, timeout):
        sent.update(url=url, headers=headers, body=body)
        return R()

    monkeypatch.setattr(apns, "_apns_post", post)
    res = apns.send_live_activity("tok", {"count": 0}, event="end", priority=5,
                                  dismissal_after=0, extra={"input-push-token": 1})
    assert res == {"ok": True}
    import json as _json
    aps = _json.loads(sent["body"])["aps"]
    assert aps["event"] == "end" and aps["dismissal-date"] == aps["timestamp"]
    assert aps["input-push-token"] == 1
    assert sent["headers"]["apns-priority"] == "5"
