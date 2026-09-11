"""Tests for skills/smart-home/jarvis-ring/scripts/ring.py — the smart ring SDK and CLI."""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "skills" / "smart-home" / "jarvis-ring" / "scripts" / "ring.py"
DEVICES_PATH = REPO_ROOT / "skills" / "jarviscopilot" / "devices" / "scripts" / "devices.py"
COLMI_SWIFT = REPO_ROOT / "ios_app" / "JarvisCopilot" / "Ring" / "ColmiR12.swift"

PHONE = "0123456789abcdef0123456789abcdef"  # pairing ids are uuid4().hex
MAC = "fedcba9876543210fedcba9876543210"
PHONE_NAME = "JarvisCopilot (iPhone)"
MAC_NAME = "Pranav's MacBook"


def load_module():
    spec = importlib.util.spec_from_file_location("jarvis_ring_skill", SCRIPT_PATH)
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
    skill(PHONE, "bottle_get_status", PHONE_NAME),
    skill(PHONE, "ring_get_status", PHONE_NAME),
    skill(PHONE, "ring_measure", PHONE_NAME),
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


# ── device discovery ─────────────────────────────────────────────────────────

def test_discovery_picks_the_device_offering_ring_get_status(mod):
    transport = FakeTransport()
    ring = mod.Ring(transport=transport)

    ring.status()
    ring.find()

    assert ring.device_id == PHONE
    assert [c["path"] for c in transport.calls] == [
        "/api/devices/skills", "/api/devices/skills/invoke", "/api/devices/skills/invoke",
    ]
    assert {b["device_id"] for b in transport.invokes} == {PHONE}


def test_discovery_prefers_the_connected_device_when_several_offer_the_ring(mod):
    push_only = "11111111111111111111111111111111"
    skills = [skill(push_only, "ring_get_status", "Old iPhone"), *DEFAULT_SKILLS]
    devices = [
        {"id": push_only, "invokable": True, "bridge_connected": False},
        {"id": PHONE, "invokable": True, "bridge_connected": True},
    ]
    transport = FakeTransport(skills=skills, devices=devices)

    mod.Ring(transport=transport).status()

    assert transport.invokes[0]["device_id"] == PHONE


def test_discovery_without_a_ring_raises(mod):
    transport = FakeTransport(skills=[skill(MAC, "chrome_snapshot", MAC_NAME)])

    with pytest.raises(mod.RingError, match="ring_get_status"):
        mod.Ring(transport=transport).status()
    assert transport.invokes == []


def test_discovery_reports_a_webui_failure(mod):
    def transport(method, path, body=None, timeout=30.0):
        return 401, {"error": "unauthorized"}

    with pytest.raises(mod.RingError, match="unauthorized"):
        mod.Ring(transport=transport).status()


def test_explicit_device_id_skips_discovery(mod):
    transport = FakeTransport(skills=[])  # nothing advertises the ring; it must not be asked

    mod.Ring(device=PHONE.upper(), transport=transport).status()

    assert [c["path"] for c in transport.calls] == ["/api/devices/skills/invoke"]
    assert transport.invokes[0]["device_id"] == PHONE


def test_explicit_device_name_is_matched_case_insensitively(mod):
    ring = mod.Ring(device="iphone", transport=FakeTransport())
    ring.status()
    assert ring.device_id == PHONE

    with pytest.raises(mod.RingError, match="no online device matching"):
        mod.Ring(device="pixel", transport=FakeTransport()).status()


# ── skill and argument mapping ───────────────────────────────────────────────

@pytest.mark.parametrize(
    ("call", "skill_name", "args"),
    [
        pytest.param(lambda r: r.status(), "ring_get_status", {}, id="status"),
        pytest.param(lambda r: r.day(date="2026-09-10", metrics=["sleep", "heart_rate"], detail=True),
                     "ring_get_day", {"date": "2026-09-10", "metrics": ["sleep", "heart_rate"], "detail": True},
                     id="day-detail"),
        pytest.param(lambda r: r.day(metrics="sleep, hrv"), "ring_get_day", {"metrics": ["sleep", "hrv"]},
                     id="day-metrics-csv"),
        pytest.param(lambda r: r.history(days=14, metrics=["activity"]), "ring_get_history",
                     {"days": 14, "metrics": ["activity"]}, id="history"),
        pytest.param(lambda r: r.sync(days=2), "ring_sync", {"days": 2}, id="sync"),
        pytest.param(lambda r: r.find(), "ring_find", {}, id="find"),
        pytest.param(lambda r: r.set_monitoring("heart_rate", True, interval_minutes=10), "ring_set_monitoring",
                     {"metric": "heart_rate", "enabled": True, "interval_minutes": 10}, id="monitoring-interval"),
        pytest.param(lambda r: r.set_monitoring("spo2", False), "ring_set_monitoring",
                     {"metric": "spo2", "enabled": False}, id="monitoring-off"),
        pytest.param(lambda r: r.set_touch_mode("gesture", "music", strength=6), "ring_set_touch_mode",
                     {"control": "gesture", "mode": "music", "strength": 6}, id="gesture"),
        pytest.param(lambda r: r.set_touch_mode("touch", "off"), "ring_set_touch_mode",
                     {"control": "touch", "mode": "off"}, id="touch-off"),
        pytest.param(lambda r: r.set_goals(steps=9000, calories=None, sleep_minutes=450), "ring_set_goals",
                     {"steps": 9000, "sleep_minutes": 450}, id="goals"),
        pytest.param(lambda r: r.set_profile(sex="female", use_24h=False), "ring_set_profile",
                     {"sex": "female", "use_24h": False}, id="profile"),
        pytest.param(lambda r: r.set_preferences(temperature_unit="celsius",
                                                 dnd={"enabled": True, "start": "22:30", "end": None}),
                     "ring_set_preferences", {"temperature_unit": "celsius", "dnd": {"enabled": True, "start": "22:30"}},
                     id="preferences"),
        pytest.param(lambda r: r.power("power_off", confirm=True), "ring_power",
                     {"action": "power_off", "confirm": True}, id="power"),
        pytest.param(lambda r: r.raw(hex="03", confirm=True), "ring_raw_command",
                     {"hex": "03", "confirm": True}, id="raw-hex"),
        pytest.param(lambda r: r.raw(big_data_cmd=0x27, payload_hex="0001", confirm=True), "ring_raw_command",
                     {"big_data_cmd": 39, "payload_hex": "0001", "confirm": True}, id="raw-big-data"),
    ],
)
def test_each_method_sends_its_skill_and_only_the_given_args(mod, call, skill_name, args):
    transport = FakeTransport()
    ring = mod.Ring(device=PHONE, transport=transport)

    assert call(ring) == {"skill": skill_name}
    assert transport.invokes == [{"device_id": PHONE, "skill": skill_name, "args": args, "timeout": 45.0}]


def test_measure_clamps_wait_seconds_and_never_waits_less_than_the_default(mod):
    transport = FakeTransport()
    ring = mod.Ring(device=PHONE, timeout=10, transport=transport)

    ring.measure("heart_rate", wait_seconds=90)
    ring.measure("spo2", wait_seconds=-5)

    assert [b["args"] for b in transport.invokes] == [
        {"metric": "heart_rate", "wait_seconds": 25},
        {"metric": "spo2", "wait_seconds": 0},
    ]
    assert [b["timeout"] for b in transport.invokes] == [45.0, 45.0]
    assert all(c["timeout"] > 45 for c in transport.calls)  # HTTP outlasts the invoke

    patient = mod.Ring(device=PHONE, timeout=90, transport=transport)
    patient.measure("heart_rate")
    assert transport.invokes[-1]["timeout"] == 90.0


def test_the_skill_result_payload_is_unwrapped(mod):
    result = {"metric": "heart_rate", "status": "done", "value": 64, "unit": "bpm"}
    transport = FakeTransport(replies={"ring_measure": (200, {"ok": True, "result": result})})

    assert mod.Ring(device=PHONE, transport=transport).measure("heart_rate") == result


def test_sdk_covers_every_ring_skill_the_phone_advertises(mod):
    if not COLMI_SWIFT.exists():
        pytest.skip("iOS sources not present")
    advertised = set(re.findall(r'name: "(ring_[a-z_]+)"', COLMI_SWIFT.read_text(encoding="utf-8")))
    transport = FakeTransport()
    ring = mod.Ring(device=PHONE, transport=transport)

    ring.status()
    ring.day()
    ring.history()
    ring.sync()
    ring.measure("heart_rate")
    ring.find()
    ring.set_monitoring("hrv", True)
    ring.set_touch_mode("touch", "music")
    ring.set_goals(steps=8000)
    ring.set_profile(age=30)
    ring.set_preferences(temperature_unit="celsius")
    ring.power("factory_reset", confirm=True)
    ring.raw(hex="03", confirm=True)

    assert len(advertised) == 13
    assert {b["skill"] for b in transport.invokes} == advertised


# ── errors and client-side guards ────────────────────────────────────────────

@pytest.mark.parametrize(
    ("reply", "text"),
    [
        pytest.param((502, {"ok": False, "error": "bad argument: 'date' must be YYYY-MM-DD"}), "YYYY-MM-DD",
                     id="ok-false-502"),
        pytest.param((200, {"ok": False, "error": "device did not respond before timeout"}), "did not respond",
                     id="ok-false-200"),
        pytest.param((401, {"error": "unauthorized"}), "unauthorized", id="non-2xx"),
        pytest.param((-1, {"error": "[Errno 61] Connection refused"}), "could not reach", id="webui-down"),
        pytest.param((500, {}), "HTTP 500", id="bare-500"),
    ],
)
def test_failed_invokes_raise_ring_error(mod, reply, text):
    transport = FakeTransport(replies={"ring_get_day": reply})

    with pytest.raises(mod.RingError, match=text):
        mod.Ring(device=PHONE, transport=transport).day(date="yesterday")


def test_power_and_raw_refuse_without_confirm_before_any_request(mod):
    transport = FakeTransport()
    ring = mod.Ring(transport=transport)  # discovery would be the first request

    with pytest.raises(mod.RingError, match="confirm"):
        ring.power("factory_reset")
    with pytest.raises(mod.RingError, match="confirm"):
        ring.power("power_off", confirm="yes")
    with pytest.raises(mod.RingError, match="confirm"):
        ring.raw(hex="FF6666")

    assert transport.calls == []


def test_malformed_calls_fail_before_any_request(mod):
    transport = FakeTransport()
    ring = mod.Ring(transport=transport)

    with pytest.raises(mod.RingError, match="hex"):
        ring.raw(confirm=True)
    with pytest.raises(mod.RingError, match="distance"):
        ring.set_goals(distance=5000)
    with pytest.raises(mod.RingError, match="at least one"):
        ring.set_profile(age=None)

    assert transport.calls == []


# ── CLI ──────────────────────────────────────────────────────────────────────

def test_cli_status_prints_the_result_as_json(mod, cli, capsys):
    cli.replies["ring_get_status"] = (200, {"ok": True, "result": {"connected": True, "battery_percent": 81}})

    assert mod.main(["status"]) == 0
    assert json.loads(capsys.readouterr().out) == {"connected": True, "battery_percent": 81}
    assert cli.invokes == [{"device_id": PHONE, "skill": "ring_get_status", "args": {}, "timeout": 45.0}]


def test_cli_measure_heart_rate(mod, cli):
    assert mod.main(["measure", "heart_rate"]) == 0
    assert cli.invokes[0]["skill"] == "ring_measure"
    assert cli.invokes[0]["args"] == {"metric": "heart_rate", "wait_seconds": 25}
    assert cli.invokes[0]["timeout"] == 45.0


def test_cli_usage_errors_keep_the_json_contract(mod, cli, capsys):
    with pytest.raises(SystemExit) as exited:
        mod.main(["day", "--metrics", "pulse"])

    assert exited.value.code == 1
    assert "metrics" in json.loads(capsys.readouterr().err)["error"]
    assert cli.calls == []


def test_cli_monitoring_heart_rate_on_with_interval(mod, cli):
    assert mod.main(["--device", PHONE, "monitoring", "heart_rate", "on", "--interval", "10"]) == 0
    assert len(cli.calls) == 1  # explicit device: no discovery
    assert cli.invokes[0]["skill"] == "ring_set_monitoring"
    assert cli.invokes[0]["args"] == {"metric": "heart_rate", "enabled": True, "interval_minutes": 10}


def test_cli_power_factory_reset_without_confirm_exits_1(mod, cli, capsys):
    assert mod.main(["power", "factory_reset"]) == 1
    assert "confirm" in json.loads(capsys.readouterr().err)["error"]
    assert cli.calls == []


def test_cli_reports_phone_errors_on_stderr(mod, cli, capsys):
    cli.replies["ring_find"] = (502, {"ok": False, "error": "device is not connected over Bluetooth"})

    assert mod.main(["find"]) == 1
    assert "not connected over Bluetooth" in json.loads(capsys.readouterr().err)["error"]


def test_cli_prefs_builds_the_nested_objects(mod, cli):
    argv = ["prefs", "--dnd-on", "--dnd-start", "22:00", "--dnd-end", "7:00", "--sedentary-interval", "60"]

    assert mod.main(argv) == 0
    assert cli.invokes[0]["args"] == {
        "dnd": {"enabled": True, "start": "22:00", "end": "07:00"},
        "sedentary": {"interval_minutes": 60},
    }


def test_cli_profile_and_goals_flags(mod, cli):
    assert mod.main(["profile", "--12h", "--imperial", "--height-cm", "180"]) == 0
    assert mod.main(["goals", "--distance-m", "6000", "--sport-minutes", "45"]) == 0

    assert [b["args"] for b in cli.invokes] == [
        {"height_cm": 180, "use_24h": False, "metric_units": False},
        {"distance_m": 6000, "sport_minutes": 45},
    ]


def test_cli_raw_big_data_accepts_a_hex_opcode(mod, cli):
    assert mod.main(["raw", "--big-data-cmd", "0x27", "--payload-hex", "0001", "--confirm"]) == 0
    assert cli.invokes[0]["args"] == {"big_data_cmd": 0x27, "payload_hex": "0001", "confirm": True}


# ── locating the devices skill ───────────────────────────────────────────────

def test_load_devices_module_finds_the_sibling_devices_skill(mod):
    module = mod.load_devices_module()

    assert Path(module.__file__).resolve() == DEVICES_PATH.resolve()
    assert callable(module._http)


def test_load_devices_module_falls_back_to_jarviscopilot_dir(mod, monkeypatch, tmp_path):
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-ring" / "scripts" / "ring.py")
    checkout = tmp_path / "checkout"
    devices = checkout / "skills" / "jarviscopilot" / "devices" / "scripts" / "devices.py"
    devices.parent.mkdir(parents=True)
    devices.write_text("def _http(method, path, body=None, timeout=30.0):\n    return 200, {'from': 'checkout'}\n")
    monkeypatch.setenv("JARVISCOPILOT_DIR", str(checkout))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    assert mod.load_devices_module()._http("GET", "/api/devices") == (200, {"from": "checkout"})


def test_load_devices_module_looks_under_hermes_home(mod, monkeypatch, tmp_path):
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-ring" / "scripts" / "ring.py")
    monkeypatch.delenv("JARVISCOPILOT_DIR", raising=False)
    hermes = tmp_path / "hermes"
    devices = hermes / "skills" / "jarviscopilot" / "devices" / "scripts" / "devices.py"
    devices.parent.mkdir(parents=True)
    devices.write_text("def _http(method, path, body=None, timeout=30.0):\n    return 200, {'from': 'hermes'}\n")
    monkeypatch.setenv("HERMES_HOME", str(hermes))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    assert mod.load_devices_module()._http("GET", "/api/devices") == (200, {"from": "hermes"})


def test_load_devices_module_explains_where_it_looked(mod, monkeypatch, tmp_path):
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-ring" / "scripts" / "ring.py")
    monkeypatch.setenv("JARVISCOPILOT_DIR", str(tmp_path / "no-checkout"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    with pytest.raises(mod.RingError) as excinfo:
        mod.load_devices_module()

    message = str(excinfo.value)
    assert "devices.py" in message
    assert "JARVISCOPILOT_DIR" in message
    assert str(tmp_path / "no-checkout") in message
