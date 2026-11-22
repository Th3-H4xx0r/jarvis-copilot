"""Tests for skills/smart-home/jarvis-meta-glasses — the Meta glasses SKILL.md, SDK and CLI."""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / "skills" / "smart-home" / "jarvis-meta-glasses"
SKILL_MD = SKILL_DIR / "SKILL.md"
SCRIPT_PATH = SKILL_DIR / "scripts" / "meta_glasses.py"
DEVICE_SWIFT = REPO_ROOT / "ios_app" / "JarvisCopilot" / "MetaGlasses" / "MetaGlassesDevice.swift"

PHONE = "0123456789abcdef0123456789abcdef"  # pairing ids are uuid4().hex
PHONE_NAME = "JarvisCopilot (iPhone)"


def load_module():
    spec = importlib.util.spec_from_file_location("jarvis_meta_glasses_skill", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def skill(device_id, name):
    return {"device_id": device_id, "device_name": PHONE_NAME, "name": name,
            "description": "", "input_schema": {"type": "object", "properties": {}}}


class FakeTransport:
    """Stands in for devices._http: records every request and answers from canned data."""

    def __init__(self, replies=None):
        self.skills = [skill(PHONE, "wearables_list"), skill(PHONE, "meta_glasses_status"),
                       skill(PHONE, "meta_glasses_photo")]
        self.replies = replies or {}
        self.calls = []

    def __call__(self, method, path, body=None, timeout=30.0):
        self.calls.append({"method": method, "path": path, "body": body, "timeout": timeout})
        if (method, path) == ("GET", "/api/devices/skills"):
            return 200, {"skills": self.skills}
        if (method, path) == ("GET", "/api/devices"):
            return 200, {"devices": []}
        if (method, path) == ("POST", "/api/devices/skills/invoke"):
            if body["skill"] in self.replies:
                return self.replies[body["skill"]]
            return 200, {"ok": True, "result": {"skill": body["skill"], "args": body["args"]}}
        return 404, {"error": "not found"}

    @property
    def invokes(self):
        return [c["body"] for c in self.calls if c["path"] == "/api/devices/skills/invoke"]


@pytest.fixture
def mod():
    return load_module()


def test_description_is_short_and_ends_with_a_period():
    text = SKILL_MD.read_text()
    match = re.search(r"^description: (.*)$", text, re.MULTILINE)
    assert match and len(match.group(1)) <= 60 and match.group(1).endswith(".")


def test_skill_md_uses_the_modern_section_order():
    text = SKILL_MD.read_text()
    order = ["# Meta Glasses Skill", "## When to Use", "## Prerequisites", "## How to Run",
             "## Quick Reference", "## Procedure", "## Pitfalls", "## Verification"]
    positions = [text.index(heading) for heading in order]
    assert positions == sorted(positions)


def test_every_tool_the_glasses_advertise_is_documented(mod):
    """The skill and the SDK cover exactly the catalogue the iOS device advertises."""
    swift = DEVICE_SWIFT.read_text()
    advertised = set(re.findall(r'name: "(meta_glasses_[a-z_]+)"', swift))
    assert advertised, "no meta_glasses_* capabilities found in MetaGlassesDevice.swift"
    text = SKILL_MD.read_text()
    for name in advertised:
        assert f"`{name}`" in text, f"{name} missing from SKILL.md"
    assert set(mod.SKILLS) == advertised


def test_photo_confirms_the_shutter_and_passes_the_question(mod):
    transport = FakeTransport()
    glasses = mod.MetaGlasses(transport=transport)
    glasses.photo(question="What am I looking at?")
    body = transport.invokes[-1]
    assert body["device_id"] == PHONE
    assert body["skill"] == "meta_glasses_photo"
    assert body["args"] == {"question": "What am I looking at?", "confirm": True}


def test_video_waits_longer_than_the_clip(mod):
    transport = FakeTransport()
    mod.MetaGlasses(transport=transport, timeout=10).video(seconds=120)
    body = transport.invokes[-1]
    assert body["args"] == {"seconds": 120, "confirm": True}
    assert body["timeout"] >= 150


def test_local_validation_mirrors_the_glasses_limits(mod):
    glasses = mod.MetaGlasses(transport=FakeTransport())
    with pytest.raises(mod.MetaGlassesError):
        glasses.video(seconds=240)
    with pytest.raises(mod.MetaGlassesError):
        glasses.settings(clip_length_seconds=90)
    with pytest.raises(mod.MetaGlassesError):
        glasses.settings(video_mode="4k60")
    with pytest.raises(mod.MetaGlassesError):
        glasses.volume(150)
    with pytest.raises(mod.MetaGlassesError):
        glasses.media("delete")


def test_a_glasses_refusal_surfaces_as_an_error(mod):
    transport = FakeTransport(replies={
        "meta_glasses_photo": (200, {"ok": False, "error": "The capture LED is covered — the camera stays off until it's uncovered"}),
    })
    with pytest.raises(mod.MetaGlassesError, match="capture LED is covered"):
        mod.MetaGlasses(transport=transport).photo()


def test_no_glasses_means_a_clear_error(mod):
    transport = FakeTransport()
    transport.skills = [skill(PHONE, "wearables_list")]
    with pytest.raises(mod.MetaGlassesError, match="meta_glasses_status"):
        mod.MetaGlasses(transport=transport).status()


def test_cli_prints_json_and_hides_image_bytes(mod, capsys, monkeypatch):
    transport = FakeTransport(replies={
        "meta_glasses_media": (200, {"ok": True, "result": {"mime": "image/jpeg", "base64": "QUJD" * 100}}),
    })
    monkeypatch.setattr(mod, "load_devices_module", lambda: type("M", (), {"_http": staticmethod(transport)}))
    assert mod.main(["media", "latest-photo"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["mime"] == "image/jpeg"
    assert out["base64"].startswith("<") and "base64 chars" in out["base64"]
    assert transport.invokes[-1]["args"] == {"action": "latest_photo"}
