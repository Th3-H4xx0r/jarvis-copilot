"""Cache tests for ``jarviscopilot_cli.env_loader.load_hermes_dotenv`` (plan 1.3).

Cached per (hermes_home, project_env) on each file's (mtime, size): a repeat
call with unchanged files is a cache hit (no re-parse), and env vars are
still re-applied to os.environ whenever a file changes.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from jarviscopilot_cli import env_loader  # noqa: E402


def _reset_cache():
    env_loader._DOTENV_CACHE.clear()


def test_cache_hit_returns_same_paths_without_reparsing(tmp_path, monkeypatch):
    _reset_cache()
    home = tmp_path
    (home / ".env").write_text("JC_TEST_RUNTIME_ENV_CACHE=one\n", encoding="utf-8")
    monkeypatch.delenv("JC_TEST_RUNTIME_ENV_CACHE", raising=False)

    calls = {"count": 0}
    real_load_dotenv = env_loader._load_dotenv_with_fallback

    def _counting_load(*a, **k):
        calls["count"] += 1
        return real_load_dotenv(*a, **k)

    monkeypatch.setattr(env_loader, "_load_dotenv_with_fallback", _counting_load)

    loaded1 = env_loader.load_hermes_dotenv(hermes_home=home)
    assert os.environ.get("JC_TEST_RUNTIME_ENV_CACHE") == "one"
    assert calls["count"] == 1

    loaded2 = env_loader.load_hermes_dotenv(hermes_home=home)
    assert loaded2 == loaded1
    assert calls["count"] == 1, "second call with unchanged .env must be a cache hit"

    monkeypatch.delenv("JC_TEST_RUNTIME_ENV_CACHE", raising=False)


def test_cache_invalidates_and_reapplies_on_change(tmp_path, monkeypatch):
    _reset_cache()
    home = tmp_path
    (home / ".env").write_text("JC_TEST_RUNTIME_ENV_CACHE=one\n", encoding="utf-8")
    monkeypatch.delenv("JC_TEST_RUNTIME_ENV_CACHE", raising=False)

    env_loader.load_hermes_dotenv(hermes_home=home)
    assert os.environ.get("JC_TEST_RUNTIME_ENV_CACHE") == "one"

    (home / ".env").write_text("JC_TEST_RUNTIME_ENV_CACHE=two-changed\n", encoding="utf-8")
    env_loader.load_hermes_dotenv(hermes_home=home)
    assert os.environ.get("JC_TEST_RUNTIME_ENV_CACHE") == "two-changed"

    monkeypatch.delenv("JC_TEST_RUNTIME_ENV_CACHE", raising=False)
