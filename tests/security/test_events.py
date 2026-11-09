"""Security event log: emit(), redaction, hash chain, pruning."""
import json


def test_emit_never_raises_and_appends(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from security import events
    events.emit("device", "auth.failed", {"ip": "203.0.113.7"}, path="/api/x")
    events.flush(timeout=2)
    rows = events.default_log().query()
    assert [r.kind for r in rows] == ["auth.failed"]
    assert rows[0].actor["ip"] == "203.0.113.7"
    assert rows[0].detail["path"] == "/api/x"
    assert rows[0].source == "device"
    assert rows[0].ts.endswith("Z") and "T" in rows[0].ts


def test_emit_swallows_store_errors(monkeypatch):
    from security import events
    monkeypatch.setattr(events, "default_log", lambda: (_ for _ in ()).throw(OSError("disk")))
    events.emit("device", "auth.failed")  # must not raise
    events.flush(timeout=2)


def test_emit_redacts_before_storage(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from security import events
    events.emit("device", "config.password_changed", {"ip": "203.0.113.8"}, password="hunter2")
    events.flush(timeout=2)
    row = events.default_log().query()[0]
    assert "hunter2" not in json.dumps(row.detail)


def test_redacts_secrets():
    from security.events import redact
    out = redact({"password": "hunter2", "headers": {"Cookie": "a=b"}, "api_key": "sk-x",
                  "note": "Bearer abc.def"})
    assert out["password"] == "[redacted]" and out["api_key"] == "[redacted]"
    assert out["headers"]["Cookie"] == "[redacted]" and "abc.def" not in out["note"]


def test_redacts_inline_api_keys_and_lists():
    from security.events import redact
    out = redact({"items": [{"Authorization": "x"}, "key sk-abc_DEF-123 here"]})
    assert out["items"][0]["Authorization"] == "[redacted]"
    assert "sk-abc_DEF-123" not in out["items"][1]


def test_detail_is_size_capped(tmp_path):
    from security.events import EventLog
    log = EventLog(tmp_path / "e.db")
    ev = log.append("agent", "tool.risky", {}, {"blob": "x" * 20000})
    assert len(json.dumps(ev.detail)) <= 4096
    assert log.query()[0].detail == ev.detail


def test_hash_chain_detects_tamper(tmp_path):
    from security.events import EventLog
    log = EventLog(tmp_path / "e.db")
    a = log.append("host", "ssh.accepted", {}, {}); log.append("host", "ssh.accepted", {}, {})
    assert log.verify_chain() is None
    log._conn.execute("UPDATE events SET kind='x' WHERE id=?", (a.id,)); log._conn.commit()
    assert log.verify_chain() == a.id


def test_hash_chain_detects_deleted_row(tmp_path):
    from security.events import EventLog
    log = EventLog(tmp_path / "e.db")
    log.append("host", "a", {}, {})
    b = log.append("host", "b", {}, {})
    c = log.append("host", "c", {}, {})
    log._conn.execute("DELETE FROM events WHERE id=?", (b.id,)); log._conn.commit()
    assert log.verify_chain() == c.id


def test_outcome_is_not_hashed(tmp_path):
    from security.events import EventLog
    log = EventLog(tmp_path / "e.db")
    a = log.append("device", "pair.claimed", {}, {})
    log.set_outcome(a.id, "alert", note="new device")
    assert log.verify_chain() is None
    assert log.query(outcome="alert")[0].id == a.id


def test_query_filters_and_cursor(tmp_path):
    from security.events import EventLog
    log = EventLog(tmp_path / "e.db")
    ids = [log.append("device", k, {}, {}).id for k in ("a", "b", "a", "c")]
    assert [e.kind for e in log.query(kinds=["a"])] == ["a", "a"]
    after = log.query(after_id=ids[1])
    assert [e.id for e in after] == ids[2:]          # cursor reads oldest first
    assert [e.id for e in log.query(limit=2)] == [ids[3], ids[2]]  # feed reads newest first


def test_prune_keeps_alerts_and_chain(tmp_path):
    from security.events import EventLog
    log = EventLog(tmp_path / "e.db")
    old_ts = "2020-01-01T00:00:00Z"
    old = [log.append("host", "ssh.failed", {}, {}, ts=old_ts) for _ in range(3)]
    never = log.append("host", "session.seen", {}, {}, ts=old_ts)  # never got an outcome: goes too
    tail = log.append("host", "ssh.failed", {}, {})
    fresh_unrated = log.append("host", "ssh.failed", {}, {})       # recent, no outcome yet: kept
    for e in old:
        log.set_outcome(e.id, "digest")
    log.set_outcome(old[1].id, "alert")
    log.set_outcome(tail.id, "digest")
    assert log.prune(digest_days=90) == 3
    remaining = sorted(e.id for e in log.query(limit=100))
    assert remaining == [old[1].id, tail.id, fresh_unrated.id]
    assert never.id not in remaining
    assert log.verify_chain() is None


def test_verify_chain_works_in_chunks(tmp_path):
    from security.events import EventLog
    log = EventLog(tmp_path / "e.db")
    rows = [log.append("host", "ssh.failed", {}, {"n": i}) for i in range(10)]
    assert log.verify_chain(chunk=3) is None
    log._conn.execute("UPDATE events SET detail='{}' WHERE id=?", (rows[7].id,))
    assert log.verify_chain(chunk=3) == rows[7].id


def test_redacts_secret_shapes_in_command_strings():
    from security.events import redact
    secrets = {
        "mysql -uroot -phunter2pw db": "hunter2pw",
        "curl --password=s3cr3t-pw https://x": "s3cr3t-pw",
        "OPENAI_API_KEY=abc123def456 python run.py": "abc123def456",
        "export STRIPE_SECRET=whsec_live_99 && go": "whsec_live_99",
        "GITHUB_TOKEN=tok_value_77 gh pr list": "tok_value_77",
        "AWS_SECRET_ACCESS_KEY=fakeAccessKeyValueForTests000 aws s3 ls": "fakeAccessKeyValue",
        "git push https://ghp_FAKEfakeFAKEfakeFAKE00@github.com": "ghp_FAKEfake",
        "curl -H 'x: xoxb-0000-fake-example' slack": "xoxb-0000",
        "run --sig=QWxhZGRpbjpvcGVuIHNlc2FtZQ0K0123456789abcdef": "QWxhZGRpbjpvcGVuIHNlc2FtZQ0K",
    }
    for command, secret in secrets.items():
        out = redact({"command": command})["command"]
        assert secret not in out, out
    plain = "ls -la /var/log && git status -p"
    assert redact({"command": plain})["command"] == plain
