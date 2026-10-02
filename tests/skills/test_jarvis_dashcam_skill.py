"""Tests for skills/smart-home/jarvis-dashcam — SKILL.md, the dashcam.py SDK/CLI and connect_drive.sh."""
from __future__ import annotations

import base64
import importlib.util
import io
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / "skills" / "smart-home" / "jarvis-dashcam"
SKILL_MD = SKILL_DIR / "SKILL.md"
SCRIPT_PATH = SKILL_DIR / "scripts" / "dashcam.py"
CONNECT_DRIVE = SKILL_DIR / "scripts" / "connect_drive.sh"

PHONE = "0123456789abcdef0123456789abcdef"
PHONE_NAME = "JarvisCopilot (iPhone)"
T0 = 1790000000.0  # 2026-09-21T14:13:20Z


def load_module():
    spec = importlib.util.spec_from_file_location("jarvis_dashcam_skill", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def iso(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def skill(name):
    return {"device_id": PHONE, "device_name": PHONE_NAME, "name": name, "description": "",
            "input_schema": {"type": "object", "properties": {}}}


class FakeTransport:
    """Stands in for devices._http: records requests, answers from `routes` keyed by (method, path-without-query)."""

    def __init__(self, routes=None):
        self.routes = routes or {}
        self.calls = []

    def __call__(self, method, path, body=None, timeout=30.0):
        self.calls.append({"method": method, "path": path, "body": body, "timeout": timeout})
        bare = path.split("?", 1)[0]
        if (method, bare) == ("GET", "/api/devices/skills"):
            return 200, {"skills": [skill("dashcam_get_status"), skill("x5_get_status")]}
        if (method, bare) == ("POST", "/api/devices/skills/invoke"):
            return 200, {"ok": True, "result": {"skill": body["skill"]}}
        reply = self.routes.get((method, bare))
        if reply is None:
            return 404, {"ok": False, "error": "unknown dashcam endpoint"}
        return reply(path, body) if callable(reply) else reply

    @property
    def invokes(self):
        return [c["body"] for c in self.calls if c["path"] == "/api/devices/skills/invoke"]

    def query(self, prefix):
        from urllib.parse import parse_qs, urlsplit
        for c in self.calls:
            if c["path"].startswith(prefix):
                return {k: v[-1] for k, v in parse_qs(urlsplit(c["path"]).query).items()}
        return None


@pytest.fixture
def mod():
    return load_module()


@pytest.fixture
def cli(mod, monkeypatch):
    transport = FakeTransport()
    monkeypatch.setattr(mod, "load_devices_module", lambda: SimpleNamespace(_http=transport))
    return transport


def run_cli(mod, argv, capsys, stdin=None, monkeypatch=None):
    if stdin is not None:
        monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    code = mod.main(argv)
    out, err = capsys.readouterr()
    return code, out, err


def every_device_call(cam):
    cam.camera_status()
    cam.sync()
    cam.lock()
    cam.snapshot()
    cam.set_recording(True)
    cam.settings()
    cam.set_setting("loop_length", "3")
    cam.sd_info()
    cam.format_sd(confirm=True)
    cam.delete_file("/sd/Normal/F/a.MP4", confirm=True)
    cam.set_wifi(ssid="A4_CAM")
    cam.fetch("2026-10-01T10:00:00Z", "2026-10-01T10:10:00Z")


# ── SKILL.md ─────────────────────────────────────────────────────────────────

def _frontmatter_field(name):
    m = re.search(rf"^\s*{name}: (.*)$", SKILL_MD.read_text(encoding="utf-8"), re.MULTILINE)
    assert m, f"SKILL.md has no {name}"
    return m.group(1).strip()


def test_description_is_one_short_sentence():
    description = _frontmatter_field("description")
    assert len(description) <= 60, len(description)
    assert description.endswith(".") and description.count(". ") == 0


def test_frontmatter():
    assert _frontmatter_field("name") == SKILL_DIR.name
    assert _frontmatter_field("author").startswith("Pranav Krishna")
    assert _frontmatter_field("platforms") == "[linux, macos, windows]"
    related = _frontmatter_field("related_skills")
    assert "jarvis-x5-ring" in related and "jarvis-ring" in related


def test_body_uses_the_modern_section_order():
    text = SKILL_MD.read_text(encoding="utf-8")
    order = ["# Dashcam Skill", "## When to Use", "## Prerequisites", "## How to Run", "## Quick Reference",
             "## Procedure", "## Pitfalls", "## Verification"]
    positions = [text.find(f"\n{heading}\n") for heading in order]
    assert all(p >= 0 for p in positions), dict(zip(order, positions))
    assert positions == sorted(positions)


def test_every_device_skill_in_the_doc_is_in_the_cli_and_the_sdk(mod):
    documented = set(re.findall(r"`(dashcam_[a-z_]+)`", SKILL_MD.read_text(encoding="utf-8")))
    assert documented == set(mod.DEVICE_SKILLS)
    assert documented == {s for skills in mod.CLI_SKILLS.values() for s in skills}
    transport = FakeTransport()
    every_device_call(mod.Dashcam(device=PHONE, transport=transport))
    assert documented == {b["skill"] for b in transport.invokes}


# ── device wrappers ──────────────────────────────────────────────────────────

def test_device_payloads(mod):
    t = FakeTransport()
    cam = mod.Dashcam(transport=t)
    cam.set_recording(False)
    cam.set_setting("speed_unit", "mph")
    cam.delete_file("/sd/Event/F/b.MP4", confirm=True)
    cam.fetch("2026-10-01T15:40:00-05:00", "2026-10-01T15:50:00-05:00")
    cam.set_wifi(password="new-password")
    cam.sync(resync=True)
    args = [(b["skill"], b["args"]) for b in t.invokes]
    assert args == [
        ("dashcam_set_recording", {"enabled": False}),
        ("dashcam_set_setting", {"key": "speed_unit", "value": "mph"}),
        ("dashcam_delete_file", {"path": "/sd/Event/F/b.MP4", "confirm": True}),
        ("dashcam_fetch_range", {"from": "2026-10-01T20:40:00Z", "to": "2026-10-01T20:50:00Z"}),
        ("dashcam_set_wifi", {"password": "new-password"}),
        ("dashcam_sync", {"resync": True}),
    ]
    assert all(b["device_id"] == PHONE for b in t.invokes)


def test_destructive_commands_need_confirm(mod):
    t = FakeTransport()
    cam = mod.Dashcam(device=PHONE, transport=t)
    with pytest.raises(mod.DashcamError, match="confirm"):
        cam.format_sd()
    with pytest.raises(mod.DashcamError, match="confirm"):
        cam.delete_file("/sd/a.MP4")
    assert t.invokes == []


def test_cli_device_commands(mod, cli, capsys, monkeypatch):
    assert run_cli(mod, ["record", "on"], capsys)[0] == 0
    assert run_cli(mod, ["settings", "set", "loop_length", "3"], capsys)[0] == 0
    assert run_cli(mod, ["settings"], capsys)[0] == 0
    code, _, err = run_cli(mod, ["format-sd"], capsys)
    assert code == 1 and "confirm" in json.loads(err)["error"]
    assert run_cli(mod, ["format-sd", "--confirm"], capsys)[0] == 0
    assert run_cli(mod, ["wifi", "--ssid", "A4", "--password-stdin"], capsys, stdin="s3cret\n",
                   monkeypatch=monkeypatch)[0] == 0
    assert [(b["skill"], b["args"]) for b in cli.invokes] == [
        ("dashcam_set_recording", {"enabled": True}),
        ("dashcam_set_setting", {"key": "loop_length", "value": "3"}),
        ("dashcam_get_settings", {}),
        ("dashcam_format_sd", {"confirm": True}),
        ("dashcam_set_wifi", {"ssid": "A4", "password": "s3cret"}),
    ]


# ── server queries ───────────────────────────────────────────────────────────

def track(t0, n, lat0=30.0, speed=20.0):
    return [[t0 + i, lat0 + i * 1e-4, -97.7, speed, 90.0] for i in range(n)]


def where_routes(drive_clips, window_clips, fixes):
    def clip_detail(path, body):
        cid = path.rsplit("/", 1)[-1]
        return 200, {"ok": True, "clip": {"id": cid, "name": cid + ".MP4"}, "fixes": fixes.get(cid, []),
                     "destinations": []}
    routes = {("GET", "/api/dashcam/drives"): (200, {"drives": [{"id": "dr_1_A4", "clip_ids": [c["id"] for c in drive_clips]}]} if drive_clips else {"drives": []}),
              ("GET", "/api/dashcam/drives/dr_1_A4"): (200, {"ok": True, "drive": {}, "polyline": [], "clips": drive_clips}),
              ("GET", "/api/dashcam/clips"): (200, {"clips": window_clips, "next": None})}
    for cid in fixes:
        routes[("GET", f"/api/dashcam/clips/{cid}")] = clip_detail
    return routes


def test_where_picks_the_nearest_fix(mod):
    clips = [{"id": "c_a", "start": iso(T0), "duration_s": 60, "has_gps": True},
             {"id": "c_b", "start": iso(T0 + 60), "duration_s": 60, "has_gps": True}]
    t = FakeTransport(where_routes(clips, [], {"c_a": track(T0, 60), "c_b": track(T0 + 60, 60, lat0=30.006)}))
    out = mod.Dashcam(transport=t).where(iso(T0 + 75))
    assert out["clip_id"] == "c_b" and out["fix_time"] == iso(T0 + 75) and out["offset_s"] == 0
    assert out["lat"] == pytest.approx(30.006 + 15e-4) and out["lon"] == -97.7
    assert out["speed_mph"] == pytest.approx(44.7, abs=0.1) and out["heading_deg"] == 90.0
    assert "30.0" in out["map_url"]
    q = t.query("/api/dashcam/drives?")
    assert q["from"] == iso(T0 + 75 - 120) and q["to"] == iso(T0 + 75 + 120)


def test_where_uses_clips_by_start_when_no_drive_matches(mod):
    clips = [{"id": "c_a", "start": iso(T0), "duration_s": 60, "has_gps": True}]
    t = FakeTransport(where_routes([], clips, {"c_a": track(T0, 60)}))
    out = mod.Dashcam(transport=t).speed("2026-09-21T09:13:30-05:00")  # = T0 + 10 s
    assert out["clip_id"] == "c_a" and out["speed_mph"] == pytest.approx(44.7, abs=0.1)
    assert out["fix_time"] == iso(T0 + 10)


def test_where_rejects_fixes_more_than_two_minutes_away(mod):
    clips = [{"id": "c_a", "start": iso(T0), "duration_s": 60, "has_gps": True}]
    t = FakeTransport(where_routes(clips, clips, {"c_a": track(T0, 60)}))
    with pytest.raises(mod.DashcamError, match="no GPS fix within 120 s"):
        mod.Dashcam(transport=t).where(iso(T0 + 59 + 121))
    assert mod.Dashcam(transport=t).where(iso(T0 + 59 + 119))["offset_s"] == -119


def test_stats_in_miles_and_mph(mod, monkeypatch):
    drives = [{"id": "dr_1", "start": iso(T0), "end": iso(T0 + 1800), "distance_m": 16093.44, "duration_s": 1800,
               "moving_s": 1200, "avg_mps": 13.4112, "max_mps": 26.8224},
              {"id": "dr_2", "start": iso(T0 + 7200), "end": iso(T0 + 9000), "distance_m": 8046.72,
               "duration_s": 1800, "moving_s": 600, "avg_mps": 13.4112, "max_mps": 31.2928}]
    t = FakeTransport({("GET", "/api/dashcam/drives"): (200, {"drives": drives})})
    out = mod.Dashcam(transport=t).stats(days=7)
    assert out["drives"] == 2 and out["miles"] == pytest.approx(15.0)
    assert out["hours"] == pytest.approx(1.0) and out["driving_hours"] == pytest.approx(0.5)
    assert out["top_mph"] == pytest.approx(70.0) and out["avg_mph"] == pytest.approx(30.0)
    assert "from" in t.query("/api/dashcam/drives?")
    listed = mod.Dashcam(transport=t).drives(days=7)["drives"]
    assert listed[0]["miles"] == pytest.approx(10.0) and listed[0]["max_mph"] == pytest.approx(60.0)


def test_clips_query(mod, cli, capsys):
    cli.routes[("GET", "/api/dashcam/clips")] = (200, {"clips": [], "next": None})
    code, out, _ = run_cli(mod, ["clips", "--kind", "event", "--from", "2026-10-01T15:00:00-05:00",
                                 "--state", "pending_upload", "--limit", "5"], capsys)
    assert code == 0 and json.loads(out) == {"clips": [], "next": None}
    assert cli.query("/api/dashcam/clips") == {"kind": "event", "from": "2026-10-01T20:00:00Z",
                                               "state": "pending_upload", "limit": "5"}


def test_cli_errors_exit_1(mod, cli, capsys):
    code, out, err = run_cli(mod, ["clip", "c_missing"], capsys)
    assert code == 1 and out == "" and "unknown dashcam endpoint" in json.loads(err)["error"]
    code, _, err = run_cli(mod, ["where"], capsys)
    assert code == 1 and "error" in json.loads(err)
    code, _, err = run_cli(mod, ["where", "--at", "not a time"], capsys)
    assert code == 1 and "time" in json.loads(err)["error"]


def test_gpx_to_file(mod, cli, capsys, tmp_path):
    cli.routes[("GET", "/api/dashcam/drives/dr_1_A4.gpx")] = (200, {"raw": "<gpx></gpx>"})
    target = tmp_path / "d.gpx"
    code, out, _ = run_cli(mod, ["gpx", "dr_1_A4", "-o", str(target)], capsys)
    assert code == 0 and target.read_text() == "<gpx></gpx>" and json.loads(out)["path"] == str(target)


# ── destinations ─────────────────────────────────────────────────────────────

def test_add_destination_reads_the_password_from_stdin(mod, cli, capsys, monkeypatch):
    cli.routes[("POST", "/api/dashcam/destinations")] = lambda path, body: (
        200, {"ok": True, "destination": {"id": "d_12345678", "type": body["type"], "name": body["name"]}})
    code, out, _ = run_cli(mod, ["add-destination", "--type", "sftp", "--name", "NAS", "--host", "nas.local",
                                 "--user", "pk", "--port", "2222", "--path", "/volume1/dashcam",
                                 "--kinds", "event,photo", "--password-stdin"], capsys, stdin="hunter2\n",
                           monkeypatch=monkeypatch)
    assert code == 0 and json.loads(out)["destination"]["id"] == "d_12345678"
    body = [c["body"] for c in cli.calls if c["path"] == "/api/dashcam/destinations"][0]
    assert body == {"type": "sftp", "name": "NAS", "path": "/volume1/dashcam", "host": "nas.local", "port": 2222,
                    "user": "pk", "password": "hunter2", "kinds": ["event", "photo"]}
    assert "hunter2" not in out


TOKEN = {"access_token": "ya29.test", "token_type": "Bearer", "refresh_token": "1//test",
         "expiry": "2026-10-01T10:00:00Z"}
AUTHORIZE_OUT = ("Paste the following into your remote machine --->\n" + json.dumps(TOKEN)
                 + "\n<---End paste\n")


@pytest.mark.parametrize("raw", [
    AUTHORIZE_OUT,
    json.dumps(TOKEN),
    "Paste the following into your remote machine --->\n"
    + base64.b64encode(json.dumps(TOKEN).encode()).decode() + "\n<---End paste\n",
])
def test_drive_token_is_extracted_from_rclone_authorize_output(mod, raw):
    assert json.loads(mod.extract_drive_token(raw)) == TOKEN


def test_drive_token_garbage_is_rejected(mod):
    with pytest.raises(mod.DashcamError):
        mod.extract_drive_token("Paste the following into your remote machine --->\nnope\n<---End paste")


def test_drive_payload_and_json_stdin(mod, cli, capsys, monkeypatch):
    monkeypatch.setenv("DASHCAM_DRIVE_CLIENT_SECRET", "csecret")
    code, out, _ = run_cli(mod, ["drive-payload", "--name", "Google Drive", "--path", "dashcam",
                                 "--client-id", "cid"], capsys, stdin=AUTHORIZE_OUT, monkeypatch=monkeypatch)
    assert code == 0
    payload = json.loads(out)
    assert payload == {"type": "drive", "name": "Google Drive", "path": "dashcam", "token": json.dumps(TOKEN),
                       "client_id": "cid", "client_secret": "csecret"}
    cli.routes[("POST", "/api/dashcam/destinations")] = (200, {"ok": True, "destination": {"id": "d_1"}})
    code, out, _ = run_cli(mod, ["add-destination", "--json-stdin"], capsys, stdin=json.dumps(payload),
                           monkeypatch=monkeypatch)
    assert code == 0 and "ya29" not in out
    assert [c["body"] for c in cli.calls if c["path"] == "/api/dashcam/destinations"][0] == payload


def test_connect_drive_script_is_valid_and_keeps_secrets_off_argv():
    assert CONNECT_DRIVE.stat().st_mode & 0o111
    subprocess.run(["bash", "-n", str(CONNECT_DRIVE)], check=True)
    text = CONNECT_DRIVE.read_text()
    assert "rclone authorize drive" in text and "--json-stdin" in text and "drive-payload" in text
    assert "--token " not in text and "--password " not in text
