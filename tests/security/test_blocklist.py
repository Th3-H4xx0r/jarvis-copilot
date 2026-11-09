"""IP deny list with expiry, persisted to a 0600 file."""
import os
import stat


def test_blocklist_ttl_and_unblock(tmp_path):
    from security.blocklist import Blocklist
    b = Blocklist(tmp_path / "blocks.json", clock=lambda: 1000.0)
    b.block("203.0.113.5", "pair brute force", ttl_s=60)
    assert b.is_blocked("203.0.113.5")
    b.clock = lambda: 1061.0
    assert not b.is_blocked("203.0.113.5")
    b.block("203.0.113.6", "x", ttl_s=60); assert b.unblock_all() == 1


def test_blocklist_persists_and_reloads_other_writers(tmp_path):
    from security.blocklist import Blocklist
    path = tmp_path / "blocks.json"
    a = Blocklist(path, clock=lambda: 1000.0)
    b = Blocklist(path, clock=lambda: 1000.0)
    entry = a.block("198.51.100.7", "bad cookie burst", ttl_s=3600, event_id=12)
    assert entry["ip"] == "198.51.100.7" and entry["event_id"] == 12
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert b.is_blocked("198.51.100.7")
    assert [e["ip"] for e in b.active()] == ["198.51.100.7"]
    assert b.unblock("198.51.100.7") is True
    assert not a.is_blocked("198.51.100.7")
    assert a.unblock("198.51.100.7") is False


def test_default_blocklist_under_hermes_home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from security.blocklist import default_blocklist
    default_blocklist().block("2001:db8::1", "x", ttl_s=60)
    assert (tmp_path / "security" / "blocks.json").exists()
