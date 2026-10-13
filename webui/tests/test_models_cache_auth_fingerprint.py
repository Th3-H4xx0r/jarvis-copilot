"""The model catalog must not rebuild because auth.json's bookkeeping changed.

auth.json is rewritten on every request (updated_at, credential-pool usage), and
the /api/models cache keyed on its mtime, so every chat start rebuilt the whole
catalog (~6.5 s on the server before the agent even started)."""
import json

from api import config


def _write(path, data):
    path.write_text(json.dumps(data))


def test_bookkeeping_changes_keep_the_fingerprint(tmp_path):
    p = tmp_path / "auth.json"
    base = {"version": 1, "updated_at": "2026-10-13T05:00:00Z", "providers": {"spotify": {"access_token": "a"}},
            "credential_pool": {"anthropic-api": [{"key": "k1", "last_used": 1}], "openrouter": []}}
    _write(p, base)
    a = config._auth_store_fingerprint(p)
    base["updated_at"] = "2026-10-13T05:01:00Z"
    base["credential_pool"]["anthropic-api"][0]["last_used"] = 2
    base["providers"]["spotify"]["access_token"] = "b"  # a refreshed token
    _write(p, base)
    assert config._auth_store_fingerprint(p) == a


def test_adding_a_provider_changes_the_fingerprint(tmp_path):
    p = tmp_path / "auth.json"
    data = {"credential_pool": {"anthropic-api": [{"key": "k1"}]}}
    _write(p, data)
    a = config._auth_store_fingerprint(p)
    data["credential_pool"]["celeris"] = [{"key": "c1"}]
    _write(p, data)
    assert config._auth_store_fingerprint(p) != a


def test_unreadable_file_falls_back(tmp_path):
    p = tmp_path / "auth.json"
    p.write_text("{not json")
    assert config._auth_store_fingerprint(p) is not None
