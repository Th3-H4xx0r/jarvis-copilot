"""Warm agents are bounded (the webui was OOM-killed holding them).

An agent idle longer than its prompt-cache retention has a cold cache anyway,
so it goes; past the size cap the least recently used goes; an agent with a
running stream never goes. A dropped agent is rebuilt on next use.
"""
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

import api.config as cfg


class _DB:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


def _agent(retention=None):
    a = SimpleNamespace(_session_db=_DB())
    if retention:
        a._cache_retention = retention
    return a


@pytest.fixture(autouse=True)
def cache(monkeypatch):
    """An empty cache and no running streams; the real contents come back after."""
    with cfg.SESSION_AGENT_CACHE_LOCK:
        saved = list(cfg.SESSION_AGENT_CACHE.items())
        cfg.SESSION_AGENT_CACHE.clear()
    with cfg.STREAMS_LOCK:
        saved_runs = dict(cfg.AGENT_INSTANCES)
        cfg.AGENT_INSTANCES.clear()
    monkeypatch.setattr(cfg, "cfg", {})  # no prompt_caching section: default retention
    yield cfg.SESSION_AGENT_CACHE
    with cfg.SESSION_AGENT_CACHE_LOCK:
        cfg.SESSION_AGENT_CACHE.clear()
        cfg.SESSION_AGENT_CACHE.update(saved)
    with cfg.STREAMS_LOCK:
        cfg.AGENT_INSTANCES.clear()
        cfg.AGENT_INSTANCES.update(saved_runs)


def _put(key, agent):
    with cfg.SESSION_AGENT_CACHE_LOCK:
        cfg.SESSION_AGENT_CACHE[key] = (agent, "sig")
        cfg.SESSION_AGENT_CACHE.move_to_end(key)
    return agent


def _use(key):
    """What a cache hit does in the streaming worker."""
    with cfg.SESSION_AGENT_CACHE_LOCK:
        cfg.SESSION_AGENT_CACHE.move_to_end(key)


def _later(seconds):
    return time.monotonic() + seconds


def test_an_agent_idle_past_its_retention_is_dropped_and_its_db_closed(cache):
    short = _put("a", _agent("standard"))
    long = _put("b", _agent("long"))

    assert cfg.sweep_session_agents(now=_later(cfg.retention_seconds({"prompt_caching": {"retention": "standard"}}) + 1)) == 1
    assert "a" not in cache and short._session_db.closed
    assert "b" in cache and not long._session_db.closed

    cfg.sweep_session_agents(now=_later(cfg.retention_seconds({"prompt_caching": {"retention": "long"}}) + 1))
    assert "b" not in cache and long._session_db.closed


def test_use_restarts_the_idle_clock(cache):
    _put("a", _agent("standard"))
    idle = cfg.retention_seconds({"prompt_caching": {"retention": "standard"}})
    cache.last_used["a"] -= idle - 1      # nearly expired …
    _use("a")                               # … then a turn picks it up
    assert cfg.sweep_session_agents(now=_later(2)) == 0
    assert "a" in cache


def test_retention_comes_from_config_when_the_agent_has_none(cache, monkeypatch):
    standard = cfg.retention_seconds({"prompt_caching": {"retention": "standard"}})
    long = cfg.retention_seconds({"prompt_caching": {"retention": "long"}})
    assert standard < long

    monkeypatch.setattr(cfg, "cfg", {"prompt_caching": {"retention": "standard"}})
    _put("a", _agent())
    cfg.sweep_session_agents(now=_later(standard + 1))
    assert "a" not in cache

    monkeypatch.setattr(cfg, "cfg", {})
    _put("b", _agent())
    cfg.sweep_session_agents(now=_later(standard + 1))
    assert "b" in cache                     # default is long


def test_retention_setting_and_its_old_alias():
    long = cfg.retention_seconds({})
    assert cfg.retention_seconds({"prompt_caching": {"retention": "long"}}) == long
    assert cfg.retention_seconds({"prompt_caching": {"retention": "standard"}}) < long
    # The old cache_ttl's "5m" was the default written into every config, so
    # on its own it says nothing (same rule as agent_init); the new key wins.
    assert cfg.retention_seconds({"prompt_caching": {"cache_ttl": "5m"}}) == long
    assert cfg.retention_seconds({"prompt_caching": {"cache_ttl": "1h"}}) == long
    assert cfg.retention_seconds({"prompt_caching": {"retention": "long", "cache_ttl": "5m"}}) == long
    assert cfg.retention_seconds({"prompt_caching": {"retention": "bogus"}}) == long


def test_past_the_cap_the_least_recently_used_goes(cache, monkeypatch):
    monkeypatch.setattr(cfg, "SESSION_AGENT_CACHE_MAX", 3)
    agents = {k: _put(k, _agent()) for k in ("a", "b", "c", "d", "e")}
    _use("a")                               # a is now the most recent

    assert cfg.sweep_session_agents() == 2
    assert list(cache) == ["d", "e", "a"]
    assert agents["b"]._session_db.closed and agents["c"]._session_db.closed


def test_an_agent_with_a_running_stream_is_never_dropped(cache, monkeypatch):
    monkeypatch.setattr(cfg, "SESSION_AGENT_CACHE_MAX", 1)
    busy = _put("busy", _agent("standard"))
    _put("idle", _agent("standard"))
    with cfg.STREAMS_LOCK:
        cfg.AGENT_INSTANCES["stream-1"] = busy

    cfg.sweep_session_agents(now=_later(10 * cfg.retention_seconds({})))
    assert "busy" in cache and not busy._session_db.closed
    assert "idle" not in cache


def test_the_entry_just_put_is_kept_even_when_everything_else_is_busy(cache, monkeypatch):
    """The streaming worker sweeps right after caching its new agent, before
    that agent's stream is registered as running."""
    monkeypatch.setattr(cfg, "SESSION_AGENT_CACHE_MAX", 1)
    busy = _put("busy", _agent())
    with cfg.STREAMS_LOCK:
        cfg.AGENT_INSTANCES["stream-1"] = busy
    new = _put("new", _agent())
    cfg.sweep_session_agents(keep=("new",))
    assert "new" in cache and not new._session_db.closed


def test_clearing_a_chat_spares_a_background_worker_mid_job(cache):
    """Deleting/clearing the chat (or a 401 self-heal on it) while a Background
    job runs must not close the worker agent's SessionDB under the job; the
    sweep drops it once the job is over."""
    chat = _put("p1", _agent())
    busy = _put("p1~bg#node:bg", _agent("standard"))
    idle = _put("p1~bg2#node:bg2", _agent())
    with cfg.STREAMS_LOCK:
        cfg.AGENT_INSTANCES["job-stream"] = busy

    assert cfg.evict_session_agents("p1") == 2
    assert set(cache) == {"p1~bg#node:bg"}
    assert chat._session_db.closed and idle._session_db.closed
    assert not busy._session_db.closed

    with cfg.STREAMS_LOCK:
        cfg.AGENT_INSTANCES.clear()
    cfg.sweep_session_agents(now=_later(cfg.retention_seconds({"prompt_caching": {"retention": "standard"}}) + 1))
    assert not cache and busy._session_db.closed


def test_a_workers_own_self_heal_still_drops_its_agent(cache):
    """Evicting the worker session itself (its own stream's credential
    self-heal) works like any chat's: the stale agent goes."""
    busy = _put("p1~bg#node:bg", _agent())
    with cfg.STREAMS_LOCK:
        cfg.AGENT_INSTANCES["job-stream"] = busy
    assert cfg.evict_session_agents("p1~bg") == 1 and not cache


def test_a_plain_dict_cache_is_tolerated(monkeypatch):
    """Some tests swap the cache for a plain dict; a sweep must not crash."""
    monkeypatch.setattr(cfg, "SESSION_AGENT_CACHE", {"a": (_agent(), "sig")})
    assert cfg.sweep_session_agents() == 0


def test_cap_reads_the_env(monkeypatch):
    monkeypatch.setenv("HERMES_WEBUI_AGENT_CACHE_MAX", "7")
    assert cfg._agent_cache_max_from_env() == 7
    monkeypatch.setenv("HERMES_WEBUI_AGENT_CACHE_MAX", "nonsense")
    assert cfg._agent_cache_max_from_env() == cfg._AGENT_CACHE_MAX_DEFAULT
    monkeypatch.delenv("HERMES_WEBUI_AGENT_CACHE_MAX")
    assert cfg._agent_cache_max_from_env() == cfg._AGENT_CACHE_MAX_DEFAULT


def test_the_streaming_worker_sweeps_when_it_caches_a_new_agent():
    """The put path bounds the cache through the sweep (which spares running
    agents), not a blind LRU pop."""
    src = (Path(__file__).resolve().parents[1] / "api" / "streaming.py").read_text()
    put = src[src.index("SESSION_AGENT_CACHE[_agent_cache_key] = (agent, _agent_sig)"):]
    put = put[:put.index("logger.debug('[webui] Created new agent")]
    assert "sweep_session_agents(" in put
    assert "popitem(" not in put
