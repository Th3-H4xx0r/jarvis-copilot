"""His time zone, and turning time words in a question into a window."""
import json
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from plugins.memory.jarvis_memory import timeparse, tz

CT = ZoneInfo("America/Chicago")


def _ts(*args):
    return datetime(*args, tzinfo=CT).timestamp()


def _end_of(y, m, d):
    return _ts(y, m, d, 23, 59, 59) + 0.999


WED = datetime(2026, 10, 21, 20, 56, tzinfo=CT)


def test_this_weekend_from_wednesday():
    w = timeparse.window("what am I doing this weekend", WED)
    assert w.start == _ts(2026, 10, 23, 17, 0)
    assert abs(w.end - _end_of(2026, 10, 25)) < 0.01
    assert w.future is True


def test_tomorrow_late_evening_is_local_tomorrow():
    fri_late = datetime(2026, 10, 23, 22, 30, tzinfo=CT)
    w = timeparse.window("what time do we leave tomorrow", fri_late)
    assert w.start == _ts(2026, 10, 24, 0, 0)
    assert abs(w.end - _end_of(2026, 10, 24)) < 0.01


def test_last_tuesday():
    w = timeparse.window("what did Sam say last tuesday", WED)
    assert w.start == _ts(2026, 10, 20, 0, 0)
    assert w.future is False


def test_bare_saturday_is_next_saturday():
    w = timeparse.window("where is the race on saturday", WED)
    assert w.start == _ts(2026, 10, 24, 0, 0)


def test_past_tense_weekday_looks_back():
    w = timeparse.window("what did we talk about on monday", WED)
    assert w.start == _ts(2026, 10, 19, 0, 0)


def test_month_day():
    w = timeparse.window("anything on Oct 25?", WED)
    assert w.start == _ts(2026, 10, 25, 0, 0)


def test_yesterday_and_tonight():
    assert timeparse.window("what did I eat yesterday", WED).start == _ts(2026, 10, 20, 0, 0)
    assert timeparse.window("plans tonight", WED).start == _ts(2026, 10, 21, 17, 0)


@pytest.mark.parametrize("text", ["Can you open navigation to the venue",
                                  "text him that I'm late", ""])
def test_no_time_words_returns_none(text):
    assert timeparse.window(text, WED) is None


def test_user_zone_order(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    tz.reset_cache()
    monkeypatch.setattr(tz, "_roster_zone", lambda: "America/Los_Angeles")
    monkeypatch.setattr(tz, "_configured_zone", lambda: "")
    assert tz.user_zone().key == "America/Los_Angeles"
    (tmp_path / "memory").mkdir()
    (tmp_path / "memory" / "context_snapshot.json").write_text(json.dumps({"tz": "America/New_York"}))
    tz.reset_cache()
    assert tz.user_zone().key == "America/New_York"
    (tmp_path / "memory" / "context_snapshot.json").write_text(json.dumps({"tz": "Not/AZone"}))
    monkeypatch.setattr(tz, "_roster_zone", lambda: "")
    tz.reset_cache()
    assert tz.user_zone().key == "America/Chicago"
