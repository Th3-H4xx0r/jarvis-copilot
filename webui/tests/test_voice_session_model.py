"""Tests for voice session model resolution: tracking the user's active model,
keeping voice off the rate-limited anthropic API, and daily rotation helpers.

Pure unit tests of the helpers in api.voice — no agent, no sockets, no store.
"""
import pathlib
import sys
import time

_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

from api import voice  # noqa: E402


# ── _preferred_voice_model: follow the user's actively-used model ─────────────
def test_preferred_voice_model_picks_most_recent_real_chat():
    rows = [
        {"source_tag": "voice", "model": "@anthropic:claude-sonnet-4-6",
         "model_provider": "anthropic", "updated_at": 100, "archived": False},
        {"source_tag": None, "model": "@claude-code:claude-opus-4-8",
         "model_provider": "claude-code", "updated_at": 90, "archived": False},
        {"source_tag": None, "model": "gpt-5.5",
         "model_provider": "openai-codex", "updated_at": 50, "archived": False},
    ]
    assert voice._preferred_voice_model(lambda: rows) == ("@claude-code:claude-opus-4-8", "claude-code")


def test_preferred_voice_model_skips_voice_anthropic_and_archived():
    rows = [
        {"source_tag": "voice", "model": "x", "model_provider": "claude-code",
         "updated_at": 999, "archived": False},                       # voice → skip
        {"source_tag": None, "model": "@anthropic:claude-opus-4-8",
         "model_provider": "anthropic", "updated_at": 998, "archived": False},  # anthropic → skip
        {"source_tag": None, "model": "gpt-5.5", "model_provider": "openai-codex",
         "updated_at": 5, "archived": True},                          # archived → skip
        {"source_tag": None, "model": "@claude-code:claude-sonnet-4-6",
         "model_provider": "claude-code", "updated_at": 3, "archived": False},
    ]
    assert voice._preferred_voice_model(lambda: rows) == ("@claude-code:claude-sonnet-4-6", "claude-code")


def test_preferred_voice_model_empty_when_nothing_usable():
    rows = [
        {"source_tag": None, "model": "", "model_provider": "", "updated_at": 1, "archived": False},
        {"source_tag": "voice", "model": "x", "model_provider": "claude-code", "updated_at": 2, "archived": False},
    ]
    assert voice._preferred_voice_model(lambda: rows) == ("", None)


# ── get_voice_lane_config: fast_lane/escalation from config.yaml (plan 2.1) ──
# _maybe_redirect_voice_anthropic (and its _claude_code_available helper) were
# deleted along with this test coverage — voice no longer force-redirects off
# the raw anthropic API; it pins to voice.fast_lane / voice.escalation config
# instead (see the tests below and cli-config.yaml.example).
def test_voice_lane_config_reads_fast_lane_and_escalation(monkeypatch):
    monkeypatch.setattr(voice, "_read_hermes_config", lambda: {
        "voice": {
            "fast_lane": {"provider": "anthropic", "model": "claude-haiku-4-5"},
            "escalation": {"provider": "anthropic", "model": "claude-sonnet-5"},
        }
    })
    assert voice.get_voice_lane_config() == {
        "fast_lane": {"provider": "anthropic", "model": "claude-haiku-4-5"},
        "escalation": {"provider": "anthropic", "model": "claude-sonnet-5"},
    }


def test_voice_lane_config_none_when_unset():
    voice_local = voice
    orig = voice_local._read_hermes_config
    try:
        voice_local._read_hermes_config = lambda: {}
        assert voice_local.get_voice_lane_config() == {"fast_lane": None, "escalation": None}
    finally:
        voice_local._read_hermes_config = orig


def test_voice_lane_config_ignores_malformed_sections(monkeypatch):
    monkeypatch.setattr(voice, "_read_hermes_config", lambda: {
        "voice": {"fast_lane": "not-a-dict", "escalation": 42},
    })
    assert voice.get_voice_lane_config() == {"fast_lane": None, "escalation": None}


# ── daily-rotation date helper ───────────────────────────────────────────────
def test_voice_session_local_date_today_vs_old():
    from datetime import date
    assert voice._voice_session_local_date(time.time()) == date.today()
    assert voice._voice_session_local_date(0) != date.today()  # epoch → 1970
    assert voice._voice_session_local_date(None) is None
