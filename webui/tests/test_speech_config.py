"""Speech engine settings over HTTP: what the phone, the web and the Mac may change."""
import io
import json
from urllib.parse import urlparse

import pytest
import yaml

from api import config as api_config
from api import speech_config


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

    def body(self):
        return self.wfile.getvalue().decode("utf-8")

    def payload(self):
        return json.loads(self.body())


@pytest.fixture
def env(tmp_path, monkeypatch):
    cfg = tmp_path / "config.yaml"
    cfg.write_text(yaml.safe_dump({"model": {"default": "m"},
                                   "speech": {"soniox": {"custom_words": ["Jarvis"]}}}))
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(cfg))
    monkeypatch.setenv("HERMES_HOME", str(home))
    # setenv first so the key the endpoint writes into os.environ is undone afterwards.
    monkeypatch.setenv("SONIOX_API_KEY", "placeholder")
    monkeypatch.delenv("SONIOX_API_KEY")
    api_config.reload_config()
    yield {"cfg": cfg, "home": home}
    api_config.reload_config()


def _get():
    handler = _Handler()
    assert speech_config.handle_speech_get(handler, urlparse("/api/speech/config"))
    return handler


def _post(path, body):
    handler = _Handler()
    assert speech_config.handle_speech_post(handler, urlparse(path), body)
    return handler


def _put(body):
    handler = _Handler()
    assert speech_config.handle_speech_put(handler, urlparse("/api/speech/config"), body)
    return handler


def test_get_returns_defaults_engines_languages_and_key_status(env):
    handler = _get()
    assert handler.status == 200
    got = handler.payload()
    assert got["config"]["surfaces"] == {"voice": "local", "live": "edge", "upload": "local"}
    assert got["config"]["soniox"]["custom_words"] == ["Jarvis"]
    assert {"local", "soniox"} <= {e["name"] for e in got["engines"]}
    assert any(row["code"] == "en" for row in got["languages"])
    assert got["soniox_key"] == {"set": False, "hint": ""}
    assert set(got["usage"]) == {"today_s", "month_s", "est_usd"}


def test_put_merges_nested_and_reports_ignored(env):
    handler = _put({"surfaces": {"upload": "soniox"}, "bogus": 1})
    assert handler.status == 200
    got = handler.payload()
    assert got["ignored_keys"] == ["bogus"]
    assert got["config"]["surfaces"] == {"voice": "local", "live": "edge", "upload": "soniox"}
    stored = yaml.safe_load(env["cfg"].read_text())
    assert stored["speech"]["surfaces"] == {"upload": "soniox"}
    assert stored["speech"]["soniox"]["custom_words"] == ["Jarvis"]
    assert stored["model"] == {"default": "m"}


def test_post_is_accepted_for_config_like_put(env):
    handler = _post("/api/speech/config", {"soniox": {"speaker_labels": False}})
    assert handler.status == 200 and handler.payload()["config"]["soniox"]["speaker_labels"] is False


def test_put_then_get_shows_the_new_value(env):
    _put({"soniox": {"language_hints": ["en", "es"]}})
    assert _get().payload()["config"]["soniox"]["language_hints"] == ["en", "es"]


def test_put_rejects_bad_values_with_400(env):
    assert _put({"soniox": {"endpoint_latency_level": 7}}).status == 400
    assert _put({"surfaces": {"live": "local"}}).status == 400
    assert _put({"soniox": {"api_key": "sk-sneaky-1234"}}).status == 400
    stored = yaml.safe_load(env["cfg"].read_text())
    assert "surfaces" not in stored["speech"]


def test_soniox_key_is_trimmed_and_never_echoed(env):
    handler = _post("/api/speech/soniox-key", {"api_key": "  sk-abcdef1a2b \n"})
    assert handler.status == 200
    assert handler.payload()["soniox_key"] == {"set": True, "hint": "••••1a2b"}
    assert "sk-abcdef1a2b" not in handler.body()
    assert "SONIOX_API_KEY=sk-abcdef1a2b" in (env["home"] / ".env").read_text().splitlines()
    later = _get()
    assert "sk-abcdef1a2b" not in later.body()
    assert later.payload()["soniox_key"]["set"] is True


def test_soniox_key_empty_removes(env):
    _post("/api/speech/soniox-key", {"api_key": "sk-abcdef1a2b"})
    handler = _post("/api/speech/soniox-key", {"api_key": ""})
    assert handler.status == 200 and handler.payload()["soniox_key"] == {"set": False, "hint": ""}
    assert "SONIOX_API_KEY" not in (env["home"] / ".env").read_text()


def test_soniox_key_rejects_junk(env):
    assert _post("/api/speech/soniox-key", {"api_key": "short"}).status == 400
    assert _post("/api/speech/soniox-key", {"api_key": "sk-abc\ndef-1234"}).status == 400


def test_test_endpoint_reports_engine_check(env, monkeypatch):
    from jarvis_speech.engines import soniox
    monkeypatch.setattr(soniox.SonioxEngine, "check", lambda self: (False, "unauthenticated: bad key"))
    handler = _post("/api/speech/test", {})
    assert handler.payload() == {"ok": False, "message": "unauthenticated: bad key"}


def test_unknown_paths_are_not_handled(env):
    assert speech_config.handle_speech_get(_Handler(), urlparse("/api/speech/nope")) is False
    assert speech_config.handle_speech_post(_Handler(), urlparse("/api/speech/nope"), {}) is False
