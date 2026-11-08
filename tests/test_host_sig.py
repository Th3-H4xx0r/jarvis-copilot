"""The host carve-out signature: one protocol (jarviscopilot_host_sig), every signer matches it.

The skill scripts keep their own copy of the signer: an installed skill lives under
~/.jarviscopilot/skills, where the repo is not importable. These tests tie each copy
to the webui's verifier.
"""
import importlib.util
import urllib.request
from pathlib import Path

import pytest

import jarviscopilot_host_sig as host_sig

REPO = Path(__file__).resolve().parents[1]
KEY = b"k" * 32


@pytest.fixture
def state_dir(tmp_path, monkeypatch):
    (tmp_path / ".signing_key").write_bytes(KEY)
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path))
    return tmp_path


def _load(rel):
    spec = importlib.util.spec_from_file_location(Path(rel).stem + "_under_test", REPO / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_a_signature_verifies_only_for_its_method_path_key_and_time():
    value = host_sig.signature(KEY, "post", "/api/island/designs")
    assert host_sig.verify(KEY, "POST", "/api/island/designs", value)
    assert not host_sig.verify(KEY, "GET", "/api/island/designs", value)
    assert not host_sig.verify(KEY, "POST", "/api/island/other", value)
    assert not host_sig.verify(b"z" * 32, "POST", "/api/island/designs", value)
    stamp = int(value.split(".")[0])
    assert not host_sig.verify(KEY, "POST", "/api/island/designs", value,
                               now=stamp + host_sig.MAX_SKEW_SECONDS + 1)
    assert not host_sig.verify(KEY, "POST", "/x", "garbage")


def test_read_key_comes_from_the_webui_state_dir(state_dir):
    assert host_sig.read_key() == KEY


@pytest.mark.parametrize("script", ["skills/jarviscopilot/devices/scripts/devices.py",
                                    "skills/jarviscopilot/dynamic-island/scripts/island.py"])
def test_standalone_skill_signers_match_the_verifier(state_dir, script):
    mod = _load(script)
    value = mod._host_signature("POST", "/api/devices/notify")
    assert host_sig.verify(KEY, "POST", "/api/devices/notify", value)


def test_the_health_skill_signs_what_the_verifier_checks(state_dir, monkeypatch):
    mod = _load("skills/jarviscopilot/health/scripts/health.py")
    monkeypatch.setattr(mod, "_STATE", state_dir, raising=False)
    sent = {}

    def capture(req, *a, **k):
        sent["sig"] = req.get_header(host_sig.HEADER.capitalize()) or req.headers.get(host_sig.HEADER)
        raise OSError("not sending")
    monkeypatch.setattr(urllib.request, "urlopen", capture)
    path = f"{mod.BASE}/now"
    try:
        mod.request("GET", path)
    except Exception:
        pass
    assert sent.get("sig") and host_sig.verify(KEY, "GET", path, sent["sig"])


def test_the_agent_tools_sign_with_the_shared_protocol(state_dir):
    from tools import chrome_device_tool
    chrome_device_tool._invalidate_signing_key_cache()
    value = chrome_device_tool._host_signature("GET", "/api/devices")
    assert host_sig.verify(KEY, "GET", "/api/devices", value)


def test_the_health_bridge_signs_with_the_shared_protocol(state_dir):
    from jarvis_health import bridge
    bridge._signing_key["key"] = None
    headers = bridge._headers("POST", "/api/x", b"{}")
    assert host_sig.verify(KEY, "POST", "/api/x", headers[host_sig.HEADER])
