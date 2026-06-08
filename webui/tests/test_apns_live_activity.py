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
