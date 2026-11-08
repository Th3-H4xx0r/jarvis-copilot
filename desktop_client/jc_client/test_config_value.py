"""credentials.config_value is the one reader of jc-client's config.yaml flags."""
import json

import pytest

from jc_client import browser_mcp, credentials, service


@pytest.fixture
def cfg(tmp_path, monkeypatch):
    path = tmp_path / "config.yaml"
    monkeypatch.setattr(credentials, "_CONFIG_FILE", path)
    return path


def test_reads_the_json_the_client_writes(cfg):
    cfg.write_text(json.dumps({"browser_relay_mcp": True, "server_url": "https://x"}))
    assert credentials.config_value("browser_relay_mcp") is True
    assert credentials.config_value("server_url") == "https://x"
    assert credentials.config_value("absent", "d") == "d"


def test_reads_a_hand_edited_yaml_file(cfg):
    pytest.importorskip("yaml")
    cfg.write_text("playwright_extension_token: abc123\nbrowser_relay_mcp: yes\n")
    assert credentials.config_value("playwright_extension_token") == "abc123"
    assert credentials.config_value("browser_relay_mcp") is True


def test_missing_or_unusable_file_gives_the_default(cfg):
    assert credentials.config_value("k", "d") == "d"
    cfg.write_text("[1, 2]")
    assert credentials.config_value("k", "d") == "d"


def test_the_flag_readers_go_through_config_value(cfg, monkeypatch):
    cfg.write_text(json.dumps({"browser_relay_mcp": True,
                               "playwright_extension": False,
                               "playwright_extension_token": "tok"}))
    assert service._relay_mcp_enabled() is True
    assert service._playwright_extension_enabled() is False
    assert browser_mcp._config_extension_token() == "tok"

    cfg.write_text(json.dumps({}))
    assert service._relay_mcp_enabled() is False
    assert browser_mcp._config_extension_token() is None
    import jc_client.mcp_relay as relay
    monkeypatch.setattr(relay, "read_extension_token_from_chrome", lambda: "live")
    assert service._playwright_extension_enabled() is True  # no flag: auto-detect


def test_load_still_reads_credentials(cfg, monkeypatch):
    monkeypatch.setattr(credentials, "_try_keyring_get", lambda: None)
    monkeypatch.setattr(credentials, "_try_keyring_get_user", lambda user: None)
    cfg.write_text(json.dumps({"server_url": "https://s", "device_id": "d1"}))
    creds = credentials.load()
    assert creds.server_url == "https://s"
    assert creds.device_id == "d1"
    cfg.write_text("{not json: [")
    assert credentials.load().server_url == ""  # unparseable -> fresh
