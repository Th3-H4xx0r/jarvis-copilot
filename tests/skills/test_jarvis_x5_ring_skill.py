"""Tests for skills/smart-home/jarvis-x5-ring — the X5 smart ring SKILL.md, SDK and CLI."""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / "skills" / "smart-home" / "jarvis-x5-ring"
SKILL_MD = SKILL_DIR / "SKILL.md"
SCRIPT_PATH = SKILL_DIR / "scripts" / "x5.py"
DEVICES_PATH = REPO_ROOT / "skills" / "jarviscopilot" / "devices" / "scripts" / "devices.py"
X5_SWIFT = REPO_ROOT / "ios_app" / "JarvisCopilot" / "Ring" / "X5" / "X5Ring.swift"

PHONE = "0123456789abcdef0123456789abcdef"  # pairing ids are uuid4().hex
MAC = "fedcba9876543210fedcba9876543210"
PHONE_NAME = "JarvisCopilot (iPhone)"
MAC_NAME = "Pranav's MacBook"


def load_module():
    spec = importlib.util.spec_from_file_location("jarvis_x5_ring_skill", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def skill(device_id, name, device_name):
    """One row of GET /api/devices/skills, as webui/api/device_bridge.all_device_skills builds it."""
    return {"device_id": device_id, "device_name": device_name, "name": name,
            "description": "", "input_schema": {"type": "object", "properties": {}}}


DEFAULT_SKILLS = [
    skill(MAC, "chrome_snapshot", MAC_NAME),
    skill(PHONE, "wearables_list", PHONE_NAME),
    skill(PHONE, "ring_get_status", PHONE_NAME),
    skill(PHONE, "x5_get_status", PHONE_NAME),
    skill(PHONE, "x5_measure", PHONE_NAME),
]


class FakeTransport:
    """Stands in for devices._http: records every request and answers from canned data."""

    def __init__(self, skills=None, devices=None, replies=None):
        self.skills = DEFAULT_SKILLS if skills is None else skills
        self.devices = devices or []
        self.replies = replies or {}
        self.calls = []

    def __call__(self, method, path, body=None, timeout=30.0):
        self.calls.append({"method": method, "path": path, "body": body, "timeout": timeout})
        if (method, path) == ("GET", "/api/devices/skills"):
            return 200, {"skills": self.skills}
        if (method, path) == ("GET", "/api/devices"):
            return 200, {"devices": self.devices}
        if (method, path) == ("POST", "/api/devices/skills/invoke"):
            if body["skill"] in self.replies:
                return self.replies[body["skill"]]
            return 200, {"ok": True, "result": {"skill": body["skill"]}}
        return 404, {"error": "not found"}

    @property
    def invokes(self):
        return [c["body"] for c in self.calls if c["path"] == "/api/devices/skills/invoke"]


@pytest.fixture
def mod():
    return load_module()


@pytest.fixture
def cli(mod, monkeypatch):
    """Routes the CLI's lazily loaded devices client to a fake transport."""
    transport = FakeTransport()
    monkeypatch.setattr(mod, "load_devices_module", lambda: SimpleNamespace(_http=transport))
    return transport


def every_call(ring):
    """One call of every SDK method, with typical arguments."""
    ring.status()
    ring.day()
    ring.health_day()
    ring.history()
    ring.sync()
    ring.measure("heart_rate")
    ring.workout("status")
    ring.set_monitoring("hrv", True)
    ring.set_gesture_mode("jarvis")
    ring.set_gesture_action("tap", none=True)
    ring.find()
    ring.set_profile(age=30)
    ring.restart()
    ring.log()


# ── SKILL.md ─────────────────────────────────────────────────────────────────

def _frontmatter_field(name):
    m = re.search(rf"^{name}: (.*)$", SKILL_MD.read_text(encoding="utf-8"), re.MULTILINE)
    assert m, f"SKILL.md has no {name}"
    return m.group(1).strip()


def test_description_is_one_short_sentence():
    description = _frontmatter_field("description")
    assert len(description) <= 60, len(description)
    assert description.endswith(".")
    assert description.count(". ") == 0, "one sentence"


def test_frontmatter_names_the_skill_and_credits_the_human_first():
    assert _frontmatter_field("name") == SKILL_DIR.name
    assert _frontmatter_field("author").startswith("Pranav Krishna")


def test_body_uses_the_modern_section_order():
    text = SKILL_MD.read_text(encoding="utf-8")
    order = ["# X5 Ring Skill", "## When to Use", "## Prerequisites", "## How to Run", "## Quick Reference",
             "## Procedure", "## Pitfalls", "## Verification"]
    positions = [text.find(f"\n{heading}\n") for heading in order]
    assert all(p >= 0 for p in positions), dict(zip(order, positions))
    assert positions == sorted(positions)


def test_every_skill_the_doc_names_is_one_the_sdk_calls(mod):
    documented = set(re.findall(r"`(x5_[a-z_]+)`", SKILL_MD.read_text(encoding="utf-8")))
    transport = FakeTransport()
    every_call(mod.X5Ring(device=PHONE, transport=transport))
    assert documented == {b["skill"] for b in transport.invokes}


def test_the_doc_lists_every_gesture_the_cli_accepts(mod):
    text = SKILL_MD.read_text(encoding="utf-8")
    assert all(f"`{gesture}`" in text for gesture in mod.GESTURES)


# ── device discovery ─────────────────────────────────────────────────────────

def test_discovery_picks_the_device_offering_x5_get_status(mod):
    transport = FakeTransport(skills=[skill(MAC, "ring_get_status", MAC_NAME), *DEFAULT_SKILLS[1:]])
    ring = mod.X5Ring(transport=transport)

    ring.status()
    ring.find()

    assert ring.device_id == PHONE
    assert [c["path"] for c in transport.calls] == [
        "/api/devices/skills", "/api/devices/skills/invoke", "/api/devices/skills/invoke",
    ]
    assert {b["device_id"] for b in transport.invokes} == {PHONE}


def test_discovery_prefers_the_connected_device_when_several_offer_the_x5(mod):
    push_only = "11111111111111111111111111111111"
    skills = [skill(push_only, "x5_get_status", "Old iPhone"), *DEFAULT_SKILLS]
    devices = [
        {"id": push_only, "invokable": True, "bridge_connected": False},
        {"id": PHONE, "invokable": True, "bridge_connected": True},
    ]
    transport = FakeTransport(skills=skills, devices=devices)

    mod.X5Ring(transport=transport).status()

    assert transport.invokes[0]["device_id"] == PHONE


def test_discovery_without_an_x5_raises(mod):
    transport = FakeTransport(skills=[skill(PHONE, "ring_get_status", PHONE_NAME)])

    with pytest.raises(mod.X5Error, match="x5_get_status"):
        mod.X5Ring(transport=transport).status()
    assert transport.invokes == []


def test_explicit_device_id_skips_discovery(mod):
    transport = FakeTransport(skills=[])

    mod.X5Ring(device=PHONE.upper(), transport=transport).status()

    assert [c["path"] for c in transport.calls] == ["/api/devices/skills/invoke"]
    assert transport.invokes[0]["device_id"] == PHONE


def test_explicit_device_name_is_matched_case_insensitively(mod):
    ring = mod.X5Ring(device="iphone", transport=FakeTransport())
    ring.status()
    assert ring.device_id == PHONE

    with pytest.raises(mod.X5Error, match="no online device matching"):
        mod.X5Ring(device="pixel", transport=FakeTransport()).status()


# ── skill and argument mapping ───────────────────────────────────────────────

@pytest.mark.parametrize(
    ("call", "skill_name", "args"),
    [
        pytest.param(lambda r: r.status(), "x5_get_status", {}, id="status"),
        pytest.param(lambda r: r.day(date="2026-09-29", metrics=["sleep", "hrv"], detail=True),
                     "x5_get_day", {"date": "2026-09-29", "metrics": ["sleep", "hrv"], "detail": True},
                     id="day-detail"),
        pytest.param(lambda r: r.day(metrics="sleep, stress"), "x5_get_day", {"metrics": ["sleep", "stress"]},
                     id="day-metrics-csv"),
        pytest.param(lambda r: r.health_day("2026-09-29"), "x5_get_health_day", {"date": "2026-09-29"},
                     id="health-day"),
        pytest.param(lambda r: r.health_day(), "x5_get_health_day", {}, id="health-day-today"),
        pytest.param(lambda r: r.history(days=14), "x5_get_history", {"days": 14}, id="history"),
        pytest.param(lambda r: r.sync(days=3), "x5_sync", {"days": 3}, id="sync"),
        pytest.param(lambda r: r.workout("start", sport="walk"), "x5_workout",
                     {"action": "start", "sport": "walk"}, id="workout-start"),
        pytest.param(lambda r: r.workout("end"), "x5_workout", {"action": "end"}, id="workout-end"),
        pytest.param(lambda r: r.set_monitoring("heart_rate", True, interval_minutes=10), "x5_set_monitoring",
                     {"metric": "heart_rate", "enabled": True, "interval_minutes": 10}, id="monitoring"),
        pytest.param(lambda r: r.set_monitoring("spo2", False), "x5_set_monitoring",
                     {"metric": "spo2", "enabled": False}, id="monitoring-off"),
        pytest.param(lambda r: r.set_gesture_mode("music"), "x5_set_gesture_mode", {"mode": "music"},
                     id="gesture-mode"),
        pytest.param(lambda r: r.set_gesture_mode("jarvis", touch_awake="always"), "x5_set_gesture_mode",
                     {"mode": "jarvis", "touch_awake": "always"}, id="gesture-mode-always"),
        pytest.param(lambda r: r.set_gesture_mode("jarvis", touch_awake="5"), "x5_set_gesture_mode",
                     {"mode": "jarvis", "touch_awake": 5}, id="gesture-mode-minutes"),
        pytest.param(lambda r: r.set_gesture_action("swipe_up", prompt="What's next?"), "x5_set_gesture_action",
                     {"gesture": "swipe_up", "prompt": "What's next?"}, id="gesture-prompt"),
        pytest.param(lambda r: r.set_gesture_action("double_tap", skill="x5_measure",
                                                    arguments={"type": "heart_rate"}),
                     "x5_set_gesture_action",
                     {"gesture": "double_tap", "skill": "x5_measure", "arguments": {"type": "heart_rate"}},
                     id="gesture-skill"),
        pytest.param(lambda r: r.set_gesture_action("hold_10s", none=True), "x5_set_gesture_action",
                     {"gesture": "hold_10s", "none": True}, id="gesture-none"),
        pytest.param(lambda r: r.find(), "x5_find", {}, id="find"),
        pytest.param(lambda r: r.set_profile(sex="male", stride_cm=None, height_cm=178), "x5_set_profile",
                     {"sex": "male", "height_cm": 178}, id="profile"),
        pytest.param(lambda r: r.restart(), "x5_restart", {}, id="restart"),
        pytest.param(lambda r: r.log(limit=20), "x5_get_log", {"limit": 20}, id="log"),
    ],
)
def test_each_method_sends_its_skill_and_only_the_given_args(mod, call, skill_name, args):
    transport = FakeTransport()
    ring = mod.X5Ring(device=PHONE, transport=transport)

    assert call(ring) == {"skill": skill_name}
    assert transport.invokes == [{"device_id": PHONE, "skill": skill_name, "args": args, "timeout": 45.0}]


def test_the_sdk_only_ever_speaks_x5_skills(mod):
    transport = FakeTransport()
    every_call(mod.X5Ring(device=PHONE, transport=transport))
    assert all(b["skill"].startswith("x5_") for b in transport.invokes)


def test_measure_never_waits_less_than_the_default(mod):
    transport = FakeTransport()
    mod.X5Ring(device=PHONE, timeout=10, transport=transport).measure("spo2")
    mod.X5Ring(device=PHONE, timeout=90, transport=transport).measure("temperature")

    assert [b["args"] for b in transport.invokes] == [{"type": "spo2"}, {"type": "temperature"}]
    assert [b["timeout"] for b in transport.invokes] == [45.0, 90.0]
    assert all(c["timeout"] > b for c, b in zip(transport.calls, (45.0, 90.0)))  # HTTP outlasts the invoke


def test_a_measurement_still_running_comes_back_as_is(mod):
    transport = FakeTransport(replies={"x5_measure": (200, {"ok": True, "result": {"status": "measuring"}})})
    assert mod.X5Ring(device=PHONE, transport=transport).measure("heart_rate") == {"status": "measuring"}


def test_sdk_covers_only_skills_the_phone_advertises(mod):
    if not X5_SWIFT.exists():
        pytest.skip("X5 iOS sources not present")
    advertised = set(re.findall(r'"(x5_[a-z_]+)"', X5_SWIFT.read_text(encoding="utf-8")))
    if not advertised:
        pytest.skip("no x5_* skill names found in X5Ring.swift")
    transport = FakeTransport()
    every_call(mod.X5Ring(device=PHONE, transport=transport))
    assert {b["skill"] for b in transport.invokes} <= advertised


# ── errors and client-side guards ────────────────────────────────────────────

@pytest.mark.parametrize(
    ("reply", "text"),
    [
        pytest.param((502, {"ok": False, "error": "bad argument: gesture"}), "bad argument", id="ok-false-502"),
        pytest.param((200, {"ok": False, "error": "device did not respond before timeout"}), "did not respond",
                     id="ok-false-200"),
        pytest.param((200, {"ok": True, "result": {"ok": False, "error": "ring is busy"}}), "busy",
                     id="result-ok-false"),
        pytest.param((401, {"error": "unauthorized"}), "unauthorized", id="non-2xx"),
        pytest.param((-1, {"error": "[Errno 61] Connection refused"}), "could not reach", id="webui-down"),
        pytest.param((500, {}), "HTTP 500", id="bare-500"),
    ],
)
def test_failed_invokes_raise_x5_error(mod, reply, text):
    transport = FakeTransport(replies={"x5_workout": reply})

    with pytest.raises(mod.X5Error, match=text):
        mod.X5Ring(device=PHONE, transport=transport).workout("start")


@pytest.mark.parametrize(
    ("call", "text"),
    [
        pytest.param(lambda r: r.set_gesture_action("tap"), "exactly one", id="no-action"),
        pytest.param(lambda r: r.set_gesture_action("tap", prompt="hi", none=True), "exactly one", id="two-actions"),
        pytest.param(lambda r: r.set_gesture_action("tap", prompt="hi", arguments={"a": "b"}), "arguments",
                     id="arguments-without-skill"),
        pytest.param(lambda r: r.set_gesture_mode("jarvis", touch_awake=10), "touch_awake", id="touch-awake"),
        pytest.param(lambda r: r.workout("pause", sport="run"), "sport", id="sport-not-start"),
        pytest.param(lambda r: r.set_profile(stride=70), "stride", id="unknown-profile-field"),
        pytest.param(lambda r: r.set_profile(age=None), "at least one", id="empty-profile"),
    ],
)
def test_malformed_calls_fail_before_any_request(mod, call, text):
    transport = FakeTransport()

    with pytest.raises(mod.X5Error, match=text):
        call(mod.X5Ring(transport=transport))  # discovery would be the first request
    assert transport.calls == []


# ── CLI ──────────────────────────────────────────────────────────────────────

def test_cli_status_prints_the_result_as_json(mod, cli, capsys):
    cli.replies["x5_get_status"] = (200, {"ok": True, "result": {"model": "X5 smart ring", "battery_percent": 64}})

    assert mod.main(["status"]) == 0
    assert json.loads(capsys.readouterr().out) == {"model": "X5 smart ring", "battery_percent": 64}
    assert cli.invokes == [{"device_id": PHONE, "skill": "x5_get_status", "args": {}, "timeout": 45.0}]


def test_cli_measure_and_workout(mod, cli):
    assert mod.main(["measure", "spo2"]) == 0
    assert mod.main(["workout", "start", "--sport", "walk"]) == 0
    assert [(b["skill"], b["args"]) for b in cli.invokes] == [
        ("x5_measure", {"type": "spo2"}),
        ("x5_workout", {"action": "start", "sport": "walk"}),
    ]


def test_cli_gesture_mode_sends_minutes_as_a_number(mod, cli):
    assert mod.main(["gesture-mode", "jarvis", "--touch-awake", "30"]) == 0
    assert mod.main(["gesture-mode", "camera", "--touch-awake", "always"]) == 0
    assert [b["args"] for b in cli.invokes] == [
        {"mode": "jarvis", "touch_awake": 30},
        {"mode": "camera", "touch_awake": "always"},
    ]


def test_cli_gesture_action_variants(mod, cli):
    assert mod.main(["gesture-action", "swipe_left", "--prompt", "Skip this song"]) == 0
    assert mod.main(["gesture-action", "double_tap", "--skill", "x5_measure", "--arg", "type=heart_rate"]) == 0
    assert mod.main(["gesture-action", "hold_5s", "--none"]) == 0
    assert [b["args"] for b in cli.invokes] == [
        {"gesture": "swipe_left", "prompt": "Skip this song"},
        {"gesture": "double_tap", "skill": "x5_measure", "arguments": {"type": "heart_rate"}},
        {"gesture": "hold_5s", "none": True},
    ]


def test_cli_profile_flags(mod, cli):
    assert mod.main(["profile", "--sex", "female", "--stride-cm", "68"]) == 0
    assert cli.invokes[0]["args"] == {"sex": "female", "stride_cm": 68}


def test_cli_usage_errors_keep_the_json_contract(mod, cli, capsys):
    with pytest.raises(SystemExit) as exited:
        mod.main(["gesture-action", "pinch", "--none"])

    assert exited.value.code == 1
    assert "gesture" in json.loads(capsys.readouterr().err)["error"]
    assert cli.calls == []


def test_cli_refuses_arguments_without_a_skill(mod, cli, capsys):
    assert mod.main(["gesture-action", "tap", "--prompt", "hi", "--arg", "a=b"]) == 1
    assert "arguments" in json.loads(capsys.readouterr().err)["error"]
    assert cli.calls == []


def test_cli_reports_phone_errors_on_stderr(mod, cli, capsys):
    cli.replies["x5_find"] = (502, {"ok": False, "error": "ring is not connected over Bluetooth"})

    assert mod.main(["find"]) == 1
    assert "not connected over Bluetooth" in json.loads(capsys.readouterr().err)["error"]


# ── locating the devices skill ───────────────────────────────────────────────

def test_load_devices_module_finds_the_sibling_devices_skill(mod):
    module = mod.load_devices_module()

    assert Path(module.__file__).resolve() == DEVICES_PATH.resolve()
    assert callable(module._http)


def test_load_devices_module_falls_back_to_jarviscopilot_dir(mod, monkeypatch, tmp_path):
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-x5-ring" / "scripts" / "x5.py")
    checkout = tmp_path / "checkout"
    devices = checkout / "skills" / "jarviscopilot" / "devices" / "scripts" / "devices.py"
    devices.parent.mkdir(parents=True)
    devices.write_text("def _http(method, path, body=None, timeout=30.0):\n    return 200, {'from': 'checkout'}\n",
                       encoding="utf-8")
    monkeypatch.setenv("JARVISCOPILOT_DIR", str(checkout))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    assert mod.load_devices_module()._http("GET", "/api/devices") == (200, {"from": "checkout"})


def test_load_devices_module_looks_under_hermes_home(mod, monkeypatch, tmp_path):
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-x5-ring" / "scripts" / "x5.py")
    monkeypatch.delenv("JARVISCOPILOT_DIR", raising=False)
    hermes = tmp_path / "hermes"
    devices = hermes / "skills" / "jarviscopilot" / "devices" / "scripts" / "devices.py"
    devices.parent.mkdir(parents=True)
    devices.write_text("def _http(method, path, body=None, timeout=30.0):\n    return 200, {'from': 'hermes'}\n",
                       encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(hermes))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    assert mod.load_devices_module()._http("GET", "/api/devices") == (200, {"from": "hermes"})


def test_load_devices_module_explains_where_it_looked(mod, monkeypatch, tmp_path):
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-x5-ring" / "scripts" / "x5.py")
    monkeypatch.setenv("JARVISCOPILOT_DIR", str(tmp_path / "no-checkout"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    with pytest.raises(mod.X5Error) as excinfo:
        mod.load_devices_module()

    message = str(excinfo.value)
    assert "devices.py" in message
    assert "JARVISCOPILOT_DIR" in message
    assert str(tmp_path / "no-checkout") in message
