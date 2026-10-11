"""Auto-compact settings over HTTP: the one place the web and the phone change them."""
import io
import json
from pathlib import Path
from urllib.parse import urlparse

import pytest
import yaml

from api import compression_config
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
    cfg.write_text(yaml.safe_dump({
        "model": {"default": "claude-sonnet-5-5", "provider": "anthropic-api"},
        "compression": {"target_ratio": 0.2, "protect_last_n": 20},
    }))
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(cfg))
    windows = {"claude-sonnet-5-5": 1_000_000, "gemma4:31b": 262_144}
    monkeypatch.setattr(compression_config, "_context_length_for",
                        lambda model, provider: windows.get(model, 0))
    api_config.reload_config()
    yield {"cfg": cfg}
    api_config.reload_config()


def _get(query=""):
    handler = _Handler()
    assert compression_config.handle_compression_get(handler, urlparse("/api/compression/config" + query))
    return handler


def _put(body):
    handler = _Handler()
    assert compression_config.handle_compression_put(handler, urlparse("/api/compression/config"), body)
    return handler


def _stored(env):
    return yaml.safe_load(env["cfg"].read_text())["compression"]


def test_get_defaults_and_preview_for_the_configured_model(env):
    handler = _get()
    assert handler.status == 200
    got = handler.payload()
    assert got["config"] == {"enabled": True, "threshold_percent": 50, "max_context_tokens": 0}
    assert got["limits"]["min_percent"] == 10 and got["limits"]["max_percent"] == 95
    assert got["preview"]["model"] == "claude-sonnet-5-5"
    assert got["preview"]["context_length"] == 1_000_000
    assert got["preview"]["threshold_tokens"] == 500_000


def test_preview_follows_the_requested_model(env):
    got = _get("?model=gemma4%3A31b&provider=ollama-cloud").payload()
    assert got["preview"]["model"] == "gemma4:31b"
    assert got["preview"]["provider"] == "ollama-cloud"
    assert got["preview"]["threshold_tokens"] == int(262_144 * 0.50)


def test_unknown_window_still_previews_a_number(env):
    got = _get("?model=mystery-model").payload()
    assert got["preview"]["context_length"] == 0
    assert got["preview"]["threshold_tokens"] > 64_000


def test_legacy_config_is_read_back(env):
    env["cfg"].write_text(yaml.safe_dump({
        "model": {"default": "claude-sonnet-5-5"},
        "compression": {"threshold": 0.75, "max_context_tokens": 64000},
    }))
    api_config.reload_config()
    got = _get().payload()
    assert got["config"]["threshold_percent"] == 75
    assert got["config"]["max_context_tokens"] == 64000
    assert got["preview"]["threshold_tokens"] == 64000


def test_put_saves_ratio_and_keeps_siblings(env):
    handler = _put({"threshold_percent": 80, "max_context_tokens": 200_000, "enabled": False})
    assert handler.status == 200
    got = handler.payload()
    assert got["config"] == {"enabled": False, "threshold_percent": 80, "max_context_tokens": 200_000}
    assert got["preview"]["threshold_tokens"] == 200_000
    stored = _stored(env)
    assert stored["threshold"] == pytest.approx(0.80)
    assert stored["max_context_tokens"] == 200_000
    assert stored["enabled"] is False
    assert stored["target_ratio"] == 0.2 and stored["protect_last_n"] == 20


def test_put_zero_cap_means_percentage_only(env):
    _put({"max_context_tokens": 200_000})
    got = _put({"max_context_tokens": 0}).payload()
    assert got["config"]["max_context_tokens"] == 0
    assert got["preview"]["threshold_tokens"] == 500_000


def test_post_works_like_put(env):
    handler = _Handler()
    assert compression_config.handle_compression_post(
        handler, urlparse("/api/compression/config"), {"threshold_percent": 60})
    assert handler.status == 200
    assert _stored(env)["threshold"] == pytest.approx(0.60)


@pytest.mark.parametrize("body", [
    {"threshold_percent": 5},
    {"threshold_percent": 96},
    {"threshold_percent": "abc"},
    {"threshold_percent": True},
    {"max_context_tokens": 1000},
    {"max_context_tokens": -1},
    {"max_context_tokens": "lots"},
    {"max_context_tokens": float("inf")},
    {"max_context_tokens": 20000.5},
    {"enabled": "yes"},
])
def test_put_rejects_out_of_range(env, body):
    handler = _put(body)
    assert handler.status == 400
    assert "threshold" not in (_stored(env) or {})


def test_put_reports_ignored_keys(env):
    got = _put({"threshold_percent": 70, "bogus": 1}).payload()
    assert got["ignored_keys"] == ["bogus"]


class _Agent:
    def __init__(self, compressor, home):
        self.context_compressor = compressor
        self.compression_enabled = True
        self._compression_feasibility_checked = True
        self._webui_profile_home = home


def test_put_reaches_live_agents_of_this_profile_only(env, monkeypatch):
    from unittest.mock import patch
    from agent.context_compressor import ContextCompressor

    def make(ctx):
        with patch("agent.context_compressor.get_model_context_length", return_value=ctx):
            return ContextCompressor(model="m", quiet_mode=True)

    home = str(Path(env["cfg"]).parent)
    mine_big = _Agent(make(1_000_000), home)
    mine_small = _Agent(make(200_000), home)
    other = _Agent(make(1_000_000), "/somewhere/else")
    monkeypatch.setattr(api_config, "SESSION_AGENT_CACHE", {
        "s1": (mine_big, "sig"), "s1::node": (mine_small, "sig"), "s2": (other, "sig"),
    })

    _put({"threshold_percent": 80, "enabled": False})

    assert mine_big.context_compressor.threshold_tokens == 800_000
    assert mine_small.context_compressor.threshold_tokens == 160_000
    assert mine_big.compression_enabled is False
    assert mine_big._compression_feasibility_checked is False
    assert other.context_compressor.threshold_tokens == 500_000
    assert other.compression_enabled is True
