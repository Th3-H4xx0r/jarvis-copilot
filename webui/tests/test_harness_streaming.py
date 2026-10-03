from types import SimpleNamespace

import api.config as cfg
from api.streaming import _plan_for_turn


def _s(**kw):
    base = dict(session_id="s1", harness_id=None, model="m", model_provider=None,
                _turn_harness_id=None, _turn_explicit_model=None, _turn_surface=None)
    base.update(kw)
    return SimpleNamespace(**base)


def test_plan_for_turn_voice_default(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path))
    s = _s(_turn_surface="voice")
    plan = _plan_for_turn(s, "hello", None)
    assert plan.harness_id == "fast-claude" and plan.node_id == "fast" and s._turn_surface is None


def test_plan_for_turn_old_client_is_single(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path))
    plan = _plan_for_turn(_s(harness_id="router", _turn_explicit_model=("@x:y", "x")), "fix my code", None)
    assert plan.harness_id == "single" and plan.model == "@x:y"


def test_plan_for_turn_requested_harness(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path))
    assert _plan_for_turn(_s(_turn_harness_id="router"), "refactor this", None).node_id == "claude"


def test_plan_for_turn_chat_default_is_single_with_session_model(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path))
    plan = _plan_for_turn(_s(model="@ollama-cloud:nemotron-3-ultra", model_provider="ollama-cloud"), "hi", None)
    assert plan.harness_id == "single" and plan.model == "@ollama-cloud:nemotron-3-ultra"


def test_evict_drops_node_agents():
    with cfg.SESSION_AGENT_CACHE_LOCK:
        for k in ("s9", "s9#fast-claude:fast", "s90"):
            cfg.SESSION_AGENT_CACHE[k] = (SimpleNamespace(_session_db=None), "sig")
    assert cfg.evict_session_agents("s9") == 2
    assert "s90" in cfg.SESSION_AGENT_CACHE
    cfg.SESSION_AGENT_CACHE.pop("s90", None)


def test_streaming_uses_plan_for_model_cache_key_and_meta():
    import inspect
    import api.streaming as st
    src = inspect.getsource(st._run_agent_streaming)
    assert "_plan_for_turn(" in src
    assert "_harness_plan.cache_key(session_id)" in src
    assert "put('turn_meta'" in src and "_dm['_meta']" in src


def test_harness_claude_nodes_are_marked_warm():
    import inspect
    import api.streaming as st
    src = inspect.getsource(st._run_agent_streaming)
    assert "agent._harness_warm = " in src and 'resolved_provider == "claude-code"' in src
