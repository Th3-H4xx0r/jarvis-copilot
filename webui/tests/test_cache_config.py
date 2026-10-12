"""'Keep prompts cached' over HTTP: the web and the phone set the generic
prompt-cache retention every provider adapter maps to what it offers."""
import io
import json
from types import SimpleNamespace
from urllib.parse import urlparse

import pytest
import yaml

from api import cache_config
from api import config as api_config


class _Handler:
    def __init__(self):
        self.wfile = io.BytesIO()
        self.headers = {}
        self.status = None

    def send_response(self, status):
        self.status = status

    def send_header(self, key, value):
        pass

    def end_headers(self):
        pass

    def payload(self):
        return json.loads(self.wfile.getvalue().decode("utf-8"))


@pytest.fixture
def env(tmp_path, monkeypatch):
    cfg = tmp_path / "config.yaml"
    cfg.write_text(yaml.safe_dump({"model": {"default": "m"}, "prompt_caching": {"cache_ttl": "5m"}}))
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(cfg))
    api_config.reload_config()
    yield {"cfg": cfg}
    api_config.reload_config()


def _get():
    h = _Handler()
    assert cache_config.handle_cache_get(h, urlparse("/api/cache/config"))
    return h


def _put(body):
    h = _Handler()
    assert cache_config.handle_cache_put(h, urlparse("/api/cache/config"), body)
    return h


def test_default_is_long(env):
    out = _get().payload()
    assert out["config"]["retention"] == "long"
    assert out["defaults"]["retention"] == "long"
    assert set(out["options"]) == {"standard", "long"}


def test_put_persists_and_get_reflects_it(env):
    assert _put({"retention": "standard"}).payload()["config"]["retention"] == "standard"
    stored = yaml.safe_load(env["cfg"].read_text())
    assert stored["prompt_caching"]["retention"] == "standard"
    assert stored["prompt_caching"]["cache_ttl"] == "5m"  # the rest of the section is kept
    assert _get().payload()["config"]["retention"] == "standard"


def test_invalid_value_is_rejected(env):
    h = _put({"retention": "forever"})
    assert h.status == 400
    assert "retention" not in (yaml.safe_load(env["cfg"].read_text()).get("prompt_caching") or {})


def test_other_paths_are_not_handled():
    assert not cache_config.handle_cache_get(_Handler(), urlparse("/api/cache/other"))


def test_a_save_reaches_agents_held_for_this_profile(env, monkeypatch):
    held = SimpleNamespace(_webui_profile_home=str(env["cfg"].parent), _cache_retention="long", _cache_ttl="1h")
    other = SimpleNamespace(_webui_profile_home="/elsewhere", _cache_retention="long", _cache_ttl="1h")
    monkeypatch.setattr(api_config, "SESSION_AGENT_CACHE", {"a": (held, "sig"), "b": (other, "sig")})
    _put({"retention": "standard"})
    assert (held._cache_retention, held._cache_ttl) == ("standard", "5m")
    assert other._cache_retention == "long"
