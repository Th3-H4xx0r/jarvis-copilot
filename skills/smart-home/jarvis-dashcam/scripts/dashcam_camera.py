#!/usr/bin/env python3
"""JarvisCopilot — reference client for Viidure-family dashcams (Peztio, Affver, …).

Talks straight to the camera over its own Wi‑Fi, the way the phone app does, so the protocol
in ``../references/protocol.md`` can be checked from a Mac: join the camera's Wi‑Fi, then

    python3 dashcam_camera.py probe                      # which family, ids, firmware, SD card
    python3 dashcam_camera.py ls [--kind event]          # every clip and photo
    python3 dashcam_camera.py gps /mnt/card/....mp4      # GPS + speed from the file's tail
    python3 dashcam_camera.py get /mnt/card/....mp4 -o clip.mp4
    python3 dashcam_camera.py thumb /mnt/card/....mp4 -o thumb.jpg
    python3 dashcam_camera.py settings | set rec_split_duration 1
    python3 dashcam_camera.py time-sync | lock | snapshot | record on|off
    python3 dashcam_camera.py --record-fixtures fixtures/ probe   # also saves raw replies

JSON on stdout; ``{"error": ...}`` on stderr and exit code 1 on failure. Stdlib only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import re
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, NoReturn

VIIDURE_HOST = "192.168.169.1"
NOVATEK_HOST = "192.168.1.254"
# Other families are only recognised, not driven (see protocol.md §1).
DETECTORS = (
    ("viidure", VIIDURE_HOST, "/app/getdeviceattr"),
    ("novatek", NOVATEK_HOST, "/?custom=1&cmd=3029"),
    ("hisilicon", "192.168.0.1", "/cgi-bin/hisnet/getwifi.cgi?"),
    ("allwinner", "192.168.10.1:8082", "/api/getdeviceinfo/?custom=1&cmd=2001"),
    ("mstar", "192.72.1.1", "/cgi-bin/Config.cgi?action=get&property=Camera.Menu.*"),
    ("huiying", "192.168.201.1", "/?cmd=302&param=network_ap"),
)
VIIDURE_FOLDERS = ("loop", "park", "event", "emr", "race")
PAGE = 100
GPS_MARKERS = (b"&&&&", b"####", b"****")
GPS_RECORD = 132
GPS_HEADER = 28
KMH = 1 / 3.6


class CameraError(Exception):
    """The camera refused a request or could not be reached."""


@dataclass
class CamFile:
    path: str
    kind: str          # normal | event | parking | photo
    lens: str          # front | rear | inside
    start: str         # ISO-8601 UTC
    duration_s: float
    size: int
    locked: bool = False
    folder: str = ""
    gps_path: str = ""

    @property
    def name(self) -> str:
        return self.path.rsplit("/", 1)[-1]


@dataclass
class Fix:
    t: float           # unix seconds
    lat: float
    lon: float
    speed_mps: float | None
    heading: float | None

    def row(self) -> list:
        return [round(self.t, 1), round(self.lat, 7), round(self.lon, 7),
                None if self.speed_mps is None else round(self.speed_mps, 2),
                None if self.heading is None else round(self.heading, 1)]


@dataclass
class Fixtures:
    """Optionally saves every raw reply so tests can replay a real camera."""
    root: Path | None = None
    count: int = field(default=0)

    def save(self, label: str, data: bytes) -> None:
        if not self.root:
            return
        self.root.mkdir(parents=True, exist_ok=True)
        self.count += 1
        safe = re.sub(r"[^A-Za-z0-9_.=-]+", "_", label)[:80]
        (self.root / f"{self.count:03d}_{safe}").write_bytes(data)


# ── HTTP ─────────────────────────────────────────────────────────────────────

def _http(url: str, *, timeout: float, headers: dict | None = None, method: str = "GET") -> tuple[int, dict, bytes]:
    req = urllib.request.Request(url, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers.items()) if e.headers else {}, e.read() or b""
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        raise CameraError(f"camera not reachable at {url.split('/')[2]}: {e}") from e


def _range_total(headers: dict) -> int | None:
    cr = next((v for k, v in headers.items() if k.lower() == "content-range"), "")
    m = re.match(r"bytes \d+-\d+/(\d+)", cr)
    return int(m.group(1)) if m else None


class _Base:
    family = "unknown"

    def __init__(self, base: str, timeout: float = 6.0, fixtures: Fixtures | None = None):
        self.base = base.rstrip("/")
        if "://" not in self.base:
            self.base = "http://" + self.base
        self.timeout = timeout
        self.fixtures = fixtures or Fixtures()

    def url(self, path: str) -> str:
        return self.base + urllib.parse.quote(path, safe="/:?&=%")

    def size(self, path: str) -> int:
        status, headers, _ = _http(self.url(path), timeout=self.timeout, headers={"Range": "bytes=0-0"})
        total = _range_total(headers)
        if status == 206 and total is not None:
            return total
        status, headers, _ = _http(self.url(path), timeout=self.timeout, method="HEAD")
        length = next((v for k, v in headers.items() if k.lower() == "content-length"), None)
        if status == 200 and length is not None:
            return int(length)
        raise CameraError(f"cannot size {path} (HTTP {status})")

    def read_range(self, path: str, start: int, length: int) -> bytes:
        status, _, body = _http(self.url(path), timeout=self.timeout,
                                headers={"Range": f"bytes={start}-{start + length - 1}"})
        if status not in (200, 206):
            raise CameraError(f"range read of {path} failed (HTTP {status})")
        if status == 200:  # server ignored Range
            body = body[start:start + length]
        return body

    def download(self, path: str, dest: Path, *, chunk: int = 1 << 20) -> int:
        """Download with resume: an existing partial ``dest`` continues where it stopped."""
        dest.parent.mkdir(parents=True, exist_ok=True)
        have = dest.stat().st_size if dest.exists() else 0
        total = self.size(path)
        if have >= total:
            return total
        req = urllib.request.Request(self.url(path), headers={"Range": f"bytes={have}-"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp, open(dest, "ab" if have else "wb") as out:
                if resp.status == 200 and have:  # no Range support: start over
                    out.seek(0)
                    out.truncate()
                while True:
                    block = resp.read(chunk)
                    if not block:
                        break
                    out.write(block)
        except (urllib.error.URLError, OSError) as e:
            raise CameraError(f"download of {path} stopped: {e}") from e
        return dest.stat().st_size

    def gps(self, f: CamFile, tz_offset_s: int = 0) -> list[Fix]:
        total = self.size(f.path)
        if total < 8:
            return []
        marker, size = parse_trailer(self.read_range(f.path, total - 8, 8)) or (None, 0)
        if not marker or size > total:
            return []
        block = self.read_range(f.path, total - size, size)
        self.fixtures.save(f"gps_{f.name}", block)
        fixes = parse_block(block, marker)
        return align_fixes(fixes, iso_to_unix(f.start), f.duration_s, tz_offset_s)


# ── Viidure ──────────────────────────────────────────────────────────────────

class ViidureCamera(_Base):
    family = "viidure"

    def call(self, cmd: str) -> Any:
        status, _, body = _http(f"{self.base}/app/{cmd}", timeout=self.timeout)
        self.fixtures.save(f"app_{cmd}", body)
        if status != 200:
            raise CameraError(f"{cmd}: HTTP {status}")
        try:
            doc = json.loads(body.decode("utf-8", "replace"))
        except json.JSONDecodeError as e:
            raise CameraError(f"{cmd}: reply is not JSON") from e
        result = doc.get("result", -1)
        if result != 0:
            raise CameraError(f"{cmd}: camera said {doc.get('info') or result}")
        return doc.get("info")

    def info(self) -> dict:
        attr = self.call("getdeviceattr") or {}
        out = {"family": self.family, "attr": attr}
        for cmd, key in (("getproductinfo", "product"), ("getmediainfo", "media"), ("getsdinfo", "sd")):
            try:
                out[key] = self.call(cmd)
            except CameraError as e:
                out[key] = {"error": str(e)}
        out["id"] = attr.get("uuid") or attr.get("imei") or attr.get("bssid") or ""
        return out

    def files(self, tz_offset_s: int | None = None) -> list[CamFile]:
        tz = local_offset_s() if tz_offset_s is None else tz_offset_s
        out: list[CamFile] = []
        for folder in VIIDURE_FOLDERS:
            start = 0
            seen: set[str] = set()
            while True:
                try:
                    info = self.call(f"getfilelist?folder={folder}&start={start}&end={start + PAGE - 1}")
                except CameraError:
                    break
                page = parse_viidure_list(info, tz)
                fresh = [f for f in page if f.path not in seen]
                if not fresh:
                    break
                seen.update(f.path for f in fresh)
                out.extend(fresh)
                if len(page) < PAGE:
                    break
                start += PAGE
        return out

    def thumbnail(self, path: str) -> bytes:
        status, _, body = _http(f"{self.base}/app/getthumbnail?file={urllib.parse.quote(path, safe='/')}",
                                timeout=self.timeout)
        if status != 200 or len(body) < 100:
            raise CameraError(f"no thumbnail for {path}")
        return body

    def set_time(self, when: dt.datetime | None = None, tz_offset_s: int | None = None) -> None:
        tz = local_offset_s() if tz_offset_s is None else tz_offset_s
        local = (when or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone(dt.timedelta(seconds=tz)))
        self.call(f"settimezone?timezone={int(round(tz / 3600))}")
        self.call(f"setsystime?date={local.strftime('%Y%m%d%H%M%S')}")

    def is_recording(self) -> bool:
        info = self.call("getparamvalue?param=rec")
        return str(_first_value(info, "rec")) == "1"

    def record(self, on: bool) -> None:
        self.call(f"setparamvalue?param=rec&value={1 if on else 0}")

    def lock(self) -> None:
        self.call("lockvideo")

    def snapshot(self) -> Any:
        return self.call("snapshot")

    def playback(self, enter: bool) -> None:
        self.call(f"playback?param={'enter' if enter else 'exit'}")

    def settings(self) -> list[dict]:
        return merge_viidure_settings(self.call("getparamitems?param=all") or [],
                                      self.call("getparamvalue?param=all") or [])

    def set(self, name: str, value: str) -> None:
        self.call(f"setparamvalue?param={urllib.parse.quote(name)}&value={urllib.parse.quote(str(value))}")

    def delete(self, path: str) -> None:
        self.call(f"deletefile?file={urllib.parse.quote(path, safe='/')}")

    def sd(self) -> dict:
        return parse_viidure_sd(self.call("getsdinfo") or {})

    def format(self) -> None:
        self.call("sdformat?index=0")

    def set_wifi(self, ssid: str | None = None, password: str | None = None) -> None:
        if ssid:
            self.call(f"setwifi?wifissid={urllib.parse.quote(ssid)}")
        if password:
            self.call(f"setwifi?wifipwd={urllib.parse.quote(password)}")


def _first_value(info: Any, name: str) -> Any:
    if isinstance(info, dict):
        return info.get("value", info.get(name))
    if isinstance(info, list):
        for item in info:
            if isinstance(item, dict) and item.get("name") in (name, None):
                return item.get("value")
    return info


def parse_viidure_list(info: Any, tz_offset_s: int) -> list[CamFile]:
    """``getfilelist`` info → files. ``createtime`` is local wall-clock seconds on Eeasy SoCs."""
    out: list[CamFile] = []
    for folder in info if isinstance(info, list) else []:
        if not isinstance(folder, dict):
            continue
        fname = str(folder.get("folder", "")).lower()
        for item in folder.get("files") or []:
            if not isinstance(item, dict) or not item.get("name"):
                continue
            size_kb = int(item.get("size") or 0)
            if size_kb <= 0:
                continue
            path = str(item["name"])
            stamp = str(item.get("createtimestr") or "")
            if re.fullmatch(r"\d{14}", stamp):
                local = dt.datetime.strptime(stamp, "%Y%m%d%H%M%S")
                start = local.replace(tzinfo=dt.timezone(dt.timedelta(seconds=tz_offset_s)))
            else:
                start = dt.datetime.fromtimestamp(int(item.get("createtime") or 0) - tz_offset_s, dt.timezone.utc)
            video = int(item.get("type") or 0) == 2
            out.append(CamFile(
                path=path,
                kind=("photo" if not video else
                      {"loop": "normal", "race": "normal", "park": "parking",
                       "event": "event", "emr": "event"}.get(fname, "normal")),
                lens=lens_from_path(path),
                start=start.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                duration_s=float(item.get("duration") or 0) if video else 0.0,
                size=size_kb * 1024,
                locked=fname == "emr",
                folder=fname,
                gps_path=str(item.get("GPSPATH") or ""),
            ))
    return out


def lens_from_path(path: str) -> str:
    low = path.lower()
    stem = low.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    if stem.endswith(("_r", "-r")) or "/rear" in low or "video_rear" in low or "/r/" in low:
        return "rear"
    if stem.endswith(("_i", "-i")) or "/inside" in low or "/in/" in low:
        return "inside"
    return "front"


def merge_viidure_settings(items: list, values: list) -> list[dict]:
    current = {str(v.get("name")): v.get("value") for v in values if isinstance(v, dict)}
    out = []
    for it in items:
        if not isinstance(it, dict) or not it.get("name"):
            continue
        name = str(it["name"])
        entry = {"name": name, "value": None if current.get(name) is None else str(current.get(name))}
        codes = [str(c) for c in it.get("index") or []]
        labels = [str(lbl) for lbl in it.get("items") or []]
        if codes:
            entry["options"] = [{"code": c, "label": labels[i] if i < len(labels) else c} for i, c in enumerate(codes)]
        if it.get("range"):
            entry["range"] = str(it["range"])
            entry["step"] = it.get("step")
            entry["unit"] = it.get("unit")
        out.append(entry)
    for name, value in current.items():  # values without an options entry (e.g. rec)
        if not any(e["name"] == name for e in out):
            out.append({"name": name, "value": None if value is None else str(value)})
    return out


def parse_viidure_sd(info: dict) -> dict:
    status = int(info.get("status", -1)) if isinstance(info, dict) else -1
    out = {"ok": status == 0, "status": status}
    if status == 0:
        out["total_bytes"] = int(info.get("total") or 0) * 1024 * 1024
        out["free_bytes"] = int(info.get("free") or 0) * 1024 * 1024
    return out


# ── Novatek ──────────────────────────────────────────────────────────────────

class NovatekCamera(_Base):
    family = "novatek"

    def cmd(self, n: int, **params: Any) -> ET.Element:
        q = "&".join(f"{k}={urllib.parse.quote(str(v), safe='/:')}" for k, v in params.items())
        status, _, body = _http(f"{self.base}/?custom=1&cmd={n}" + (f"&{q}" if q else ""), timeout=self.timeout)
        self.fixtures.save(f"nvt_{n}", body)
        if status != 200:
            raise CameraError(f"cmd {n}: HTTP {status}")
        try:
            root = ET.fromstring(body)
        except ET.ParseError as e:
            raise CameraError(f"cmd {n}: reply is not XML") from e
        st = root.findtext(".//Status")
        if st is not None and st.strip() not in ("0", ""):
            raise CameraError(f"cmd {n}: camera status {st.strip()}")
        return root

    def info(self) -> dict:
        root = self.cmd(3029)
        return {"family": self.family, "id": (root.findtext(".//String") or "").strip(),
                "attr": {child.tag: (child.text or "").strip() for child in root}}

    def files(self, tz_offset_s: int | None = None) -> list[CamFile]:
        tz = local_offset_s() if tz_offset_s is None else tz_offset_s
        return parse_novatek_list(ET.tostring(self.cmd(3015)), tz)

    def thumbnail(self, path: str) -> bytes:
        status, _, body = _http(self.url(path) + "?custom=1&cmd=4001", timeout=self.timeout)
        if status != 200 or len(body) < 100:
            raise CameraError(f"no thumbnail for {path}")
        return body

    def set_time(self, when: dt.datetime | None = None, tz_offset_s: int | None = None) -> None:
        tz = local_offset_s() if tz_offset_s is None else tz_offset_s
        local = (when or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone(dt.timedelta(seconds=tz)))
        self.cmd(3005, str=local.strftime("%Y-%m-%d"))
        self.cmd(3006, str=local.strftime("%H:%M:%S"))

    def record(self, on: bool) -> None:
        self.cmd(2001, par=1 if on else 0)

    def is_recording(self) -> bool:
        return (self.cmd(2016).findtext(".//Value") or "0").strip() not in ("0", "")

    def lock(self) -> None:
        self.cmd(9133, par=1)

    def snapshot(self) -> Any:
        return ET.tostring(self.cmd(1001)).decode()

    def delete(self, path: str) -> None:
        self.cmd(4003, str="A:" + path.replace("/", "\\"))

    def format(self) -> None:
        self.cmd(3010, par=1)

    def set_wifi(self, ssid: str | None = None, password: str | None = None) -> None:
        if ssid:
            self.cmd(3003, str=ssid)
        if password:
            self.cmd(3004, str=password)

    def gps(self, f: CamFile, tz_offset_s: int = 0) -> list[Fix]:
        if not f.gps_path:
            return []  # Novatek MP4 'gps ' atoms are not read here (protocol.md §4)
        status, _, body = _http(self.url(f.gps_path), timeout=self.timeout)
        if status != 200:
            return []
        fixes = [x for x in (parse_line(ln) for ln in body.decode("ascii", "replace").splitlines()) if x]
        return align_fixes(fixes, iso_to_unix(f.start), f.duration_s, tz_offset_s)


def parse_novatek_list(xml_bytes: bytes, tz_offset_s: int) -> list[CamFile]:
    root = ET.fromstring(xml_bytes)
    out = []
    for node in root.iter("File"):
        fpath = (node.findtext("FPATH") or "").strip()
        if not fpath:
            continue
        path = (fpath.split(":", 1)[1] if ":" in fpath[:3] else fpath).replace("\\", "/")
        size = int((node.findtext("SIZE") or "0").strip() or 0)
        attr = int((node.findtext("ATTR") or "0").strip() or "0", 16)
        stamp = (node.findtext("TIME_START") or node.findtext("TIME") or "").strip()
        try:
            local = dt.datetime.strptime(stamp, "%Y/%m/%d %H:%M:%S")
        except ValueError:
            local = dt.datetime(1970, 1, 1)
        start = local.replace(tzinfo=dt.timezone(dt.timedelta(seconds=tz_offset_s)))
        stop = (node.findtext("TIME_STOP") or "").strip()
        duration = 0.0
        if stop:
            try:
                duration = max(0.0, (dt.datetime.strptime(stop, "%Y/%m/%d %H:%M:%S") - local).total_seconds())
            except ValueError:
                pass
        upper = path.upper()
        photo = upper.endswith((".JPG", ".JPEG")) or "/PHOTO/" in upper
        locked = bool(attr & 1) or "/RO/" in upper or "/EMR/" in upper
        kind = "photo" if photo else ("event" if locked else ("parking" if "/PARK" in upper else "normal"))
        out.append(CamFile(path=path, kind=kind, lens=lens_from_path(path),
                           start=start.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                           duration_s=duration, size=size, locked=locked,
                           gps_path=(node.findtext("GPSPATH") or "").strip()))
    return out


# ── GPS ──────────────────────────────────────────────────────────────────────

def parse_trailer(last8: bytes) -> tuple[bytes, int] | None:
    if len(last8) != 8 or last8[:4] not in GPS_MARKERS:
        return None
    size = struct.unpack(">I", last8[4:8])[0]
    return (last8[:4], size) if 0 < size < 1_024_000 else None


def parse_block(block: bytes, marker: bytes) -> list[Fix]:
    """GPS block (the file's last ``size`` bytes) → fixes in file order."""
    if len(block) < GPS_HEADER or struct.unpack(">I", block[:4])[0] != len(block) or block[4:8] != b"free":
        return []
    fh = block[8:10] == b"FH"
    lines: list[str] = []
    if fh:
        off = GPS_HEADER + 64
        while off <= len(block) - 136:
            lines.append(_cstr(block, off))
            off += GPS_RECORD
    else:
        off = GPS_HEADER
        while off <= len(block) - GPS_RECORD:
            lines.append(_cstr(block, off + 4))
            off += GPS_RECORD
    out = []
    for line in lines:
        fix = parse_line(line, scrambled=(marker == b"****" and not fh))
        if fix:
            out.append(fix)
    return out


def _cstr(buf: bytes, start: int) -> str:
    end = buf.find(b"\x00", start, start + GPS_RECORD)
    return buf[start:end if end >= 0 else start + GPS_RECORD - 4].decode("ascii", "replace")


def line_valid(line: str) -> bool:
    s = line.strip()
    return len(s) > 20 and s.startswith("20") and s[20] in "NS"


def _coord(token: str, is_lat: bool) -> float | None:
    """``N:4152.6800`` / ``W:08737.8000`` / ``N:41.878`` → signed decimal degrees."""
    if len(token) < 3 or token[1] != ":" or token[0] not in ("NS" if is_lat else "EW"):
        return None
    raw = token[2:]
    if raw in ("-", "NA") or not raw:
        return None
    neg = token[0] in "SW"
    if raw.startswith("-"):
        neg, raw = not neg, raw[1:]
    try:
        value = float(raw)
    except ValueError:
        return None
    whole = raw.split(".")[0]
    if len(whole) < (3 if is_lat else 4):   # already decimal degrees (p102h6/f.java#e)
        deg = value
    else:
        dd = 2 if is_lat else 3
        whole = whole.zfill(4 if is_lat else 5)
        frac = raw.split(".")[1] if "." in raw else "0"
        deg = float(whole[:dd]) + float(whole[dd:] + "." + frac) / 60.0
    return -deg if neg else deg


def _num(token: str, prefix: str = "") -> float | None:
    if prefix:
        if not token.startswith(prefix):
            return None
        token = token[len(prefix):]
    if token in ("-", "NA", ""):
        return None
    try:
        v = float(token)
    except ValueError:
        return None
    return v if math.isfinite(v) else None


def parse_line(line: str, scrambled: bool = False) -> Fix | None:
    """One Viidure track line → Fix (time as written, treated as UTC until aligned)."""
    if not line_valid(line):
        return None
    tok = line.strip().replace(",", " ").split()
    if len(tok) < 5:
        return None
    try:
        when = dt.datetime.strptime(tok[0].replace("-", "/") + " " + tok[1], "%Y/%m/%d %H:%M:%S")
    except ValueError:
        return None
    t = when.replace(tzinfo=dt.timezone.utc).timestamp()
    ms = next((_num(x, "MS:") for x in tok if x.startswith("MS:")), None)
    if ms is not None:
        t += ms / 10.0
    speed = _num(tok[4])
    if scrambled:
        a, b = _num(tok[2][2:]), _num(tok[3][2:])
        if a is None or b is None:
            return None
        a10, b10 = math.floor(a / 10) * 10, math.floor(b / 10) * 10
        lat = _coord(f"{tok[2][:2]}{(b - b10) / 0.8668 + a10:.6f}", True)
        lon = _coord(f"{tok[3][:2]}{b10 + (a - a10) / 0.8668:.6f}", False)
        speed = None if speed is None else speed * 1.852
    else:
        lat, lon = _coord(tok[2], True), _coord(tok[3], False)
    if lat is None or lon is None or (abs(lat) < 1e-6 and abs(lon) < 1e-6):
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    heading = next((_num(x, "A:") for x in tok[5:] if x.startswith("A:")), None)
    if heading is None:
        if len(tok) >= 19:
            heading = _num(tok[9][2:]) if len(tok[9]) > 2 else None
        elif len(tok) == 10 and "H" in tok[9]:
            heading = _num(tok[8][2:]) if len(tok[8]) > 2 else None
    if heading is not None and not (0 <= heading <= 360):
        heading = None
    mps = None if speed is None or speed < 0 or speed > 400 else speed * KMH
    return Fix(t=t, lat=lat, lon=lon, speed_mps=mps, heading=heading)


def align_fixes(fixes: list[Fix], start_unix: float, duration_s: float, tz_offset_s: int) -> list[Fix]:
    """Line times are wall-clock; keep the reading (UTC or camera-local) that lands in the clip."""
    if not fixes:
        return fixes
    lo, hi = start_unix - 60, start_unix + max(duration_s, 1) + 60

    def inside(shift: float) -> int:
        return sum(1 for f in fixes if lo <= f.t - shift <= hi)

    best = max((0, tz_offset_s), key=inside)
    if best:
        for f in fixes:
            f.t -= best
    return fixes


# ── helpers ──────────────────────────────────────────────────────────────────

def local_offset_s() -> int:
    return int(dt.datetime.now().astimezone().utcoffset().total_seconds())


def iso_to_unix(s: str) -> float:
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()


def detect(host: str | None = None, timeout: float = 2.5) -> tuple[str, str]:
    """(family, base URL). ``host`` pins the address (e.g. a fake camera on 127.0.0.1:8099)."""
    for family, default, path in DETECTORS:
        base = "http://" + (host or default)
        try:
            status, _, body = _http(base + path, timeout=timeout)
        except CameraError:
            continue
        if status != 200:
            continue
        if family == "viidure":
            try:
                if json.loads(body).get("result") != 0:
                    continue
            except (json.JSONDecodeError, AttributeError):
                continue
        elif family == "novatek" and b"<" not in body[:64]:
            continue
        return family, base
    raise CameraError("no dashcam answered (join the camera's Wi‑Fi first)")


def open_camera(host: str | None = None, fixtures: Fixtures | None = None) -> _Base:
    family, base = detect(host)
    if family == "viidure":
        return ViidureCamera(base, fixtures=fixtures)
    if family == "novatek":
        return NovatekCamera(base, fixtures=fixtures)
    raise CameraError(f"{family} camera found at {base} — not supported yet (see protocol.md)")


# ── CLI ──────────────────────────────────────────────────────────────────────

def _fail(msg: str) -> NoReturn:
    print(json.dumps({"error": msg}), file=sys.stderr)
    sys.exit(1)


def _find(cam: _Base, path: str) -> CamFile:
    for f in cam.files():  # type: ignore[attr-defined]
        if f.path == path or f.name == path:
            return f
    raise CameraError(f"{path} is not on the camera")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Talk to a Viidure-family dashcam over its Wi‑Fi.")
    p.add_argument("--host", help="camera address (default: try every family's address)")
    p.add_argument("--record-fixtures", metavar="DIR", help="save every raw reply here")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("probe")
    ls = sub.add_parser("ls")
    ls.add_argument("--kind", choices=("normal", "event", "parking", "photo"))
    for name in ("gps", "get", "thumb"):
        sp = sub.add_parser(name)
        sp.add_argument("path")
        if name != "gps":
            sp.add_argument("-o", "--out", required=True)
    sub.add_parser("settings")
    st = sub.add_parser("set")
    st.add_argument("name")
    st.add_argument("value")
    sub.add_parser("time-sync")
    sub.add_parser("lock")
    sub.add_parser("snapshot")
    rec = sub.add_parser("record")
    rec.add_argument("state", choices=("on", "off"))
    args = p.parse_args(argv)
    fixtures = Fixtures(Path(args.record_fixtures)) if args.record_fixtures else None
    try:
        cam: Any = open_camera(args.host, fixtures)
        if args.cmd == "probe":
            out: Any = cam.info()
            try:
                out["recording"] = cam.is_recording()
            except CameraError as e:
                out["recording"] = {"error": str(e)}
            try:
                out["files_listed_without_playback_mode"] = len(cam.files())
            except CameraError as e:
                out["files_listed_without_playback_mode"] = {"error": str(e)}
        elif args.cmd == "ls":
            out = [asdict(f) for f in cam.files() if not args.kind or f.kind == args.kind]
        elif args.cmd == "gps":
            out = [fx.row() for fx in cam.gps(_find(cam, args.path), local_offset_s())]
        elif args.cmd == "get":
            f = _find(cam, args.path)
            out = {"path": f.path, "bytes": cam.download(f.path, Path(args.out))}
        elif args.cmd == "thumb":
            Path(args.out).write_bytes(cam.thumbnail(args.path))
            out = {"ok": True, "out": args.out}
        elif args.cmd == "settings":
            if not isinstance(cam, ViidureCamera):
                _fail("settings are only readable on Viidure cameras")
            out = cam.settings()
        elif args.cmd == "set":
            cam.set(args.name, args.value)
            out = {"ok": True}
        elif args.cmd == "time-sync":
            cam.set_time()
            out = {"ok": True}
        elif args.cmd == "lock":
            cam.lock()
            out = {"ok": True}
        elif args.cmd == "snapshot":
            out = {"ok": True, "reply": cam.snapshot()}
        else:
            cam.record(args.state == "on")
            out = {"ok": True}
    except CameraError as e:
        _fail(str(e))
    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
