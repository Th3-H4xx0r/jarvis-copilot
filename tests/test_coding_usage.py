import json
import os
from datetime import datetime, timezone

from agent import coding_usage


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def _usage_entry(ts, inp, out, cache_create=0):
    return {"timestamp": _iso(ts), "message": {"usage": {
        "input_tokens": inp, "output_tokens": out,
        "cache_creation_input_tokens": cache_create,
        "cache_read_input_tokens": 999999}}}  # cache_read excluded


def _write_transcript(home, name, entries):
    proj = os.path.join(home, ".claude", "projects", "-x-proj")
    os.makedirs(proj, exist_ok=True)
    with open(os.path.join(proj, name), "w") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")


def _reset_cache():
    coding_usage._cache.update({"at": 0.0, "val": None})


def test_compute_usage_buckets(tmp_path, monkeypatch):
    home = str(tmp_path)
    now = 1_000_000.0
    monkeypatch.setenv("JC_CODING_5H_BUDGET", "1000")
    monkeypatch.setenv("JC_CODING_WEEK_BUDGET", "10000")
    _write_transcript(home, "a.jsonl", [
        _usage_entry(now - 60, 100, 50),       # in 5h -> 150
        _usage_entry(now - 2 * 3600, 100, 0),  # in 5h -> 100
        _usage_entry(now - 2 * 86400, 500, 0),  # week only -> 500
        _usage_entry(now - 10 * 86400, 9999, 0),  # older than a week -> ignored
    ])
    u = coding_usage.compute_usage(now=now, home=home)
    assert u["five_hour_tokens"] == 250
    assert u["weekly_tokens"] == 750
    assert u["five_hour_pct"] == 25     # 250 / 1000
    assert u["weekly_pct"] == 8         # round(100 * 750 / 10000) = 8


def test_compute_usage_clamps_to_100(tmp_path, monkeypatch):
    home = str(tmp_path)
    now = 1_000_000.0
    monkeypatch.setenv("JC_CODING_5H_BUDGET", "100")
    _write_transcript(home, "a.jsonl", [_usage_entry(now - 60, 9999, 0)])
    u = coding_usage.compute_usage(now=now, home=home)
    assert u["five_hour_pct"] == 100


def test_cache_creation_counted_cache_read_excluded(tmp_path):
    home = str(tmp_path)
    now = 1_000_000.0
    _write_transcript(home, "a.jsonl", [_usage_entry(now - 60, 10, 20, cache_create=5)])
    u = coding_usage.compute_usage(now=now, home=home)
    assert u["five_hour_tokens"] == 35  # 10+20+5, the 999999 cache_read ignored


def test_get_usage_none_without_store(tmp_path):
    _reset_cache()
    assert coding_usage.get_usage(now=123.0, home=str(tmp_path), force=True) is None


def test_get_usage_caches_within_ttl(tmp_path):
    home = str(tmp_path)
    now = 1_000_000.0
    _write_transcript(home, "a.jsonl", [_usage_entry(now - 60, 100, 50)])
    _reset_cache()
    u1 = coding_usage.get_usage(now=now, home=home, force=True)
    assert u1 is not None
    # within TTL it returns the cached value even pointed at an empty home
    u2 = coding_usage.get_usage(now=now + 10, home=str(tmp_path / "nope"))
    assert u2 is u1


def test_malformed_lines_ignored(tmp_path):
    home = str(tmp_path)
    now = 1_000_000.0
    proj = os.path.join(home, ".claude", "projects", "-x")
    os.makedirs(proj, exist_ok=True)
    with open(os.path.join(proj, "a.jsonl"), "w") as f:
        f.write("not json but has usage keyword\n")
        f.write(json.dumps({"timestamp": "garbage", "usage": {"input_tokens": 5}}) + "\n")
        f.write(json.dumps(_usage_entry(now - 30, 7, 3)) + "\n")
    u = coding_usage.compute_usage(now=now, home=home)
    assert u["five_hour_tokens"] == 10  # only the well-formed, timestamped entry
