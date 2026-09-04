"""Tests for plan 2.1 — voice pins to the configured fast lane instead of
force-redirecting off the raw anthropic API.

Covers:
  * _maybe_redirect_voice_anthropic / _claude_code_available are GONE.
  * get_voice_lane_config() reads voice.fast_lane / voice.escalation.
  * _run_agent_turn_via_chat resolves (model, provider) in the right
    precedence order: per-turn override > voice.fast_lane > session default.

Pure unit tests — the agent/session-store internals are faked so this never
touches a real session, a real provider, or a real streaming agent.
"""
import pathlib
import sys

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent.parent / "webui"
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

from api import voice  # noqa: E402


# ── the old force-redirect is gone ───────────────────────────────────────────

def test_redirect_function_removed():
    assert not hasattr(voice, "_maybe_redirect_voice_anthropic")
    assert not hasattr(voice, "_claude_code_available")


# ── get_voice_lane_config() ──────────────────────────────────────────────────

def test_lane_config_shape_when_unset(monkeypatch):
    monkeypatch.setattr(voice, "_read_hermes_config", lambda: {})
    assert voice.get_voice_lane_config() == {"fast_lane": None, "escalation": None}


def test_lane_config_reads_both_sections(monkeypatch):
    monkeypatch.setattr(voice, "_read_hermes_config", lambda: {
        "voice": {
            "fast_lane": {"provider": "anthropic", "model": "claude-haiku-4-5"},
            "escalation": {"provider": "anthropic", "model": "claude-sonnet-5"},
        }
    })
    cfg = voice.get_voice_lane_config()
    assert cfg["fast_lane"] == {"provider": "anthropic", "model": "claude-haiku-4-5"}
    assert cfg["escalation"] == {"provider": "anthropic", "model": "claude-sonnet-5"}


def test_lane_config_requires_both_provider_and_model(monkeypatch):
    monkeypatch.setattr(voice, "_read_hermes_config", lambda: {
        "voice": {"fast_lane": {"provider": "anthropic"}},  # model missing
    })
    assert voice.get_voice_lane_config()["fast_lane"] is None


# ── _run_agent_turn_via_chat: model/provider resolution precedence ──────────

class _FakeSession:
    def __init__(self, model=None, model_provider=None):
        self.model = model
        self.model_provider = model_provider
        self.workspace = ""


class _FakeChannel:
    def subscribe(self):
        return object()


def _drive(monkeypatch, *, session_model=None, session_provider=None,
           fast_lane=None, model_override="", provider_override=""):
    """Drive _run_agent_turn_via_chat just far enough to observe the
    (model, provider) it hands to _resolve_compatible_session_model_state,
    without a real session store or a real streaming agent."""
    import api.models as models_mod
    import api.routes as routes_mod
    import api.config as config_mod

    fake_session = _FakeSession(session_model, session_provider)
    monkeypatch.setattr(models_mod, "get_session", lambda sid: fake_session)
    monkeypatch.setattr(voice, "get_voice_lane_config",
                         lambda: {"fast_lane": fast_lane, "escalation": None})

    captured = {}

    def _fake_resolve(model, provider):
        captured["model"] = model
        captured["provider"] = provider
        return (model or ""), provider, False

    monkeypatch.setattr(routes_mod, "_resolve_compatible_session_model_state", _fake_resolve)
    monkeypatch.setattr(routes_mod, "_start_chat_stream_for_session",
                         lambda session, **kw: {"stream_id": "bench-stream"})
    monkeypatch.setattr(config_mod, "STREAMS", {"bench-stream": _FakeChannel()})
    monkeypatch.setattr(voice, "_consume_agent_stream", lambda *a, **k: iter(()))

    list(voice._run_agent_turn_via_chat(
        "sess-1", "hello",
        model_override=model_override, provider_override=provider_override,
    ))
    return captured


def test_fast_lane_used_when_no_override_and_no_session_default(monkeypatch):
    captured = _drive(
        monkeypatch,
        session_model=None, session_provider=None,
        fast_lane={"provider": "anthropic", "model": "claude-haiku-4-5"},
    )
    assert captured["model"] == "claude-haiku-4-5"
    assert captured["provider"] == "anthropic"


def test_session_default_used_when_fast_lane_unset(monkeypatch):
    captured = _drive(
        monkeypatch,
        session_model="@claude-code:claude-opus-4-8", session_provider="claude-code",
        fast_lane=None,
    )
    assert captured["model"] == "@claude-code:claude-opus-4-8"
    assert captured["provider"] == "claude-code"


def test_per_turn_override_wins_over_fast_lane(monkeypatch):
    captured = _drive(
        monkeypatch,
        session_model="whatever", session_provider="whatever-provider",
        fast_lane={"provider": "anthropic", "model": "claude-haiku-4-5"},
        model_override="claude-opus-5", provider_override="anthropic",
    )
    assert captured["model"] == "claude-opus-5"
    assert captured["provider"] == "anthropic"


def test_fast_lane_ignored_when_per_turn_override_set_even_partially(monkeypatch):
    # Only model_override supplied — provider falls back to the session's own
    # provider (mirrors the pre-existing per-field fallback semantics), NOT
    # the fast lane.
    captured = _drive(
        monkeypatch,
        session_model="session-model", session_provider="session-provider",
        fast_lane={"provider": "anthropic", "model": "claude-haiku-4-5"},
        model_override="override-model", provider_override="",
    )
    assert captured["model"] == "override-model"
    assert captured["provider"] == "session-provider"
