"""Coverage for Claude Code quota support + the aggregate /api/provider/quota/all.

Claude Code's subscription quota is the same Anthropic OAuth usage snapshot the
Dynamic Island reads; these tests pin that it is no longer "unsupported" on the
web path, and that the aggregate endpoint dedupes claude-code/anthropic (same
token) and only returns configured providers — each with windows that carry a
``used_percent`` for the client's progress bar.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import api.config as config
import api.profiles as profiles

ROOT = Path(__file__).resolve().parents[1]


def _with_config(model=None, providers=None):
    old_cfg = dict(config.cfg)
    old_mtime = config._cfg_mtime
    config.cfg.clear()
    config.cfg["model"] = model or {}
    if providers is not None:
        config.cfg["providers"] = providers
    try:
        config._cfg_mtime = config.Path(config._get_config_path()).stat().st_mtime
    except Exception:
        config._cfg_mtime = 0.0
    return old_cfg, old_mtime


def _restore_config(old_cfg, old_mtime):
    config.cfg.clear()
    config.cfg.update(old_cfg)
    config._cfg_mtime = old_mtime


def _avail(provider, display, windows, *, quota=None, label=None, details=None):
    """A minimal get_provider_quota 'available' result."""
    result = {
        "ok": True,
        "provider": provider,
        "display_name": display,
        "supported": True,
        "status": "available",
        "label": label,
        "quota": quota,
        "message": f"{display} account limits loaded.",
    }
    if quota is None:
        result["account_limits"] = {
            "provider": provider,
            "source": "oauth_usage_api",
            "title": "Account limits",
            "plan": None,
            "windows": windows,
            "details": details or [],
            "available": True,
            "unavailable_reason": None,
            "fetched_at": "2030-03-17T12:30:00Z",
        }
    return result


def _window(label, used):
    return {
        "label": label,
        "used_percent": used,
        "remaining_percent": max(0.0, 100.0 - used),
        "reset_at": None,
        "detail": None,
    }


# ── Claude Code is now a supported quota provider on the web path ──────────────


def test_claude_code_quota_is_now_supported(monkeypatch, tmp_path):
    """get_provider_quota('claude-code') returns windows instead of 'unsupported'."""
    monkeypatch.setattr(profiles, "get_active_hermes_home", lambda: tmp_path)
    old_cfg, old_mtime = _with_config(model={"provider": "claude-code"})

    import api.providers as providers

    monkeypatch.setattr(
        providers,
        "_agent_fetch_account_usage_for_home",
        lambda provider, home, api_key=None: SimpleNamespace(
            provider="claude-code",
            source="oauth_usage_api",
            title="Account limits",
            plan=None,
            fetched_at=datetime(2030, 3, 17, 12, 30, tzinfo=timezone.utc),
            available=True,
            windows=(
                SimpleNamespace(
                    label="Current session",
                    used_percent=45.0,
                    reset_at=datetime(2030, 3, 17, 17, 30, tzinfo=timezone.utc),
                    detail=None,
                ),
            ),
            details=(),
            unavailable_reason=None,
        ),
    )
    try:
        result = providers.get_provider_quota()
    finally:
        _restore_config(old_cfg, old_mtime)

    assert result["ok"] is True
    assert result["provider"] == "claude-code"
    assert result["display_name"] == "Claude Code"
    assert result["status"] == "available"
    assert result["account_limits"]["windows"][0]["used_percent"] == 45.0
    assert result["account_limits"]["windows"][0]["remaining_percent"] == 55.0


def test_claude_code_is_in_account_usage_providers():
    import api.providers as providers

    assert "claude-code" in providers._ACCOUNT_USAGE_PROVIDERS


# ── Aggregate endpoint ────────────────────────────────────────────────────────


def test_get_all_provider_quota_includes_claude_code_and_codex_and_skips_anthropic(monkeypatch):
    """With claude-code available, anthropic is never probed (same token = dup)."""
    import api.providers as providers

    seen = []

    def fake(provider, refresh=False):
        seen.append(provider)
        if provider == "claude-code":
            return _avail("claude-code", "Claude Code", [_window("Current session", 45.0)])
        if provider == "openai-codex":
            return _avail("openai-codex", "OpenAI Codex", [_window("Session", 61.0)])
        if provider == "openrouter":
            return {"ok": False, "provider": "openrouter", "status": "no_key", "quota": None}
        if provider == "anthropic":
            raise AssertionError("anthropic must be skipped while claude-code is available")
        return {"status": "unsupported"}

    monkeypatch.setattr(providers, "get_provider_quota", fake)
    result = providers.get_all_provider_quota()

    assert result["ok"] is True
    assert [b["provider"] for b in result["providers"]] == ["claude-code", "openai-codex"]
    assert result["providers"][0]["windows"][0]["used_percent"] == 45.0
    assert result["providers"][1]["display_name"] == "OpenAI Codex"
    assert "anthropic" not in seen


def test_get_all_provider_quota_falls_back_to_anthropic_when_claude_code_unavailable(monkeypatch):
    import api.providers as providers

    def fake(provider, refresh=False):
        if provider == "anthropic":
            return _avail("anthropic", "Anthropic", [_window("Current week", 10.0)])
        if provider == "openai-codex":
            return _avail("openai-codex", "OpenAI Codex", [_window("Session", 5.0)])
        return {"status": "unavailable", "provider": provider}

    monkeypatch.setattr(providers, "get_provider_quota", fake)
    result = providers.get_all_provider_quota()

    provider_ids = [b["provider"] for b in result["providers"]]
    assert "claude-code" not in provider_ids
    assert provider_ids[0] == "anthropic"  # inserted at the front
    assert "openai-codex" in provider_ids


def _codex_exhausted(total_credentials=1, next_reset_at="2030-03-17T18:46:40Z"):
    """A get_provider_quota result for a Codex pool whose credentials are spent."""
    return {
        "ok": False,
        "provider": "openai-codex",
        "display_name": "OpenAI Codex",
        "supported": True,
        "status": "unavailable",
        "quota": None,
        "account_limits": {
            "provider": "openai-codex",
            "source": "usage_api_pool",
            "title": "Account limits",
            "plan": None,
            "windows": [],
            "details": [f"0/{total_credentials} credentials available", f"{total_credentials} exhausted"],
            "available": False,
            "unavailable_reason": "No Codex pool credentials returned available account limits.",
            "fetched_at": "2030-03-17T12:30:00Z",
            "pool": {
                "total_credentials": total_credentials,
                "available_credentials": 0,
                "exhausted_credentials": total_credentials,
                "failed_credentials": 0,
                "next_reset_at": next_reset_at,
                "credentials": [],
            },
        },
        "message": "OpenAI Codex account limits are unavailable.",
    }


def test_get_all_provider_quota_keeps_exhausted_codex_visible(monkeypatch):
    """A spent Codex pool must NOT disappear — it stays as a full 'used up' bar."""
    import api.providers as providers

    def fake(provider, refresh=False):
        if provider == "openai-codex":
            return _codex_exhausted()
        return {"status": "no_key", "provider": provider}

    monkeypatch.setattr(providers, "get_provider_quota", fake)
    result = providers.get_all_provider_quota()

    codex = next((b for b in result["providers"] if b["provider"] == "openai-codex"), None)
    assert codex is not None, "exhausted Codex section should remain visible"
    assert codex["available"] is False
    assert len(codex["windows"]) == 1
    assert codex["windows"][0]["used_percent"] == 100.0
    assert codex["windows"][0]["remaining_percent"] == 0.0
    assert codex["windows"][0]["reset_at"] == "2030-03-17T18:46:40Z"
    assert any("exhausted" in d for d in codex["details"])


def test_get_all_provider_quota_omits_codex_with_zero_pool_credentials(monkeypatch):
    """A Codex provider with no pool credentials at all is not configured → omitted."""
    import api.providers as providers

    def fake(provider, refresh=False):
        if provider == "openai-codex":
            return _codex_exhausted(total_credentials=0)
        return {"status": "no_key", "provider": provider}

    monkeypatch.setattr(providers, "get_provider_quota", fake)
    result = providers.get_all_provider_quota()

    assert all(b["provider"] != "openai-codex" for b in result["providers"])


def test_get_all_provider_quota_omits_unconfigured_providers(monkeypatch):
    import api.providers as providers

    def fake(provider, refresh=False):
        if provider == "claude-code":
            return _avail("claude-code", "Claude Code", [_window("Current session", 30.0)])
        return {"status": "no_key", "provider": provider}

    monkeypatch.setattr(providers, "get_provider_quota", fake)
    result = providers.get_all_provider_quota()

    assert [b["provider"] for b in result["providers"]] == ["claude-code"]


def test_get_all_provider_quota_is_resilient_to_a_provider_raising(monkeypatch):
    """One provider raising must not blank the whole aggregate (no 500)."""
    import api.providers as providers

    def fake(provider, refresh=False):
        if provider == "claude-code":
            return _avail("claude-code", "Claude Code", [_window("Current session", 45.0)])
        if provider == "openai-codex":
            raise RuntimeError("codex pool subprocess exploded")
        return {"status": "no_key", "provider": provider}

    monkeypatch.setattr(providers, "get_provider_quota", fake)

    result = providers.get_all_provider_quota()  # must not raise

    assert result["ok"] is True
    assert [b["provider"] for b in result["providers"]] == ["claude-code"]


def test_get_all_provider_quota_synthesizes_openrouter_credit_window(monkeypatch):
    import api.providers as providers

    def fake(provider, refresh=False):
        if provider == "openrouter":
            return {
                "ok": True,
                "provider": "openrouter",
                "display_name": "OpenRouter",
                "supported": True,
                "status": "available",
                "label": "OpenRouter credits",
                "quota": {"limit_remaining": 70.0, "usage": 30.0, "limit": 100.0},
                "message": "OpenRouter quota status loaded.",
            }
        return {"status": "unavailable", "provider": provider}

    monkeypatch.setattr(providers, "get_provider_quota", fake)
    result = providers.get_all_provider_quota()

    block = next(b for b in result["providers"] if b["provider"] == "openrouter")
    assert block["windows"][0]["label"] == "Credits"
    assert block["windows"][0]["used_percent"] == 30.0
    assert block["windows"][0]["remaining_percent"] == 70.0


def test_provider_quota_all_route_is_registered():
    routes = (ROOT / "api" / "routes.py").read_text(encoding="utf-8")
    assert 'parsed.path == "/api/provider/quota/all"' in routes
    assert "get_all_provider_quota(refresh=refresh)" in routes
    assert "get_all_provider_quota" in routes


def test_provider_quota_windows_render_a_progress_bar():
    """Every quota window must show a usage progress bar on the web card."""
    panels = (ROOT / "static" / "panels.js").read_text(encoding="utf-8")
    css = (ROOT / "static" / "style.css").read_text(encoding="utf-8")
    assert "function _providerQuotaBar" in panels
    # bar wired into both the main card and the credential-pool breakdown
    assert panels.count("_providerQuotaBar(w&&w.used_percent)") >= 2
    assert ".provider-quota-bar{" in css
    assert ".provider-quota-bar-fill" in css
    assert ".provider-quota-bar.is-critical" in css
