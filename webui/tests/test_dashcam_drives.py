"""Dashcam drive builder (api.dashcam_drives): GPS fixes -> drives, stats, thinning, GPX.

Pure functions plus rebuild() on a real DashcamStore in tmp_path. Run from webui/:
    TZ=UTC LANG=C.UTF-8 python3 -m pytest -o addopts="" -q -p no:cacheprovider tests/test_dashcam_drives.py
"""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET

import pytest

from api import dashcam_drives as dd
from api.dashcam_store import DashcamStore, now_iso

CAM = "A4-1234"
M_PER_DEG_LAT = 111_195.08  # haversine metres per degree of latitude (R = 6371008.8 m)
T0 = 1790000000.0           # 2026-09-21T14:13:20Z


def track(t0, n, *, lat0=30.0, lon0=-97.7, speed=10.0, heading=0.0, step=1.0):
    """n fixes one `step` apart, driving due north at `speed` m/s."""
    return [[t0 + i * step, lat0 + i * step * speed / M_PER_DEG_LAT, lon0, speed, heading] for i in range(n)]


def clip(cid, start_ts, *, duration=60.0, kind="normal", lens="front", camera=CAM):
    return {"id": cid, "camera_id": camera, "kind": kind, "lens": lens,
            "start": now_iso(start_ts), "duration_s": duration}


def test_haversine_one_degree_of_latitude():
    assert dd.haversine_m(0, 0, 1, 0) == pytest.approx(M_PER_DEG_LAT, rel=1e-4)


def test_clips_30_s_apart_make_one_drive():
    clips = [clip("a", T0), clip("b", T0 + 90)]
    fixes = {"a": track(T0, 60), "b": track(T0 + 90, 60, lat0=30.0 + 90 * 10 / M_PER_DEG_LAT)}
    drives = dd.build_drives(clips, fixes)
    assert len(drives) == 1
    d = drives[0]
    assert d["clip_ids"] == ["a", "b"]
    assert re.fullmatch(rf"dr_{int(T0)}_[0-9a-f]{{6}}", d["id"])
    assert dd.build_drives(clips, fixes)[0]["id"] == d["id"]       # stable across rebuilds
    assert d["camera_id"] == CAM and d["start"] == now_iso(T0) and d["end"] == now_iso(T0 + 149)


def test_clips_10_min_apart_make_two_drives():
    clips = [clip("a", T0), clip("b", T0 + 60 + 600)]
    fixes = {"a": track(T0, 60), "b": track(T0 + 660, 60, lat0=30.1)}
    drives = dd.build_drives(clips, fixes)
    assert [d["clip_ids"] for d in drives] == [["a"], ["b"]]


def test_parking_and_photo_clips_are_not_drives():
    clips = [clip("p", T0, kind="parking"), clip("ph", T0 + 10, kind="photo", duration=0)]
    assert dd.build_drives(clips, {"p": track(T0, 60), "ph": track(T0 + 10, 1)}) == []


def test_event_clips_join_the_drive_without_double_counting():
    clips = [clip("a", T0), clip("ev", T0 + 20, kind="event", duration=20)]
    fixes = {"a": track(T0, 60), "ev": track(T0, 60)[20:40]}
    d = dd.build_drives(clips, fixes)[0]
    assert d["clip_ids"] == ["a", "ev"]
    assert d["distance_m"] == pytest.approx(590, rel=0.01)


def test_rear_clips_only_fill_windows_without_a_front_clip():
    clips = [clip("f", T0), clip("r_dup", T0, lens="rear"), clip("r_fill", T0 + 70, lens="rear")]
    fixes = {"f": track(T0, 60),
             "r_dup": track(T0, 60, lon0=-97.6),   # rear GPS disagrees: must be ignored
             "r_fill": track(T0 + 70, 60, lat0=30.0 + 70 * 10 / M_PER_DEG_LAT)}
    d = dd.build_drives(clips, fixes)[0]
    assert d["clip_ids"] == ["f", "r_fill"]
    assert "r_dup" in d["other_clip_ids"]
    assert d["bounds"][1] == pytest.approx(-97.7) and d["bounds"][3] == pytest.approx(-97.7)


def test_a_one_degree_jump_is_dropped():
    fixes = track(T0, 60)
    fixes[30] = [fixes[30][0], fixes[30][1] + 1.0, fixes[30][2], 10.0, 0.0]
    cleaned = dd.clean_fixes(fixes)
    assert len(cleaned) == 59 and all(abs(f[1] - 30.0) < 0.01 for f in cleaned)
    d = dd.build_drives([clip("a", T0)], {"a": fixes})[0]
    assert d["distance_m"] == pytest.approx(590, rel=0.01)
    assert d["bounds"][2] < 30.01


def test_a_bad_first_fix_is_dropped():
    fixes = track(T0, 60)
    fixes[0] = [T0, 51.5, -0.12, 0.0, 0.0]  # London, then Texas a second later
    cleaned = dd.clean_fixes(fixes)
    assert len(cleaned) == 59 and cleaned[0][1] == pytest.approx(30.0, abs=0.01)


def test_cleaning_never_leaves_a_line_across_the_globe():
    a = track(T0, 30)
    b = track(T0 + 30, 10, lat0=-33.9, lon0=151.2)  # a stretch on the other side of the world
    cleaned = dd.clean_fixes(a + b)
    for p, q in zip(cleaned, cleaned[1:]):
        assert dd.haversine_m(p[1], p[2], q[1], q[2]) / max(q[0] - p[0], 1e-9) <= dd.MAX_IMPLIED_MPS
    assert len(cleaned) == 30


def test_a_drive_across_utc_midnight_stays_one():
    midnight = 1790035200.0  # 2026-09-22T00:00:00Z
    start = midnight - 90
    clips = [clip("a", start), clip("b", start + 65)]
    fixes = {"a": track(start, 60), "b": track(start + 65, 60, lat0=30.0 + 65 * 10 / M_PER_DEG_LAT)}
    drives = dd.build_drives(clips, fixes)
    assert len(drives) == 1 and drives[0]["start"] < "2026-09-22" < drives[0]["end"]


def test_one_km_straight_line():
    n = 101  # 100 one-second steps at 10 m/s
    d = dd.build_drives([clip("a", T0, duration=100)], {"a": track(T0, n)})[0]
    assert d["distance_m"] == pytest.approx(1000, rel=0.01)
    assert d["duration_s"] == pytest.approx(100)
    assert d["moving_s"] == pytest.approx(100)
    assert d["avg_mps"] == pytest.approx(10, rel=0.01)
    assert d["point_count"] == n


def test_avg_uses_moving_time_and_max_drops_the_top_half_percent():
    fixes = track(T0, 400)
    stopped = [[T0 + 400 + i, fixes[-1][1], fixes[-1][2], 0.0, None] for i in range(1, 201)]
    for i in (10, 20):                        # two spikes in 600 samples: the top 0.5 % is 3
        fixes[i][3] = 60.0
    d = dd.build_drives([clip("a", T0, duration=600)], {"a": fixes + stopped})[0]
    assert d["moving_s"] == pytest.approx(399)
    assert d["avg_mps"] == pytest.approx(10, rel=0.01)
    assert d["max_mps"] == pytest.approx(10)
    assert d["duration_s"] == pytest.approx(600)


def test_a_clip_without_fixes_joins_by_time_but_adds_no_distance():
    clips = [clip("a", T0), clip("nofix", T0 + 60), clip("b", T0 + 120)]
    fixes = {"a": track(T0, 60), "b": track(T0 + 120, 60, lat0=30.0 + 120 * 10 / M_PER_DEG_LAT)}
    d = dd.build_drives(clips, fixes)[0]
    assert d["clip_ids"] == ["a", "nofix", "b"]
    no_gap = dd.build_drives([clips[0], clips[2]], fixes)[0]
    assert d["distance_m"] == pytest.approx(no_gap["distance_m"])


def test_clips_without_any_gps_make_no_drive():
    clips = [clip("a", T0), clip("b", T0 + 60), clip("c", T0 + 9000)]
    drives = dd.build_drives(clips, {"c": track(T0 + 9000, 60)})
    assert [d["clip_ids"] for d in drives] == [["c"]]


def test_wrong_camera_clock_uses_gps_time():
    # Before the first time sync the camera thinks it is 2020; the GPS time is right.
    clips = [clip("a", T0), clip("b", 1580000000.0)]
    fixes = {"a": track(T0, 60), "b": track(T0 + 61, 60, lat0=30.0 + 61 * 10 / M_PER_DEG_LAT)}
    drives = dd.build_drives(clips, fixes)
    assert len(drives) == 1 and drives[0]["clip_ids"] == ["a", "b"]


def test_drives_are_per_camera():
    clips = [clip("a", T0), clip("b", T0 + 30, camera="other")]
    fixes = {"a": track(T0, 60), "b": track(T0 + 30, 60, lat0=40.0)}
    assert sorted(d["camera_id"] for d in dd.build_drives(clips, fixes)) == [CAM, "other"]


def test_polyline_is_thinned_and_keeps_both_ends():
    fixes = track(T0, 5000)
    d = dd.build_drives([clip("a", T0, duration=5000)], {"a": fixes})[0]
    line = dd.drive_polyline(d, {"a": fixes}, limit=100)
    assert 2 <= len(line) <= 100
    assert line[0] == [fixes[0][1], fixes[0][2], fixes[0][3], fixes[0][0]]
    assert line[-1] == [fixes[-1][1], fixes[-1][2], fixes[-1][3], fixes[-1][0]]
    assert len(dd.drive_polyline(d, {"a": fixes[:50]}, limit=100)) == 50


def test_gpx_parses_with_times_and_speeds():
    fixes = track(T0, 30)
    d = dd.build_drives([clip("a", T0)], {"a": fixes})[0]
    root = ET.fromstring(dd.drive_gpx(d, {"a": fixes}))
    ns = {"g": "http://www.topografix.com/GPX/1/1"}
    assert root.tag == "{http://www.topografix.com/GPX/1/1}gpx" and root.get("version") == "1.1"
    pts = root.findall(".//g:trk/g:trkseg/g:trkpt", ns)
    assert len(pts) == 30
    assert pts[0].find("g:time", ns).text == now_iso(T0)
    assert float(pts[0].get("lat")) == pytest.approx(30.0)
    assert "10" in ET.tostring(pts[0], encoding="unicode").split("speed>")[1]


def test_rebuild_writes_drives_and_sets_clip_drive_ids(tmp_path):
    store = DashcamStore(tmp_path)
    store.apply_inventory(CAM, [
        {"path": "/sd/a.MP4", "kind": "normal", "lens": "front", "start": now_iso(T0), "duration": 60, "size": 1},
        {"path": "/sd/b.MP4", "kind": "normal", "lens": "front", "start": now_iso(T0 + 60), "duration": 60, "size": 1},
        {"path": "/sd/p.MP4", "kind": "parking", "lens": "front", "start": now_iso(T0 + 9000), "duration": 60,
         "size": 1},
    ])
    a, b, p = (DashcamStore.clip_id(CAM, f"/sd/{n}.MP4") for n in ("a", "b", "p"))
    store.put_fixes(a, track(T0, 60))
    store.put_fixes(b, track(T0 + 60, 60, lat0=30.0 + 60 * 10 / M_PER_DEG_LAT))
    drives = dd.rebuild(store)
    assert len(drives) == 1 and store.drives()[0]["id"] == drives[0]["id"]
    assert store.get_clip(a)["drive_id"] == drives[0]["id"] == store.get_clip(b)["drive_id"]
    assert store.get_clip(p)["drive_id"] is None
    # A clip that stops belonging to a drive loses its drive_id on the next rebuild.
    store.put_fixes(b, track(T0 + 5000, 60, lat0=31.0))
    store.apply_inventory(CAM, [
        {"path": "/sd/b.MP4", "kind": "parking", "lens": "front", "start": now_iso(T0 + 60), "duration": 60,
         "size": 1}])
    dd.rebuild(store)
    assert store.get_clip(b)["drive_id"] is None


def test_polyline_points_carry_their_time():
    fixes = [[1_790_000_000 + i, 41.0 + i * 1e-4, -87.0, 10.0, 90.0] for i in range(5)]
    d = {"id": "dr", "clip_ids": ["a"], "start": "2026-09-21T13:46:40Z", "end": "2026-09-21T13:46:44Z"}
    line = dd.drive_polyline(d, {"a": fixes}, limit=100)
    assert [p[3] for p in line] == [f[0] for f in fixes]
    assert line[0][:3] == [41.0, -87.0, 10.0]


def test_drive_ids_of_cameras_sharing_a_prefix_never_collide():
    a, b = "Affver-A4-0001", "Affver-A4-0002"     # same first six characters
    clips = [clip("a", T0, camera=a), clip("b", T0, camera=b)]
    fixes = {"a": track(T0, 60), "b": track(T0, 60, lat0=40.0)}
    ids = [d["id"] for d in dd.build_drives(clips, fixes)]
    assert len(ids) == 2 and len(set(ids)) == 2
    route = re.compile(r"^dr_[0-9]+_[A-Za-z0-9_-]{0,6}$")   # what /drives/<id> accepts
    assert all(route.match(i) for i in ids)


@pytest.mark.parametrize("t,expected", [
    (1759351200.0, "2025-10-01T20:40:00Z"),
    (1759351200.5, "2025-10-01T20:40:00.500Z"),
    (1759351200.0004, "2025-10-01T20:40:00Z"),
    (1759351200.0006, "2025-10-01T20:40:00.001Z"),
    (1759351200.9996, "2025-10-01T20:40:01Z"),       # rounds up into the next second, never ".1000Z"
    (1759351259.9999, "2025-10-01T20:41:00Z"),
])
def test_gpx_time_rounds_to_milliseconds(t, expected):
    assert dd._gpx_time(t) == expected
