"""Cache tests for ``api.profiles.get_profile_runtime_env`` (plan task 1.3).

Cached per profile home on (config.yaml mtime+size, .env mtime+size) — a
second call with unchanged files must not re-read either file, and a
mtime/size change to either file must produce fresh values.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

import api.profiles as profiles  # noqa: E402


def _reset_cache():
    profiles._RUNTIME_ENV_CACHE.clear()


def test_cache_hit_skips_reread(tmp_path, monkeypatch):
    _reset_cache()
    home = tmp_path
    (home / "config.yaml").write_text("terminal:\n  backend: docker\n", encoding="utf-8")
    (home / ".env").write_text("FOO=bar\n", encoding="utf-8")

    read_calls = {"count": 0}
    real_read_text = Path.read_text

    def _counting_read_text(self, *a, **k):
        if self.name in ("config.yaml", ".env"):
            read_calls["count"] += 1
        return real_read_text(self, *a, **k)

    monkeypatch.setattr(Path, "read_text", _counting_read_text)

    env1 = profiles.get_profile_runtime_env(home)
    assert env1.get("FOO") == "bar"
    calls_after_first = read_calls["count"]
    assert calls_after_first >= 1

    env2 = profiles.get_profile_runtime_env(home)
    assert env2 == env1
    assert read_calls["count"] == calls_after_first, "second call must be a cache hit (no re-read)"


def test_cache_invalidates_on_env_change(tmp_path):
    _reset_cache()
    home = tmp_path
    (home / ".env").write_text("FOO=bar\n", encoding="utf-8")

    env1 = profiles.get_profile_runtime_env(home)
    assert env1.get("FOO") == "bar"

    # Force a distinguishable (mtime, size) — write a longer value.
    (home / ".env").write_text("FOO=baz-changed\n", encoding="utf-8")

    env2 = profiles.get_profile_runtime_env(home)
    assert env2.get("FOO") == "baz-changed"


def test_cache_invalidates_on_config_change(tmp_path):
    _reset_cache()
    home = tmp_path
    (home / "config.yaml").write_text("terminal:\n  backend: local\n", encoding="utf-8")

    env1 = profiles.get_profile_runtime_env(home)
    assert env1.get("TERMINAL_ENV") == "local"

    (home / "config.yaml").write_text("terminal:\n  backend: docker\n", encoding="utf-8")

    env2 = profiles.get_profile_runtime_env(home)
    assert env2.get("TERMINAL_ENV") == "docker"


def test_separate_homes_cached_independently(tmp_path):
    _reset_cache()
    home_a = tmp_path / "a"
    home_b = tmp_path / "b"
    home_a.mkdir()
    home_b.mkdir()
    (home_a / ".env").write_text("FOO=a\n", encoding="utf-8")
    (home_b / ".env").write_text("FOO=b\n", encoding="utf-8")

    assert profiles.get_profile_runtime_env(home_a)["FOO"] == "a"
    assert profiles.get_profile_runtime_env(home_b)["FOO"] == "b"
