"""
JarvisCopilot Web UI -- built-in app updates for the iPhone and Mac apps.

Claude uploads a finished build (iPhone: development-signed .ipa; Mac: zipped
Jarvis.app) to ``POST /api/app-updates/upload``. The server keeps the current
build and the one before it per platform, tells the apps (device-bridge topic
``app_update`` for an open app, an APNs banner for a closed iPhone), and hands
out install links from ``GET /api/app-updates/latest``.

The links live under ``/ota/`` and need no session: iOS's installer fetches the
itms-services manifest and the IPA itself, with no cookie. Each URL carries a
token signed with the WebUI key that names one build and expires in minutes,
so a leaked or guessed link is useless. The public host is the edge route named
``ota_route`` (a hostname with no Cloudflare Access in front of it).

Run as ``python -m api.app_updates upload ...`` on the server to upload a file
from stdin through the same endpoint (host-signed, localhost only).
"""
import hashlib
import hmac
import json
import logging
import os
import plistlib
import re
import tempfile
import threading
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, quote

from api.config import STATE_DIR
from api.helpers import j

logger = logging.getLogger(__name__)

# platform → (file name served to the device, where the app's Info.plist sits in the archive)
PLATFORMS = {
    "ios": ("JarvisCopilot.ipa", re.compile(r"^Payload/[^/]+\.app/Info\.plist$")),
    "mac": ("Jarvis.zip", re.compile(r"^[^/]+\.app/Contents/Info\.plist$")),
}
LINK_TTL = 600
MAX_BYTES = 1024 * 1024 * 1024
_CHUNK = 1024 * 1024
_LOCK = threading.Lock()
_TOKEN_RE = re.compile(r"^(ios|mac)\.(\d{1,12})\.(\d{1,12})\.([0-9a-f]{32})$")


def _root() -> Path:
    return STATE_DIR / "app_updates"


def _load_index() -> dict:
    try:
        data = json.loads((_root() / "index.json").read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_index(index: dict) -> None:
    path = _root() / "index.json"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(index, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def current(platform: str) -> Optional[dict]:
    return (_load_index().get(platform) or {}).get("current")


def _known(platform: str, build: int) -> Optional[dict]:
    slot = _load_index().get(platform) or {}
    for rec in (slot.get("current"), slot.get("previous")):
        if rec and rec.get("build") == build:
            return rec
    return None


# ── Signed links ────────────────────────────────────────────────────────────

def _sig(platform: str, build: int, exp: int) -> str:
    from api.auth import _signing_key
    msg = f"ota|{platform}|{build}|{exp}".encode()
    return hmac.new(_signing_key(), msg, hashlib.sha256).hexdigest()[:32]


def make_token(platform: str, build: int, *, ttl: int = LINK_TTL, now: Optional[float] = None) -> str:
    exp = int((now if now is not None else time.time()) + ttl)
    return f"{platform}.{build}.{exp}.{_sig(platform, build, exp)}"


def check_token(token: str, *, now: Optional[float] = None) -> Optional[dict]:
    """The build a token grants, or None when it is malformed, forged, expired or
    names a build the server no longer keeps."""
    m = _TOKEN_RE.match(token or "")
    if not m:
        return None
    platform, build, exp, sig = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
    if not hmac.compare_digest(sig, _sig(platform, build, exp)):
        return None
    if exp < (now if now is not None else time.time()):
        return None
    rec = _known(platform, build)
    return dict(rec, platform=platform) if rec else None


def public_base(handler=None) -> str:
    """Where the /ota/ links point: the edge's ``ota_route`` host, or "" when there
    is none (then no link is offered — the main host's Access login would turn an
    install into a failure halfway through)."""
    try:
        from edge.state import load_settings
        settings = load_settings()
        route, domain = settings.get("ota_route"), settings.get("domain")
        if settings.get("enabled") and route and domain and route in (settings.get("routes") or {}):
            return f"https://{route}.{domain}".lower()
    except Exception:
        logger.debug("edge settings unavailable for OTA links", exc_info=True)
    return ""


def install_url(platform: str, build: int, base: str) -> str:
    token = make_token(platform, build)
    if platform == "ios":
        manifest = f"{base}/ota/m/{token}.plist"
        return "itms-services://?action=download-manifest&url=" + quote(manifest, safe="")
    return f"{base}/ota/d/{token}/{PLATFORMS[platform][0]}"


def manifest_plist(rec: dict, base: str, token: str) -> bytes:
    return plistlib.dumps({"items": [{
        "assets": [{"kind": "software-package",
                    "url": f"{base}/ota/d/{token}/{PLATFORMS['ios'][0]}"}],
        "metadata": {"bundle-identifier": rec.get("bundle_id") or "",
                     "bundle-version": rec.get("version") or "1.0",
                     "kind": "software", "title": "Jarvis"},
    }]})


# ── Storing a build ─────────────────────────────────────────────────────────

class UploadError(ValueError):
    pass


def _read_info_plist(path: Path, platform: str) -> dict:
    pattern = PLATFORMS[platform][1]
    try:
        with zipfile.ZipFile(path) as zf:
            for name in zf.namelist():
                if pattern.match(name):
                    return plistlib.loads(zf.read(name))
    except (zipfile.BadZipFile, plistlib.InvalidFileException, OSError) as exc:
        raise UploadError(f"not a readable {platform} build: {exc}") from exc
    raise UploadError(f"no app Info.plist in the {platform} archive")


def store_upload(platform: str, build: int, rfile, length: int, *,
                 commit: str = "", notes: str = "") -> dict:
    """Stream ``length`` bytes from ``rfile`` into the store as ``platform``'s new
    current build. The archive's own Info.plist must say ``build`` (else the app
    would install, read an older number and offer itself again)."""
    if platform not in PLATFORMS:
        raise UploadError("platform must be ios or mac")
    if build <= 0:
        raise UploadError("build must be a positive integer")
    if length <= 0 or length > MAX_BYTES:
        raise UploadError("Content-Length must be between 1 byte and 1 GiB")
    cur = current(platform)
    if cur and build <= int(cur.get("build") or 0):
        raise UploadError(f"build {build} is not newer than the current build {cur.get('build')}")
    root = _root()
    root.mkdir(parents=True, exist_ok=True)
    ext = ".ipa" if platform == "ios" else ".zip"
    final = root / f"{platform}-{build}{ext}"
    # Its own temp file per upload: a retry racing the first attempt must not write
    # into the file the first one is about to move into place.
    fd, tmp_name = tempfile.mkstemp(dir=root, prefix=f".{platform}-{build}-", suffix=".part")
    tmp = Path(tmp_name)
    digest = hashlib.sha256()
    remaining = length
    try:
        with os.fdopen(fd, "wb") as out:
            while remaining:
                chunk = rfile.read(min(_CHUNK, remaining))
                if not chunk:
                    raise UploadError("body shorter than Content-Length")
                out.write(chunk)
                digest.update(chunk)
                remaining -= len(chunk)
        info = _read_info_plist(tmp, platform)
        if str(info.get("CFBundleVersion") or "") != str(build):
            raise UploadError(f"the archive is build {info.get('CFBundleVersion')!r}, not {build}")
        rec = {
            "build": build,
            "version": str(info.get("CFBundleShortVersionString") or ""),
            "bundle_id": str(info.get("CFBundleIdentifier") or ""),
            "commit": (commit or "")[:40],
            "notes": (notes or "").strip()[:2000],
            "size": length,
            "sha256": digest.hexdigest(),
            "uploaded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "file": final.name,
        }
        with _LOCK:
            index = _load_index()
            slot = index.get(platform) or {}
            cur = slot.get("current")
            if cur and build <= int(cur.get("build") or 0):
                raise UploadError(f"build {build} is not newer than the current build {cur.get('build')}")
            if cur and cur.get("bundle_id") and cur["bundle_id"] != rec["bundle_id"]:
                raise UploadError(f"bundle id {rec['bundle_id']} does not match {cur['bundle_id']}")
            os.replace(tmp, final)
            index[platform] = {"current": rec, "previous": cur}
            _save_index(index)
            _prune(index)
        return rec
    finally:
        tmp.unlink(missing_ok=True)


def rollback(platform: str) -> Optional[dict]:
    """Make the previous build current again (the bad one is dropped)."""
    with _LOCK:
        index = _load_index()
        slot = index.get(platform) or {}
        prev = slot.get("previous")
        if not prev:
            return None
        index[platform] = {"current": prev, "previous": None}
        _save_index(index)
        _prune(index)
        return prev


def _prune(index: dict) -> None:
    keep = {rec["file"] for slot in index.values() if isinstance(slot, dict)
            for rec in (slot.get("current"), slot.get("previous")) if rec}
    for path in _root().iterdir():
        if path.suffix in (".ipa", ".zip") and path.name not in keep:
            path.unlink(missing_ok=True)


def announce(platform: str, rec: dict) -> None:
    """Tell the apps: a live pop-up in an open app, a banner on a closed iPhone."""
    data = {"platform": platform, "build": rec["build"]}
    try:
        from api import device_bridge
        device_bridge.publish("app_update", data)
    except Exception:
        logger.warning("app_update bridge publish failed", exc_info=True)
    if platform != "ios":
        return
    first = next((ln.strip(" -•*\t") for ln in (rec.get("notes") or "").splitlines() if ln.strip()), "")
    try:
        from api.push import alert_phones
        alert_phones("Jarvis update ready", first or "A new version is ready to install.",
                     data={"kind": "app_update", **data})
    except Exception:
        logger.warning("app_update push failed", exc_info=True)


def latest(platform: str, client_build: int, base: str) -> dict:
    rec = current(platform)
    # Build 1 is an unstamped build (Xcode Run, a plain `build.sh`): it may well be
    # newer than anything published, so it's never offered one.
    if not rec or client_build <= 1 or int(rec.get("build") or 0) <= client_build:
        return {"available": False, "platform": platform,
                "build": int(rec.get("build") or 0) if rec else 0}
    return {
        "available": True, "platform": platform,
        "build": rec["build"], "version": rec.get("version") or "",
        "notes": rec.get("notes") or "", "commit": rec.get("commit") or "",
        "size": rec.get("size") or 0, "uploaded_at": rec.get("uploaded_at") or "",
        "install_url": install_url(platform, rec["build"], base) if base else "",
    }


# ── HTTP ────────────────────────────────────────────────────────────────────

def _q(parsed, name: str, default: str = "") -> str:
    return (parse_qs(parsed.query).get(name) or [default])[0]


def _int(value: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def handle_get(handler, parsed) -> bool:
    if parsed.path == "/api/app-updates/install-status":
        j(handler, {"started": install_started(_q(parsed, "token"))})
        return True
    if parsed.path != "/api/app-updates/latest":
        return False
    platform = _q(parsed, "platform")
    if platform not in PLATFORMS:
        j(handler, {"error": "platform must be ios or mac"}, status=400)
        return True
    j(handler, latest(platform, _int(_q(parsed, "build")), public_base(handler)))
    return True


def handle_post(handler, parsed) -> bool:
    """Raw-body upload and rollback. Called before the JSON body is read."""
    if parsed.path == "/api/app-updates/upload":
        try:
            length = int(handler.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        platform = _q(parsed, "platform")
        try:
            rec = store_upload(platform, _int(_q(parsed, "build")), handler.rfile, length,
                               commit=_q(parsed, "commit"), notes=_q(parsed, "notes"))
        except UploadError as exc:
            j(handler, {"ok": False, "error": str(exc)}, status=400)
            return True
        threading.Thread(target=announce, args=(platform, rec), daemon=True,
                         name="app-update-announce").start()
        j(handler, {"ok": True, "build": rec})
        return True
    if parsed.path == "/api/app-updates/rollback":
        platform = _q(parsed, "platform")
        if platform not in PLATFORMS:
            j(handler, {"ok": False, "error": "platform must be ios or mac"}, status=400)
            return True
        rec = rollback(platform)
        j(handler, {"ok": bool(rec), "build": rec}, status=200 if rec else 404)
        return True
    return False


_OTA_MANIFEST = re.compile(r"^/ota/m/([^/]+)\.plist$")
_OTA_DOWNLOAD = re.compile(r"^/ota/d/([^/]+)/([^/]+)$")


# Install links whose package iOS has started fetching. iOS fetches it only after the
# user taps Install on its own confirm, so this is how the app learns to step aside:
# iOS won't install over a Jarvis that's still running.
_STARTED: dict = {}
_STARTED_LOCK = threading.Lock()


def mark_started(token: str, *, now: Optional[float] = None) -> None:
    now = now if now is not None else time.time()
    with _STARTED_LOCK:
        for old in [t for t, at in _STARTED.items() if now - at > 2 * LINK_TTL]:
            del _STARTED[old]
        _STARTED[token] = now


def install_started(token: str) -> bool:
    with _STARTED_LOCK:
        return token in _STARTED


def handle_ota(handler, parsed) -> bool:
    """Public install links. Anything without a valid token is a bare 403."""
    m = _OTA_MANIFEST.match(parsed.path)
    if m:
        rec = check_token(m.group(1))
        if not rec or rec["platform"] != "ios":
            return _forbidden(handler)
        body = manifest_plist(rec, public_base(handler), m.group(1))
        handler.send_response(200)
        handler.send_header("Content-Type", "application/xml")
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "no-store")
        handler.end_headers()
        handler.wfile.write(body)
        return True
    m = _OTA_DOWNLOAD.match(parsed.path)
    if m:
        rec = check_token(m.group(1))
        if not rec or m.group(2) != PLATFORMS[rec["platform"]][0]:
            return _forbidden(handler)
        path = _root() / rec["file"]
        try:
            fh = open(path, "rb")
        except OSError:
            return _forbidden(handler)
        mark_started(m.group(1))
        with fh:
            handler.send_response(200)
            handler.send_header("Content-Type", "application/octet-stream")
            handler.send_header("Content-Length", str(os.fstat(fh.fileno()).st_size))
            handler.send_header("Cache-Control", "no-store")
            handler.end_headers()
            while True:
                chunk = fh.read(_CHUNK)
                if not chunk:
                    break
                handler.wfile.write(chunk)
        return True
    return _forbidden(handler)


def _forbidden(handler) -> bool:
    handler.send_response(403)
    handler.send_header("Content-Type", "text/plain; charset=utf-8")
    handler.send_header("Content-Length", "9")
    handler.end_headers()
    handler.wfile.write(b"forbidden")
    return True


# ── CLI: upload from stdin through the running WebUI ────────────────────────

def _local_post(path: str, size: int = 0, body=None):
    """A host-signed POST to the WebUI on this machine; returns the open connection
    with the headers sent, ready for ``size`` body bytes."""
    import http.client
    import ssl

    from api.auth import _signing_key
    from api.config import PORT

    ts = int(time.time())
    sig = hmac.new(_signing_key(), f"POST\n{path}\n{ts}".encode(), hashlib.sha256).hexdigest()
    # The WebUI serves its own self-signed TLS when the service sets a cert (an env
    # this shell may not have), so try TLS on localhost first, then plain HTTP.
    conn = http.client.HTTPSConnection("127.0.0.1", PORT, timeout=600,
                                       context=ssl._create_unverified_context())
    try:
        conn.connect()
    except ssl.SSLError:
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=600)
    conn.putrequest("POST", path)
    conn.putheader("Content-Length", str(size))
    conn.putheader("Content-Type", "application/octet-stream")
    conn.putheader("X-JC-Host-Sig", f"{ts}.{sig}")
    conn.endheaders()
    return conn


def _cli(argv: list) -> int:
    import argparse
    import sys
    from urllib.parse import urlencode

    ap = argparse.ArgumentParser(prog="python -m api.app_updates")
    ap.add_argument("action", choices=["upload", "rollback"])
    ap.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    ap.add_argument("--build", type=int, default=0)
    ap.add_argument("--size", type=int, default=0, help="bytes that will arrive on stdin")
    ap.add_argument("--commit", default="")
    ap.add_argument("--notes", default="")
    args = ap.parse_args(argv)
    if args.action == "rollback":
        # Through the running WebUI, so it shares the store's lock with uploads.
        resp = _local_post("/api/app-updates/rollback?" + urlencode({"platform": args.platform})).getresponse()
        print(resp.read().decode("utf-8", "replace"))
        return 0 if resp.status == 200 else 1
    # Say why before streaming tens of MB into a request the server will refuse.
    cur = current(args.platform)
    if cur and args.build <= int(cur.get("build") or 0):
        print(f"build {args.build} is not newer than the current {args.platform} build {cur.get('build')}",
              file=sys.stderr)
        return 1
    conn = _local_post("/api/app-updates/upload?" + urlencode({
        "platform": args.platform, "build": args.build,
        "commit": args.commit, "notes": args.notes}), size=args.size)
    remaining = args.size
    try:
        while remaining:
            chunk = sys.stdin.buffer.read(min(_CHUNK, remaining))
            if not chunk:
                print("stdin ended before --size bytes", file=sys.stderr)
                return 1
            conn.send(chunk)
            remaining -= len(chunk)
    except OSError:
        pass  # the server answered early and closed; its answer says why
    try:
        resp = conn.getresponse()
    except OSError as exc:
        print(f"upload failed: {exc}", file=sys.stderr)
        return 1
    print(resp.read().decode("utf-8", "replace"))
    return 0 if resp.status == 200 else 1


if __name__ == "__main__":
    import sys
    sys.exit(_cli(sys.argv[1:]))
