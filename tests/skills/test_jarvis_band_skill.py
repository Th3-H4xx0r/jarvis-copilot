"""Tests for skills/smart-home/jarvis-band — the HBand smart band SKILL.md, SDK and CLI."""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / "skills" / "smart-home" / "jarvis-band"
SKILL_MD = SKILL_DIR / "SKILL.md"
SCRIPT_PATH = SKILL_DIR / "scripts" / "band.py"
DEVICES_PATH = REPO_ROOT / "skills" / "jarviscopilot" / "devices" / "scripts" / "devices.py"
IOS_SOURCES = REPO_ROOT / "ios_app" / "JarvisCopilot"

PHONE = "0123456789abcdef0123456789abcdef"  # pairing ids are uuid4().hex
MAC = "fedcba9876543210fedcba9876543210"
PHONE_NAME = "JarvisCopilot (iPhone)"
MAC_NAME = "Pranav's MacBook"


def load_module():
    spec = importlib.util.spec_from_file_location("jarvis_band_skill", SCRIPT_PATH)
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
    skill(PHONE, "band_get_status", PHONE_NAME),
    skill(PHONE, "band_measure", PHONE_NAME),
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


def every_call(band):
    """One call of every SDK method, with typical arguments."""
    band.status()
    band.day()
    band.health_day()
    band.history()
    band.sync()
    band.measure("blood_pressure")
    band.workout("status")
    band.find()
    band.heart_rate_alarm(True, high=150, low=50)
    band.raise_to_wake(True)
    band.skin_tone(3)
    band.camera(True)
    band.clear_data(confirm=True)
    band.set_alerts(calls=True)
    band.set_alarm("list")
    band.set_sedentary(True)
    band.set_profile(age=30)
    band.set_monitoring("blood_pressure", True)
    band.log()


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
    order = ["# Smart Band Skill", "## When to Use", "## Prerequisites", "## How to Run", "## Quick Reference",
             "## Procedure", "## Pitfalls", "## Verification"]
    positions = [text.find(f"\n{heading}\n") for heading in order]
    assert all(p >= 0 for p in positions), dict(zip(order, positions))
    assert positions == sorted(positions)


def test_every_skill_the_doc_names_is_one_the_sdk_calls(mod):
    documented = set(re.findall(r"`(band_[a-z_]+)`", SKILL_MD.read_text(encoding="utf-8")))
    transport = FakeTransport()
    every_call(mod.Band(device=PHONE, transport=transport))
    assert documented == {b["skill"] for b in transport.invokes}


def test_the_doc_tells_a_conversation_the_tools_are_device_band_skills():
    text = SKILL_MD.read_text(encoding="utf-8")
    assert "`device_band_<skill>`" in text
    assert "`device_band_get_status`" in text


def test_the_doc_lists_every_measurement_and_monitored_metric_the_cli_accepts(mod):
    text = SKILL_MD.read_text(encoding="utf-8")
    assert all(f"`{name}`" in text for name in (*mod.MEASUREMENTS, *mod.MONITORED_METRICS))


# ── device discovery ─────────────────────────────────────────────────────────

def test_discovery_picks_the_device_offering_band_get_status(mod):
    transport = FakeTransport(skills=[skill(MAC, "x5_get_status", MAC_NAME), *DEFAULT_SKILLS[1:]])
    band = mod.Band(transport=transport)

    band.status()
    band.find()

    assert band.device_id == PHONE
    assert [c["path"] for c in transport.calls] == [
        "/api/devices/skills", "/api/devices/skills/invoke", "/api/devices/skills/invoke",
    ]
    assert {b["device_id"] for b in transport.invokes} == {PHONE}


def test_discovery_prefers_the_connected_device_when_several_offer_the_band(mod):
    push_only = "11111111111111111111111111111111"
    skills = [skill(push_only, "band_get_status", "Old iPhone"), *DEFAULT_SKILLS]
    devices = [
        {"id": push_only, "invokable": True, "bridge_connected": False},
        {"id": PHONE, "invokable": True, "bridge_connected": True},
    ]
    transport = FakeTransport(skills=skills, devices=devices)

    mod.Band(transport=transport).status()

    assert transport.invokes[0]["device_id"] == PHONE


def test_discovery_without_a_band_raises(mod):
    transport = FakeTransport(skills=[skill(PHONE, "x5_get_status", PHONE_NAME)])

    with pytest.raises(mod.BandError, match="band_get_status"):
        mod.Band(transport=transport).status()
    assert transport.invokes == []


def test_explicit_device_id_skips_discovery(mod):
    transport = FakeTransport(skills=[])

    mod.Band(device=PHONE.upper(), transport=transport).status()

    assert [c["path"] for c in transport.calls] == ["/api/devices/skills/invoke"]
    assert transport.invokes[0]["device_id"] == PHONE


def test_explicit_device_name_is_matched_case_insensitively(mod):
    band = mod.Band(device="iphone", transport=FakeTransport())
    band.status()
    assert band.device_id == PHONE

    with pytest.raises(mod.BandError, match="no online device matching"):
        mod.Band(device="pixel", transport=FakeTransport()).status()


# ── skill and argument mapping ───────────────────────────────────────────────

@pytest.mark.parametrize(
    ("call", "skill_name", "args"),
    [
        pytest.param(lambda b: b.status(), "band_get_status", {}, id="status"),
        pytest.param(lambda b: b.day(date="2026-10-04", metrics=["sleep", "blood_pressure"], detail=True),
                     "band_get_day", {"date": "2026-10-04", "metrics": ["sleep", "blood_pressure"], "detail": True},
                     id="day-detail"),
        pytest.param(lambda b: b.day(metrics="sleep, hrv"), "band_get_day", {"metrics": ["sleep", "hrv"]},
                     id="day-metrics-csv"),
        pytest.param(lambda b: b.health_day("2026-10-04"), "band_get_health_day", {"date": "2026-10-04"},
                     id="health-day"),
        pytest.param(lambda b: b.health_day(), "band_get_health_day", {}, id="health-day-today"),
        pytest.param(lambda b: b.history(days=14), "band_get_history", {"days": 14}, id="history"),
        pytest.param(lambda b: b.sync(days=3), "band_sync", {"days": 3}, id="sync"),
        pytest.param(lambda b: b.measure("blood_pressure"), "band_measure", {"type": "blood_pressure"},
                     id="measure-bp"),
        pytest.param(lambda b: b.workout("start", sport="walk"), "band_workout",
                     {"action": "start", "sport": "walk"}, id="workout-start"),
        pytest.param(lambda b: b.workout("end"), "band_workout", {"action": "end"}, id="workout-end"),
        pytest.param(lambda b: b.find(), "band_find", {}, id="find"),
        pytest.param(lambda b: b.find(stop=True), "band_find", {"stop": True}, id="find-stop"),
        pytest.param(lambda b: b.set_alerts(calls=True, messages=False), "band_set_alerts",
                     {"calls": True, "messages": False}, id="alerts"),
        pytest.param(lambda b: b.set_alerts(apps="WhatsApp, Telegram"), "band_set_alerts",
                     {"apps": ["WhatsApp", "Telegram"]}, id="alerts-apps-csv"),
        pytest.param(lambda b: b.set_alerts(apps=[]), "band_set_alerts", {"apps": []}, id="alerts-no-apps"),
        pytest.param(lambda b: b.set_alarm("list"), "band_set_alarm", {"action": "list"}, id="alarm-list"),
        pytest.param(lambda b: b.set_alarm("add", time="6:45", days="Mon,tue,mon", enabled=True),
                     "band_set_alarm",
                     {"action": "add", "time": "06:45", "days": ["mon", "tue"], "enabled": True}, id="alarm-add"),
        pytest.param(lambda b: b.set_alarm("add", time="22:00"), "band_set_alarm",
                     {"action": "add", "time": "22:00"}, id="alarm-add-once"),
        pytest.param(lambda b: b.set_alarm("delete", alarm_id=2), "band_set_alarm",
                     {"action": "delete", "id": 2}, id="alarm-delete"),
        pytest.param(lambda b: b.set_sedentary(True, interval_minutes=60, start="9:00", end="18:30"),
                     "band_set_sedentary",
                     {"enabled": True, "interval_minutes": 60, "start": "09:00", "end": "18:30"}, id="sedentary"),
        pytest.param(lambda b: b.set_sedentary(False), "band_set_sedentary", {"enabled": False},
                     id="sedentary-off"),
        pytest.param(lambda b: b.set_profile(sex="female", weight_kg=None, height_cm=165), "band_set_profile",
                     {"sex": "female", "height_cm": 165}, id="profile"),
        pytest.param(lambda b: b.set_monitoring("blood_pressure", True, interval_minutes=30), "band_set_monitoring",
                     {"metric": "blood_pressure", "enabled": True, "interval_minutes": 30}, id="monitoring"),
        pytest.param(lambda b: b.set_monitoring("spo2", False), "band_set_monitoring",
                     {"metric": "spo2", "enabled": False}, id="monitoring-off"),
        pytest.param(lambda b: b.log(limit=20), "band_get_log", {"limit": 20}, id="log"),
    ],
)
def test_each_method_sends_its_skill_and_only_the_given_args(mod, call, skill_name, args):
    transport = FakeTransport()
    band = mod.Band(device=PHONE, transport=transport)

    assert call(band) == {"skill": skill_name}
    assert transport.invokes == [{"device_id": PHONE, "skill": skill_name, "args": args, "timeout": 45.0}]


def test_the_sdk_only_ever_speaks_band_skills(mod):
    transport = FakeTransport()
    every_call(mod.Band(device=PHONE, transport=transport))
    assert all(b["skill"].startswith("band_") for b in transport.invokes)


def test_measure_never_waits_less_than_the_default(mod):
    transport = FakeTransport()
    mod.Band(device=PHONE, timeout=10, transport=transport).measure("spo2")
    mod.Band(device=PHONE, timeout=90, transport=transport).measure("blood_pressure")

    assert [b["args"] for b in transport.invokes] == [{"type": "spo2"}, {"type": "blood_pressure"}]
    assert [b["timeout"] for b in transport.invokes] == [45.0, 90.0]
    assert all(c["timeout"] > b for c, b in zip(transport.calls, (45.0, 90.0)))  # HTTP outlasts the invoke


def test_a_measurement_still_running_comes_back_as_is(mod):
    transport = FakeTransport(replies={"band_measure": (200, {"ok": True, "result": {"status": "measuring"}})})
    assert mod.Band(device=PHONE, transport=transport).measure("blood_pressure") == {"status": "measuring"}


def _advertised_band_skills():
    """Every ``band_*`` name the iOS sources spell out, wherever the band's files live."""
    if not IOS_SOURCES.is_dir():
        return set()
    names = set()
    for path in IOS_SOURCES.rglob("*.swift"):
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if '"band_get_status"' in text:
            names |= set(re.findall(r'"(band_[a-z_]+)"', text))
    return names


def test_sdk_covers_only_skills_the_phone_advertises(mod):
    advertised = _advertised_band_skills()
    if not advertised:
        pytest.skip("no band_* skills found in the iOS sources")
    transport = FakeTransport()
    every_call(mod.Band(device=PHONE, transport=transport))
    assert {b["skill"] for b in transport.invokes} <= advertised


# ── errors and client-side guards ────────────────────────────────────────────

@pytest.mark.parametrize(
    ("reply", "text"),
    [
        pytest.param((502, {"ok": False, "error": "bad argument: action"}), "bad argument", id="ok-false-502"),
        pytest.param((200, {"ok": False, "error": "device did not respond before timeout"}), "did not respond",
                     id="ok-false-200"),
        pytest.param((200, {"ok": True, "result": {"ok": False, "error": "band is busy"}}), "busy",
                     id="result-ok-false"),
        pytest.param((401, {"error": "unauthorized"}), "unauthorized", id="non-2xx"),
        pytest.param((-1, {"error": "[Errno 61] Connection refused"}), "could not reach", id="webui-down"),
        pytest.param((500, {}), "HTTP 500", id="bare-500"),
    ],
)
def test_failed_invokes_raise_band_error(mod, reply, text):
    transport = FakeTransport(replies={"band_workout": reply})

    with pytest.raises(mod.BandError, match=text):
        mod.Band(device=PHONE, transport=transport).workout("start")


@pytest.mark.parametrize(
    ("call", "text"),
    [
        pytest.param(lambda b: b.workout("pause", sport="run"), "sport", id="sport-not-start"),
        pytest.param(lambda b: b.set_alerts(), "at least one", id="empty-alerts"),
        pytest.param(lambda b: b.set_alarm("snooze"), "action", id="unknown-alarm-action"),
        pytest.param(lambda b: b.set_alarm("add"), "time", id="add-without-time"),
        pytest.param(lambda b: b.set_alarm("add", time="25:00"), "HH:MM", id="bad-time"),
        pytest.param(lambda b: b.set_alarm("add", time="7.30"), "HH:MM", id="not-a-clock"),
        pytest.param(lambda b: b.set_alarm("add", time="07:30", days=["mon", "funday"]), "funday",
                     id="unknown-day"),
        pytest.param(lambda b: b.set_alarm("delete"), "id", id="delete-without-id"),
        pytest.param(lambda b: b.set_alarm("delete", alarm_id=1, time="07:00"), "only", id="delete-with-time"),
        pytest.param(lambda b: b.set_alarm("list", alarm_id=1), "no other", id="list-with-args"),
        pytest.param(lambda b: b.set_sedentary(True, start="noon"), "start", id="bad-sedentary-start"),
        pytest.param(lambda b: b.set_profile(stride_cm=70), "stride_cm", id="unknown-profile-field"),
        pytest.param(lambda b: b.set_profile(age=None), "at least one", id="empty-profile"),
    ],
)
def test_malformed_calls_fail_before_any_request(mod, call, text):
    transport = FakeTransport()

    with pytest.raises(mod.BandError, match=text):
        call(mod.Band(transport=transport))  # discovery would be the first request
    assert transport.calls == []


# ── CLI ──────────────────────────────────────────────────────────────────────

def test_cli_status_prints_the_result_as_json(mod, cli, capsys):
    cli.replies["band_get_status"] = (200, {"ok": True, "result": {"model": "HBand smart band",
                                                                     "battery_percent": 71}})

    assert mod.main(["status"]) == 0
    assert json.loads(capsys.readouterr().out) == {"model": "HBand smart band", "battery_percent": 71}
    assert cli.invokes == [{"device_id": PHONE, "skill": "band_get_status", "args": {}, "timeout": 45.0}]


def test_cli_measure_and_workout(mod, cli):
    assert mod.main(["measure", "blood_pressure"]) == 0
    assert mod.main(["workout", "start", "--sport", "walk"]) == 0
    assert [(b["skill"], b["args"]) for b in cli.invokes] == [
        ("band_measure", {"type": "blood_pressure"}),
        ("band_workout", {"action": "start", "sport": "walk"}),
    ]


def test_cli_find_starts_and_stops(mod, cli):
    assert mod.main(["find"]) == 0
    assert mod.main(["find", "--stop"]) == 0
    assert [(b["skill"], b["args"]) for b in cli.invokes] == [("band_find", {}), ("band_find", {"stop": True})]


def test_cli_alerts_take_on_off_and_an_app_list(mod, cli):
    assert mod.main(["alerts", "--calls", "on", "--messages", "off", "--apps", "WhatsApp,Telegram"]) == 0
    assert mod.main(["alerts", "--apps", ""]) == 0
    assert [b["args"] for b in cli.invokes] == [
        {"calls": True, "messages": False, "apps": ["WhatsApp", "Telegram"]},
        {"apps": []},
    ]


def test_cli_alarm_list_add_and_delete(mod, cli):
    assert mod.main(["alarm", "list"]) == 0
    assert mod.main(["alarm", "add", "--time", "06:45", "--days", "mon,fri", "--enabled", "on"]) == 0
    assert mod.main(["alarm", "delete", "--id", "3"]) == 0
    assert [b["args"] for b in cli.invokes] == [
        {"action": "list"},
        {"action": "add", "time": "06:45", "days": ["mon", "fri"], "enabled": True},
        {"action": "delete", "id": 3},
    ]


def test_cli_sedentary_monitoring_profile_and_log(mod, cli):
    assert mod.main(["sedentary", "on", "--interval", "45", "--start", "09:00", "--end", "17:00"]) == 0
    assert mod.main(["monitoring", "temperature", "off"]) == 0
    assert mod.main(["profile", "--sex", "male", "--weight-kg", "72"]) == 0
    assert mod.main(["log", "--limit", "5"]) == 0
    assert [(b["skill"], b["args"]) for b in cli.invokes] == [
        ("band_set_sedentary", {"enabled": True, "interval_minutes": 45, "start": "09:00", "end": "17:00"}),
        ("band_set_monitoring", {"metric": "temperature", "enabled": False}),
        ("band_set_profile", {"sex": "male", "weight_kg": 72}),
        ("band_get_log", {"limit": 5}),
    ]


def test_cli_usage_errors_keep_the_json_contract(mod, cli, capsys):
    with pytest.raises(SystemExit) as exited:
        mod.main(["measure", "hrv"])   # the E910 has no HRV spot command

    assert exited.value.code == 1
    assert "type" in json.loads(capsys.readouterr().err)["error"]
    assert cli.calls == []


def test_cli_refuses_an_alarm_without_a_time(mod, cli, capsys):
    assert mod.main(["alarm", "add", "--days", "mon"]) == 1
    assert "time" in json.loads(capsys.readouterr().err)["error"]
    assert cli.calls == []


def test_cli_reports_phone_errors_on_stderr(mod, cli, capsys):
    cli.replies["band_find"] = (502, {"ok": False, "error": "band is not connected over Bluetooth"})

    assert mod.main(["find"]) == 1
    assert "not connected over Bluetooth" in json.loads(capsys.readouterr().err)["error"]


# ── locating the devices skill ───────────────────────────────────────────────

def test_load_devices_module_finds_the_sibling_devices_skill(mod):
    module = mod.load_devices_module()

    assert Path(module.__file__).resolve() == DEVICES_PATH.resolve()
    assert callable(module._http)


def test_load_devices_module_falls_back_to_jarviscopilot_dir(mod, monkeypatch, tmp_path):
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-band" / "scripts" / "band.py")
    checkout = tmp_path / "checkout"
    devices = checkout / "skills" / "jarviscopilot" / "devices" / "scripts" / "devices.py"
    devices.parent.mkdir(parents=True)
    devices.write_text("def _http(method, path, body=None, timeout=30.0):\n    return 200, {'from': 'checkout'}\n",
                       encoding="utf-8")
    monkeypatch.setenv("JARVISCOPILOT_DIR", str(checkout))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    assert mod.load_devices_module()._http("GET", "/api/devices") == (200, {"from": "checkout"})


def test_load_devices_module_looks_under_hermes_home(mod, monkeypatch, tmp_path):
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-band" / "scripts" / "band.py")
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
    monkeypatch.setattr(mod, "_HERE", tmp_path / "x" / "smart-home" / "jarvis-band" / "scripts" / "band.py")
    monkeypatch.setenv("JARVISCOPILOT_DIR", str(tmp_path / "no-checkout"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    with pytest.raises(mod.BandError) as excinfo:
        mod.load_devices_module()

    message = str(excinfo.value)
    assert "devices.py" in message
    assert "JARVISCOPILOT_DIR" in message
    assert str(tmp_path / "no-checkout") in message
