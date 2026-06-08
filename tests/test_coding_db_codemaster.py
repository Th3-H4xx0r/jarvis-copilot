"""Round-trip tests for the Code Master DB additions: the single-row account
usage snapshot and the key/value JSON settings store."""
from agent.coding_session_db import CodingSessionStore


def test_usage_snapshot_roundtrip(tmp_path):
    s = CodingSessionStore(str(tmp_path / "c.db"))
    assert s.get_usage_snapshot() is None
    s.upsert_usage_snapshot(five_hour_pct=47, weekly_pct=23,
                            five_hour_reset_at=1000.0, weekly_reset_at=2000.0,
                            available=True, fetched_at=500.0)
    snap = s.get_usage_snapshot()
    assert snap["five_hour_pct"] == 47
    assert snap["weekly_pct"] == 23
    assert snap["five_hour_reset_at"] == 1000.0
    assert snap["available"] is True


def test_usage_snapshot_is_single_row_upsert(tmp_path):
    s = CodingSessionStore(str(tmp_path / "c.db"))
    s.upsert_usage_snapshot(five_hour_pct=47, weekly_pct=23,
                            five_hour_reset_at=None, weekly_reset_at=None,
                            available=True, fetched_at=1.0)
    s.upsert_usage_snapshot(five_hour_pct=50, weekly_pct=10,
                            five_hour_reset_at=None, weekly_reset_at=None,
                            available=False, fetched_at=2.0)
    snap = s.get_usage_snapshot()
    assert snap["five_hour_pct"] == 50          # overwritten, not appended
    assert snap["available"] is False
    assert snap["five_hour_reset_at"] is None


def test_settings_roundtrip_and_default(tmp_path):
    s = CodingSessionStore(str(tmp_path / "c.db"))
    assert s.get_setting("notifications", {"x": 1}) == {"x": 1}  # default when unset
    s.set_setting("notifications", {"events": {"finished": {"telegram": True}},
                                    "usage_display": False})
    got = s.get_setting("notifications")
    assert got["events"]["finished"]["telegram"] is True
    assert got["usage_display"] is False
