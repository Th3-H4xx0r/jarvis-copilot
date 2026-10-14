"""Where service settings live: secrets in the profile's .env, the rest in services.json."""
from __future__ import annotations

import json

import pytest

from jarvis_services.config import ServicesConfig


def _writer(log):
    def write(path, updates):
        log.append((path, dict(updates)))
        lines = path.read_text().splitlines() if path.exists() else []
        kept = [l for l in lines if l.split("=", 1)[0] not in updates]
        kept += [f"{k}={v}" for k, v in updates.items() if v is not None]
        path.write_text("\n".join(kept) + "\n")
    return write


def test_reads_secrets_from_the_profile_env_then_the_process_env(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text('# keys\nSERVICES_STRIPE_API_KEY="sk_test_123"\n')
    monkeypatch.setenv("SERVICES_VERCEL_TOKEN", "vc_from_env")
    view = ServicesConfig(home_fn=lambda: tmp_path).load()
    assert view.secret("SERVICES_STRIPE_API_KEY") == "sk_test_123"
    assert view.secret("SERVICES_VERCEL_TOKEN") == "vc_from_env"
    assert view.secret("SERVICES_GITHUB_TOKEN") == ""


def test_home_follows_the_home_function(tmp_path):
    homes = [tmp_path / "a", tmp_path / "b"]
    for h in homes:
        h.mkdir()
    (homes[1] / ".env").write_text("SERVICES_NOTION_API_KEY=secret_b\n")
    current = {"home": homes[0]}
    cfg = ServicesConfig(home_fn=lambda: current["home"])
    assert cfg.load().secret("SERVICES_NOTION_API_KEY") == ""
    current["home"] = homes[1]
    assert cfg.load().secret("SERVICES_NOTION_API_KEY") == "secret_b"


def test_settings_round_trip_and_merge(tmp_path):
    cfg = ServicesConfig(home_fn=lambda: tmp_path)
    cfg.save_settings("n8n", {"url": "https://n8n.example.com"})
    cfg.save_settings("n8n", {"workflows": ["Sync"]})
    cfg.save_settings("crypto", {"enabled": True})
    stored = json.loads((tmp_path / "services.json").read_text())
    assert stored["n8n"] == {"url": "https://n8n.example.com", "workflows": ["Sync"]}
    view = cfg.load()
    assert view.setting("n8n", "url") == "https://n8n.example.com"
    assert view.setting("n8n", "missing", "dflt") == "dflt"
    assert view.section("crypto") == {"enabled": True}


def test_corrupt_settings_read_as_empty(tmp_path):
    (tmp_path / "services.json").write_text("{not json")
    assert ServicesConfig(home_fn=lambda: tmp_path).load().section("n8n") == {}


def test_set_secrets_goes_through_the_injected_writer(tmp_path):
    log = []
    cfg = ServicesConfig(home_fn=lambda: tmp_path, write_env=_writer(log))
    cfg.set_secrets({"SERVICES_RESEND_API_KEY": "re_123456789"})
    cfg.set_secrets({"SERVICES_RESEND_API_KEY": None})
    assert log == [(tmp_path / ".env", {"SERVICES_RESEND_API_KEY": "re_123456789"}),
                   (tmp_path / ".env", {"SERVICES_RESEND_API_KEY": None})]
    assert cfg.load().secret("SERVICES_RESEND_API_KEY") == ""


def test_set_secrets_without_a_writer_refuses(tmp_path):
    with pytest.raises(RuntimeError):
        ServicesConfig(home_fn=lambda: tmp_path).set_secrets({"X": "y"})


def test_default_home_is_get_hermes_home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    assert ServicesConfig().home == tmp_path
