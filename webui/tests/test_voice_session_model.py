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


# ── _maybe_redirect_voice_anthropic: keep voice on the subscription ───────────
def test_redirect_anthropic_to_claude_code(monkeypatch):
    monkeypatch.setattr(voice, "_claude_code_available", lambda: True)
    monkeypatch.delenv("HERMES_VOICE_ALLOW_ANTHROPIC", raising=False)
    assert voice._maybe_redirect_voice_anthropic("@anthropic:claude-sonnet-4-6", "anthropic") \
        == ("@claude-code:claude-sonnet-4-6", "claude-code")
    assert voice._maybe_redirect_voice_anthropic("claude-opus-4-8", "anthropic") \
        == ("@claude-code:claude-opus-4-8", "claude-code")


def test_redirect_leaves_non_anthropic_untouched(monkeypatch):
    monkeypatch.setattr(voice, "_claude_code_available", lambda: True)
    assert voice._maybe_redirect_voice_anthropic("@claude-code:claude-opus-4-8", "claude-code") \
        == ("@claude-code:claude-opus-4-8", "claude-code")
    assert voice._maybe_redirect_voice_anthropic("gpt-5.5", "openai-codex") == ("gpt-5.5", "openai-codex")


def test_redirect_noop_without_claude_code(monkeypatch):
    # A user who genuinely uses anthropic (no claude-code) is left alone.
    monkeypatch.setattr(voice, "_claude_code_available", lambda: False)
    assert voice._maybe_redirect_voice_anthropic("@anthropic:claude-opus-4-8", "anthropic") \
        == ("@anthropic:claude-opus-4-8", "anthropic")


def test_redirect_opt_out_env(monkeypatch):
    monkeypatch.setattr(voice, "_claude_code_available", lambda: True)
    monkeypatch.setenv("HERMES_VOICE_ALLOW_ANTHROPIC", "1")
    assert voice._maybe_redirect_voice_anthropic("@anthropic:claude-opus-4-8", "anthropic") \
        == ("@anthropic:claude-opus-4-8", "anthropic")


# ── daily-rotation date helper ───────────────────────────────────────────────
def test_voice_session_local_date_today_vs_old():
    from datetime import date
    assert voice._voice_session_local_date(time.time()) == date.today()
    assert voice._voice_session_local_date(0) != date.today()  # epoch → 1970
    assert voice._voice_session_local_date(None) is None
