"""Celeris runtime: per-model base URL, missing-key contract, CELERIS_BASE_URL."""
import pytest


@pytest.fixture(autouse=True)
def _discover(monkeypatch):
    import model_tools  # noqa: F401
    monkeypatch.delenv("CELERIS_BASE_URL", raising=False)


def _resolve(monkeypatch, model_cfg=None, **kw):
    from jarviscopilot_cli import runtime_provider as rp
    monkeypatch.setattr(rp, "_get_model_config", lambda: dict(model_cfg or {}))
    return rp.resolve_runtime_provider(requested="celeris", **kw)


def test_missing_key_is_a_shown_error(monkeypatch):
    monkeypatch.delenv("CELERIS_API_KEY", raising=False)
    from agent.error_classifier import is_missing_credential
    with pytest.raises(Exception) as exc:
        _resolve(monkeypatch, target_model="celeris-1")
    assert is_missing_credential(str(exc.value))
    assert "CELERIS_API_KEY" in str(exc.value)


def test_url_follows_the_model(monkeypatch):
    monkeypatch.setenv("CELERIS_API_KEY", "ck_test")
    rt = _resolve(monkeypatch, target_model="celeris-1-magnus")
    assert rt["provider"] == "celeris" and rt["api_mode"] == "chat_completions"
    assert rt["base_url"] == "https://inference.celeris.ai/celeris-1-magnus/v1"
    assert rt["api_key"] == "ck_test"


def test_no_model_uses_config_default_then_celeris_1(monkeypatch):
    monkeypatch.setenv("CELERIS_API_KEY", "ck_test")
    rt = _resolve(monkeypatch, model_cfg={"provider": "celeris", "default": "celeris-1-magnus"})
    assert rt["base_url"].endswith("/celeris-1-magnus/v1")
    rt = _resolve(monkeypatch, model_cfg={"provider": "openrouter", "default": "x/y"})
    assert rt["base_url"].endswith("/celeris-1/v1")


def test_base_url_env_override(monkeypatch):
    monkeypatch.setenv("CELERIS_API_KEY", "ck_test")
    monkeypatch.setenv("CELERIS_BASE_URL", "https://eu.inference.celeris.ai")
    rt = _resolve(monkeypatch, target_model="celeris-1")
    assert rt["base_url"] == "https://eu.inference.celeris.ai/celeris-1/v1"
