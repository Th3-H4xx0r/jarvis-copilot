"""Mistral (Voxtral) TTS is disabled (mistralai quarantined on PyPI)."""

from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    for key in ("MISTRAL_API_KEY", "HERMES_SESSION_PLATFORM"):
        monkeypatch.delenv(key, raising=False)


@pytest.fixture
def mock_mistral_module():
    mock_client = MagicMock()
    mock_client.__enter__ = MagicMock(return_value=mock_client)
    mock_client.__exit__ = MagicMock(return_value=False)
    mock_mistral_cls = MagicMock(return_value=mock_client)
    fake_module = MagicMock()
    fake_module.Mistral = mock_mistral_cls
    with patch.dict("sys.modules", {"mistralai": fake_module, "mistralai.client": fake_module}):
        yield mock_client


class TestTtsDispatcherMistral:
    def test_dispatcher_returns_disabled_error(
        self, tmp_path, mock_mistral_module, monkeypatch
    ):
        """Mistral TTS is intentionally disabled (PyPI quarantine 2026-05-12).

        The dispatcher must short-circuit with a clear status message before
        attempting any SDK import, even when MISTRAL_API_KEY is set and a
        mock SDK is wired in. Restore routing once `mistralai` is
        un-quarantined on PyPI.
        """
        import json

        from tools.tts_tool import text_to_speech_tool

        monkeypatch.setenv("MISTRAL_API_KEY", "test-key")

        output_path = str(tmp_path / "out.mp3")
        with patch("tools.tts_tool._load_tts_config", return_value={"provider": "mistral"}):
            result = json.loads(text_to_speech_tool("Hello", output_path=output_path))

        assert result["success"] is False
        assert "temporarily disabled" in result["error"]
        assert "quarantined" in result["error"]
        # SDK must not have been called.
        mock_mistral_module.audio.speech.complete.assert_not_called()


class TestCheckTtsRequirementsMistral:
    def test_mistral_key_alone_does_not_satisfy_requirements(self, mock_mistral_module, monkeypatch):
        """Mistral TTS is disabled, so its key must not make TTS look available."""
        from tools.tts_tool import check_tts_requirements

        monkeypatch.setenv("MISTRAL_API_KEY", "test-key")
        with patch("tools.tts_tool._import_edge_tts", side_effect=ImportError), \
             patch("tools.tts_tool._import_elevenlabs", side_effect=ImportError), \
             patch("tools.tts_tool._import_openai_client", side_effect=ImportError), \
             patch("tools.tts_tool._check_neutts_available", return_value=False), \
             patch("tools.tts_tool._check_kittentts_available", return_value=False), \
             patch("tools.tts_tool._check_piper_available", return_value=False), \
             patch("tools.tts_tool._has_any_command_tts_provider", return_value=False):
            assert check_tts_requirements() is False
