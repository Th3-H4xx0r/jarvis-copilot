"""Dashcam GPS -> drives: cleaning, grouping, stats, thinned polylines and GPX.

Pure functions over clip dicts (as ``dashcam_store`` keeps them) and their fixes
``[t_unix, lat, lon, speed_mps|null, heading_deg|null]``, plus ``rebuild(store)``
which writes ``drives.json`` and each clip's ``drive_id``.

Rules:
- Only ``normal`` and ``event`` clips make drives; parking and photo clips never do.
- A clip's time window comes from its GPS fixes when it has any (GPS time is right even
  before the camera's clock is set), else from ``start`` + ``duration_s``.
- Per camera, front-lens clips always count; rear/inside clips only fill windows no front
  clip covers. Clips whose windows are < 5 min apart form one drive. Calendar and UTC-day
  boundaries never split a drive.
- The drive's fixes are the member clips' fixes merged by time (duplicates from an event
  clip overlapping a normal clip collapse), cleaned of implied jumps > 70 m/s: the track is
  split at every jump, stretches under 5 points are dropped, and of two stretches that still
  disagree the longer wins - so nothing draws a line to null island or across the globe.
- A group with fewer than 2 fixes in total (no GPS yet, or none at all) is not a drive.
- ``moving_s`` counts time at >= 1 m/s; ``avg_mps`` = distance / moving_s; ``max_mps`` drops
  the top 0.5 % of speed samples (one-sample GPS spikes).
"""
from __future__ import annotations

import math
import re
from xml.sax.saxutils import escape

from api.dashcam_store import now_iso, parse_iso

GAP_S = 300              # < 5 min between clips joins a drive
MAX_IMPLIED_MPS = 70.0   # jump filter
THIN_POINTS = 2000
DRIVE_KINDS = ("normal", "event")
MOVING_MPS = 1.0
MIN_DRIVE_POINTS = 2
MIN_STRETCH = 5          # fixes; shorter stretches between jumps are junk
SPEED_SAMPLE_DT = 5.0    # trust the GPS speed field for steps up to this long
EARTH_R = 6371008.8
_DEFAULT_DURATION_S = 60.0


def haversine_m(a_lat, a_lon, b_lat, b_lon) -> float:
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp = p2 - p1
    dl = math.radians(b_lon - a_lon)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R * math.asin(min(1.0, math.sqrt(h)))


def _implied(a, b) -> float:
    dt = b[0] - a[0]
    d = haversine_m(a[1], a[2], b[1], b[2])
    if dt <= 0:
        return 0.0 if d < 1 else math.inf
    return d / dt


def _valid(f) -> bool:
    return (isinstance(f, (list, tuple)) and len(f) == 5
            and all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in f[:3]))


def _merge(lists) -> list:
    """Fixes from several clips, sorted by time, one per instant (< 0.5 s apart collapse)."""
    pts = sorted(([float(f[0]), float(f[1]), float(f[2]), f[3], f[4]] for fx in lists for f in fx if _valid(f)),
                 key=lambda f: f[0])
    out = []
    for f in pts:
        if out and f[0] - out[-1][0] < 0.5:
            continue
        out.append(f)
    return out


def clean_fixes(fixes: list) -> list:
    """Sorted, de-duplicated fixes with implied-speed jumps (> 70 m/s) removed."""
    pts = _merge([fixes])
    if not pts:
        return []
    stretches = [[pts[0]]]
    for f in pts[1:]:
        if _implied(stretches[-1][-1], f) > MAX_IMPLIED_MPS:
            stretches.append([f])
        else:
            stretches[-1].append(f)
    if len(stretches) == 1:
        return stretches[0]
    long_ones = [s for s in stretches if len(s) >= MIN_STRETCH]
    if not long_ones:
        long_ones = [max(stretches, key=len)]
    # Join what's left, settling any remaining disagreement in favour of the longer stretch.
    kept: list[list] = []
    for s in long_ones:
        if kept and _implied(kept[-1][-1], s[0]) > MAX_IMPLIED_MPS:
            if len(s) > len(kept[-1]):
                kept[-1] = s
            continue
        kept.append(s)
    # A replaced stretch can disagree with the one before it; one more pass keeps it honest.
    out: list = []
    for s in kept:
        if out and _implied(out[-1], s[0]) > MAX_IMPLIED_MPS:
            continue
        out.extend(s)
    return out


def _window(clip: dict, fixes: list) -> tuple[float, float] | None:
    if fixes:
        return fixes[0][0], fixes[-1][0]
    start = parse_iso(clip.get("start"))
    if start is None:
        return None
    dur = clip.get("duration_s")
    dur = float(dur) if isinstance(dur, (int, float)) and not isinstance(dur, bool) and dur >= 0 else _DEFAULT_DURATION_S
    return start, start + dur


def _overlaps(a, b) -> bool:
    return a[0] < b[1] and b[0] < a[1]


def _stats(fx: list) -> dict:
    distance = moving = 0.0
    implied_speeds = []
    for a, b in zip(fx, fx[1:]):
        dt = b[0] - a[0]
        d = haversine_m(a[1], a[2], b[1], b[2])
        distance += d
        if dt <= 0:
            continue
        sp = b[3] if b[3] is not None and dt <= SPEED_SAMPLE_DT else d / dt
        if sp >= MOVING_MPS:
            moving += dt
        if dt <= SPEED_SAMPLE_DT:
            implied_speeds.append(d / dt)
    speeds = [f[3] for f in fx if f[3] is not None] or implied_speeds
    max_mps = 0.0
    if speeds:
        ranked = sorted(speeds, reverse=True)
        max_mps = ranked[min(int(len(ranked) * 0.005), len(ranked) - 1)]
    bounds = None
    if fx:
        lats = [f[1] for f in fx]
        lons = [f[2] for f in fx]
        bounds = [min(lats), min(lons), max(lats), max(lons)]
    return {"distance_m": round(distance, 1), "moving_s": round(moving, 1),
            "avg_mps": round(distance / moving, 3) if moving > 0 else 0.0,
            "max_mps": round(float(max_mps), 3), "bounds": bounds, "point_count": len(fx)}


def _drive_id(start: float, camera_id: str) -> str:
    return f"dr_{int(start)}_{re.sub(r'[^A-Za-z0-9_-]', '', str(camera_id))[:6]}"


def build_drives(clips: list[dict], fixes_by_clip: dict[str, list]) -> list[dict]:
    """Groups clips into drives (oldest first); see the module docstring for the rules."""
    by_camera: dict[str, list] = {}
    others: dict[str, list] = {}
    for clip in clips:
        if not isinstance(clip, dict) or not clip.get("id"):
            continue
        fx = clean_fixes(fixes_by_clip.get(clip["id"]) or [])
        win = _window(clip, fx)
        if win is None:
            continue
        row = (clip, win)
        cam = str(clip.get("camera_id") or "")
        if clip.get("kind") in DRIVE_KINDS:
            by_camera.setdefault(cam, []).append(row)
        elif clip.get("kind") != "parking":
            others.setdefault(cam, []).append(row)

    drives = []
    for cam, rows in by_camera.items():
        front = [r for r in rows if r[0].get("lens", "front") == "front"]
        fill = [r for r in rows if r[0].get("lens", "front") != "front"]
        selected = front + [r for r in fill if not any(_overlaps(r[1], f[1]) for f in front)]
        skipped = [r for r in fill if r not in selected]
        selected.sort(key=lambda r: (r[1][0], r[0]["id"]))
        groups: list[list] = []
        end = None
        for r in selected:
            if groups and r[1][0] - end < GAP_S:
                groups[-1].append(r)
                end = max(end, r[1][1])
            else:
                groups.append([r])
                end = r[1][1]
        for group in groups:
            start = min(r[1][0] for r in group)
            stop = max(r[1][1] for r in group)
            ids = [r[0]["id"] for r in group]
            fx = clean_fixes(_merge(fixes_by_clip.get(i) or [] for i in ids))
            if len(fx) < MIN_DRIVE_POINTS:
                continue
            extra = [r[0]["id"] for r in skipped + others.get(cam, []) if _overlaps(r[1], (start, stop))
                     or r[1][0] == r[1][1] and start <= r[1][0] <= stop]
            drive = {"id": _drive_id(start, cam), "camera_id": cam, "start": now_iso(start),
                     "end": now_iso(stop), "duration_s": round(stop - start, 1), "clip_ids": ids,
                     "other_clip_ids": sorted(extra)}
            drive.update(_stats(fx))
            drives.append(drive)
    drives.sort(key=lambda d: (d["start"], d["id"]))
    return drives


def _drive_fixes(drive: dict, fixes_by_clip: dict[str, list]) -> list:
    return clean_fixes(_merge(fixes_by_clip.get(i) or [] for i in drive.get("clip_ids") or []))


def drive_polyline(drive: dict, fixes_by_clip: dict[str, list], limit: int = THIN_POINTS) -> list:
    """``[[lat, lon, speed_mps|null, t], ...]`` thinned to ``limit`` points by an even time stride,
    always keeping the first and last fix. ``t`` (Unix seconds) lets a client map a point on the
    line back to the clip recorded there."""
    fx = _drive_fixes(drive, fixes_by_clip)
    limit = max(2, int(limit))
    if len(fx) > limit:
        t0, t1 = fx[0][0], fx[-1][0]
        picked, j = [], 0
        for k in range(limit):
            target = t0 + (t1 - t0) * k / (limit - 1)
            while j < len(fx) - 1 and fx[j][0] < target:
                j += 1
            if not picked or picked[-1] != j:
                picked.append(j)
        if picked[-1] != len(fx) - 1:
            picked[-1] = len(fx) - 1
        fx = [fx[i] for i in picked]
    return [[f[1], f[2], f[3], f[0]] for f in fx]


def _gpx_time(t: float) -> str:
    if float(t).is_integer():
        return now_iso(t)
    whole = math.floor(t)
    return now_iso(whole)[:-1] + f".{int(round((t - whole) * 1000)):03d}Z"


def drive_gpx(drive: dict, fixes_by_clip: dict[str, list]) -> str:
    """GPX 1.1 with one track; speed (m/s) and course in Garmin TrackPointExtension v2."""
    fx = _drive_fixes(drive, fixes_by_clip)
    name = escape(f"Drive {drive.get('start', '')}")
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<gpx version="1.1" creator="JarvisCopilot" xmlns="http://www.topografix.com/GPX/1/1" '
             'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">',
             f"  <metadata><name>{name}</name><time>{escape(str(drive.get('start', '')))}</time></metadata>",
             f"  <trk><name>{name}</name><trkseg>"]
    for t, lat, lon, speed, heading in fx:
        ext = ""
        if speed is not None or heading is not None:
            parts = ""
            if speed is not None:
                parts += f"<gpxtpx:speed>{float(speed):.2f}</gpxtpx:speed>"
            if heading is not None:
                parts += f"<gpxtpx:course>{float(heading):.1f}</gpxtpx:course>"
            ext = f"<extensions><gpxtpx:TrackPointExtension>{parts}</gpxtpx:TrackPointExtension></extensions>"
        lines.append(f'    <trkpt lat="{lat:.7f}" lon="{lon:.7f}"><time>{_gpx_time(t)}</time>{ext}</trkpt>')
    lines += ["  </trkseg></trk>", "</gpx>", ""]
    return "\n".join(lines)


def rebuild(store) -> list[dict]:
    """Rebuilds every drive from the store's clips and fixes; writes drives.json and each clip's
    ``drive_id`` (cleared for clips no longer in a drive)."""
    clips = store.all_clips()
    fixes = {c["id"]: store.get_fixes(c["id"]) for c in clips if c.get("has_gps") and c.get("kind") != "parking"}
    drives = build_drives(clips, fixes)
    store.write_drives(drives)
    mapping = {c["id"]: None for c in clips}
    for d in drives:
        for cid in d["clip_ids"] + d["other_clip_ids"]:
            mapping[cid] = d["id"]
    store.assign_drive_ids(mapping)
    return drives
