"""What the server pushes to the phone instead of the phone polling (battery drain, 2026-10-13)."""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

from api import dashcam_routes  # noqa: E402


@pytest.mark.parametrize("method,path,status,what", [
    ("POST", "/destinations", 200, ["destinations"]),
    ("POST", "/destinations/d_0123abcd", 200, ["destinations"]),
    ("POST", "/destinations/d_0123abcd/delete", 200, ["destinations"]),
    ("POST", "/destinations/d_0123abcd/reconnect", 200, ["destinations"]),
    ("DELETE", "/destinations/d_0123abcd", 200, ["destinations"]),
    ("POST", "/settings", 200, ["rules"]),
    ("POST", "/destinations/d_0123abcd/token", 200, None),
    ("POST", "/destinations/d_0123abcd/test", 200, None),
    ("POST", "/clips/c_0123456789abcdef0123/phone", 200, None),
    ("POST", "/uploads", 200, None),
    ("POST", "/destinations", 400, None),
    ("GET", "/destinations", 200, None),
])
def test_which_dashcam_changes_reach_the_phone(method, path, status, what):
    assert dashcam_routes.phone_should_hear(method, path, status) == what


def test_the_device_that_made_the_change_is_excluded(monkeypatch):
    calls = []
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "publish", lambda topic, data=None, exclude=None: calls.append((topic, data, exclude)))
    dashcam_routes.tell_phone("POST", "/destinations", 200, "phone-1")
    dashcam_routes.tell_phone("POST", "/clips/c_0123456789abcdef0123/phone", 200, "phone-1")
    assert calls == [("dashcam", {"what": ["destinations"]}, "phone-1")]


def test_relay_finishing_tells_the_phone(monkeypatch):
    calls = []
    from api import dashcam_relay, device_bridge
    monkeypatch.setattr(device_bridge, "publish", lambda topic, data=None, exclude=None: calls.append((topic, data)))
    dashcam_relay._tell_phone_clips()
    assert calls == [("dashcam", {"what": ["clips"]})]


def test_coding_changes_tell_widgets(monkeypatch):
    calls = []
    from api import coding_events, device_bridge
    monkeypatch.setattr(device_bridge, "publish", lambda topic, data=None, exclude=None: calls.append((topic, data)))
    coding_events.notify()
    assert calls == [("widgets", {"what": ["coding"]})]


def test_energy_reports_are_appended_and_capped(tmp_path, monkeypatch):
    from api import routes
    monkeypatch.setattr(routes, "_ENERGY_KEEP", 3)
    for n in range(5):
        routes._append_energy_report("phone-1", {"cpuSeconds": n, "backgroundSeconds": 3600, "junk": "x",
                                                 "received": "2026-10-14T06:00:00Z", "flag": True}, state_dir=tmp_path)
    rows = [json.loads(line) for line in (tmp_path / "energy.jsonl").read_text().splitlines()]
    assert [r["cpuSeconds"] for r in rows] == [2.0, 3.0, 4.0]
    assert rows[-1]["device_id"] == "phone-1" and "junk" not in rows[-1] and "flag" not in rows[-1]


def test_bg_traffic_summary():
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
    import phone_bg_traffic
    lines = [
        '[webui] {"ts": "2026-10-14T03:01:00Z", "method": "GET", "path": "/api/dashcam/clips/c_0123456789abcdef0123", "status": 404, "ms": 1, "bg": 1}',
        '[webui] {"ts": "2026-10-14T03:02:00Z", "method": "GET", "path": "/api/devices?x=1", "status": 200, "ms": 1, "bg": 1}',
        '[webui] {"ts": "2026-10-14T03:03:00Z", "method": "GET", "path": "/api/devices", "status": 200, "ms": 1}',
        "noise",
    ]
    per_hour, per_path = phone_bg_traffic.summarize(lines)
    assert per_hour == {"2026-10-14T03": 2}
    assert per_path == {"GET /api/dashcam/clips/…": 1, "GET /api/devices": 1}


def test_hourly_probe_rows_keep_their_fields(tmp_path):
    from api import routes
    row = routes._append_energy_report("phone-1", {"kind": "probe", "cpuSeconds": 42.5, "wallSeconds": 3600,
                                                   "background": 1}, state_dir=tmp_path)
    assert (row["kind"], row["cpuSeconds"], row["wallSeconds"], row["background"]) == ("probe", 42.5, 3600.0, 1.0)


def test_probe_thread_breakdown_is_kept_small(tmp_path):
    from api import routes
    threads = {f"t{i}": float(i) for i in range(12)} | {"bad": "x", "flag": True}
    row = routes._append_energy_report("phone-1", {"kind": "probe", "cpuSeconds": 1, "threads": threads},
                                       state_dir=tmp_path)
    assert len(row["threads"]) <= 8 and all(isinstance(v, float) for v in row["threads"].values())


def test_probe_rows_keep_the_ledger_hour_bounded(tmp_path):
    from api import routes
    hour = {"start": 1792000000, "end": 1792003600, "batteryStart": 0.8, "batteryEnd": 0.77,
            "seconds": {"foreground": 600, "background": 3000, "bg.keepalive": 3000, "junk": "x"},
            "cpu": {f"where.chat|S{i}": float(i) for i in range(300)},
            "counts": {"bridge.in": 90, "bridge.out": 90, "net.Chat": 4, "flag": True}}
    row = routes._append_energy_report("phone-1", {"kind": "probe", "cpuSeconds": 1, "hour": hour,
                                                   "backgroundExits": {"memory pressure": 2, "x": "y"}},
                                       state_dir=tmp_path)
    kept = row["hour"]
    assert kept["batteryEnd"] == 0.77 and kept["seconds"]["bg.keepalive"] == 3000.0
    assert "junk" not in kept["seconds"] and "flag" not in kept["counts"]
    assert len(kept["cpu"]) <= routes._ENERGY_MAP_KEYS
    assert row["backgroundExits"] == {"memory pressure": 2}


def test_the_hour_line_says_where_the_battery_went():
    from api import routes
    line = routes._energy_hour_line({
        "batteryStart": 0.8, "batteryEnd": 0.77,
        "seconds": {"foreground": 600, "background": 3000, "bg.keepalive": 3000, "bg.cellular": 1200},
        "cpu": {"foreground": 150, "background": 20, "where.health|Sleep": 100, "where.chat|": 50},
        "counts": {"bridge.in": 90, "bridge.out": 90, "bridge.drop": 1, "net.Chat": 4, "net.bg.Chat": 2}})
    assert "battery -3%" in line
    assert "screen 10 min / 150 s CPU" in line
    assert "kept alive 50, cellular 20" in line
    assert "top health › Sleep 100 s, chat 50 s" in line
    assert "link 180 frames, 1 drops; 4 requests" in line


def test_energy_report_summarises_pocket_drain():
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
    import phone_energy_report as report
    t = 1792000000

    def row(i, **seconds):
        return json.dumps({"kind": "probe", "hour": {"start": t + i * 3600, "end": t + (i + 1) * 3600,
                                                      "batteryStart": 0.9 - i * 0.02, "batteryEnd": 0.88 - i * 0.02,
                                                      "seconds": seconds}})
    hours = report.hours_from([row(0, background=3600, **{"bg.keepalive": 3600, "bg.wifi": 3600}),
                               row(1, background=3600, **{"bg.cellular": 3600}), "noise"])
    rates = report.summary(hours)
    assert round(rates["pocket, kept alive"][0], 3) == 2.0
    assert round(rates["pocket, suspended"][0], 3) == 2.0
    assert rates["on screen"][0] is None
    assert "+2%" not in report.row_text(hours[0], -5) and "-2%" in report.row_text(hours[0], -5)
