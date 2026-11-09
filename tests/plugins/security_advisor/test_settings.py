"""Security Advisor settings live under config.yaml ``security_advisor``."""
import pytest


def test_defaults_and_save_round_trip(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from plugins.security_advisor import settings
    s = settings.load()
    assert s["alert_cap_per_hour"] == 3 and s["digest_hour"] == 8 and s["block_ttl_hours"] == 24
    assert s["quiet_hours"] == [23, 7] and s["file_poll_s"] == 300
    out = settings.save({"alert_cap_per_hour": 5, "disabled_rules": ["new_device"]})
    assert out["alert_cap_per_hour"] == 5 and settings.load()["disabled_rules"] == ["new_device"]
    assert settings.load()["digest_hour"] == 8


def test_save_rejects_bad_values(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from plugins.security_advisor import settings
    for bad in ({"digest_hour": 25}, {"quiet_hours": [1]}, {"known_ssh_ips": ["nope"]},
                {"unknown_key": 1}, {"alert_cap_per_hour": "lots"}):
        with pytest.raises(ValueError):
            settings.save(bad)


def test_default_config_matches_plugin_defaults():
    from jarviscopilot_cli.config import DEFAULT_CONFIG
    from plugins.security_advisor.settings import DEFAULTS
    assert DEFAULT_CONFIG["security_advisor"] == DEFAULTS
