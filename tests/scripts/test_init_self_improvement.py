"""Tests for the idempotent self-improvement home initializer."""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest
import yaml

_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "init_self_improvement.py"


def _load_module():
    """Load scripts/init_self_improvement.py by path (scripts/ is not a package)."""
    spec = importlib.util.spec_from_file_location("init_self_improvement", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    return tmp_path


def _run_init(monkeypatch):
    init = _load_module()
    # Avoid copying the real bundled skill tree in tests.
    monkeypatch.setattr(
        init, "sync_skills", lambda quiet=True: {"copied": [], "total_bundled": 0}
    )
    return init.initialize(quiet=True)


def test_init_creates_home_config_and_git(home, monkeypatch):
    _run_init(monkeypatch)
    cfg_path = home / "config.yaml"
    assert cfg_path.exists()
    cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8"))
    assert cfg["memory"]["nudge_interval"] == 3
    assert cfg["memory"]["provider"] == ""
    assert cfg["skills"]["creation_nudge_interval"] == 3
    assert cfg["curator"]["interval_hours"] == 24
    assert (home / "memories").is_dir()
    assert (home / ".git").is_dir()


def test_init_is_idempotent_and_preserves_existing_keys(home, monkeypatch):
    (home / "config.yaml").write_text(
        yaml.safe_dump({"memory": {"memory_char_limit": 9999}}), encoding="utf-8"
    )
    _run_init(monkeypatch)
    _run_init(monkeypatch)  # second run must not raise
    cfg = yaml.safe_load((home / "config.yaml").read_text(encoding="utf-8"))
    # Existing user value preserved; tuned values merged in.
    assert cfg["memory"]["memory_char_limit"] == 9999
    assert cfg["memory"]["nudge_interval"] == 3


def test_init_fills_null_section(home, monkeypatch):
    # An empty `memory:` section parses as null; init must fill it (not no-op).
    (home / "config.yaml").write_text(
        "memory:\nskills:\n", encoding="utf-8"
    )
    _run_init(monkeypatch)
    cfg = yaml.safe_load((home / "config.yaml").read_text(encoding="utf-8"))
    assert cfg["memory"]["nudge_interval"] == 3
    assert cfg["memory"]["provider"] == ""
    assert cfg["skills"]["creation_nudge_interval"] == 3
