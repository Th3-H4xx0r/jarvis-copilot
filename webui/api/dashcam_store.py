"""Per-profile storage for the dashcam: cameras, clips, GPS fixes, thumbnails,
sync settings, upload destinations, chunked uploads and the staging area.

A JSON-file store under the webui state dir, beside the island/widget stores::

    <state>/dashcam/<profile>/
        cameras.json              {"cameras": {camera_id: {id, model, dialect, ssid, gateway, firmware, last_seen, sd}}}
        settings.json             {"rules": {...}, "staging_cap_bytes": n}
        destinations.json         {"destinations": {dest_id: {id, type, name, remote, path, enabled, kinds,
                                                              host, port, user, status, error, created_at}}}
        clips/<clip_id>.json      one clip (see ``_new_clip``)
        fixes/<clip_id>.json      {"fixes": [[t_unix, lat, lon, speed_mps|null, heading_deg|null], ...]}
        thumbs/<clip_id>.jpg
        drives.json               {"drives": {drive_id: {...}}, "built_at"}   (written by dashcam_drives.rebuild)
        uploads/<upload_id>.json  {id, clip_id, size, sha256, chunk_size, chunks, received, created_at,
                                   updated_at, completed_at, remuxed, staged_size}
        staging/<upload_id>.part  the clip's bytes as they arrive, and while they wait for every destination
        staging/<upload_id>.mp4   instead of the .part once a .ts clip was remuxed (``dashcam_remux``)

A clip's identity is ``<camera_id>:<camera path>``, hashed to ``c_<20 hex>``. Its
``upload.state`` walks ``none -> staging -> staged -> done``: staging while the phone
sends chunks, staged once the bytes are checked (size + sha256) and waiting for the
relay, done once every enabled destination has it and the staging file is gone. A ``.ts``
clip is remuxed to MP4 losslessly between the check and staged, so destinations get a file
that plays anywhere; when that fails (ffmpeg missing, a corrupt clip) the ``.ts`` is staged as
it is. The clip records what was staged - ``container`` (``"mp4"``, ``"ts"``, ... - the staged
file's extension) and ``staged_name`` (the name destinations get: ``x.ts`` -> ``x.mp4``) - and
the upload ``remuxed`` plus ``staged_size``, its real size on disk for the staging cap. A staged
clip no enabled destination takes any more goes back to ``none`` (``abandon_upload``) so the
phone sends it again later; an upload is refused (``no_destination``) while none takes it.
Each destination entry walks ``pending -> uploading -> done`` (or ``failed`` after
the relay's retries).

Secrets (FTP/SFTP/SMB passwords, Drive tokens, camera Wi-Fi passwords) are never
written here: they go straight into the rclone config. Writes are atomic
(temp + os.replace); a missing or corrupt file reads as empty, never raises.
"""
from __future__ import annotations

import copy
import hashlib
import logging
import math
import os
import re
import secrets
import shutil
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from api import dashcam_remux
from api.island_store import _read_json, _safe_id, _write_json

logger = logging.getLogger(__name__)

# Serializes read-modify-write across the threaded HTTP server and the relay worker.
_LOCK = threading.RLock()

KINDS = ("normal", "event", "parking", "photo")
LENSES = ("front", "rear", "inside")
PHONE_STATES = ("none", "queued", "downloading", "local", "deleted", "failed")
DEST_STATES = ("pending", "uploading", "done", "failed")
DEST_TYPES = ("drive", "sftp", "ftp", "smb")
STATE_FILTERS = ("on_camera_only", "on_phone", "uploading", "uploaded", "failed", "pending_upload")

CHUNK_SIZE = 16 * 1024 * 1024          # under the edge nginx's 64 MiB body cap
MIN_CHUNK_SIZE = 256 * 1024            # smallest chunk a phone may ask for
THUMB_MAX_BYTES = 512 * 1024
MAX_FIXES = 20_000
FIX_MIN_T = 1420070400.0               # 2015-01-01T00:00:00Z
FIX_MAX_AHEAD_S = 2 * 86400
MAX_SPEED_MPS = 100.0
STAGING_CAP_MIN = 256 * 1024 ** 2
STAGING_CAP_MAX = 64 * 1024 ** 3
IDLE_UPLOAD_S = 24 * 3600              # unfinished uploads idle this long are purged when space is needed
DISK_RESERVE_BYTES = 2 * 1024 ** 3     # an upload is refused (staging_full) if it would leave less free

DEFAULT_SETTINGS = {
    "rules": {"normal": "all",          # off | front | all (auto sync pulls everything by default)
              "normal_when": "any",     # any | parked
              "phone_cap_gb": 20,       # 1..512, applies to normal footage only
              "keep_on_phone": False,
              "upload": True,           # cloud uploads on/off
              "upload_data": "all",     # all | events | never — what may use mobile data
              "upload_when": "any"},    # any | parked
    "staging_cap_bytes": 4 * 1024 ** 3,
}

_SECRET_KEY = re.compile(r"pass|token|secret", re.IGNORECASE)
_DEST_ID = re.compile(r"^d_[0-9a-f]{8}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_DEST_FIELDS = ("id", "type", "name", "remote", "path", "enabled", "kinds", "host", "port", "user",
                "status", "error", "created_at", "tested_at")
_DEST_PATCHABLE = ("name", "remote", "path", "enabled", "kinds", "status", "error", "tested_at")


# ── time helpers ─────────────────────────────────────────────────────────────

def now_iso(ts: float | None = None) -> str:
    """ISO-8601 UTC with a Z suffix, to the second."""
    dt = datetime.fromtimestamp(time.time() if ts is None else ts, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value) -> float | None:
    """Unix seconds from an ISO-8601 string (``Z`` or an offset; naive means UTC), else None."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def _finite(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


# ── clip predicates (shared by list filters and counts) ──────────────────────

def _applicable(dest: dict, clip: dict) -> bool:
    return bool(dest.get("enabled")) and clip.get("kind") in (dest.get("kinds") or KINDS)


def _entries(clip: dict, dests: dict) -> list[dict]:
    """The clip's destination entries for destinations that still exist and apply to it."""
    out = []
    for dest_id, entry in (clip.get("destinations") or {}).items():
        dest = dests.get(dest_id)
        if dest and _applicable(dest, clip) and isinstance(entry, dict):
            out.append(entry)
    return out


def _is_uploaded(clip: dict, dests: dict) -> bool:
    state = (clip.get("upload") or {}).get("state")
    if state == "done":
        return True
    if state != "staged":
        return False
    entries = _entries(clip, dests)
    return bool(entries) and all(e.get("state") == "done" for e in entries)


def _is_failed(clip: dict, dests: dict) -> bool:
    if (clip.get("phone") or {}).get("state") == "failed":
        return True
    if (clip.get("upload") or {}).get("state") == "done":
        return False
    return any(e.get("state") == "failed" for e in _entries(clip, dests))


def _matches_state(clip: dict, state: str, dests: dict) -> bool:
    phone = (clip.get("phone") or {}).get("state")
    upload = (clip.get("upload") or {}).get("state")
    uploaded = _is_uploaded(clip, dests)
    if state == "on_phone":
        return phone == "local"
    if state == "uploaded":
        return uploaded
    if state == "failed":
        return _is_failed(clip, dests)
    if state == "on_camera_only":
        return bool(clip.get("on_camera")) and phone != "local" and upload == "none"
    if state == "uploading":
        return (not uploaded and upload in ("staging", "staged")
                and not any(e.get("state") == "failed" for e in _entries(clip, dests)))
    if state == "pending_upload":
        return not uploaded and (bool(clip.get("on_camera")) or phone == "local"
                                 or upload in ("staging", "staged"))
    return False


def _sort_key(clip: dict) -> tuple[float, str]:
    ts = parse_iso(clip.get("start"))
    if ts is None:
        ts = parse_iso(clip.get("first_seen")) or 0.0
    return ts, str(clip.get("id") or "")


def _empty_upload() -> dict:
    return {"state": "none", "upload_id": None, "bytes": 0, "sha256": None}


def _reset_upload(clip: dict) -> None:
    """Back to nothing uploaded: no upload, no destination entries, nothing staged."""
    clip["upload"] = _empty_upload()
    clip["destinations"] = {}
    clip["container"] = None
    clip["staged_name"] = None


def _extension(name: str) -> str | None:
    return os.path.splitext(name)[1].lstrip(".").lower() or None


class DashcamStore:
    def __init__(self, root, profile: str = "default"):
        self.root = Path(root)
        self.base = self.root / "dashcam" / (profile or "default")

    # ── paths ────────────────────────────────────────────────────────────────
    def _clip_path(self, clip_id: str) -> Path:
        return self.base / "clips" / f"{_safe_id(clip_id)}.json"

    def _fixes_path(self, clip_id: str) -> Path:
        return self.base / "fixes" / f"{_safe_id(clip_id)}.json"

    def _thumb_file(self, clip_id: str) -> Path:
        return self.base / "thumbs" / f"{_safe_id(clip_id)}.jpg"

    def _upload_path(self, upload_id: str) -> Path:
        return self.base / "uploads" / f"{_safe_id(upload_id)}.json"

    def staging_path(self, upload_id: str) -> Path:
        return self.base / "staging" / f"{_safe_id(upload_id)}.part"

    def remuxed_path(self, upload_id: str) -> Path:
        return self.base / "staging" / f"{_safe_id(upload_id)}.mp4"

    def staged_file(self, upload_id: str) -> Path:
        """Where an upload's checked bytes are: the remuxed ``.mp4`` once there is one, else the
        ``.part`` they arrived in."""
        up = self.get_upload(upload_id)
        return self.remuxed_path(upload_id) if up and up.get("remuxed") else self.staging_path(upload_id)

    # ── cameras ──────────────────────────────────────────────────────────────
    def _cameras_doc(self) -> dict:
        doc = _read_json(self.base / "cameras.json", None)
        cams = doc.get("cameras") if isinstance(doc, dict) else None
        return cams if isinstance(cams, dict) else {}

    def cameras(self) -> list[dict]:
        return [c for _, c in sorted(self._cameras_doc().items()) if isinstance(c, dict)]

    def upsert_camera(self, camera: dict) -> dict:
        """Merges ``camera`` into the stored one (``id`` required); drops secret-looking keys."""
        if not isinstance(camera, dict) or not isinstance(camera.get("id"), str) or not camera["id"].strip():
            raise ValueError("camera id is required")
        cam_id = camera["id"].strip()[:64]
        with _LOCK:
            cams = self._cameras_doc()
            merged = dict(cams.get(cam_id) or {})
            for key, value in camera.items():
                if isinstance(key, str) and not _SECRET_KEY.search(key):
                    merged[key] = value
            merged["id"] = cam_id
            merged["last_seen"] = now_iso()
            cams[cam_id] = merged
            _write_json(self.base / "cameras.json", {"cameras": cams})
        return merged

    # ── settings ─────────────────────────────────────────────────────────────
    def get_settings(self) -> dict:
        doc = _read_json(self.base / "settings.json", None)
        doc = doc if isinstance(doc, dict) else {}
        out = copy.deepcopy(DEFAULT_SETTINGS)
        rules = doc.get("rules")
        if isinstance(rules, dict):
            out["rules"].update({k: v for k, v in rules.items() if k in out["rules"]})
        if isinstance(doc.get("staging_cap_bytes"), int):
            out["staging_cap_bytes"] = doc["staging_cap_bytes"]
        return out

    def update_settings(self, patch: dict) -> tuple[dict | None, list[str]]:
        """Validates and merges a partial ``{"rules": {...}, "staging_cap_bytes": n}``."""
        if not isinstance(patch, dict):
            return None, ["settings must be an object"]
        errors: list[str] = []
        for key in patch:
            if key not in DEFAULT_SETTINGS:
                errors.append(f"unknown setting {key!r}")
        rules = patch.get("rules", {})
        if not isinstance(rules, dict):
            errors.append("rules must be an object")
            rules = {}
        for key, value in rules.items():
            if key == "normal" and value not in ("off", "front", "all"):
                errors.append("rules.normal must be off, front or all")
            elif key == "normal_when" and value not in ("any", "parked"):
                errors.append("rules.normal_when must be any or parked")
            elif key == "phone_cap_gb" and not (isinstance(value, int) and not isinstance(value, bool)
                                                and 1 <= value <= 512):
                errors.append("rules.phone_cap_gb must be a whole number from 1 to 512")
            elif key in ("keep_on_phone", "upload") and not isinstance(value, bool):
                errors.append(f"rules.{key} must be true or false")
            elif key == "upload_data" and value not in ("all", "events", "never"):
                errors.append("rules.upload_data must be all, events or never")
            elif key == "upload_when" and value not in ("any", "parked"):
                errors.append("rules.upload_when must be any or parked")
            elif key not in DEFAULT_SETTINGS["rules"]:
                errors.append(f"unknown rule {key!r}")
        if "staging_cap_bytes" in patch:
            cap = patch["staging_cap_bytes"]
            if not (isinstance(cap, int) and not isinstance(cap, bool) and STAGING_CAP_MIN <= cap <= STAGING_CAP_MAX):
                errors.append("staging_cap_bytes must be between 256 MiB and 64 GiB")
        if errors:
            return None, errors
        with _LOCK:
            current = self.get_settings()
            current["rules"].update(rules)
            if "staging_cap_bytes" in patch:
                current["staging_cap_bytes"] = patch["staging_cap_bytes"]
            _write_json(self.base / "settings.json", current)
        return current, []

    # ── clips ────────────────────────────────────────────────────────────────
    @staticmethod
    def clip_id(camera_id: str, path: str) -> str:
        return "c_" + hashlib.sha1(f"{camera_id}:{path}".encode("utf-8")).hexdigest()[:20]

    def get_clip(self, clip_id: str) -> dict | None:
        doc = _read_json(self._clip_path(clip_id), None)
        return doc if isinstance(doc, dict) and doc.get("id") == clip_id else None

    def _save_clip(self, clip: dict) -> None:
        _write_json(self._clip_path(clip["id"]), clip)

    def all_clips(self) -> list[dict]:
        d = self.base / "clips"
        if not d.is_dir():
            return []
        out = []
        for p in d.glob("*.json"):
            doc = _read_json(p, None)
            if isinstance(doc, dict) and isinstance(doc.get("id"), str):
                out.append(doc)
        return out

    @staticmethod
    def normalize_item(raw) -> tuple[dict | None, str | None]:
        """One inventory row checked and normalised, or ``(None, reason)``."""
        if not isinstance(raw, dict):
            return None, "inventory item is not an object"
        path = raw.get("path")
        if not isinstance(path, str) or not path.strip() or len(path) > 512:
            return None, "inventory item needs a path"
        kind = raw.get("kind", "normal")
        if kind not in KINDS:
            return None, f"{path}: kind must be one of {', '.join(KINDS)}"
        lens = raw.get("lens", "front")
        if lens not in LENSES:
            return None, f"{path}: lens must be one of {', '.join(LENSES)}"
        size = raw.get("size")
        if not (isinstance(size, int) and not isinstance(size, bool) and size >= 0):
            return None, f"{path}: size must be a whole number of bytes"
        duration = raw.get("duration_s", raw.get("duration"))
        duration = float(duration) if _finite(duration) and duration >= 0 else None
        start_ts = parse_iso(raw.get("start"))
        return {"path": path, "kind": kind, "lens": lens, "size": size, "duration_s": duration,
                "start": now_iso(start_ts) if start_ts is not None else None}, None

    def _new_clip(self, camera_id: str, item: dict, now: str) -> dict:
        return {
            "id": self.clip_id(camera_id, item["path"]), "camera_id": camera_id, "path": item["path"],
            "name": item["path"].replace("\\", "/").rsplit("/", 1)[-1],
            "kind": item["kind"], "lens": item["lens"], "start": item["start"],
            "duration_s": item["duration_s"], "size": item["size"],
            "on_camera": True, "size_stable": False, "first_seen": now, "last_seen": now,
            "has_gps": False, "has_thumb": False,
            "phone": {"state": "none", "error": None, "updated_at": now},
            "upload": _empty_upload(), "destinations": {}, "drive_id": None,
            "container": None, "staged_name": None,
        }

    def _drop_upload(self, upload_id) -> None:
        if not upload_id:
            return
        try:
            self._upload_path(upload_id).unlink()
        except FileNotFoundError:
            pass
        # The .part, the remuxed .mp4 and any remux still being written (it then fails and is discarded).
        for p in (self.base / "staging").glob(f"{_safe_id(upload_id)}.*"):
            try:
                p.unlink()
            except FileNotFoundError:
                pass

    def apply_inventory(self, camera_id: str, items: list, warnings: list | None = None) -> list[dict]:
        """Upserts one full camera listing. A size that changed since the last listing makes the
        clip unstable and, unless its upload is done, throws the upload away (the camera was still
        writing it); the same size twice makes it stable. This camera's clips missing from the
        listing are marked off the camera. Returns compact rows for the listed clips."""
        now = now_iso()
        rows = []
        dests = self._dest_doc()
        with _LOCK:
            seen: set[str] = set()
            for raw in items if isinstance(items, list) else []:
                item, why = self.normalize_item(raw)
                if item is None:
                    if warnings is not None:
                        warnings.append(why)
                    continue
                cid = self.clip_id(camera_id, item["path"])
                if cid in seen:
                    continue
                seen.add(cid)
                clip = self.get_clip(cid)
                if clip is None:
                    clip = self._new_clip(camera_id, item, now)
                else:
                    changed = clip.get("size") != item["size"]
                    clip["size_stable"] = not changed
                    if changed and (clip.get("upload") or {}).get("state") != "done":
                        self._drop_upload((clip.get("upload") or {}).get("upload_id"))
                        _reset_upload(clip)
                    for key in ("kind", "lens", "size"):
                        clip[key] = item[key]
                    for key in ("start", "duration_s"):
                        if item[key] is not None:
                            clip[key] = item[key]
                    clip["on_camera"] = True
                    clip["last_seen"] = now
                self._save_clip(clip)
                rows.append(self._row(clip, dests))
            for clip in self.all_clips():
                if clip.get("camera_id") == camera_id and clip["id"] not in seen and clip.get("on_camera"):
                    clip["on_camera"] = False
                    self._save_clip(clip)
        return rows

    @staticmethod
    def _row(clip: dict, dests: dict) -> dict:
        return {"id": clip["id"], "path": clip["path"], "has_gps": bool(clip.get("has_gps")),
                "has_thumb": bool(clip.get("has_thumb")), "uploaded": _is_uploaded(clip, dests),
                "size_stable": bool(clip.get("size_stable"))}

    def list_clips(self, *, kind=None, lens=None, state=None, drive=None, start_from=None, start_to=None,
                   cursor=None, limit=100) -> tuple[list[dict], str | None]:
        """Newest first. ``cursor`` is the last id of the previous page; the next cursor is None at the end."""
        dests = self._dest_doc()
        lo = parse_iso(start_from) if start_from else None
        hi = parse_iso(start_to) if start_to else None
        out = []
        for clip in self.all_clips():
            if kind and clip.get("kind") != kind:
                continue
            if lens and clip.get("lens") != lens:
                continue
            if drive and clip.get("drive_id") != drive:
                continue
            if state and not _matches_state(clip, state, dests):
                continue
            if lo is not None or hi is not None:
                ts = parse_iso(clip.get("start"))
                if ts is None or (lo is not None and ts < lo) or (hi is not None and ts > hi):
                    continue
            out.append(clip)
        out.sort(key=_sort_key, reverse=True)
        if cursor:
            anchor = self.get_clip(cursor)
            if anchor is not None:
                key = _sort_key(anchor)
                out = [c for c in out if _sort_key(c) < key]
        limit = max(1, min(int(limit or 100), 1000))
        page = out[:limit]
        nxt = page[-1]["id"] if len(out) > limit else None
        return page, nxt

    def set_phone_state(self, clip_id: str, state: str, error: str | None = None) -> dict | None:
        if state not in PHONE_STATES:
            raise ValueError(f"phone state must be one of {', '.join(PHONE_STATES)}")
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None:
                return None
            clip["phone"] = {"state": state, "error": (str(error)[:500] if error else None),
                             "updated_at": now_iso()}
            self._save_clip(clip)
        return clip

    def assign_drive_ids(self, mapping: dict) -> None:
        """Sets ``drive_id`` on each listed clip (None clears it); writes only what changed."""
        with _LOCK:
            for clip_id, drive_id in mapping.items():
                clip = self.get_clip(clip_id)
                if clip is not None and clip.get("drive_id") != drive_id:
                    clip["drive_id"] = drive_id
                    self._save_clip(clip)

    def is_uploaded(self, clip: dict, dests: dict | None = None) -> bool:
        """Every enabled destination taking the clip has it (or its staging is already released)."""
        return _is_uploaded(clip, self._dest_doc() if dests is None else dests)

    def destinations_by_id(self) -> dict:
        return self._dest_doc()

    def counts(self) -> dict:
        dests = self._dest_doc()
        clips = self.all_clips()
        out = {"clips": len(clips)}
        for name in ("on_camera_only", "on_phone", "pending_upload", "uploaded", "failed"):
            out[name] = sum(1 for c in clips if _matches_state(c, name, dests))
        return out

    # ── fixes ────────────────────────────────────────────────────────────────
    def put_fixes(self, clip_id: str, fixes) -> tuple[bool, list[str]]:
        """Stores a clip's GPS track. Invalid fixes are dropped (counted in the warnings) and the
        rest sorted by time; an all-invalid list clears the track. Returns ``(ok, warnings|errors)``."""
        if not isinstance(fixes, list):
            return False, ["fixes must be a list"]
        if len(fixes) > MAX_FIXES:
            return False, [f"at most {MAX_FIXES} fixes per clip"]
        max_t = time.time() + FIX_MAX_AHEAD_S
        kept = []
        for fix in fixes:
            if not isinstance(fix, (list, tuple)) or len(fix) != 5:
                continue
            t, lat, lon, speed, heading = fix
            if not (_finite(t) and FIX_MIN_T <= t <= max_t):
                continue
            if not (_finite(lat) and _finite(lon) and -90 <= lat <= 90 and -180 <= lon <= 180):
                continue
            if lat == 0 and lon == 0:
                continue
            if speed is not None and not (_finite(speed) and 0 <= speed <= MAX_SPEED_MPS):
                continue
            if heading is not None and not (_finite(heading) and 0 <= heading <= 360):
                continue
            kept.append([float(t), float(lat), float(lon),
                         None if speed is None else float(speed),
                         None if heading is None else float(heading)])
        kept.sort(key=lambda f: f[0])
        dropped = len(fixes) - len(kept)
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None:
                return False, ["clip not found"]
            _write_json(self._fixes_path(clip_id), {"fixes": kept})
            clip["has_gps"] = bool(kept)
            self._save_clip(clip)
        return True, ([f"dropped {dropped} invalid fixes"] if dropped else [])

    def get_fixes(self, clip_id: str) -> list:
        doc = _read_json(self._fixes_path(clip_id), None)
        fixes = doc.get("fixes") if isinstance(doc, dict) else None
        return fixes if isinstance(fixes, list) else []

    # ── thumbnails ───────────────────────────────────────────────────────────
    def put_thumb(self, clip_id: str, jpeg: bytes) -> tuple[bool, str | None]:
        if not isinstance(jpeg, (bytes, bytearray)) or not jpeg.startswith(b"\xff\xd8"):
            return False, "thumbnail must be a JPEG"
        if len(jpeg) > THUMB_MAX_BYTES:
            return False, "thumbnail is larger than 512 KiB"
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None:
                return False, "clip not found"
            p = self._thumb_file(clip_id)
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_suffix(".jpg.tmp")
            tmp.write_bytes(bytes(jpeg))
            os.replace(tmp, p)
            clip["has_thumb"] = True
            self._save_clip(clip)
        return True, None

    def thumb_path(self, clip_id: str) -> Path | None:
        p = self._thumb_file(clip_id)
        return p if p.is_file() else None

    # ── destinations (metadata only) ─────────────────────────────────────────
    def _dest_doc(self) -> dict:
        doc = _read_json(self.base / "destinations.json", None)
        dests = doc.get("destinations") if isinstance(doc, dict) else None
        return {k: v for k, v in dests.items() if isinstance(v, dict)} if isinstance(dests, dict) else {}

    def _save_dests(self, dests: dict) -> None:
        _write_json(self.base / "destinations.json", {"destinations": dests})

    def destinations(self) -> list[dict]:
        return sorted(self._dest_doc().values(), key=lambda d: (str(d.get("created_at") or ""), d.get("id", "")))

    def get_destination(self, dest_id: str) -> dict | None:
        return self._dest_doc().get(dest_id)

    @staticmethod
    def new_destination_id() -> str:
        return "d_" + secrets.token_hex(4)

    def add_destination(self, meta: dict) -> dict:
        """Stores a destination's metadata (never its password or token); id ``d_<8 hex>``."""
        with _LOCK:
            dests = self._dest_doc()
            dest_id = meta.get("id") if isinstance(meta.get("id"), str) and _DEST_ID.match(meta["id"]) else None
            while dest_id is None or dest_id in dests:
                dest_id = self.new_destination_id()
            kinds = meta.get("kinds")
            dest = {
                "id": dest_id, "type": meta.get("type"), "name": meta.get("name"),
                "remote": meta.get("remote") or "", "path": meta.get("path") or "",
                "enabled": meta.get("enabled", True) is not False,
                "kinds": [k for k in kinds if k in KINDS] if isinstance(kinds, list) else list(KINDS),
                "host": meta.get("host"), "port": meta.get("port"), "user": meta.get("user"),
                "status": "new", "error": None, "created_at": now_iso(), "tested_at": None,
            }
            dests[dest_id] = {k: dest[k] for k in _DEST_FIELDS}
            self._save_dests(dests)
        return dests[dest_id]

    def update_destination(self, dest_id: str, patch: dict) -> dict | None:
        with _LOCK:
            dests = self._dest_doc()
            dest = dests.get(dest_id)
            if dest is None:
                return None
            for key, value in (patch or {}).items():
                if key not in _DEST_PATCHABLE:
                    continue
                if key == "kinds":
                    value = [k for k in value if k in KINDS] if isinstance(value, list) else dest.get("kinds")
                if key == "enabled":
                    value = bool(value)
                dest[key] = value
            self._save_dests(dests)
        return dest

    def delete_destination(self, dest_id: str) -> bool:
        with _LOCK:
            dests = self._dest_doc()
            if dest_id not in dests:
                return False
            del dests[dest_id]
            self._save_dests(dests)
        return True

    def set_destination_state(self, clip_id: str, dest_id: str, state: str, error=None, remote_path=None,
                              *, attempts: int | None = None, next_at: float | None = None,
                              upload_id: str | None = None) -> dict | None:
        """``upload_id`` (the relay always passes it) is the upload the copy was made from: when the
        clip has moved on to another upload since, the update is ignored and None returned - a copy
        of the old bytes must never mark the new ones done."""
        if state not in DEST_STATES:
            raise ValueError(f"destination state must be one of {', '.join(DEST_STATES)}")
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None:
                return None
            if upload_id is not None and (clip.get("upload") or {}).get("upload_id") != upload_id:
                return None
            entries = clip.setdefault("destinations", {})
            entry = entries.get(dest_id) if isinstance(entries.get(dest_id), dict) else {
                "state": "pending", "error": None, "attempts": 0, "remote_path": None, "next_at": None}
            entry["state"] = state
            entry["error"] = str(error)[:500] if error else None
            if remote_path is not None:
                entry["remote_path"] = remote_path
            if attempts is not None:
                entry["attempts"] = int(attempts)
            entry["next_at"] = next_at
            entry["updated_at"] = now_iso()
            entries[dest_id] = entry
            self._save_clip(clip)
        return clip

    def queue_destinations(self, clip_id: str) -> list[str]:
        """Adds a ``pending`` entry for every enabled destination that applies to a staged clip and
        has none yet (a destination added after the upload finished). Returns the ids added."""
        added = []
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None or (clip.get("upload") or {}).get("state") != "staged":
                return added
            entries = clip.setdefault("destinations", {})
            for dest in self._dest_doc().values():
                if _applicable(dest, clip) and dest["id"] not in entries:
                    entries[dest["id"]] = {"state": "pending", "error": None, "attempts": 0,
                                           "remote_path": None, "next_at": None, "updated_at": now_iso()}
                    added.append(dest["id"])
            if added:
                self._save_clip(clip)
        return added

    def retry_destinations(self, clip_id: str) -> int | None:
        """Re-queues the clip's failed destinations with a fresh retry budget; None if no such clip."""
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None:
                return None
            n = 0
            for entry in (clip.get("destinations") or {}).values():
                if isinstance(entry, dict) and entry.get("state") == "failed":
                    entry.update({"state": "pending", "error": None, "attempts": 0, "next_at": None,
                                  "updated_at": now_iso()})
                    n += 1
            if n:
                self._save_clip(clip)
        return n

    # ── uploads + staging ────────────────────────────────────────────────────
    def get_upload(self, upload_id: str) -> dict | None:
        doc = _read_json(self._upload_path(upload_id), None)
        if not isinstance(doc, dict) or doc.get("id") != upload_id:
            return None
        doc["complete"] = bool(doc.get("completed_at"))
        return doc

    def _uploads(self) -> list[dict]:
        d = self.base / "uploads"
        if not d.is_dir():
            return []
        out = []
        for p in d.glob("*.json"):
            doc = _read_json(p, None)
            if isinstance(doc, dict) and isinstance(doc.get("id"), str):
                out.append(doc)
        return out

    def _save_upload(self, doc: dict) -> None:
        doc = {k: v for k, v in doc.items() if k != "complete"}
        _write_json(self._upload_path(doc["id"]), doc)

    def staging_bytes(self) -> int:
        """Bytes reserved in staging: the full size of every upload still arriving, and the real
        on-disk size of every staged one (a remuxed MP4 is a little smaller than its .ts)."""
        return sum(int(u.get("staged_size", u.get("size")) or 0) for u in self._uploads())

    def staged_clip_ids(self) -> list[str]:
        """Clips whose bytes are checked and waiting in staging for the relay."""
        return sorted({u["clip_id"] for u in self._uploads() if u.get("completed_at") and u.get("clip_id")})

    def _has_room(self, size: int, cap: int, staging: Path) -> bool:
        """Under the staging cap, and the disk keeps DISK_RESERVE_BYTES free after this upload."""
        if self.staging_bytes() + size > cap:
            return False
        try:
            free = shutil.disk_usage(staging).free
        except OSError:
            return True
        return free - size >= DISK_RESERVE_BYTES

    def _purge_idle_uploads(self, now: float) -> None:
        for u in self._uploads():
            if u.get("completed_at") or now - float(u.get("updated_at") or 0) < IDLE_UPLOAD_S:
                continue
            self._drop_upload(u["id"])
            clip = self.get_clip(u.get("clip_id") or "")
            if clip is not None and (clip.get("upload") or {}).get("upload_id") == u["id"]:
                clip["upload"] = _empty_upload()
                self._save_clip(clip)

    def create_upload(self, clip_id: str, size: int, sha256: str, chunk_size: int) -> tuple[dict | None, str | None]:
        """Opens (or resumes) the upload of one clip's bytes. The same clip + size + sha256 returns
        the open upload with the chunks already received; once the bytes are staged it comes back
        ``complete`` and after release the answer is ``already_uploaded``. Errors: clip_not_found,
        bad_request, no_destination (no enabled destination takes the clip's kind: the phone keeps
        the file and asks again later), too_large (bigger than the staging cap), staging_full."""
        if not (isinstance(size, int) and not isinstance(size, bool) and size > 0):
            return None, "bad_request"
        if not isinstance(sha256, str) or not _SHA256.match(sha256.lower()):
            return None, "bad_request"
        if not (isinstance(chunk_size, int) and not isinstance(chunk_size, bool) and 0 < chunk_size <= CHUNK_SIZE):
            return None, "bad_request"
        sha256 = sha256.lower()
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None:
                return None, "clip_not_found"
            up = clip.get("upload") or _empty_upload()
            same = up.get("sha256") == sha256
            if up.get("state") == "done" and same:
                return None, "already_uploaded"
            if not any(_applicable(d, clip) for d in self._dest_doc().values()):
                return None, "no_destination"  # staged bytes nobody takes would sit in staging forever
            if up.get("upload_id"):
                existing = self.get_upload(up["upload_id"])
                # Resume with the chunk size it was opened with once any chunk is in; one that never got a
                # chunk (it stalled at 0%) starts over at the size the phone asks for now.
                if existing and same and existing.get("size") == size and (
                        existing.get("chunk_size") == chunk_size or existing.get("received")):
                    return existing, None
                self._drop_upload(up["upload_id"])
                _reset_upload(clip)
                self._save_clip(clip)
            cap = self.get_settings()["staging_cap_bytes"]
            if size > cap:
                return None, "too_large"
            now = time.time()
            staging = self.base / "staging"
            staging.mkdir(parents=True, exist_ok=True)
            if not self._has_room(size, cap, staging):
                self._purge_idle_uploads(now)
                if not self._has_room(size, cap, staging):
                    return None, "staging_full"
            doc = {"id": "u_" + secrets.token_hex(8), "clip_id": clip_id, "size": size, "sha256": sha256,
                   "chunk_size": chunk_size, "chunks": math.ceil(size / chunk_size), "received": [],
                   "created_at": now, "updated_at": now, "completed_at": None}
            self._save_upload(doc)
            # The .part exists from the start, so write_chunk never has to create it.
            os.close(os.open(self.staging_path(doc["id"]), os.O_RDWR | os.O_CREAT, 0o600))
            clip["upload"] = {"state": "staging", "upload_id": doc["id"], "bytes": 0, "sha256": sha256}
            self._save_clip(clip)
        doc["complete"] = False
        return doc, None

    def write_chunk(self, upload_id: str, n: int, data: bytes) -> tuple[dict | None, str | None]:
        """Writes chunk ``n`` at ``n * chunk_size``; every chunk is ``chunk_size`` long except the last.
        Re-sending a chunk is harmless. Errors: upload_not_found, bad_chunk_index, bad_chunk_length."""
        up = self.get_upload(upload_id)
        if up is None:
            return None, "upload_not_found"
        if not (isinstance(n, int) and not isinstance(n, bool) and 0 <= n < up["chunks"]):
            return None, "bad_chunk_index"
        expected = up["chunk_size"] if n < up["chunks"] - 1 else up["size"] - up["chunk_size"] * (up["chunks"] - 1)
        if len(data) != expected:
            return None, "bad_chunk_length"
        if up.get("completed_at"):
            return up, None  # the checked bytes are never rewritten
        path = self.staging_path(upload_id)
        with _LOCK:
            # Opened only after re-checking, under the lock, that the upload still exists: a drop
            # (new camera size, idle purge, replaced upload) can't slip in between and leave an
            # orphan .part behind. A drop after the open just writes into the unlinked file.
            current = self.get_upload(upload_id)
            if current is None:
                return None, "upload_not_found"
            if current.get("completed_at"):
                return current, None
            try:
                fd = os.open(path, os.O_RDWR)
            except FileNotFoundError:   # an upload opened before create_upload made the .part
                path.parent.mkdir(parents=True, exist_ok=True)
                fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            os.pwrite(fd, data, n * up["chunk_size"])
        finally:
            os.close(fd)
        with _LOCK:
            up = self.get_upload(upload_id)
            if up is None:
                return None, "upload_not_found"
            if n not in up["received"]:
                up["received"] = sorted(set(up["received"]) | {n})
            up["updated_at"] = time.time()
            self._save_upload(up)
            clip = self.get_clip(up["clip_id"])
            if clip is not None and (clip.get("upload") or {}).get("upload_id") == upload_id:
                got = sum(up["chunk_size"] if i < up["chunks"] - 1 else
                          up["size"] - up["chunk_size"] * (up["chunks"] - 1) for i in up["received"])
                clip["upload"]["bytes"] = got
                self._save_clip(clip)
        return up, None

    def complete_upload(self, upload_id: str) -> tuple[dict | None, str | None]:
        """Checks every chunk is in, the size and the sha256, remuxes a ``.ts`` clip to MP4, then
        stages the clip and queues it for every enabled destination taking its kind. On a hash
        mismatch the received chunks are forgotten so a resume re-sends them. A failed remux keeps
        the ``.ts`` and completes all the same. Errors: upload_not_found, missing_chunks,
        size_mismatch, sha256_mismatch, clip_not_found.

        The hash and the remux (a second or two for a 100 MB clip) run in the request's own thread
        - the server is threaded - outside the store lock: only the swap into place is under it."""
        up = self.get_upload(upload_id)
        if up is None:
            return None, "upload_not_found"
        if up.get("completed_at"):
            clip = self.get_clip(up["clip_id"])
            return (clip, None) if clip is not None else (None, "clip_not_found")
        if len(up["received"]) != up["chunks"]:
            return None, "missing_chunks"
        path = self.staging_path(upload_id)
        try:
            actual = path.stat().st_size
        except FileNotFoundError:
            actual = -1
        digest = hashlib.sha256()
        if actual == up["size"]:
            with open(path, "rb") as f:
                for block in iter(lambda: f.read(1024 * 1024), b""):
                    digest.update(block)
        remuxed = None
        if actual == up["size"] and digest.hexdigest() == up["sha256"]:
            remuxed = self._remux(upload_id, (self.get_clip(up["clip_id"]) or {}).get("name"))
        try:
            with _LOCK:
                up = self.get_upload(upload_id)
                if up is None:
                    return None, "upload_not_found"
                if up.get("completed_at"):
                    # A retried /complete that raced the first: never reset destinations in flight.
                    clip = self.get_clip(up["clip_id"])
                    return (clip, None) if clip is not None else (None, "clip_not_found")
                if actual != up["size"] or digest.hexdigest() != up["sha256"]:
                    up["received"] = []
                    up["updated_at"] = time.time()
                    self._save_upload(up)
                    return None, "size_mismatch" if actual != up["size"] else "sha256_mismatch"
                clip = self.get_clip(up["clip_id"])
                if clip is None:
                    return None, "clip_not_found"
                self._swap_in(up, clip, remuxed)
                up["completed_at"] = time.time()
                self._save_upload(up)
                clip["upload"] = {"state": "staged", "upload_id": upload_id, "bytes": up["size"],
                                  "sha256": up["sha256"]}
                entries = {}
                now = now_iso()
                for dest in self._dest_doc().values():
                    if _applicable(dest, clip):
                        entries[dest["id"]] = {"state": "pending", "error": None, "attempts": 0,
                                               "remote_path": None, "next_at": None, "updated_at": now}
                clip["destinations"] = entries
                self._save_clip(clip)
                if up["remuxed"]:
                    path.unlink(missing_ok=True)   # the .ts, only once the MP4 is recorded
        finally:
            if remuxed is not None:
                remuxed.unlink(missing_ok=True)    # not swapped in (a race, an error): discard it
        return clip, None

    def _remux(self, upload_id: str, name) -> Path | None:
        """A ``.ts`` upload's bytes remuxed to a temporary MP4 beside them (a unique name, so two
        racing callers never share one), or None: not a .ts, or the remux failed (logged)."""
        if not dashcam_remux.is_ts(name):
            return None
        tmp = self.base / "staging" / f"{_safe_id(upload_id)}.{secrets.token_hex(4)}.mp4.tmp"
        why = dashcam_remux.remux(self.staging_path(upload_id), tmp)
        if why is None:
            return tmp
        if why != dashcam_remux.NOT_INSTALLED:   # that one is warned once, by dashcam_remux
            logger.warning("dashcam: remuxing %s (%s) to MP4 failed, keeping the .ts: %s", name, upload_id, why)
        return None

    def _swap_in(self, up: dict, clip: dict, remuxed: Path | None) -> None:
        """Under _LOCK, once the bytes are checked: moves a remuxed MP4 into place and records what
        is staged - ``remuxed`` and ``staged_size`` (the real size on disk) on the upload,
        ``container`` and ``staged_name`` on the clip. The caller saves both and only then drops
        the .part a remux replaced, so a crash in between never loses the bytes."""
        name = str(clip.get("name") or "")
        target = self.staging_path(up["id"])
        if remuxed is not None:
            try:
                os.replace(remuxed, self.remuxed_path(up["id"]))
                target, name = self.remuxed_path(up["id"]), dashcam_remux.mp4_name(name)
            except OSError as exc:
                logger.warning("dashcam: could not move the MP4 of %s into place, keeping the .ts: %s", up["id"], exc)
                remuxed = None
        up["remuxed"] = remuxed is not None
        try:
            up["staged_size"] = target.stat().st_size
        except OSError:
            up["staged_size"] = up["size"]
        clip["container"] = _extension(name)
        clip["staged_name"] = name or None

    def remux_staged(self, clip_id: str) -> bool:
        """Brings a clip staged before uploads were remuxed (its upload records no ``remuxed``) in
        line with a fresh one: a ``.ts`` is remuxed to MP4 (kept as it is when that fails) and what
        is staged gets recorded. The relay worker calls it before it copies a staged clip, so no
        copy of its own is reading the .part; streams read through their open file. True when it
        recorded anything."""
        clip = self.get_clip(clip_id)
        cur = (clip or {}).get("upload") or {}
        upload_id = cur.get("upload_id")
        if cur.get("state") != "staged" or not upload_id:
            return False
        up = self.get_upload(upload_id)
        if up is None or not up.get("completed_at") or "remuxed" in up:
            return False
        remuxed = self._remux(upload_id, clip.get("name"))
        try:
            with _LOCK:
                clip = self.get_clip(clip_id)
                up = self.get_upload(upload_id)
                cur = (clip or {}).get("upload") or {}
                if (up is None or "remuxed" in up or cur.get("state") != "staged"
                        or cur.get("upload_id") != upload_id):
                    return False   # dropped, replaced or recorded meanwhile
                self._swap_in(up, clip, remuxed)
                self._save_upload(up)
                self._save_clip(clip)
                if up["remuxed"]:
                    self.staging_path(upload_id).unlink(missing_ok=True)
        finally:
            if remuxed is not None:
                remuxed.unlink(missing_ok=True)
        return True

    def release_staging_if_done(self, clip_id: str) -> bool:
        """Deletes the staged bytes and the upload once every enabled destination that takes the
        clip reports done (at least one must); the clip's upload becomes ``done``."""
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None or (clip.get("upload") or {}).get("state") != "staged":
                return False
            if not _is_uploaded(clip, self._dest_doc()):
                return False
            self._drop_upload(clip["upload"].get("upload_id"))
            clip["upload"]["state"] = "done"
            self._save_clip(clip)
        return True

    def abandon_upload(self, clip_id: str) -> bool:
        """Drops a staged clip's bytes when no enabled destination takes it any more (its only
        destination was deleted, disabled, or stopped taking its kind). The upload goes back to
        ``none`` - not done: the clip is not uploaded, so the phone keeps it and sends it again
        once a destination takes it. Re-checked under the lock; False when nothing was dropped."""
        with _LOCK:
            clip = self.get_clip(clip_id)
            if clip is None or (clip.get("upload") or {}).get("state") != "staged":
                return False
            if any(_applicable(d, clip) for d in self._dest_doc().values()):
                return False
            self._drop_upload(clip["upload"].get("upload_id"))
            _reset_upload(clip)
            self._save_clip(clip)
        return True

    # ── drives (built by dashcam_drives) ─────────────────────────────────────
    def write_drives(self, drives: list[dict]) -> None:
        with _LOCK:
            _write_json(self.base / "drives.json",
                        {"drives": {d["id"]: d for d in drives}, "built_at": now_iso()})

    def drives(self) -> list[dict]:
        doc = _read_json(self.base / "drives.json", None)
        drives = doc.get("drives") if isinstance(doc, dict) else None
        if not isinstance(drives, dict):
            return []
        out = [d for d in drives.values() if isinstance(d, dict)]
        out.sort(key=lambda d: (str(d.get("start") or ""), str(d.get("id"))), reverse=True)
        return out

    def get_drive(self, drive_id: str) -> dict | None:
        doc = _read_json(self.base / "drives.json", None)
        drives = doc.get("drives") if isinstance(doc, dict) else None
        d = drives.get(drive_id) if isinstance(drives, dict) else None
        return d if isinstance(d, dict) else None

    # ── aggregate view for GET /state ────────────────────────────────────────
    def snapshot(self) -> dict:
        settings = self.get_settings()
        return {"cameras": self.cameras(), "settings": settings, "destinations": self.destinations(),
                "counts": self.counts(),
                "staging": {"bytes": self.staging_bytes(), "cap": settings["staging_cap_bytes"]}}


def store_for_request() -> DashcamStore:
    """Build a store rooted at the webui state dir for the active profile."""
    root = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if not root:
        root = str(Path.home() / ".jarviscopilot" / "webui")
    try:
        from api.profiles import get_active_profile_name
        profile = get_active_profile_name()
    except Exception:
        profile = "default"
    return DashcamStore(root, profile)
