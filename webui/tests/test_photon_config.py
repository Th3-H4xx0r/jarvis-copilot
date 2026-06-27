"""Tests for the Photon provider setup endpoint backend (api.photon_config)."""

from __future__ import annotations

import importlib
import sys
from pathlib import Path

import pytest

_WEBUI = Path(__file__).resolve().parents[1]
if str(_WEBUI) not in sys.path:
    sys.path.insert(0, str(_WEBUI))

photon_config = importlib.import_module("api.photon_config")


@pytest.fixture(autouse=True)
def _clear_env(monkeypatch):
    for var in (
        "PHOTON_PROJECT_ID", "PHOTON_PROJECT_SECRET", "PHOTON_NOTIFY_TARGET",
        "PHOTON_SIDECAR_URL", "PHOTON_SIDECAR_TOKEN", "PHOTON_ALLOWED_USERS",
    ):
        monkeypatch.delenv(var, raising=False)


def test_get_masks_secrets_and_reports_unconfigured(monkeypatch):
    cfg = photon_config.get_photon_config()
    assert cfg["configured"] is False
    assert cfg["project_secret"] == ""          # never leaked
    assert cfg["project_secret_set"] is False
    # Default sidecar URL surfaced so the field isn't blank.
    assert cfg["sidecar_url"].startswith("http")
    assert any(f["key"] == "project_id" for f in cfg["fields"])


def test_get_reports_secret_set_without_value(monkeypatch):
    monkeypatch.setenv("PHOTON_PROJECT_ID", "pid")
    monkeypatch.setenv("PHOTON_PROJECT_SECRET", "supersecret")
    cfg = photon_config.get_photon_config()
    assert cfg["configured"] is True
    assert cfg["project_id"] == "pid"
    assert cfg["project_secret"] == ""
    assert cfg["project_secret_set"] is True


def test_set_requires_project_id():
    res = photon_config.set_photon_config({"project_secret": "s"})
    assert res["ok"] is False
    assert "Project ID" in res["error"]


def test_set_requires_secret_when_none_stored(monkeypatch):
    res = photon_config.set_photon_config({"project_id": "pid"})
    assert res["ok"] is False
    assert "secret" in res["error"].lower()


def test_set_writes_env(monkeypatch, tmp_path):
    written = {}

    def fake_write(env_path, updates):
        written.update(updates)
        # Mirror the real writer's os.environ update so post-write checks pass.
        import os
        for k, v in updates.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    monkeypatch.setattr("api.providers._write_env_file", fake_write)
    monkeypatch.setattr("api.providers._get_hermes_home", lambda: tmp_path)

    res = photon_config.set_photon_config({
        "project_id": "pid", "project_secret": "sec",
        "notify_target": "+15555550123",
    })
    assert res["ok"] is True
    assert written["PHOTON_PROJECT_ID"] == "pid"
    assert written["PHOTON_PROJECT_SECRET"] == "sec"
    assert written["PHOTON_NOTIFY_TARGET"] == "+15555550123"


def test_set_preserves_secret_when_blank(monkeypatch, tmp_path):
    monkeypatch.setenv("PHOTON_PROJECT_ID", "pid")
    monkeypatch.setenv("PHOTON_PROJECT_SECRET", "existing")
    written = {}
    monkeypatch.setattr("api.providers._write_env_file", lambda p, u: written.update(u))
    monkeypatch.setattr("api.providers._get_hermes_home", lambda: tmp_path)

    # Re-save with a new notify target but no secret typed → secret untouched.
    res = photon_config.set_photon_config({
        "project_id": "pid", "project_secret": "", "notify_target": "+1999",
    })
    assert res["ok"] is True
    assert "PHOTON_PROJECT_SECRET" not in written
    assert written["PHOTON_NOTIFY_TARGET"] == "+1999"


def test_set_rejects_newlines():
    res = photon_config.set_photon_config({"project_id": "a\nb"})
    assert res["ok"] is False
