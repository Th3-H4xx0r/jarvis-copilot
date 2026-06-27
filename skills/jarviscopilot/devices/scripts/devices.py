#!/usr/bin/env python3
"""JarvisCopilot — devices skill helper.

Stdlib-only. Talks to the same pairing/devices files the webui reads so
the agent can pair / list / revoke devices without any extra auth.

Pair flow uses the shared ``.pending_pair.json`` file directly (the webui
reads it on claim). All other ops hit the webui's REST API on localhost
using a host signing-key carve-out so this script needs no cookies.

Usage examples (the SKILL.md has the full list):

    python3 devices.py pair               # blocks until paired or expired
    python3 devices.py pair --no-wait     # print code + return
    python3 devices.py list
    python3 devices.py revoke <id-or-name>
    python3 devices.py logout <id-or-name>
    python3 devices.py skills
    python3 devices.py invoke <device> send_sms --json-args '{...}'

Exit codes:
    0   success
    1   error (printed to stderr as JSON)
    2   pairing expired without a claim
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path


# ── State paths ─────────────────────────────────────────────────────────────

def _state_dir() -> Path:
    """Resolve the webui's STATE_DIR (matches webui/api/config.py)."""
    env = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.home() / ".jarviscopilot" / "webui").resolve()


def _media_cache_dir() -> Path:
    """Return an allowlisted image-cache dir for delivered media.

    Device screenshots / inline images get emitted as MEDIA directives, so
    they MUST land under one of gateway.platforms.base.MEDIA_DELIVERY_SAFE_ROOTS
    or they're dropped ("Skipping unsafe MEDIA directive path outside allowed
    roots"). The image cache (``{HERMES_HOME}/cache/images`` or legacy
    ``image_cache/``) is on that allowlist, so we resolve it the same way the
    gateway does (jarviscopilot_constants.get_hermes_dir — import-safe, stdlib
    only). Falls back to replicating that resolution by hand if the import
    isn't reachable. NEVER returns a /tmp path.
    """
    home: Path | None = None
    try:
        # repo root = parents[4] (scripts/devices/jarviscopilot/skills/<repo>)
        repo_root = Path(__file__).resolve().parents[4]
        if str(repo_root) not in sys.path:
            sys.path.insert(0, str(repo_root))
        from jarviscopilot_constants import get_hermes_dir  # type: ignore
        cache_dir = get_hermes_dir("cache/images", "image_cache")
    except Exception:
        # Stdlib-only fallback mirroring get_hermes_home()+get_hermes_dir().
        env_home = os.environ.get("HERMES_HOME", "").strip()
        home = Path(env_home) if env_home else (Path.home() / ".jarviscopilot")
        legacy = home / "image_cache"
        cache_dir = legacy if legacy.exists() else (home / "cache" / "images")
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir


def _webui_origin() -> str:
    """Best-effort guess of the webui's local URL. Honors env overrides."""
    scheme = "https" if os.environ.get("HERMES_WEBUI_TLS_CERT") else "http"
    port = os.environ.get("HERMES_WEBUI_PORT", "8787")
    host = os.environ.get("HERMES_WEBUI_HOST", "127.0.0.1")
    return f"{scheme}://{host}:{port}"


def _public_pair_url() -> str:
    """URL we tell the user to open on the device being paired.

    Uses ``hostname -I`` (Linux) / a UDP-probe trick (cross-platform)
    to find a routable LAN IP so iPhones-on-wifi can reach it.
    """
    scheme = "https" if os.environ.get("HERMES_WEBUI_TLS_CERT") else "http"
    port = os.environ.get("HERMES_WEBUI_PORT", "8787")
    host = os.environ.get("HERMES_WEBUI_PUBLIC_HOST", "").strip()
    if not host:
        try:
            import socket
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            host = s.getsockname()[0]
            s.close()
        except Exception:
            host = "localhost"
    return f"{scheme}://{host}:{port}/pair"


# ── pairing.py reuse ───────────────────────────────────────────────────────
# Try to import the live webui module; fall back to a minimal local
# implementation if webui/ isn't on sys.path (e.g. the agent's working
# dir is unrelated).

def _ensure_pairing_module():
    """Locate <repo>/webui/api/pairing.py and add it to sys.path."""
    # __file__ is skills/jarviscopilot/devices/scripts/devices.py
    # parents: [0]=scripts [1]=devices [2]=jarviscopilot [3]=skills [4]=repo
    candidates = [
        Path(__file__).resolve().parents[4] / "webui",  # repo layout
    ]
    # Also check $JARVISCOPILOT_DIR and a few install conventions.
    for env_key in ("JARVISCOPILOT_DIR", "HERMES_REPO"):
        v = os.environ.get(env_key)
        if v:
            candidates.append(Path(v).expanduser() / "webui")
    # And common system install paths.
    for root in (Path.home(), Path("/root"), Path("/opt")):
        cand = root / "JarvisCopilot" / "webui"
        if cand not in candidates:
            candidates.append(cand)
    for c in candidates:
        if (c / "api" / "pairing.py").exists():
            if str(c) not in sys.path:
                sys.path.insert(0, str(c))
            return True
    return False


# ── HTTP helpers ───────────────────────────────────────────────────────────

def _host_signature(method: str, path: str) -> str | None:
    """Build the X-JC-Host-Sig header value (`<ts>.<hmac>`).

    Matches webui/api/auth.py:_check_host_signature(). Returns None if
    the signing key isn't readable (in which case auth'd HTTP calls
    will get a 401 and the script falls back to disk for read-only ops).
    """
    sk_path = _state_dir() / ".signing_key"
    try:
        import hmac as _hmac, hashlib as _hashlib
        sk = sk_path.read_bytes()
        ts = int(time.time())
        msg = f"{method.upper()}\n{path}\n{ts}".encode("utf-8")
        sig = _hmac.new(sk, msg, _hashlib.sha256).hexdigest()
        return f"{ts}.{sig}"
    except Exception:
        return None


def _http(method: str, path: str, body: dict | None = None,
          timeout: float = 30.0) -> tuple[int, dict]:
    """Make a host-signed request to the local webui. Returns (status, json|{})."""
    url = _webui_origin() + path
    data = None
    headers = {"Accept": "application/json", "X-Requested-With": "fetch"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    sig = _host_signature(method, path)
    if sig:
        headers["X-JC-Host-Sig"] = sig
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        ctx = None
        if url.startswith("https://"):
            import ssl
            ctx = ssl._create_unverified_context()
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            raw = r.read().decode("utf-8", errors="replace") or "{}"
            try:
                return r.status, json.loads(raw)
            except Exception:
                return r.status, {"raw": raw}
    except urllib.error.HTTPError as e:
        try:
            raw = e.read().decode("utf-8", errors="replace") or "{}"
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {}
    except Exception as e:
        return -1, {"error": str(e)}


# ── Commands ───────────────────────────────────────────────────────────────

def cmd_pair(args) -> int:
    if not _ensure_pairing_module():
        print(json.dumps({"error": "could not locate webui/api/pairing.py — set JARVISCOPILOT_DIR"}), file=sys.stderr)
        return 1
    from api.pairing import create_pairing_code, poll_pairing_code, cancel_pairing_code

    info = create_pairing_code(label=args.label, ttl=int(args.ttl))
    code = info["code"]
    url = _public_pair_url()
    # Always print the code + URL first so the agent can show it.
    print(json.dumps({
        "code": code,
        "url": url,
        "expires_at": info["expires_at"],
        "ttl": info["ttl"],
    }))
    sys.stdout.flush()
    if args.no_wait:
        return 0

    end = info["expires_at"]
    try:
        while time.time() < end:
            state = poll_pairing_code(code)
            status = state.get("status")
            if status == "claimed":
                print(json.dumps({
                    "status": "claimed",
                    "device_name": state.get("device_name"),
                    "device_ip": state.get("device_ip"),
                }))
                return 0
            if status in ("expired", "unknown"):
                break
            time.sleep(1.0)
    except KeyboardInterrupt:
        cancel_pairing_code(code)
        print(json.dumps({"status": "cancelled"}))
        return 130

    cancel_pairing_code(code)
    print(json.dumps({"status": "expired"}))
    return 2


def cmd_list(args) -> int:
    status, data = _http("GET", "/api/devices")
    if status == 200:
        print(json.dumps(data.get("devices", []), indent=2))
        return 0
    # Fall back to reading the disk record directly.
    if _ensure_pairing_module():
        from api.pairing import list_devices
        print(json.dumps(list_devices(), indent=2))
        return 0
    print(json.dumps({"error": f"webui returned {status}", "detail": data}), file=sys.stderr)
    return 1


def _resolve_device_id(query: str) -> str | None:
    """Accept an ID prefix OR a name substring."""
    if not _ensure_pairing_module():
        return None
    from api.pairing import list_devices
    q = query.lower()
    matches = []
    for d in list_devices():
        did = (d.get("id") or "").lower()
        name = (d.get("name") or "").lower()
        if did.startswith(q) or q in name:
            matches.append(d)
    if not matches:
        return None
    # Prefer ID-prefix match over name-substring.
    matches.sort(key=lambda d: (0 if d.get("id", "").lower().startswith(q) else 1,
                                -d.get("paired_at", 0)))
    return matches[0].get("id")


def cmd_revoke(args) -> int:
    dev_id = _resolve_device_id(args.device)
    if not dev_id:
        print(json.dumps({"error": f"no device matching {args.device!r}"}), file=sys.stderr)
        return 1
    status, data = _http("DELETE", f"/api/devices/{dev_id}")
    if status == 200:
        print(json.dumps({"ok": True, "id": dev_id, **data}))
        return 0
    print(json.dumps({"error": f"webui returned {status}", "detail": data}), file=sys.stderr)
    return 1


def cmd_logout(args) -> int:
    dev_id = _resolve_device_id(args.device)
    if not dev_id:
        print(json.dumps({"error": f"no device matching {args.device!r}"}), file=sys.stderr)
        return 1
    status, data = _http("POST", f"/api/devices/{dev_id}/logout", body={})
    if status == 200:
        print(json.dumps({"ok": True, "id": dev_id, **data}))
        return 0
    print(json.dumps({"error": f"webui returned {status}", "detail": data}), file=sys.stderr)
    return 1


def cmd_skills(args) -> int:
    status, data = _http("GET", "/api/devices/skills")
    if status == 200:
        print(json.dumps(data.get("skills", []), indent=2))
        return 0
    print(json.dumps({"error": f"webui returned {status}", "detail": data}), file=sys.stderr)
    return 1


def cmd_invoke(args) -> int:
    dev_id = _resolve_device_id(args.device)
    if not dev_id:
        print(json.dumps({"error": f"no device matching {args.device!r}"}), file=sys.stderr)
        return 1
    try:
        skill_args = json.loads(args.json_args) if args.json_args else {}
    except Exception as e:
        print(json.dumps({"error": f"--json-args isn't valid JSON: {e}"}), file=sys.stderr)
        return 1
    if not isinstance(skill_args, dict):
        print(json.dumps({"error": "--json-args must be a JSON object"}), file=sys.stderr)
        return 1
    status, data = _http("POST", "/api/devices/skills/invoke", body={
        "device_id": dev_id,
        "skill": args.skill,
        "args": skill_args,
        "timeout": args.timeout,
    }, timeout=args.timeout + 5)
    _strip_image_payloads(data)
    print(json.dumps(data, indent=2))
    return 0 if data.get("ok") else 1


def cmd_screenshot(args) -> int:
    """Capture a screen and SAVE it to a file. Returns only the path +
    metadata in stdout — the bot reads the file via its vision tool
    instead of swallowing a megabyte of base64."""
    import base64
    import uuid

    dev_id = _resolve_device_id(args.device)
    if not dev_id:
        print(json.dumps({"error": f"no device matching {args.device!r}"}), file=sys.stderr)
        return 1

    skill_args = {
        "format": args.format,
        "quality": args.quality,
        "max_dim": args.max_dim,
    }
    if args.region:
        try:
            skill_args["region"] = json.loads(args.region)
        except Exception as e:
            print(json.dumps({"error": f"--region isn't valid JSON: {e}"}), file=sys.stderr)
            return 1

    status, data = _http("POST", "/api/devices/skills/invoke", body={
        "device_id": dev_id,
        "skill": "screenshot",
        "args": skill_args,
        "timeout": args.timeout,
    }, timeout=args.timeout + 5)

    if not data.get("ok"):
        print(json.dumps(data, indent=2), file=sys.stderr)
        return 1

    result = data.get("result") or {}
    b64 = result.get("img_b64") or result.get("png_b64")
    if not b64:
        print(json.dumps({"error": "device returned no image data"}, indent=2), file=sys.stderr)
        return 1

    fmt = (result.get("format") or args.format or "jpeg").lower()
    ext = "jpg" if fmt == "jpeg" else fmt
    out_path = args.out
    if not out_path:
        # Default to an ALLOWLISTED media cache dir (not /tmp) so the saved
        # screenshot survives gateway media-delivery validation when emitted
        # as a MEDIA directive over a messaging platform.
        out_path = str(_media_cache_dir() / f"jc-screenshot-{uuid.uuid4().hex[:12]}.{ext}")
    try:
        with open(out_path, "wb") as f:
            f.write(base64.b64decode(b64))
    except Exception as e:
        print(json.dumps({"error": f"failed to write {out_path}: {e}"}, indent=2), file=sys.stderr)
        return 1

    print(json.dumps({
        "ok": True,
        "path": out_path,
        "format": fmt,
        "width": result.get("width"),
        "height": result.get("height"),
        "bytes": os.path.getsize(out_path),
    }, indent=2))
    return 0


def _strip_image_payloads(data: dict, save_dir: Path | None = None) -> None:
    """If a skill result contains an inline image (img_b64 / png_b64),
    write it to a file and replace the field with `image_path`.
    Keeps the printed JSON small so the bot's tool layer doesn't choke
    on a megabyte of base64.

    The file lands in an ALLOWLISTED media cache dir (not /tmp) so the image
    survives gateway media-delivery validation when emitted as a MEDIA
    directive over a messaging platform."""
    import base64
    import uuid

    res = data.get("result") if isinstance(data, dict) else None
    if not isinstance(res, dict):
        return
    b64 = res.get("img_b64") or res.get("png_b64")
    if not b64 or not isinstance(b64, str) or len(b64) < 1024:
        return  # too small to bother with a file
    fmt = (res.get("format") or "png").lower()
    ext = "jpg" if fmt == "jpeg" else fmt
    path = str(_media_cache_dir() / f"jc-image-{uuid.uuid4().hex[:12]}.{ext}")
    try:
        with open(path, "wb") as f:
            f.write(base64.b64decode(b64))
    except Exception:
        return
    res.pop("img_b64", None)
    res.pop("png_b64", None)
    res["image_path"] = path
    res["image_bytes"] = os.path.getsize(path)


def main() -> int:
    p = argparse.ArgumentParser(prog="devices", description="JarvisCopilot device management")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("pair", help="Start a pairing flow")
    sp.add_argument("--ttl", type=int, default=600, help="Code lifetime (60-3600s, default 600)")
    sp.add_argument("--label", default=None, help="Optional label stored on the device record")
    sp.add_argument("--no-wait", action="store_true", help="Print code + return immediately (don't poll)")
    sp.set_defaults(func=cmd_pair)

    sub.add_parser("list", help="List paired devices").set_defaults(func=cmd_list)

    sp = sub.add_parser("revoke", help="Revoke pairing + invalidate session")
    sp.add_argument("device", help="Device ID prefix or name substring")
    sp.set_defaults(func=cmd_revoke)

    sp = sub.add_parser("logout", help="Invalidate session, keep pairing")
    sp.add_argument("device", help="Device ID prefix or name substring")
    sp.set_defaults(func=cmd_logout)

    sub.add_parser("skills", help="List skills exposed by connected devices").set_defaults(func=cmd_skills)

    sp = sub.add_parser("invoke", help="Invoke a device-exposed skill")
    sp.add_argument("device", help="Device ID prefix or name substring")
    sp.add_argument("skill", help="Skill name (as registered by the device)")
    sp.add_argument("--json-args", default="{}", help="JSON object passed as the skill's args")
    sp.add_argument("--timeout", type=float, default=30.0, help="Seconds to wait for a response")
    sp.set_defaults(func=cmd_invoke)

    sp = sub.add_parser(
        "screenshot",
        help="Capture a device's screen, save it to a file, print {path, format, width, height} — "
             "doesn't dump base64 to stdout. Prefer this over `invoke ... screenshot` for screen capture.",
    )
    sp.add_argument("device", help="Device ID prefix or name substring")
    sp.add_argument("--out", help="Output path (default: temp file)")
    sp.add_argument("--format", choices=["jpeg", "png"], default="jpeg")
    sp.add_argument("--quality", type=int, default=70, help="JPEG quality 1-100 (default 70)")
    sp.add_argument("--max-dim", dest="max_dim", type=int, default=1400,
                    help="Cap longest side in px (default 1400; 0 disables)")
    sp.add_argument("--region", help="JSON {x,y,w,h} for a sub-rect; omit for full screen")
    sp.add_argument("--timeout", type=float, default=15.0, help="Seconds to wait")
    sp.set_defaults(func=cmd_screenshot)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
