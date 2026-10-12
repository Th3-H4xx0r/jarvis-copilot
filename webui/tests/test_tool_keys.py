"""Settings → Providers → tool keys (Pranav, 2026-10-11): "Add the input field in
the web UI so I can do it there instead of using .env configs".

The Parallel key is saved to the active profile's .env from the web UI; saving it
makes Parallel the web search backend, removing it hands search back to the free
engine. The key itself is never sent back to the browser."""
import io
import json
from urllib.parse import urlparse

import pytest
import yaml

from api import config as api_config
from api import profiles
from api import tool_keys


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
def home(tmp_path, monkeypatch):
    cfg = tmp_path / "config.yaml"
    cfg.write_text(yaml.safe_dump({"web": {"backend": "ddgs", "search_backend": ""}}))
    (tmp_path / ".env").write_text("# keys\nOPENROUTER_API_KEY=sk-or-keep-me\n")
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(cfg))
    monkeypatch.setattr(profiles, "get_active_hermes_home", lambda: tmp_path)
    monkeypatch.delenv("PARALLEL_API_KEY", raising=False)
    api_config.reload_config()
    yield tmp_path
    api_config.reload_config()


def _get():
    h = _Handler()
    assert tool_keys.handle_tool_keys_get(h, urlparse("/api/tool-keys"))
    return h


def _post(body):
    h = _Handler()
    assert tool_keys.handle_tool_keys_post(h, urlparse("/api/tool-keys"), body)
    return h


def _parallel(payload):
    return next(t for t in payload["tools"] if t["id"] == "parallel")


def test_lists_parallel_without_a_key(home):
    p = _parallel(_get().payload())
    assert p["display_name"] == "Parallel" and p["has_key"] is False and p["in_use"] is False
    assert p["purpose"] and p["url"].startswith("https://")


def test_saving_the_key_writes_env_and_switches_search_to_parallel(home):
    out = _post({"tool": "parallel", "api_key": "  par-live-key-12345  "}).payload()
    assert out["ok"] is True and _parallel(out)["has_key"] is True and _parallel(out)["in_use"] is True
    env = (home / ".env").read_text()
    assert "PARALLEL_API_KEY=par-live-key-12345" in env and "OPENROUTER_API_KEY=sk-or-keep-me" in env
    web = yaml.safe_load((home / "config.yaml").read_text())["web"]
    assert web["search_backend"] == "parallel" and web["backend"] == "ddgs"


def test_saving_the_key_keeps_page_reads_on_the_free_local_reader(home):
    """With web.backend ddgs (search-only) and no extract_backend, the extract lookup
    walks a paid-first list — so a saved Parallel key would take over page reads."""
    _post({"tool": "parallel", "api_key": "par-live-key-12345"})
    assert yaml.safe_load((home / "config.yaml").read_text())["web"]["extract_backend"] == "local"
    _post({"tool": "parallel", "api_key": None})
    assert yaml.safe_load((home / "config.yaml").read_text())["web"]["extract_backend"] == "local"


def test_saving_the_key_leaves_a_chosen_page_reader_alone(home):
    cfg = home / "config.yaml"
    cfg.write_text(yaml.safe_dump({"web": {"backend": "ddgs", "extract_backend": "firecrawl"}}))
    _post({"tool": "parallel", "api_key": "par-live-key-12345"})
    assert yaml.safe_load(cfg.read_text())["web"]["extract_backend"] == "firecrawl"


def test_the_key_never_comes_back(home):
    _post({"tool": "parallel", "api_key": "par-live-key-12345"})
    assert "par-live-key-12345" not in json.dumps(_get().payload())


def test_removing_the_key_hands_search_back(home):
    _post({"tool": "parallel", "api_key": "par-live-key-12345"})
    out = _post({"tool": "parallel", "api_key": ""}).payload()
    assert out["ok"] is True and _parallel(out)["has_key"] is False and _parallel(out)["in_use"] is False
    assert "PARALLEL_API_KEY" not in (home / ".env").read_text()
    assert yaml.safe_load((home / "config.yaml").read_text())["web"]["search_backend"] == ""


def test_removing_leaves_another_chosen_backend_alone(home):
    cfg = home / "config.yaml"
    cfg.write_text(yaml.safe_dump({"web": {"backend": "ddgs", "search_backend": "tavily"}}))
    _post({"tool": "parallel", "api_key": None})
    assert yaml.safe_load(cfg.read_text())["web"]["search_backend"] == "tavily"


@pytest.mark.parametrize("body", [
    {"tool": "nope", "api_key": "par-live-key-12345"},
    {"tool": "parallel", "api_key": "short"},
    {"tool": "parallel", "api_key": "has\nnewline-12345"},
    {"tool": "parallel", "api_key": "has space-12345"},
    {"tool": "parallel", "api_key": 12345678},
    {"api_key": "par-live-key-12345"},
])
def test_refuses_bad_input(home, body):
    assert _post(body).status == 400
    assert "PARALLEL_API_KEY" not in (home / ".env").read_text()
