"""holo_drop — Jarvis flings a link, text or a file onto one of Pranav's devices.

Goes to the webui over the host-signed loopback; the drop follows the device's arrival default
(open, save, copy…), exactly as if he had sent it (his decision).
"""
from __future__ import annotations

import json
import os
import urllib.parse

from tools.chrome_device_tool import _api_request
from tools.registry import registry


def _fail(msg: str) -> str:
    return json.dumps({"ok": False, "error": msg}, ensure_ascii=False)


def _pick(devices: list[dict], target: str) -> dict | None:
    t = (target or "").strip().lower()
    if not t:
        return None
    for d in devices:
        if t in (d["id"].lower(), d["name"].lower()):
            return d
    aliases = {"mac": "mac", "macbook": "mac", "laptop": "mac", "computer": "mac", "phone": "iphone",
               "iphone": "iphone", "ipad": "ipad", "web": "web", "browser": "web", "glasses": "glasses", "pod": "pod"}
    kind = aliases.get(t)
    matches = [d for d in devices if d["kind"] == kind] or [d for d in devices if t in d["name"].lower()]
    matches.sort(key=lambda d: not d.get("online"))
    return matches[0] if matches else None


def holo_drop(args=None, **_kw) -> str:
    args = args or {}
    listing = _api_request("GET", "/api/holo-drop/devices")
    if "_error" in listing or "error" in listing:
        return _fail(listing.get("_error") or listing.get("error"))
    target = _pick(listing.get("devices") or [], str(args.get("target") or ""))
    if target is None:
        names = ", ".join(d["name"] for d in listing.get("devices") or [])
        return _fail(f"no device called {args.get('target')!r} (have: {names or 'none'})")
    action = args.get("action")
    if args.get("file_path"):
        return _send_file(str(args["file_path"]), target, action)
    url, text = str(args.get("url") or "").strip(), str(args.get("text") or "")
    if not url and not text:
        return _fail("give url, text or file_path")
    body = {"kind": "link" if url else "text", "target": target["id"], "url": url, "text": text}
    if action:
        body["action"] = action
    out = _api_request("POST", "/api/holo-drop/drops", body)
    if "_error" in out or "error" in out:
        return _fail(out.get("_error") or out.get("error"))
    d = out.get("drop") or {}
    return json.dumps({"ok": True, "to": target["name"], "state": d.get("state"), "id": d.get("id"),
                       "note": "Held until the device is back (a Mac is woken)." if d.get("state") == "held" else ""},
                      ensure_ascii=False)


def _send_file(path: str, target: dict, action) -> str:
    import mimetypes
    import urllib.request
    from tools.chrome_device_tool import _host_signature, _webui_origin
    if not os.path.isfile(path):
        return _fail(f"no file at {path}")
    mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
    kind = "image" if mime.startswith("image/") else "video" if mime.startswith("video/") else "file"
    q = {"kind": kind, "target": target["id"], "name": os.path.basename(path), "mime": mime}
    if action:
        q["action"] = action
    sub = "/api/holo-drop/drops/upload?" + urllib.parse.urlencode(q)
    size = os.path.getsize(path)
    headers = {"Content-Length": str(size), "Content-Type": "application/octet-stream", "X-Requested-With": "fetch"}
    sig = _host_signature("POST", sub)
    if sig:
        headers["X-JC-Host-Sig"] = sig
    with open(path, "rb") as fh:
        req = urllib.request.Request(_webui_origin() + sub, data=fh, method="POST", headers=headers)
        ctx = None
        if req.full_url.startswith("https://"):
            import ssl
            ctx = ssl._create_unverified_context()
        try:
            with urllib.request.urlopen(req, timeout=600, context=ctx) as r:
                out = json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            try:
                return _fail(json.loads(e.read().decode() or "{}").get("error") or str(e))
            except Exception:
                return _fail(str(e))
    d = out.get("drop") or {}
    return json.dumps({"ok": True, "to": target["name"], "state": d.get("state"), "id": d.get("id")}, ensure_ascii=False)


_SCHEMA = {
    "name": "holo_drop",
    "description": (
        "Holo Drop: put a link, some text or a file onto one of Pranav's devices (Mac, iPhone, iPad, "
        "the web app, glasses, Pod). It arrives with that device's usual action (open, save or copy) "
        "unless you set one. Offline devices get it when they're back."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "target": {"type": "string", "description": "Device name or kind: Mac, iPhone, iPad, web, glasses, pod"},
            "url": {"type": "string"},
            "text": {"type": "string"},
            "file_path": {"type": "string", "description": "A file on the server to send"},
            "action": {"type": "string", "enum": ["save", "open", "copy", "save_open", "save_copy"]},
        },
        "required": ["target"],
    },
}

registry.register(name="holo_drop", toolset="holo_drop", schema=_SCHEMA,
                  handler=lambda args, **kw: holo_drop(args, **kw), emoji="✋")
