"""Settings → Web & browser over HTTP (web + phone): the extraction model (a model or
a harness), the browser engine and the stealth fallback."""
import io
import json
from urllib.parse import urlparse

import pytest
import yaml

from api import config as api_config
from api import web_config


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
    cfg.write_text(yaml.safe_dump({"web": {"backend": "ddgs"}, "browser": {"engine": "auto", "command_timeout": 30}}))
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(cfg))
    monkeypatch.setattr(web_config, "_lightpanda_installed", lambda: True)
    api_config.reload_config()
    yield cfg
    api_config.reload_config()


def _get():
    h = _Handler()
    assert web_config.handle_web_config_get(h, urlparse("/api/web/config"))
    return h


def _put(body):
    h = _Handler()
    assert web_config.handle_web_config_put(h, urlparse("/api/web/config"), body)
    return h


def test_reads_the_defaults(env):
    body = _get().payload()
    assert body["config"] == {"extract_model": "", "engine": "chrome", "stealth_fallback": True}
    assert body["lightpanda_installed"] is True and "lightpanda" in body["engines"]


def test_saves_a_model_a_harness_and_the_engine(env):
    assert _put({"extract_model": "@celeris:celeris-1", "engine": "lightpanda"}).payload()["ok"]
    stored = yaml.safe_load(env.read_text())
    assert stored["web"]["extract_model"] == "@celeris:celeris-1" and stored["web"]["backend"] == "ddgs"
    assert stored["browser"]["engine"] == "lightpanda" and stored["browser"]["command_timeout"] == 30
    assert _put({"extract_model": "harness:extract-fast"}).payload()["config"]["extract_model"] == "harness:extract-fast"
    assert _put({"stealth_fallback": False}).payload()["config"]["stealth_fallback"] is False


@pytest.mark.parametrize("body", [
    {"extract_model": "not a model ref with spaces"},
    {"extract_model": 7},
    {"engine": "netscape"},
    {"stealth_fallback": "yes"},
])
def test_refuses_bad_values(env, body):
    h = _put(body)
    assert h.status == 400


def test_a_new_engine_reaches_the_running_browser_tools(env, monkeypatch):
    import tools.browser_tool as bt
    bt._browser_engine_resolved, bt._cached_browser_engine = True, "auto"
    _put({"engine": "lightpanda"})
    assert bt._browser_engine_resolved is False          # re-read on the next browser call
