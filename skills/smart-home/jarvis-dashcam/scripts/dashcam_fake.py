#!/usr/bin/env python3
"""JarvisCopilot — a fake Viidure dashcam for tests and the simulator.

Serves the Viidure ``/app/`` API (see ``../references/protocol.md``) from a folder that looks
like the camera's SD card, with GPS + speed blocks at the end of every video file, range reads,
thumbnails and settings. ``--playback-required`` makes the file list refuse to answer outside
playback mode and pauses recording in playback mode, the worst case Jarvis has to handle.

    python3 dashcam_fake.py make-sample /tmp/fakecam --clips 6
    python3 dashcam_fake.py serve /tmp/fakecam --port 8099
    python3 dashcam_camera.py --host 127.0.0.1:8099 ls

Stdlib only. ``FakeCamera(root).start()`` gives tests a running camera on a free port.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import struct
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SD = "/mnt/card"
FOLDERS = {"loop": "video_front", "loop_r": "video_rear", "park": "park", "event": "event",
           "emr": "emr", "photo": "photo"}
# A minimal valid JPEG (1×1 grey); clients treat anything under 100 bytes as "no thumbnail".
JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300080606070605080707070909080a0c140d0c0b0b0c19"
    "12130f141d1a1f1e1d1a1c1c20242e2720222c231c1c2837292c30313434341f27393d38323c2e333432ffc0000b08"
    "0001000101011100ffc4001f0000010501010101010100000000000000000102030405060708090a0bffc400b51000"
    "02010303020403050504040000017d01020300041105122131410613516107227114328191a1082342b1c11552d1f0"
    "2433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768"
    "696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3"
    "c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9faffda0008010100003f00fb"
    "d0ffd9")


# ── sample SD card ───────────────────────────────────────────────────────────

def nmea(value: float, is_lat: bool) -> str:
    deg = int(abs(value))
    minutes = (abs(value) - deg) * 60
    return f"{deg:02d}{minutes:07.4f}" if is_lat else f"{deg:03d}{minutes:07.4f}"


def track_line(t: dt.datetime, lat: float, lon: float, kmh: float | None, heading: float) -> str:
    """10-field Viidure line: date time N: E: speed X: Y: Z: A: H:."""
    ns = "N" if lat >= 0 else "S"
    ew = "E" if lon >= 0 else "W"
    speed = "-" if kmh is None else f"{kmh:.1f}"
    return (f"{t:%Y/%m/%d %H:%M:%S} {ns}:{nmea(lat, True)} {ew}:{nmea(lon, False)} {speed} "
            f"X:0.01 Y:-0.02 Z:0.98 A:{heading:.1f} H:182")


def gps_block(lines: list[str], marker: bytes = b"&&&&", fh: bool = False) -> bytes:
    """``free`` box + 132-byte records + ``<marker><size>`` trailer (protocol.md §5)."""
    records = bytearray()
    for i, line in enumerate(lines):
        raw = line.encode("ascii")[:127]
        if fh:
            records += raw + b"\x00" * (132 - len(raw))
        else:
            records += struct.pack(">I", i) + raw + b"\x00" * (128 - len(raw))
    head_pad = 20 + (64 if fh else 0)
    size = 8 + head_pad + len(records) + 8
    body = struct.pack(">I", size) + b"free" + (b"FH" if fh else b"\x00\x00") + b"\x00" * (head_pad - 2)
    return body + bytes(records) + marker + struct.pack(">I", size)


def make_sample(root: Path, *, clips: int = 6, start: dt.datetime | None = None, seconds: int = 60,
                lat: float = 41.8781, lon: float = -87.6298, kmh: float = 50.0, video_bytes: int = 200_000,
                tz_offset_s: int = -5 * 3600, rear: bool = True, gap_after: int | None = None) -> list[dict]:
    """Write a fake card: ``clips`` consecutive front (+rear) clips driving east, one locked event
    clip, one parking clip and one photo. Returns the manifest (also saved as ``manifest.json``)."""
    start = start or dt.datetime(2026, 10, 1, 20, 40, 0, tzinfo=dt.timezone.utc)
    tz = dt.timezone(dt.timedelta(seconds=tz_offset_s))
    manifest: list[dict] = []
    m_per_deg_lon = 111_320 * math.cos(math.radians(lat))
    t = start
    cur_lon = lon

    def write(folder_key: str, name: str, payload: bytes, kind: str, duration: int, created: dt.datetime) -> None:
        rel = f"{SD}/{FOLDERS[folder_key]}/{name}"
        path = root / rel.lstrip("/")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        # The app lists only loop/park/event/emr/race and tells photos apart by type (protocol.md §3),
        # so photos are served from the event folder's list.
        listed = "event" if folder_key == "photo" else folder_key.split("_")[0]
        manifest.append({"path": rel, "folder": listed, "kind": kind,
                         "type": 1 if kind == "photo" else 2, "duration": duration,
                         "createtimestr": created.astimezone(tz).strftime("%Y%m%d%H%M%S"),
                         "size_bytes": len(payload)})

    for i in range(clips):
        if gap_after is not None and i == gap_after:
            t += dt.timedelta(minutes=12)
        lines = []
        for s in range(seconds):
            when = t + dt.timedelta(seconds=s)
            cur_lon += (kmh / 3.6) / m_per_deg_lon
            lines.append(track_line(when, lat, cur_lon, kmh + (s % 7), 90.0))
        payload = os.urandom(video_bytes) + gps_block(lines)
        stamp = t.astimezone(tz).strftime("%Y%m%d_%H%M%S")
        write("loop", f"{stamp}_F.mp4", payload, "normal", seconds, t)
        if rear:
            write("loop_r", f"{stamp}_R.mp4", os.urandom(video_bytes // 2) + gps_block(lines), "normal", seconds, t)
        t += dt.timedelta(seconds=seconds)
    ev_lines = [track_line(t + dt.timedelta(seconds=s), lat, cur_lon, kmh, 90.0) for s in range(20)]
    write("emr", f"{t.astimezone(tz):%Y%m%d_%H%M%S}_F.mp4", os.urandom(video_bytes // 2) + gps_block(ev_lines),
          "event", 20, t)
    park_t = t + dt.timedelta(hours=1)
    write("park", f"{park_t.astimezone(tz):%Y%m%d_%H%M%S}_F.mp4",
          os.urandom(video_bytes // 4) + gps_block([track_line(park_t, lat, cur_lon, 0, 0)]),
          "parking", 30, park_t)
    write("photo", f"{t.astimezone(tz):%Y%m%d_%H%M%S}_F.jpg", JPEG, "photo", 0, t)
    (root / "manifest.json").write_text(json.dumps({"files": manifest, "tz_offset_s": tz_offset_s}, indent=1))
    return manifest


# ── server ───────────────────────────────────────────────────────────────────

SETTING_ITEMS = [
    {"name": "rec_resolution", "index": ["0", "1", "2"], "items": ["4K+2.5K", "2.5K+1080P", "1080P+1080P"]},
    {"name": "rec_split_duration", "index": ["0", "1", "2"], "items": ["1 min", "2 min", "3 min"]},
    {"name": "gsr_sensitivity", "index": ["0", "1", "2", "3"], "items": ["Off", "Low", "Medium", "High"]},
    {"name": "mic", "index": ["0", "1"], "items": ["Off", "On"]},
    {"name": "speed_unit", "index": ["0", "1"], "items": ["km/h", "mph"]},
    {"name": "parking_monitor", "index": ["0", "1"], "items": ["Off", "On"]},
]


class CameraState:
    def __init__(self, root: Path, playback_required: bool = False):
        self.root = root
        self.playback_required = playback_required
        self.recording = True
        self.playback = False
        self.locked = 0
        self.time_set: str | None = None
        self.timezone: str | None = None
        self.settings = {"rec_resolution": "0", "rec_split_duration": "1", "gsr_sensitivity": "1",
                         "mic": "1", "speed_unit": "1", "parking_monitor": "1"}
        self.lock = threading.Lock()
        self.requests: list[str] = []

    def manifest(self) -> list[dict]:
        try:
            doc = json.loads((self.root / "manifest.json").read_text())
        except (OSError, json.JSONDecodeError):
            return []
        return [f for f in doc.get("files", []) if (self.root / f["path"].lstrip("/")).exists()]


def make_handler(state: CameraState):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):  # quiet
            pass

        def _json(self, result: int, info) -> None:
            body = json.dumps({"result": result, "info": info}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _empty(self, status: int, extra: dict | None = None) -> None:
            self.send_response(status)
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _bytes(self, data: bytes, ctype: str, head: bool = False) -> None:
            rng = self.headers.get("Range")
            start, end, status = 0, len(data) - 1, 200
            if rng:
                m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
                if not m or (not m.group(1) and not m.group(2)):
                    return self._empty(416)
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else len(data) - 1
                else:
                    start = max(0, len(data) - int(m.group(2)))
                end = min(end, len(data) - 1)
                if start > end:
                    return self._empty(416, {"Content-Range": f"bytes */{len(data)}"})
                status = 206
            chunk = data[start:end + 1]
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(chunk)))
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.end_headers()
            if not head:
                self.wfile.write(chunk)

        def do_HEAD(self):
            self.do_GET(head=True)

        def do_GET(self, head: bool = False):
            parsed = urllib.parse.urlparse(self.path)
            q = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
            with state.lock:
                state.requests.append(self.path)
            if parsed.path.startswith("/app/"):
                return self._app(parsed.path[5:], q)
            target = state.root / urllib.parse.unquote(parsed.path).lstrip("/")
            if not target.resolve().is_relative_to(state.root.resolve()) or not target.is_file():
                return self._empty(404)
            ctype = "image/jpeg" if target.suffix.lower() == ".jpg" else "video/mp4"
            return self._bytes(target.read_bytes(), ctype, head)

        def _app(self, cmd: str, q: dict) -> None:
            s = state
            if cmd == "getdeviceattr":
                return self._json(0, {"uuid": "FAKE-A4-0001", "softver": "V1.0.fake", "hwver": "A4",
                                      "bssid": "aa:bb:cc:dd:ee:ff", "camnum": 2, "curcamid": 0})
            if cmd == "getproductinfo":
                return self._json(0, {"model": "A4", "company": "Affver", "sp": "PEZTIO", "soc": "eeasytech"})
            if cmd == "getmediainfo":
                return self._json(0, {"rtsp": "rtsp://127.0.0.1:554/live", "port": 5000, "page": 1,
                                      "autorecord": 1})
            if cmd == "getsdinfo":
                return self._json(0, {"status": 0, "total": 60000, "free": 42000})
            if cmd == "getbatteryinfo":
                return self._json(0, {"capacity": 100, "charge": 1})
            if cmd == "getparamitems":
                return self._json(0, SETTING_ITEMS)
            if cmd == "getparamvalue":
                if q.get("param") == "rec":
                    return self._json(0, {"value": 1 if s.recording else 0})
                return self._json(0, [{"name": k, "value": v} for k, v in s.settings.items()]
                                  + [{"name": "rec", "value": 1 if s.recording else 0}])
            if cmd == "setparamvalue":
                name, value = q.get("param", ""), q.get("value", "")
                if name == "rec":
                    s.recording = value == "1"
                elif name in s.settings:
                    s.settings[name] = value
                else:
                    return self._json(-1, f"unknown setting {name}")
                return self._json(0, None)
            if cmd == "setsystime":
                s.time_set = q.get("date")
                return self._json(0, None) if re.fullmatch(r"\d{14}", s.time_set or "") else self._json(-1, "bad date")
            if cmd == "settimezone":
                s.timezone = q.get("timezone")
                return self._json(0, None)
            if cmd == "playback":
                s.playback = q.get("param") == "enter"
                if s.playback_required and s.playback:
                    s.recording = False
                return self._json(0, None)
            if cmd == "getfilelist":
                if s.playback_required and not s.playback:
                    return self._json(-3, "not in playback mode")
                return self._json(0, self._list(q.get("folder", "loop"), int(q.get("start", 0)), int(q.get("end", 99))))
            if cmd == "deletefile":
                target = s.root / urllib.parse.unquote(q.get("file", "")).lstrip("/")
                if target.is_file() and target.resolve().is_relative_to(s.root.resolve()):
                    target.unlink()
                    return self._json(0, None)
                return self._json(-1, "no such file")
            if cmd == "lockvideo":
                s.locked += 1
                return self._json(0, None)
            if cmd == "snapshot":
                return self._json(0, {"name": f"{SD}/photo/snap.jpg"})
            if cmd == "getthumbnail":
                return self._bytes(JPEG + b"\x00" * 64, "image/jpeg")
            if cmd in ("setting", "setwifi", "sdformat", "wifireboot", "capability"):
                return self._json(0, None)
            return self._json(-1, f"unknown command {cmd}")

        def _list(self, folder: str, start: int, end: int) -> list:
            files = sorted((f for f in state.manifest() if f["folder"] == folder), key=lambda f: f["path"])
            page = files[start:end + 1]
            return [{"folder": folder, "count": len(files), "files": [
                {"name": f["path"], "createtimestr": f["createtimestr"],
                 "size": max(1, math.ceil((state.root / f["path"].lstrip("/")).stat().st_size / 1024)),
                 "type": f["type"], "duration": f["duration"]} for f in page]}]

    return Handler


class FakeCamera:
    def __init__(self, root: Path, port: int = 0, playback_required: bool = False):
        self.state = CameraState(Path(root), playback_required)
        self.server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(self.state))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def host(self) -> str:
        return f"127.0.0.1:{self.server.server_address[1]}"

    def start(self) -> "FakeCamera":
        self.thread.start()
        return self

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Fake Viidure dashcam.")
    sub = p.add_subparsers(dest="cmd", required=True)
    mk = sub.add_parser("make-sample")
    mk.add_argument("root")
    mk.add_argument("--clips", type=int, default=6)
    mk.add_argument("--seconds", type=int, default=60)
    mk.add_argument("--video-bytes", type=int, default=200_000)
    sv = sub.add_parser("serve")
    sv.add_argument("root")
    sv.add_argument("--port", type=int, default=8099)
    sv.add_argument("--host", default="127.0.0.1")
    sv.add_argument("--playback-required", action="store_true")
    args = p.parse_args(argv)
    if args.cmd == "make-sample":
        files = make_sample(Path(args.root), clips=args.clips, seconds=args.seconds, video_bytes=args.video_bytes)
        print(json.dumps({"files": len(files), "root": args.root}))
        return 0
    state = CameraState(Path(args.root), args.playback_required)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    print(json.dumps({"serving": f"http://{args.host}:{args.port}", "root": args.root}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
