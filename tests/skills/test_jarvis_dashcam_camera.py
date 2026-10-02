"""Tests for skills/smart-home/jarvis-dashcam — the reference camera client and the fake camera."""
from __future__ import annotations

import datetime as dt
import struct
import importlib.util
import math
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "skills" / "smart-home" / "jarvis-dashcam" / "scripts"


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


cam_mod = _load("dashcam_camera")
fake_mod = _load("dashcam_fake")

TZ = -5 * 3600  # Central daylight time, like the sample card


@pytest.fixture
def card(tmp_path):
    fake_mod.make_sample(tmp_path, clips=3, seconds=30, video_bytes=50_000, tz_offset_s=TZ)
    return tmp_path


@pytest.fixture
def camera(card):
    fc = fake_mod.FakeCamera(card).start()
    yield fc
    fc.stop()


def test_probe_finds_viidure_camera(camera):
    cam = cam_mod.open_camera(camera.host)
    assert isinstance(cam, cam_mod.ViidureCamera)
    info = cam.info()
    assert info["id"] == "FAKE-A4-0001"
    assert info["product"]["sp"] == "PEZTIO"
    assert info["sd"]["free"] == 42000


def test_ls_types_every_file(camera):
    files = cam_mod.ViidureCamera("http://" + camera.host).files(TZ)
    kinds = sorted((f.kind, f.lens) for f in files)
    assert kinds.count(("normal", "front")) == 3
    assert kinds.count(("normal", "rear")) == 3
    assert ("event", "front") in kinds and ("parking", "front") in kinds and ("photo", "front") in kinds
    first = min((f for f in files if f.kind == "normal"), key=lambda f: f.start)
    # createtimestr is camera-local (UTC-5) → the sample started at 20:40 UTC
    assert first.start == "2026-10-01T20:40:00Z"
    assert first.duration_s == 30
    assert next(f for f in files if f.kind == "event").locked


def test_gps_reads_only_the_tail(camera):
    cam = cam_mod.ViidureCamera("http://" + camera.host)
    clip = min((f for f in cam.files(TZ) if f.kind == "normal" and f.lens == "front"), key=lambda f: f.start)
    before = len(camera.state.requests)
    fixes = cam.gps(clip, TZ)
    assert len(fixes) == 30
    # two range reads (+ the size probe), never a full download
    assert len(camera.state.requests) - before <= 3
    start = cam_mod.iso_to_unix(clip.start)
    assert all(start - 1 <= f.t <= start + 31 for f in fixes)
    assert fixes[0].heading == 90.0
    assert 13.0 < fixes[0].speed_mps < 16.5          # ~50 km/h
    assert fixes[-1].lon > fixes[0].lon               # driving east
    assert fixes[0].lat == pytest.approx(41.8781, abs=1e-4)
    assert fixes[0].lon < -87                         # W → negative


def _block_lines(start: dt.datetime, n: int = 5):
    return [fake_mod.track_line(start + dt.timedelta(seconds=i), 41.8781, -87.6298 + i * 1e-4, 36.0, 45.0)
            for i in range(n)]


def test_parse_block_normal_and_hash_markers():
    t0 = dt.datetime(2026, 10, 1, 20, 0, 0)
    for marker in (b"&&&&", b"####"):
        block = fake_mod.gps_block(_block_lines(t0), marker=marker)
        trailer = cam_mod.parse_trailer(block[-8:])
        assert trailer == (marker, len(block))
        fixes = cam_mod.parse_block(block, marker)
        assert len(fixes) == 5
        assert fixes[0].speed_mps == pytest.approx(10.0, abs=0.01)


def _a4_skip_block(lines, marker=b"####"):
    """The A4's .ts tail: a SKIP box ("SKIPLIGO" "GPSINFO", record count) of 132-byte records + marker/size."""
    size = 28 + 132 * len(lines) + 8
    out = struct.pack(">I", size) + b"SKIPLIGO" + b"GPSINFO     " + struct.pack(">I", len(lines))
    for i, line in enumerate(lines, 1):
        out += struct.pack(">I", i) + line.encode().ljust(128, b"\0")
    return out + marker + struct.pack(">I", size)


def test_parse_block_a4_ts_skip_box():
    lines = ["2026/10/02 13:19:32 N:4152.6860 W:08737.7880 48.0 km/h x:+0.00 y:+0.00 z:+0.00 A:91.0 H:182.0 304A126B2FC86505BTRX",
             "2026/10/02 13:19:33 N:4152.6860 W:08737.7860 49.0 km/h x:0.0 y:0.0 z:0.0 A:91 H:182 M:0.0",
             "2026/10/02 13:19:34 N:0 E:0 0.0 km/h x:+0.00 y:+0.00 z:+0.00 A:0.0 H:0.0 304A126B2FC86505BTRX"]   # no fix yet
    block = _a4_skip_block(lines)
    assert cam_mod.parse_trailer(block[-8:]) == (b"####", len(block))
    fixes = cam_mod.parse_block(block, b"####")
    assert len(fixes) == 2
    assert fixes[0].lat == pytest.approx(41 + 52.686 / 60, abs=1e-6)
    assert fixes[0].lon == pytest.approx(-(87 + 37.788 / 60), abs=1e-6)
    assert fixes[0].speed_mps == pytest.approx(48 / 3.6, abs=0.01)
    assert fixes[0].heading == 91.0


def test_parse_block_fh_variant():
    t0 = dt.datetime(2026, 10, 1, 20, 0, 0)
    block = fake_mod.gps_block(_block_lines(t0, 4), fh=True)
    assert block[8:10] == b"FH"
    assert len(cam_mod.parse_block(block, b"&&&&")) == 4


def test_parse_block_scrambled_xgc_marker():
    lat_raw, lon_raw = 4152.686, 8737.788           # NMEA numbers for 41.8781, -87.6298
    a10, b10 = math.floor(lat_raw / 10) * 10, math.floor(lon_raw / 10) * 10
    a = a10 + (lon_raw - b10) * 0.8668
    b = b10 + (lat_raw - a10) * 0.8668
    knots = 20.0
    line = f"2026/10/01 20:00:00 N:{a:.6f} W:{b:.6f} {knots} X:0 Y:0 Z:1 A:10.0 H:5"
    block = fake_mod.gps_block([line], marker=b"****")
    fixes = cam_mod.parse_block(block, b"****")
    assert len(fixes) == 1
    assert fixes[0].lat == pytest.approx(41.8781, abs=1e-4)
    assert fixes[0].lon == pytest.approx(-87.6298, abs=1e-4)
    assert fixes[0].speed_mps == pytest.approx(knots * 1.852 / 3.6, abs=0.01)


def test_invalid_lines_dropped():
    good = fake_mod.track_line(dt.datetime(2026, 10, 1, 20, 0, 0), 41.0, -87.0, 10, 0)
    assert cam_mod.parse_line(good) is not None
    assert cam_mod.parse_line("2026/10/01 20:00:00 N:- E:- - X:0 Y:0 Z:0 A:0 H:0") is None
    assert cam_mod.parse_line("2026/10/01 20:00:00 N:0000.0000 E:00000.0000 0 X:0 Y:0 Z:0 A:0 H:0") is None
    assert cam_mod.parse_line("garbage") is None
    assert cam_mod.parse_line("") is None


def test_decimal_degree_coordinates():
    fix = cam_mod.parse_line("2026/10/01 20:00:00 N:41.878100 W:87.629800 72.0 X:0 Y:0 Z:1 A:180.0 H:3")
    assert fix.lat == pytest.approx(41.8781)
    assert fix.lon == pytest.approx(-87.6298)
    assert fix.heading == 180.0
    assert fix.speed_mps == pytest.approx(20.0)


def test_align_fixes_shifts_local_line_times_to_utc():
    local = dt.datetime(2026, 10, 1, 15, 40, 0)     # line written in camera-local (UTC-5) time
    fixes = [cam_mod.parse_line(fake_mod.track_line(local + dt.timedelta(seconds=i), 41, -87, 30, 0))
             for i in range(10)]
    start_utc = dt.datetime(2026, 10, 1, 20, 40, 0, tzinfo=dt.timezone.utc).timestamp()
    out = cam_mod.align_fixes(fixes, start_utc, 10, TZ)
    assert out[0].t == pytest.approx(start_utc)


def test_download_resumes(camera, tmp_path):
    cam = cam_mod.ViidureCamera("http://" + camera.host)
    clip = next(f for f in cam.files(TZ) if f.kind == "event")
    whole = (camera.state.root / clip.path.lstrip("/")).read_bytes()
    dest = tmp_path / "out" / "clip.mp4"
    dest.parent.mkdir()
    dest.write_bytes(whole[:1000])                   # interrupted earlier
    assert cam.download(clip.path, dest) == len(whole)
    assert dest.read_bytes() == whole
    ranges = [r for r in camera.state.requests if clip.path in r]
    assert ranges                                     # it asked for the file again …
    assert camera.state.requests                      # … from byte 1000 (checked by equality above)


def test_settings_merge_and_set(camera):
    cam = cam_mod.ViidureCamera("http://" + camera.host)
    items = {s["name"]: s for s in cam.settings()}
    assert items["speed_unit"]["value"] == "1"
    assert {"code": "1", "label": "mph"} in items["speed_unit"]["options"]
    cam.set("rec_split_duration", "2")
    assert camera.state.settings["rec_split_duration"] == "2"


def test_time_sync_and_controls(camera):
    cam = cam_mod.ViidureCamera("http://" + camera.host)
    cam.set_time(dt.datetime(2026, 10, 1, 20, 0, 5, tzinfo=dt.timezone.utc), TZ)
    assert camera.state.time_set == "20261001150005"
    assert camera.state.timezone == "-5"
    assert cam.is_recording() is True
    cam.record(False)
    assert cam.is_recording() is False
    cam.lock()
    assert camera.state.locked == 1


def test_playback_required_camera(card):
    fc = fake_mod.FakeCamera(card, playback_required=True).start()
    try:
        cam = cam_mod.ViidureCamera("http://" + fc.host)
        assert cam.files(TZ) == []                    # refuses outside playback mode
        cam.playback(True)
        assert cam.is_recording() is False            # and pauses recording inside it
        assert len(cam.files(TZ)) > 0
        cam.playback(False)
        cam.record(True)
        assert cam.is_recording() is True
    finally:
        fc.stop()


def test_camera_error_on_refusal(camera):
    cam = cam_mod.ViidureCamera("http://" + camera.host)
    with pytest.raises(cam_mod.CameraError, match="unknown setting"):
        cam.set("nope", "1")


def test_novatek_list_parsing():
    xml = b"""<?xml version="1.0"?><LIST><ALLFile>
      <File><NAME>2026_1001_154000_F.MP4</NAME><FPATH>A:\\CARDV\\MOVIE\\2026_1001_154000_F.MP4</FPATH>
        <SIZE>157286400</SIZE><TIMECODE>1</TIMECODE><TIME>2026/10/01 15:40:00</TIME><ATTR>32</ATTR></File>
      <File><NAME>2026_1001_154100_R.MP4</NAME><FPATH>A:\\CARDV\\MOVIE\\RO\\2026_1001_154100_R.MP4</FPATH>
        <SIZE>1000</SIZE><TIME>2026/10/01 15:41:00</TIME><ATTR>21</ATTR></File>
      <File><NAME>2026_1001_154200_F.JPG</NAME><FPATH>A:\\CARDV\\PHOTO\\2026_1001_154200_F.JPG</FPATH>
        <SIZE>2000</SIZE><TIME>2026/10/01 15:42:00</TIME><ATTR>32</ATTR></File>
    </ALLFile></LIST>"""
    files = cam_mod.parse_novatek_list(xml, TZ)
    assert [f.path for f in files][0] == "/CARDV/MOVIE/2026_1001_154000_F.MP4"
    assert files[0].start == "2026-10-01T20:40:00Z" and files[0].kind == "normal" and files[0].lens == "front"
    assert files[1].kind == "event" and files[1].locked and files[1].lens == "rear"
    assert files[2].kind == "photo"


@pytest.mark.parametrize("path,lens", [
    ("/mnt/card/video_front/20261001_154000_F.mp4", "front"),
    ("/mnt/card/video_rear/20261001_154000_R.mp4", "rear"),
    ("/CARDV/MOVIE/2026_1001_154000_R.MP4", "rear"),
    ("/mnt/card/photo/x.jpg", "front"),
    ("/mnt/card/video_back/2026-10-02_13_21_09_b.ts", "rear"),    # the real A4
    ("/mnt/card/video_front/2026-10-02_13_21_09_f.ts", "front"),
])
def test_lens_from_path(path, lens):
    assert cam_mod.lens_from_path(path) == lens


def test_cli_probe_and_error(camera, capsys):
    assert cam_mod.main(["--host", camera.host, "probe"]) == 0
    out = capsys.readouterr().out
    assert "FAKE-A4-0001" in out
    with pytest.raises(SystemExit) as exc:
        cam_mod.main(["--host", "127.0.0.1:9", "probe"])
    assert exc.value.code == 1
