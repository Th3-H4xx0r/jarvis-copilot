"""Tests for the accurate (OAuth usage API) coding usage provider.

The provider fetches Anthropic's real subscription-limit utilization; these
tests inject a fake ``fetch`` so they never hit the network, and reset the shared
module cache between cases.
"""
import pytest

from agent import coding_usage


@pytest.fixture(autouse=True)
def _reset_cache():
    coding_usage._cache = None
    yield
    coding_usage._cache = None


# ── compute_usage: payload → snapshot ────────────────────────────────────────

def test_compute_usage_maps_payload():
    payload = {
        "five_hour": {"utilization": 0.47, "resets_at": "2026-06-08T22:00:00Z"},
        "seven_day": {"utilization": 23, "resets_at": "2026-06-13T00:00:00Z"},
    }
    snap = coding_usage.compute_usage(now=1000.0, fetch=lambda: payload)
    assert snap["five_hour_pct"] == 47    # 0.47 fraction → 47%
    assert snap["weekly_pct"] == 23       # already 0-100 → kept
    assert snap["available"] is True
    assert snap["five_hour_reset_at"] is not None
    assert snap["weekly_reset_at"] is not None


def test_compute_usage_transient_error_returns_none():
    # A transient fetch failure must NOT produce a snapshot (so the caller keeps
    # the last good one).
    assert coding_usage.compute_usage(now=1.0, fetch=lambda: None) is None


def test_compute_usage_non_oauth_is_unavailable():
    # A definitive "no usage" (API-key account) → available=False, persistable.
    snap = coding_usage.compute_usage(now=1.0, fetch=lambda: {})
    assert snap is not None
    assert snap["available"] is False
    assert snap["five_hour_pct"] is None


def test_pct_clamps_and_rounds():
    assert coding_usage._pct(0.47) == 47      # fraction → percent
    assert coding_usage._pct(23) == 23        # already 0-100 → kept
    assert coding_usage._pct(150) == 100      # over-100 clamps
    assert coding_usage._pct(0.0) == 0
    assert coding_usage._pct(0.999) == 100    # 99.9 → 100
    assert coding_usage._pct(None) is None
    assert coding_usage._pct("bad") is None


# ── _to_usage_dict / get_usage: snapshot → consumer dict ─────────────────────

def test_to_usage_dict_none_when_unavailable():
    assert coding_usage._to_usage_dict(None, now=1.0) is None
    assert coding_usage._to_usage_dict({"available": False}, now=1.0) is None


def test_get_usage_reset_strings_from_absolute_ts():
    coding_usage._cache = {
        "five_hour_pct": 47, "weekly_pct": 23,
        "five_hour_reset_at": 1000.0 + 2 * 3600 + 30 * 60,  # 2h30m out
        "weekly_reset_at": 1000.0 + 3 * 86400,              # 3d out
        "available": True, "fetched_at": 1000.0,
    }
    d = coding_usage.get_usage(now=1000.0)
    assert d["five_hour_pct"] == 47
    assert d["weekly_pct"] == 23
    assert d["five_hour_resets"] == "2h 30m"
    assert d["weekly_resets"] == "3d"


def test_get_usage_none_when_no_snapshot():
    assert coding_usage.get_usage(now=1.0) is None


# ── refresh: fetch + persist + cache, transient-safe ─────────────────────────

class _FakeStore:
    def __init__(self, snap=None):
        self.saved = None
        self._snap = snap

    def upsert_usage_snapshot(self, **kw):
        self.saved = kw

    def get_usage_snapshot(self):
        return self._snap


def test_refresh_persists_and_caches():
    store = _FakeStore()
    payload = {"five_hour": {"utilization": 0.5, "resets_at": None},
               "seven_day": {"utilization": 0.1, "resets_at": None}}
    snap = coding_usage.refresh(store, now=1000.0, fetch=lambda: payload)
    assert snap["five_hour_pct"] == 50
    assert store.saved["five_hour_pct"] == 50
    assert store.saved["available"] in (1, True)
    # cache now serves reads
    assert coding_usage.get_usage(now=1000.0)["five_hour_pct"] == 50


def test_refresh_transient_keeps_last_and_does_not_persist():
    coding_usage._cache = {
        "five_hour_pct": 47, "weekly_pct": None,
        "five_hour_reset_at": None, "weekly_reset_at": None,
        "available": True, "fetched_at": 1.0,
    }

    class _Boom:
        def upsert_usage_snapshot(self, **kw):
            raise AssertionError("must not persist on a transient error")

    snap = coding_usage.refresh(_Boom(), now=2.0, fetch=lambda: None)
    assert snap["five_hour_pct"] == 47  # unchanged


def test_get_usage_reads_db_on_cold_cache():
    snap = {"five_hour_pct": 12, "weekly_pct": 3,
            "five_hour_reset_at": None, "weekly_reset_at": None,
            "available": True, "fetched_at": 1.0}
    store = _FakeStore(snap=snap)
    d = coding_usage.get_usage(store, now=1.0)
    assert d["five_hour_pct"] == 12
    assert d["weekly_pct"] == 3


# ── _fetch_oauth_usage token classification (transient vs definitive) ─────────

def test_fetch_oauth_usage_no_token_is_transient(monkeypatch):
    import agent.anthropic_adapter as aa
    monkeypatch.setattr(aa, "resolve_anthropic_token", lambda: "")
    monkeypatch.setattr(aa, "_is_oauth_token", lambda t: True)
    # Empty token may be a transient OAuth-refresh blip → None (keep last good),
    # NOT {} (which would clobber the cache to "unavailable").
    assert coding_usage._fetch_oauth_usage() is None


def test_fetch_oauth_usage_token_error_is_transient(monkeypatch):
    import agent.anthropic_adapter as aa

    def _boom():
        raise RuntimeError("oauth refresh failed")

    monkeypatch.setattr(aa, "resolve_anthropic_token", _boom)
    monkeypatch.setattr(aa, "_is_oauth_token", lambda t: True)
    assert coding_usage._fetch_oauth_usage() is None


def test_fetch_oauth_usage_non_oauth_is_definitively_unavailable(monkeypatch):
    import agent.anthropic_adapter as aa
    monkeypatch.setattr(aa, "resolve_anthropic_token", lambda: "sk-ant-apikey")
    monkeypatch.setattr(aa, "_is_oauth_token", lambda t: False)
    assert coding_usage._fetch_oauth_usage() == {}
