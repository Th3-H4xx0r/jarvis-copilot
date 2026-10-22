"""The always-on brief: what's going on in his life now."""
import json
import time

import pytest

from plugins.memory.jarvis_memory import brief
from plugins.memory.jarvis_memory.store import GLOBAL_NS

from tests.jarvis_memory.conftest_map import NOW, build_venue_store, ts


@pytest.fixture(autouse=True)
def _clean():
    brief.reset()
    yield
    brief.reset()


def test_brief_lists_upcoming_f1_with_people_and_place(tmp_path):
    s, _e, ids = build_venue_store(tmp_path)
    text = brief.build(s, GLOBAL_NS, now=NOW)
    assert text.startswith("[Now — what's going on in his life]")
    assert "Wed 21 Oct" in text and "8:56 PM" in text
    line = next(l for l in text.splitlines() if "F1 US Grand Prix" in l)
    assert "Fri 23" in line and "Circuit of the Americas" in line and "Sid Patel" in line


def test_past_and_far_events_left_out(tmp_path):
    s, _e, _ids = build_venue_store(tmp_path)
    s.upsert_entity({"type": "event", "canonical": "Spring Break", "event_start": ts(2026, 3, 1, 0, 0)})
    s.upsert_entity({"type": "event", "canonical": "Ski trip", "event_start": ts(2026, 12, 20, 0, 0)})
    text = brief.build(s, GLOBAL_NS, now=NOW)
    assert "Spring Break" not in text and "Ski trip" not in text


def test_calendar_items_merge_into_coming_up(tmp_path):
    s, _e, _ids = build_venue_store(tmp_path)
    brief.register_data("calendar", lambda ctx: [
        {"title": "Mom's Bday", "start": ts(2026, 10, 23, 0, 0), "all_day": True, "location": ""},
        {"title": "F1 US Grand Prix", "start": ts(2026, 10, 23, 9, 0), "all_day": False, "location": ""},
    ])
    text = brief.build(s, GLOBAL_NS, now=NOW)
    assert "Mom's Bday" in text
    assert text.count("F1 US Grand Prix") == 1  # same thing, listed once


def test_people_lately_and_pinned(tmp_path):
    s, _e, ids = build_venue_store(tmp_path)
    s.set_map_fields(ids["home"], pinned=1)
    text = brief.build(s, GLOBAL_NS, now=NOW)
    people = next(l for l in text.splitlines() if l.startswith("People lately"))
    assert "Sid Patel" in people
    assert "Pinned" in text and "1625 Main St" in text


def test_failing_or_slow_source_omitted(tmp_path):
    s, _e, _ids = build_venue_store(tmp_path)

    def boom(ctx):
        raise RuntimeError("HA down")

    def slow(ctx):
        time.sleep(2)
        return "Car: never shown"

    brief.register_source("home", boom, order=50)
    brief.register_source("car", slow, order=51, timeout_s=0.2)
    brief.register_source("health", lambda ctx: "Health today: slept 7 h 10 m", order=40)
    t0 = time.perf_counter()
    text = brief.build(s, GLOBAL_NS, now=NOW)
    assert time.perf_counter() - t0 < 1.5
    assert "Health today: slept 7 h 10 m" in text
    assert "never shown" not in text and "HA down" not in text


def test_brief_capped(tmp_path):
    s, _e, _ids = build_venue_store(tmp_path)
    brief.register_source("huge", lambda ctx: "x" * 10_000, order=90)
    assert len(brief.build(s, GLOBAL_NS, now=NOW)) <= brief.MAX_CHARS


def test_current_text_never_blocks_before_first_build():
    t0 = time.perf_counter()
    assert brief.current_text() == ""
    assert time.perf_counter() - t0 < 0.05


def test_start_builds_and_mark_dirty_rebuilds(tmp_path):
    s, _e, _ids = build_venue_store(tmp_path)
    calls = []
    brief.register_source("probe", lambda ctx: calls.append(1) or "probe line", order=99)
    brief.start(s, GLOBAL_NS, interval=60, debounce=0.05)
    deadline = time.time() + 3
    while "probe line" not in brief.current_text() and time.time() < deadline:
        time.sleep(0.02)
    assert "probe line" in brief.current_text()
    n = len(calls)
    brief.mark_dirty()
    deadline = time.time() + 3
    while len(calls) == n and time.time() < deadline:
        time.sleep(0.02)
    assert len(calls) > n


def test_prefetch_contains_brief_and_recall(tmp_path):
    from plugins.memory.jarvis_memory import JarvisMemoryProvider
    p = JarvisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path), platform="cli",
                 _config_override={"embedder": "fake", "embed_dim": 64, "extract": "off",
                                   "proactive": "off", "migrate_builtin": False})
    p.handle_tool_call("memory_store", {"content": "the watch app deploys via deploy_both.sh"})
    brief._set_text("[Now — what's going on in his life]\nComing up\n- Fri 23 Oct: F1")
    out = p.prefetch("deploy the watch app")
    assert out.index("[Now") < out.index("[Long-term memory]")
    assert "deploy_both.sh" in out
    p.shutdown()


def test_same_day_calendar_duplicates_listed_once(tmp_path):
    s, _e, _ids = build_venue_store(tmp_path)
    brief.register_data("calendar", lambda ctx: [
        {"title": "Mom's Bday", "start": ts(2026, 10, 23, 0, 0), "all_day": True},
        {"title": "Mom's birthday", "start": ts(2026, 10, 23, 0, 0), "all_day": True},
        {"title": "Mom’s 47th Birthday", "start": ts(2026, 10, 23, 0, 0), "all_day": True},
        {"title": "Dentist", "start": ts(2026, 10, 23, 9, 0), "all_day": False}])
    text = brief.build(s, GLOBAL_NS, now=NOW)
    assert sum("Mom" in l for l in text.splitlines()) == 1 and "Dentist" in text
