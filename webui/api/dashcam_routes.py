"""HTTP API for the dashcam: ``/api/dashcam/*`` (normal session-cookie auth, like the rest of /api).

Three entry points, wired from ``routes.py``:

- ``handle_dashcam_request(method, path, query, body, store)`` - the JSON endpoints, pure:
  returns ``(status, payload)`` for ``j(handler, payload, status=status)``. ``path`` is the part
  after ``/api/dashcam`` (a ``?query`` on it is merged into ``query``).
- ``handle_dashcam_raw_post(handler, path, store)`` - raw-body POSTs, dispatched before
  ``read_body``: chunk uploads and thumbnails. Returns False for every other path without
  touching the body.
- ``handle_dashcam_binary_get(handler, path, store)`` - thumbnail JPEG, Range-aware clip stream,
  drive GPX. Returns False for every other path.

Endpoints (GET/POST/DELETE only)::

    GET    /state                       -> {cameras, settings, destinations, counts, staging:{bytes, cap}, relay:{installed}}
    POST   /cameras  {id, ...}          -> {ok, camera}
    POST   /settings {rules:{...}, staging_cap_bytes?}   (flat rule keys also accepted) -> {ok, settings}
    POST   /inventory {camera_id, clips:[{path, kind, lens, start, duration, size}]}
                                        -> {ok, clips:[{id, path, has_gps, has_thumb, uploaded, size_stable}], warnings}
    POST   /clips/<id>/gps {fixes:[[t, lat, lon, speed|null, heading|null], ...]} -> {ok, has_gps, warnings}
    POST   /clips/<id>/thumb            raw JPEG (<= 512 KiB) -> {ok}
    POST   /clips/<id>/phone {state, error?} -> {ok, phone}
    POST   /clips/<id>/retry            -> {ok, requeued}
    GET    /clips?kind&lens&state&drive&from&to&cursor&limit -> {clips, next}
    GET    /clips/<id>                  -> {ok, clip, fixes, destinations:[{id, name, type, state, error, attempts, remote_path, next_at, updated_at}]}
    GET    /clips/<id>/thumb            -> image/jpeg
    GET    /clips/<id>/stream           -> clip bytes (Range/206): staging file first, else the first
                                           destination that has it, through rclone; 404 before upload.
                                           A remuxed clip is video/mp4 (the clip's container says which)
    POST   /uploads {clip_id, size, sha256} -> {ok, upload_id, chunk_size, chunks, received, complete[, already_uploaded]}
                                           | 507 {ok:false, error:"staging_full", retry_after} | 413 too_large
                                           | 409 {ok:false, error:"no_destination"} (no enabled destination
                                             takes the clip's kind: keep the file, ask again later)
    GET    /uploads/<id>                -> {ok, upload_id, size, chunk_size, chunks, received, complete}
    POST   /uploads/<id>/chunk?n=<n>    raw bytes (<= chunk_size) -> {ok, received, chunks}
    POST   /uploads/<id>/complete       -> {ok, clip} | 400 {error: missing_chunks (+missing) | size_mismatch | sha256_mismatch}
                                           (a .ts clip is remuxed to MP4 first, in this request; see dashcam_store)
    GET    /drives?from&to              -> {drives}
    GET    /drives/<id>                 -> {ok, drive, polyline:[[lat, lon, speed], ...], clips}
    GET    /drives/<id>.gpx             -> application/gpx+xml
    GET    /destinations                -> {destinations}
    POST   /destinations {type: drive|sftp|ftp|smb, name, path?, kinds?, enabled?, host?, port?, user?,
                          password?, token?, client_id?, client_secret?} -> {ok, destination}
    POST   /destinations/<id> {name?, enabled?, kinds?, path?} -> {ok, destination}
    POST   /destinations/<id>/test      -> {ok, error?}
    POST   /destinations/<id>/delete    -> {ok}            (alias of DELETE /destinations/<id>)

Clips carry ``container`` (``"mp4"`` once a ``.ts`` was remuxed, ``"ts"`` when it was kept as it
is, null before an upload) and ``staged_name`` (the name destinations get it under) beside the
camera's ``name``.

Passwords and tokens go straight to rclone's config (``dashcam_relay.create_remote``) and are
never stored in the dashcam store, echoed, or logged.
"""
from __future__ import annotations

import logging
import re
import threading
import time
from urllib.parse import parse_qs

from api import dashcam_drives, dashcam_relay
from api.dashcam_relay import RelayError, RelayUnavailable
from api.dashcam_store import CHUNK_SIZE as _STORE_CHUNK_SIZE, MIN_CHUNK_SIZE
from api.dashcam_store import KINDS, LENSES, PHONE_STATES, STATE_FILTERS, THUMB_MAX_BYTES, parse_iso

logger = logging.getLogger(__name__)

DASHCAM_PATH_PREFIX = "/api/dashcam"
CHUNK_SIZE = _STORE_CHUNK_SIZE          # 16 MiB: under the edge nginx's 64 MiB body cap
RETRY_AFTER_S = 60
REBUILD_MIN_S = 2.0
_MAX_LIMIT = 500

_CLIP = r"(c_[0-9a-f]{20})"
_UPLOAD = r"(u_[0-9a-f]{16})"
_DEST = r"(d_[0-9a-f]{8})"
_DRIVE = r"(dr_[0-9]+_[A-Za-z0-9_-]{0,6})"
_RE_CLIP = re.compile(rf"^/clips/{_CLIP}$")
_RE_CLIP_ACTION = re.compile(rf"^/clips/{_CLIP}/(gps|phone|retry|delete_cloud|forget)$")
_RE_CLIP_THUMB = re.compile(rf"^/clips/{_CLIP}/thumb$")
_RE_CLIP_STREAM = re.compile(rf"^/clips/{_CLIP}/stream$")
_RE_UPLOAD = re.compile(rf"^/uploads/{_UPLOAD}$")
_RE_UPLOAD_COMPLETE = re.compile(rf"^/uploads/{_UPLOAD}/complete$")
_RE_UPLOAD_CHUNK = re.compile(rf"^/uploads/{_UPLOAD}/chunk$")
_RE_DRIVE = re.compile(rf"^/drives/{_DRIVE}$")
_RE_DRIVE_GPX = re.compile(rf"^/drives/{_DRIVE}\.gpx$")
_RE_DEST = re.compile(rf"^/destinations/{_DEST}$")
_RE_DEST_ACTION = re.compile(rf"^/destinations/{_DEST}/(test|delete|token)$")
_RE_CLIP_DIRECT = re.compile(rf"^/clips/{_CLIP}/direct$")

_UNKNOWN = (404, {"ok": False, "error": "unknown dashcam endpoint"})


# ── helpers ──────────────────────────────────────────────────────────────────

def _split(path: str, query=None) -> tuple[str, dict]:
    """Path without the prefix, query string or trailing slash; plus a flat query dict."""
    path = path or "/"
    if path.startswith(DASHCAM_PATH_PREFIX):
        path = path[len(DASHCAM_PATH_PREFIX):] or "/"
    flat: dict[str, str] = {}
    for key, value in (query or {}).items():
        flat[key] = value[-1] if isinstance(value, list) and value else value if isinstance(value, str) else ""
    if "?" in path:
        path, qs = path.split("?", 1)
        for key, values in parse_qs(qs).items():
            flat.setdefault(key, values[-1])
    if len(path) > 1:
        path = path.rstrip("/") or "/"
    return path, flat


def _relay(relay):
    return relay if relay is not None else dashcam_relay.relay()


def _err(status: int, error: str, **extra) -> tuple[int, dict]:
    return status, {"ok": False, "error": error, **extra}


def _upload_reply(up: dict) -> dict:
    return {"ok": True, "upload_id": up["id"], "size": up["size"], "chunk_size": up["chunk_size"],
            "chunks": up["chunks"], "received": up["received"], "complete": bool(up.get("complete"))}


# ── drive rebuilds: at most one per REBUILD_MIN_S per store, the last call always lands ──

_rebuild_lock = threading.Lock()
_rebuild_run_lock = threading.Lock()
_rebuild_last: dict[str, float] = {}
_rebuild_timers: dict[str, threading.Timer] = {}


def _run_rebuild(store, key: str) -> None:
    with _rebuild_lock:
        _rebuild_timers.pop(key, None)
        _rebuild_last[key] = time.monotonic()
    try:
        with _rebuild_run_lock:
            dashcam_drives.rebuild(store)
    except Exception:
        logger.exception("dashcam drive rebuild failed")


def schedule_rebuild(store) -> None:
    """Rebuilds drives now if the last rebuild is older than REBUILD_MIN_S, else once when it is."""
    key = str(store.base)
    with _rebuild_lock:
        if key in _rebuild_timers:
            return
        wait = _rebuild_last.get(key, -REBUILD_MIN_S) + REBUILD_MIN_S - time.monotonic()
        if wait > 0:
            timer = threading.Timer(wait, _run_rebuild, args=(store, key))
            timer.daemon = True
            _rebuild_timers[key] = timer
            timer.start()
            return
        _rebuild_last[key] = time.monotonic()
    try:
        with _rebuild_run_lock:
            dashcam_drives.rebuild(store)
    except Exception:
        logger.exception("dashcam drive rebuild failed")


# ── JSON dispatcher ──────────────────────────────────────────────────────────

def handle_dashcam_request(method: str, path: str, query, body, store, *, relay=None) -> tuple[int, dict]:
    body = body if isinstance(body, dict) else {}
    p, q = _split(path, query)

    if method == "GET":
        if p == "/state":
            snap = store.snapshot()
            try:
                snap["relay"] = {"installed": bool(_relay(relay).binary())}
            except Exception:
                snap["relay"] = {"installed": False}
            return 200, snap
        if p == "/clips":
            return _list_clips(store, q)
        if p == "/drives":
            return _list_drives(store, q)
        if p == "/destinations":
            return 200, {"destinations": store.destinations()}
        m = _RE_CLIP.match(p)
        if m:
            return _get_clip(store, m.group(1))
        m = _RE_UPLOAD.match(p)
        if m:
            up = store.get_upload(m.group(1))
            return (200, _upload_reply(up)) if up else _err(404, "upload not found")
        m = _RE_DRIVE.match(p)
        if m:
            return _get_drive(store, m.group(1))
        return _UNKNOWN

    if method == "POST":
        if p == "/cameras":
            return _cameras(store, body)
        if p == "/settings":
            return _settings(store, body)
        if p == "/inventory":
            return _inventory(store, body)
        if p == "/uploads":
            return _create_upload(store, body)
        if p == "/destinations":
            return _create_destination(store, body, relay)
        m = _RE_CLIP_ACTION.match(p)
        if m:
            cid, action = m.groups()
            if action == "gps":
                return _gps(store, cid, body)
            if action == "phone":
                return _phone(store, cid, body)
            if action == "delete_cloud":
                return _delete_cloud(store, cid, relay)
            if action == "forget":
                return (200, {"ok": True}) if store.forget_clip(cid) else _err(404, "clip not found")
            n = store.retry_destinations(cid)
            return (200, {"ok": True, "requeued": n}) if n is not None else _err(404, "clip not found")
        m = _RE_UPLOAD_COMPLETE.match(p)
        if m:
            return _complete(store, m.group(1))
        m = _RE_DEST.match(p)
        if m:
            return _update_destination(store, m.group(1), body)
        m = _RE_DEST_ACTION.match(p)
        if m:
            did, action = m.groups()
            if action == "test":
                return _test_destination(store, did, relay)
            if action == "token":
                return _destination_token(store, did, relay)
            return _delete_destination(store, did, relay)
        m = _RE_CLIP_DIRECT.match(p)
        if m:
            return _record_direct(store, m.group(1), body)
        return _UNKNOWN

    if method == "DELETE":
        m = _RE_DEST.match(p)
        if m:
            return _delete_destination(store, m.group(1), relay)
        return _UNKNOWN

    return 405, {"ok": False, "error": f"method {method} not allowed"}


def _cameras(store, body):
    camera = body.get("camera") if isinstance(body.get("camera"), dict) else body
    try:
        return 200, {"ok": True, "camera": store.upsert_camera(camera)}
    except ValueError as exc:
        return _err(400, str(exc))




def _settings(store, body):
    if "rules" in body or "staging_cap_bytes" in body:
        patch = body
    else:
        patch = {"rules": {k: body[k] for k in body}} if body else {}
    saved, errors = store.update_settings(patch)
    if saved is None:
        return 400, {"ok": False, "error": "; ".join(errors[:3]), "errors": errors}
    return 200, {"ok": True, "settings": saved}


def _inventory(store, body):
    camera_id = body.get("camera_id")
    if not isinstance(camera_id, str) or not camera_id.strip():
        return _err(400, "camera_id is required")
    clips = body.get("clips")
    if not isinstance(clips, list):
        return _err(400, "clips must be a list")
    camera_id = camera_id.strip()[:64]
    store.upsert_camera({"id": camera_id})
    warnings: list[str] = []
    rows = store.apply_inventory(camera_id, clips, warnings=warnings)
    return 200, {"ok": True, "clips": rows, "warnings": warnings}


def _gps(store, cid, body):
    if store.get_clip(cid) is None:
        return _err(404, "clip not found")
    fixes = body.get("fixes")
    ok, notes = store.put_fixes(cid, fixes)
    if not ok:
        return 400, {"ok": False, "error": "; ".join(notes), "errors": notes}
    schedule_rebuild(store)
    clip = store.get_clip(cid) or {}
    return 200, {"ok": True, "has_gps": bool(clip.get("has_gps")), "warnings": notes}


def _phone(store, cid, body):
    state = body.get("state")
    if state not in PHONE_STATES:
        return _err(400, f"state must be one of {', '.join(PHONE_STATES)}")
    error = body.get("error") if isinstance(body.get("error"), str) else None
    clip = store.set_phone_state(cid, state, error)
    if clip is None:
        return _err(404, "clip not found")
    return 200, {"ok": True, "phone": clip["phone"]}


def _list_clips(store, q):
    for key, allowed in (("kind", KINDS), ("lens", LENSES), ("state", STATE_FILTERS)):
        if q.get(key) and q[key] not in allowed:
            return _err(400, f"{key} must be one of {', '.join(allowed)}")
    for key in ("from", "to"):
        if q.get(key) and parse_iso(q[key]) is None:
            return _err(400, f"{key} must be an ISO-8601 time")
    try:
        limit = int(q.get("limit") or 100)
    except ValueError:
        return _err(400, "limit must be a number")
    limit = max(1, min(limit, _MAX_LIMIT))
    clips, nxt = store.list_clips(kind=q.get("kind") or None, lens=q.get("lens") or None,
                                  state=q.get("state") or None, drive=q.get("drive") or None,
                                  start_from=q.get("from") or None, start_to=q.get("to") or None,
                                  cursor=q.get("cursor") or None, limit=limit)
    dests = store.destinations_by_id()
    for clip in clips:
        clip["uploaded"] = store.is_uploaded(clip, dests)
    return 200, {"clips": clips, "next": nxt}


def _dest_rows(store, clip: dict) -> list[dict]:
    dests = store.destinations_by_id()
    rows = []
    for did, entry in (clip.get("destinations") or {}).items():
        if not isinstance(entry, dict):
            continue
        dest = dests.get(did) or {}
        rows.append({"id": did, "name": dest.get("name"), "type": dest.get("type"),
                     "state": entry.get("state"), "error": entry.get("error"),
                     "attempts": entry.get("attempts", 0), "remote_path": entry.get("remote_path"),
                     "next_at": entry.get("next_at"), "updated_at": entry.get("updated_at")})
    return rows


def _get_clip(store, cid):
    clip = store.get_clip(cid)
    if clip is None:
        return _err(404, "clip not found")
    clip["uploaded"] = store.is_uploaded(clip)
    return 200, {"ok": True, "clip": clip, "fixes": store.get_fixes(cid), "destinations": _dest_rows(store, clip)}


def _list_drives(store, q):
    lo = parse_iso(q.get("from")) if q.get("from") else None
    hi = parse_iso(q.get("to")) if q.get("to") else None
    if (q.get("from") and lo is None) or (q.get("to") and hi is None):
        return _err(400, "from/to must be ISO-8601 times")
    out = []
    for d in store.drives():
        start, end = parse_iso(d.get("start")), parse_iso(d.get("end"))
        if lo is not None and (end if end is not None else start or 0) < lo:
            continue
        if hi is not None and (start or 0) > hi:
            continue
        out.append(d)
    return 200, {"drives": out}


def _get_drive(store, drive_id):
    drive = store.get_drive(drive_id)
    if drive is None:
        return _err(404, "drive not found")
    ids = list(drive.get("clip_ids") or [])
    fixes = {cid: store.get_fixes(cid) for cid in ids}
    clips = [c for cid in ids + list(drive.get("other_clip_ids") or []) if (c := store.get_clip(cid))]
    return 200, {"ok": True, "drive": drive, "polyline": dashcam_drives.drive_polyline(drive, fixes),
                 "clips": clips}


def _create_upload(store, body):
    cid = body.get("clip_id")
    if not isinstance(cid, str):
        return _err(400, "clip_id is required")
    # The phone may ask for smaller chunks: over weak LTE a 16 MiB one can't finish inside a request.
    asked = body.get("chunk_size")
    chunk = asked if (isinstance(asked, int) and not isinstance(asked, bool)
                      and MIN_CHUNK_SIZE <= asked <= CHUNK_SIZE) else CHUNK_SIZE
    up, err = store.create_upload(cid, body.get("size"), body.get("sha256"), chunk)
    if err == "already_uploaded":
        clip = store.get_clip(cid) or {}
        size = int(clip.get("size") or body.get("size") or 0)
        return 200, {"ok": True, "upload_id": None, "size": size, "chunk_size": CHUNK_SIZE,
                     "chunks": -(-size // CHUNK_SIZE) if size else 0, "received": [], "complete": True,
                     "already_uploaded": True}
    if err == "clip_not_found":
        return _err(404, "clip not found")
    if err == "no_destination":
        return _err(409, "no_destination")   # the phone keeps the file and asks again later
    if err == "staging_full":
        return _err(507, "staging_full", retry_after=RETRY_AFTER_S)
    if err == "too_large":
        return _err(413, "too_large")
    if err:
        return _err(400, "size (bytes > 0) and sha256 (64 hex) are required")
    return 200, _upload_reply(up)


def _complete(store, upload_id):
    clip, err = store.complete_upload(upload_id)
    if err == "upload_not_found" or err == "clip_not_found":
        return _err(404, err.replace("_", " "))
    if err == "missing_chunks":
        up = store.get_upload(upload_id) or {"chunks": 0, "received": []}
        missing = sorted(set(range(up["chunks"])) - set(up["received"]))
        return _err(400, "missing_chunks", missing=missing)
    if err:
        return _err(400, err)
    return 200, {"ok": True, "clip": clip}


def _check_kinds(kinds):
    if kinds is None:
        return None
    if not isinstance(kinds, list) or not kinds or any(k not in KINDS for k in kinds):
        return f"kinds must be a non-empty list of {', '.join(KINDS)}"
    return None


def _create_destination(store, body, relay):
    dtype = body.get("type")
    allowed = dashcam_relay.DEST_TYPES + (("local",) if dashcam_relay.local_allowed() else ())
    if dtype not in allowed:
        return _err(400, f"type must be one of {', '.join(dashcam_relay.DEST_TYPES)}")
    name = body.get("name")
    if not isinstance(name, str) or not name.strip() or len(name) > 64:
        return _err(400, "name is required (up to 64 characters)")
    path = body.get("path", "dashcam")
    if not isinstance(path, str) or len(path) > 512 or "\n" in path:
        return _err(400, "path must be a folder path")
    kinds_error = _check_kinds(body.get("kinds"))
    if kinds_error:
        return _err(400, kinds_error)
    fields = {k: body[k] for k in ("host", "port", "user", "password", "token", "client_id", "client_secret",
                                   "explicit_tls", "domain") if body.get(k) not in (None, "")}
    dest_id = store.new_destination_id()
    try:
        remote = _relay(relay).create_remote(dest_id, dtype, fields)
    except ValueError as exc:
        return _err(400, str(exc))
    except RelayUnavailable as exc:
        return _err(503, str(exc))
    except RelayError as exc:
        return _err(400, f"rclone refused the destination: {exc}")
    port = fields.get("port")
    try:
        port = int(port) if port is not None else None
    except (TypeError, ValueError):
        port = None
    dest = store.add_destination({
        "id": dest_id, "type": dtype, "name": name.strip(), "remote": remote, "path": path.strip(),
        "enabled": body.get("enabled", True) is not False, "kinds": body.get("kinds"),
        "host": fields.get("host"), "port": port, "user": fields.get("user")})
    return 200, {"ok": True, "destination": dest}


def _update_destination(store, did, body):
    if store.get_destination(did) is None:
        return _err(404, "destination not found")
    patch = {}
    if "name" in body:
        if not isinstance(body["name"], str) or not body["name"].strip() or len(body["name"]) > 64:
            return _err(400, "name must be 1-64 characters")
        patch["name"] = body["name"].strip()
    if "enabled" in body:
        if not isinstance(body["enabled"], bool):
            return _err(400, "enabled must be true or false")
        patch["enabled"] = body["enabled"]
    if "kinds" in body:
        kinds_error = _check_kinds(body["kinds"])
        if kinds_error:
            return _err(400, kinds_error)
        patch["kinds"] = body["kinds"]
    if "path" in body:
        if not isinstance(body["path"], str) or len(body["path"]) > 512:
            return _err(400, "path must be a folder path")
        patch["path"] = body["path"].strip()
    return 200, {"ok": True, "destination": store.update_destination(did, patch)}


def _test_destination(store, did, relay):
    dest = store.get_destination(did)
    if dest is None:
        return _err(404, "destination not found")
    try:
        ok, error = _relay(relay).test_remote(dest.get("remote") or "", dest.get("path") or "")
    except RelayUnavailable as exc:
        return _err(503, str(exc))
    from api.dashcam_store import now_iso
    store.update_destination(did, {"status": "ok" if ok else "error", "error": error, "tested_at": now_iso()})
    return 200, ({"ok": True} if ok else {"ok": False, "error": error})


def _delete_cloud(store, cid, relay):
    """Deletes the clip's copy from every destination that has one (rclone, by its recorded path - the
    same for copies the phone uploaded itself), then forgets the upload."""
    clip = store.get_clip(cid)
    if clip is None:
        return _err(404, "clip not found")
    dests = store.destinations_by_id()
    errors = []
    for did, entry in (clip.get("destinations") or {}).items():
        dest = dests.get(did)
        path = entry.get("remote_path") if isinstance(entry, dict) else None
        if not dest or not dest.get("remote") or not path or entry.get("state") != "done":
            continue
        for remote_path in [path] + ([entry["preview_path"]] if entry.get("preview_path") else []):
            try:
                _relay(relay).rc("operations/deletefile", {"fs": dest["remote"] + ":", "remote": remote_path})
            except (RelayError, RelayUnavailable) as exc:
                if "not found" not in str(exc).lower():
                    errors.append(f"{dest.get('name') or did}: {exc}")
    if errors:
        return _err(502, "; ".join(errors)[:500])
    store.forget_cloud(cid)
    return 200, {"ok": True}


def _destination_token(store, did, relay):
    """A short-lived Drive access token, so the phone uploads clips to Drive itself (no Cloudflare
    tunnel and no staging in between). Only for destinations the phone can reach directly."""
    from api.dashcam_store import DIRECT_TYPES
    dest = store.get_destination(did)
    if dest is None:
        return _err(404, "destination not found")
    if dest.get("type") not in DIRECT_TYPES or not dest.get("remote"):
        return _err(400, "not_direct")
    try:
        access = _relay(relay).drive_access(dest["remote"])
    except RelayUnavailable as exc:
        return _err(503, str(exc))
    except RelayError as exc:
        return _err(502, str(exc))
    return 200, {"ok": True, "type": dest["type"], "access_token": access["access_token"],
                 "expires_at": access["expires_at"], "team_drive": access["team_drive"],
                 "path": dest.get("path") or ""}


def _record_direct(store, cid, body):
    did = body.get("destination_id")
    if not isinstance(did, str):
        return _err(400, "destination_id is required")
    clip, err = store.record_direct(cid, did, body.get("remote_path"), body.get("file_id"), body.get("size"),
                                    body.get("preview_path"), body.get("preview_file_id"))
    if err in ("clip_not_found", "destination_not_found"):
        return _err(404, err.replace("_", " "))
    if err:
        return _err(400, err)
    return 200, {"ok": True, "clip": clip}


def _delete_destination(store, did, relay):
    dest = store.get_destination(did)
    if dest is None:
        return _err(404, "destination not found")
    if dest.get("remote"):
        try:
            _relay(relay).delete_remote(dest["remote"])
        except (RelayError, RelayUnavailable) as exc:
            logger.warning("dashcam: could not delete rclone remote %s: %s", dest["remote"], exc)
    store.delete_destination(did)
    return 200, {"ok": True}


# ── raw-body POSTs ───────────────────────────────────────────────────────────

def _read_exact(rfile, length: int) -> bytes:
    parts, got = [], 0
    while got < length:
        block = rfile.read(min(1024 * 1024, length - got))
        if not block:
            break
        parts.append(block)
        got += len(block)
    return b"".join(parts)


def handle_dashcam_raw_post(handler, path: str, store) -> bool:
    """Chunk and thumbnail uploads; True when the path was one of them (a reply was sent)."""
    from api.helpers import j
    p, q = _split(path)
    chunk = _RE_UPLOAD_CHUNK.match(p)
    thumb = None if chunk else _RE_CLIP_THUMB.match(p)
    if not chunk and not thumb:
        return False
    raw_len = handler.headers.get("Content-Length")
    try:
        length = int(raw_len) if raw_len not in (None, "") else -1
    except ValueError:
        length = -1
    if length < 0:
        handler.close_connection = True
        j(handler, {"ok": False, "error": "Content-Length is required"}, status=411)
        return True
    cap = CHUNK_SIZE if chunk else THUMB_MAX_BYTES
    if length > cap:
        # The body is not read, so the connection can't be reused.
        handler.close_connection = True
        j(handler, {"ok": False, "error": f"body larger than {cap} bytes"}, status=413)
        return True
    data = _read_exact(handler.rfile, length)
    if len(data) != length:
        handler.close_connection = True
        j(handler, {"ok": False, "error": "body shorter than Content-Length"}, status=400)
        return True
    if chunk:
        try:
            n = int(q.get("n", ""))
        except ValueError:
            j(handler, {"ok": False, "error": "chunk number ?n= is required"}, status=400)
            return True
        up, err = store.write_chunk(chunk.group(1), n, data)
        if err == "upload_not_found":
            j(handler, {"ok": False, "error": "upload not found"}, status=404)
        elif err:
            j(handler, {"ok": False, "error": err}, status=400)
        else:
            j(handler, {"ok": True, "received": up["received"], "chunks": up["chunks"]})
        return True
    ok, err = store.put_thumb(thumb.group(1), data)
    if ok:
        j(handler, {"ok": True})
    else:
        j(handler, {"ok": False, "error": err}, status=404 if err == "clip not found" else 400)
    return True


# ── binary GETs ──────────────────────────────────────────────────────────────

def _send_bytes(handler, data: bytes, content_type: str, *, cache: str = "private, max-age=3600",
                disposition: str | None = None) -> None:
    from api.helpers import _security_headers
    handler.send_response(200)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", cache)
    if disposition:
        handler.send_header("Content-Disposition", disposition)
    _security_headers(handler)
    handler.end_headers()
    handler.wfile.write(data)


def handle_dashcam_binary_get(handler, path: str, store, *, relay=None) -> bool:
    """Thumbnail, clip stream and GPX; True when the path was one of them (a reply was sent)."""
    from api.helpers import j
    p, _ = _split(path)
    m = _RE_CLIP_THUMB.match(p)
    if m:
        thumb = store.thumb_path(m.group(1))
        if thumb is None:
            j(handler, {"ok": False, "error": "no thumbnail"}, status=404)
        else:
            _send_bytes(handler, thumb.read_bytes(), "image/jpeg")
        return True
    m = _RE_DRIVE_GPX.match(p)
    if m:
        drive = store.get_drive(m.group(1))
        if drive is None:
            j(handler, {"ok": False, "error": "drive not found"}, status=404)
            return True
        fixes = {cid: store.get_fixes(cid) for cid in drive.get("clip_ids") or []}
        gpx = dashcam_drives.drive_gpx(drive, fixes).encode("utf-8")
        _send_bytes(handler, gpx, "application/gpx+xml", cache="private, no-store",
                    disposition=f'attachment; filename="{drive["id"]}.gpx"')
        return True
    m = _RE_CLIP_STREAM.match(p)
    if m:
        _stream(handler, store, m.group(1), relay)
        return True
    return False


def _stream(handler, store, cid: str, relay) -> None:
    from api.helpers import _security_headers, j
    clip = store.get_clip(cid)
    if clip is None:
        j(handler, {"ok": False, "error": "clip not found"}, status=404)
        return
    up = clip.get("upload") or {}
    if up.get("state") == "staged" and up.get("upload_id"):
        target = store.staged_file(up["upload_id"])
        if target.is_file():
            from api.routes import _serve_file_bytes
            # The file decides the type: a remuxed .mp4, else whatever the camera recorded.
            mime = "video/mp4" if target.suffix == ".mp4" else dashcam_relay._content_type(clip.get("name") or "")
            _serve_file_bytes(handler, target, mime, "inline", "private, no-store")
            return
    dests = store.destinations_by_id()
    for did, entry in (clip.get("destinations") or {}).items():
        dest = dests.get(did)
        if not dest or not isinstance(entry, dict) or entry.get("state") != "done" or not entry.get("remote_path"):
            continue
        try:
            status, headers, blocks = _relay(relay).open_stream(dest["remote"], entry["remote_path"],
                                                                handler.headers.get("Range"))
        except RelayUnavailable as exc:
            j(handler, {"ok": False, "error": str(exc)}, status=503)
            return
        except RelayError as exc:
            j(handler, {"ok": False, "error": str(exc)}, status=502)
            return
        handler.send_response(status)
        for key, value in headers.items():
            handler.send_header(key, value)
        handler.send_header("Cache-Control", "private, no-store")
        _security_headers(handler)
        handler.end_headers()
        try:
            for block in blocks:
                handler.wfile.write(block)
        except Exception as exc:
            # The status line and headers are out: a JSON error now would land inside the clip's
            # bytes. End the response instead; the short body plus the closed connection tells the
            # player to ask for the range again.
            handler.close_connection = True
            if not isinstance(exc, (BrokenPipeError, ConnectionResetError)):  # else: the player cancelled
                logger.info("dashcam stream of %s ended early: %s", cid, exc)
        finally:
            close = getattr(blocks, "close", None)
            if close:
                close()
        return
    j(handler, {"ok": False, "error": "clip is not uploaded yet"}, status=404)
