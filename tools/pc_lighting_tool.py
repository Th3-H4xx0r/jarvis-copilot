"""PC Lighting tools — Jarvis colours Pranav's gaming PC: fans (top, rear, bottom), the cooler's logo and
the bottom strip, part by part or all at once, with effects, brightness and saved looks.

Both go to the webui over the host-signed loopback (/api/pc-lighting); the server applies the LED map and
the Power switch, and the PC's jc-client drives OpenRGB. Spec:
docs/superpowers/specs/2026-11-20-pc-lighting-model-specs-design.md
"""
from __future__ import annotations

import json
import re
import urllib.parse

from tools.chrome_device_tool import _api_request
from tools.registry import registry

PARTS = ("all", "top", "rear", "bottom", "cooler", "strip")
EFFECTS = ("static", "breathing", "rainbow", "spectrum", "comet")
NAMES = {
    "black": "#000000", "silver": "#c0c0c0", "gray": "#808080", "grey": "#808080", "white": "#ffffff",
    "maroon": "#800000", "red": "#ff0000", "purple": "#800080", "fuchsia": "#ff00ff", "magenta": "#ff00ff",
    "green": "#008000", "lime": "#00ff00", "olive": "#808000", "yellow": "#ffff00", "navy": "#000080",
    "blue": "#0000ff", "teal": "#008080", "aqua": "#00ffff", "cyan": "#00ffff", "orange": "#ffa500",
    "pink": "#ffc0cb", "violet": "#ee82ee", "warm white": "#ffd7a8",
}
NOT_SET_UP = "PC lighting isn't set up yet: open the PC page on your iPhone (Devices → Wearables → PC) to set it up"


def _out(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, default=str)


def _colour(value: str):
    v = str(value or "").strip().lower()
    if re.fullmatch(r"#?[0-9a-f]{6}", v):
        return v if v.startswith("#") else "#" + v
    return NAMES.get(v)


def _err(r: dict) -> str:
    return str(r.get("_error") or r.get("error") or "")


def pc_lights(args=None, **_kw) -> str:
    args = args or {}
    action = str(args.get("action") or "status")
    if action == "set":
        partial = {"part": str(args.get("part") or "all")}
        if partial["part"] not in PARTS:
            return _out({"ok": False, "error": f"part must be one of {', '.join(PARTS)}"})
        if args.get("color") is not None:
            hexed = _colour(args["color"])
            if not hexed:
                return _out({"ok": False, "error": f"Unknown colour {args['color']!r}: use #rrggbb or a basic name"})
            partial["color"] = hexed
        for key in ("effect", "speed", "brightness", "on"):
            if args.get(key) is not None:
                partial[key] = args[key]
        if partial.get("effect") is not None and partial["effect"] not in EFFECTS:
            return _out({"ok": False, "error": f"effect must be one of {', '.join(EFFECTS)}"})
        now = _api_request("GET", "/api/pc-lighting")
        if _err(now):
            return _out({"ok": False, "error": _err(now)})
        if not (now.get("map") or {}).get("segments"):
            return _out({"ok": False, "error": NOT_SET_UP})
        r = _api_request("POST", "/api/pc-lighting/state", partial)
        if r.get("ok") is False or _err(r):
            return _out({"ok": False, "error": _err(r) or "The PC didn't take the change"})
        return _out({"ok": True, "state": r.get("state")})
    r = _api_request("GET", "/api/pc-lighting")
    if _err(r):
        return _out({"ok": False, "error": _err(r)})
    st = r.get("state") or {}
    out = {"ok": True, "online": r.get("online"), "on": st.get("on"), "brightness": st.get("brightness"),
           "parts": st.get("parts"), "engine": (r.get("live") or {}).get("engine"), "coverage": r.get("coverage")}
    if not (r.get("map") or {}).get("segments"):
        out["note"] = NOT_SET_UP
    return _out(out)


def pc_light_looks(args=None, **_kw) -> str:
    args = args or {}
    action = str(args.get("action") or "list")
    name = str(args.get("name") or "")
    if action == "list":
        r = _api_request("GET", "/api/pc-lighting/looks")
    elif action == "save":
        r = _api_request("POST", "/api/pc-lighting/looks", {"name": name})
    elif action == "apply":
        r = _api_request("POST", "/api/pc-lighting/looks/apply", {"name": name})
    elif action == "delete":
        r = _api_request("DELETE", f"/api/pc-lighting/looks/{urllib.parse.quote(name)}")
    else:
        return _out({"ok": False, "error": "action must be list, save, apply or delete"})
    if r.get("ok") is False or _err(r):
        return _out({"ok": False, "error": _err(r)})
    return _out(dict(r, ok=True))


registry.register(
    name="pc_lights", toolset="pc_lighting", emoji="🌈",
    schema={
        "name": "pc_lights",
        "description": ("Pranav's gaming PC lighting: status, or set the colour/effect/speed/brightness/on of one part "
                        "(top fans, rear fans, bottom fans, cooler logo, bottom strip) or all of them. Effects: static, "
                        "breathing, rainbow, spectrum, comet."),
        "parameters": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["status", "set"]},
            "part": {"type": "string", "enum": list(PARTS), "description": "Default all"},
            "color": {"type": "string", "description": "#rrggbb or a basic colour name (red, blue, warm white …)"},
            "effect": {"type": "string", "enum": list(EFFECTS)},
            "speed": {"type": "integer", "description": "1–10 for animated effects"},
            "brightness": {"type": "integer", "description": "0–100"},
            "on": {"type": "boolean"},
        }, "required": ["action"]},
    },
    handler=lambda args, **kw: pc_lights(args, **kw),
)

registry.register(
    name="pc_light_looks", toolset="pc_lighting", emoji="🎨",
    schema={
        "name": "pc_light_looks",
        "description": "Saved PC lighting looks (every part's colour/effect + brightness): list, save the current one, apply or delete.",
        "parameters": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["list", "save", "apply", "delete"]},
            "name": {"type": "string"},
        }, "required": ["action"]},
    },
    handler=lambda args, **kw: pc_light_looks(args, **kw),
)
