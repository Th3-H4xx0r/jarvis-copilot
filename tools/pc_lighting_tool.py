"""PC Lighting tools — Jarvis colours Pranav's gaming PC: fans (top, rear, bottom), the cooler's logo and
the bottom strip, part by part or all at once, with effects, brightness and saved looks; runs the setup
steps, lights test LEDs for calibration, and reads the LED map and the PC's specs.

pc_lights       status, on, off, brightness, color, effect, speed, set (several at once)
pc_light_looks  list, save, apply, delete
pc_light_setup  steps, run_step, connectors, test_leds, led_count, clear_test, map, specs, refresh_specs

Every call goes to the webui over the host-signed loopback (/api/pc-lighting, /api/pc-specs), the same
routes the iPhone and the web use: the server validates, sets a shared part's host too, queues the push
and tells every device. The PC's jc-client drives OpenRGB. Jarvis never writes the LED map: calibration
needs Pranav's eyes, so it is finished on the iPhone. Setup steps that install software ask Face ID on
the iPhone before anything runs (the PC's admin helper). Spec:
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
PART_NAMES = {"top": "top fans", "rear": "rear fans", "bottom": "bottom fans", "cooler": "cooler logo",
              "strip": "strip"}
# Colour names as LED colours: the PC turns screen colours into LED power, so every hue here has a
# channel at full (web "green" #008000 would light the fans at half power). Greys are dim whites.
NAMES = {
    "black": "#000000", "silver": "#c0c0c0", "gray": "#808080", "grey": "#808080", "white": "#ffffff",
    "maroon": "#ff0018", "red": "#ff0000", "purple": "#8000ff", "fuchsia": "#ff00ff", "magenta": "#ff00ff",
    "green": "#00ff00", "lime": "#00ff00", "olive": "#a0ff00", "yellow": "#ffff00", "navy": "#0010ff",
    "blue": "#0000ff", "teal": "#00ffc0", "aqua": "#00ffff", "cyan": "#00ffff", "orange": "#ff6a00",
    "pink": "#ff1493", "violet": "#b266ff", "warm white": "#ffd7a8", "cool white": "#e6f0ff",
    "hot pink": "#ff69b4", "deep pink": "#ff1493", "crimson": "#ff0030", "gold": "#ffbf00", "amber": "#ffbf00",
    "indigo": "#4000ff", "turquoise": "#00ffd0", "sky blue": "#00aaff", "royal blue": "#2050ff",
    "lavender": "#b266ff", "coral": "#ff5030", "mint": "#00ffc0", "emerald": "#00ff60",
}
SETUP_STEPS = (
    ("openrgb", "Install OpenRGB and run it at login (asks Face ID on the iPhone first)"),
    ("signalrgb", "Quit SignalRGB and stop it starting at login, never uninstalls it (Face ID if its service runs)"),
    ("driver", "PawnIO driver, only when lights sit on SMBus (asks Face ID to update); USB boards skip it"),
    ("detect", "Check OpenRGB sees the lighting controllers"),
    ("cost", "Measure whether animated effects should pause while a game runs"),
    ("calibrate", "Match LEDs to parts: done on the iPhone, as each part lights up"),
)
FACE_ID_STEPS = ("openrgb", "signalrgb", "driver")
WHITE = "#ffffff"
NOT_SET_UP = "PC lighting isn't set up yet: open the PC page on your iPhone (Devices → Wearables → PC) to set it up"
CALIBRATE_ON_IPHONE = ("Calibration needs your eyes: finish it on your iPhone (Devices → Wearables → PC → "
                       "Lighting setup), tapping each part as it lights up")


def _out(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, default=str)


def _no(error: str) -> str:
    return _out({"ok": False, "error": error})


def _colour(value):
    v = re.sub(r"[\s_-]+", " ", str(value or "")).strip().lower()
    if re.fullmatch(r"#?[0-9a-f]{6}", v):
        return v if v.startswith("#") else "#" + v
    return NAMES.get(v)


def _err(r: dict) -> str:
    return str(r.get("_error") or r.get("error") or "")


def _failed(r: dict, fallback: str = "") -> str:
    """The server's refusal as the tool's answer, keeping why (offline / OpenRGB down)."""
    out = {"ok": False, "error": _err(r) or fallback or "The server refused"}
    for flag in ("offline", "engine_error", "power_off"):
        if r.get(flag):
            out[flag] = r[flag]
    return _out(out)


def _bad(r: dict) -> bool:
    return r.get("ok") is False or bool(_err(r))


def _int(args: dict, key: str, lo: int, hi: int, default=None):
    """(value, error): a whole number in lo..hi, or the default when it's missing."""
    v = args.get(key)
    if v is None or v == "":
        return default, (None if default is not None else f"{key} is required")
    if isinstance(v, bool):
        return None, f"{key} must be a whole number"
    try:
        n = float(v)
    except (TypeError, ValueError):
        return None, f"{key} must be a whole number"
    if n != int(n) or not lo <= n <= hi:
        return None, f"{key} must be a whole number from {lo} to {hi}"
    return int(n), None


def _lights(coverage: dict, part: str) -> str:
    host = (coverage or {}).get(part, "missing")
    if host is None:
        return "own"
    if host == "missing":
        return "none"
    return f"mirrors {host}"


# ── pc_lights ────────────────────────────────────────────────────────────────
def _status() -> str:
    r = _api_request("GET", "/api/pc-lighting")
    if _err(r):
        return _failed(r)
    st, live, cov = r.get("state") or {}, r.get("live") or {}, r.get("coverage") or {}
    raw = st.get("parts") or {}
    parts = {}
    for p in PART_NAMES:
        host = cov.get(p)
        shown = raw.get(host) if host and host != "missing" and host in raw else raw.get(p)
        parts[p] = dict(shown or {}, lights=_lights(cov, p))
    steps = r.get("setup") or {}
    done = sum(1 for k, _ in SETUP_STEPS if (steps.get(k) or {}).get("state") in ("done", "skipped"))
    out = {"ok": True, "online": r.get("online"), "engine": live.get("engine"),
           "paused_for_game": bool(live.get("paused_for_game")), "on": st.get("on"),
           "brightness": st.get("brightness"), "parts": parts, "set_up": bool((r.get("map") or {}).get("segments")),
           "setup": f"{done} of {len(SETUP_STEPS)} steps done"}
    if live.get("error"):
        out["engine_error"] = live["error"]
    if live.get("push_error"):
        out["push_error"] = live["push_error"]
    if not out["set_up"]:
        out["note"] = NOT_SET_UP
    elif not r.get("online"):
        out["note"] = "The PC is asleep or offline: changes wait until it's back"
    return _out(out)


def _change(partial: dict) -> str:
    now = _api_request("GET", "/api/pc-lighting")
    if _err(now):
        return _failed(now)
    if not (now.get("map") or {}).get("segments"):
        return _no(NOT_SET_UP)
    r = _api_request("POST", "/api/pc-lighting/state", partial)
    if _bad(r):
        return _failed(r, "The PC didn't take the change")
    st = r.get("state") or {}
    out = {"ok": True, "state": {"on": st.get("on"), "brightness": st.get("brightness"), "parts": st.get("parts")}}
    part = partial.get("part", "all")
    host = (now.get("coverage") or {}).get(part) if part != "all" else None
    if host and host != "missing":
        pn, hn = PART_NAMES[part], PART_NAMES[host]
        out["note"] = (f"The {pn} {'mirror' if pn.endswith('s') else 'mirrors'} the {hn} (one lighting stream), "
                       f"so the {hn} changed too")
    if (now.get("live") or {}).get("paused_for_game") and partial.get("effect") not in (None, "static"):
        out["note_game"] = "A game is running: animated effects stay paused until it ends"
    return _out(out)


def _part(args: dict):
    part = str(args.get("part") or "all")
    return (part, None) if part in PARTS else (None, f"part must be one of {', '.join(PARTS)}")


def pc_lights(args=None, **_kw) -> str:
    args = args or {}
    action = str(args.get("action") or "status")
    if action == "status":
        return _status()
    if action in ("on", "off"):
        return _change({"part": "all", "on": action == "on"})
    if action == "brightness":
        n, err = _int(args, "brightness", 0, 100)
        return _no(err) if err else _change({"part": "all", "brightness": n})
    if action not in ("color", "effect", "speed", "set"):
        return _no("unknown action: use status, on, off, brightness, color, effect, speed or set")
    part, err = _part(args)
    if err:
        return _no(err)
    partial: dict = {"part": part}
    if action in ("color", "set") and args.get("color") not in (None, ""):
        hexed = _colour(args["color"])
        if not hexed:
            return _no(f"Unknown colour {args['color']!r}: use #rrggbb or a colour name (red, warm white …)")
        partial["color"] = hexed
    if action in ("effect", "set") and args.get("effect") not in (None, ""):
        if args["effect"] not in EFFECTS:
            return _no(f"effect must be one of {', '.join(EFFECTS)}")
        partial["effect"] = args["effect"]
    if action in ("speed", "effect", "set") and (action == "speed" or args.get("speed") is not None):
        n, err = _int(args, "speed", 1, 10)
        if err:
            return _no(err)
        partial["speed"] = n
    if action == "set" and args.get("brightness") is not None:
        n, err = _int(args, "brightness", 0, 100)
        if err:
            return _no(err)
        partial["brightness"] = n
    if action == "set" and args.get("on") is not None:
        if not isinstance(args["on"], bool):
            return _no("on must be true or false")
        partial["on"] = args["on"]
    need = {"color": "color", "effect": "effect"}.get(action)
    if need and need not in partial:
        return _no(f"{need} is required")
    if action == "set" and len(partial) == 1:
        return _no("set needs at least one of color, effect, speed, brightness, on")
    return _change(partial)


# ── pc_light_looks ───────────────────────────────────────────────────────────
def pc_light_looks(args=None, **_kw) -> str:
    args = args or {}
    action = str(args.get("action") or "list")
    name = str(args.get("name") or "").strip()
    if action not in ("list", "save", "apply", "delete"):
        return _no("unknown action: use list, save, apply or delete")
    if action != "list" and not name:
        return _no(f"{action} needs the look's name")
    if action == "list":
        r = _api_request("GET", "/api/pc-lighting/looks")
    elif action == "save":
        r = _api_request("POST", "/api/pc-lighting/looks", {"name": name})
    elif action == "apply":
        r = _api_request("POST", "/api/pc-lighting/looks/apply", {"name": name})
    else:
        have = _api_request("GET", "/api/pc-lighting/looks")
        if _err(have):
            return _failed(have)
        names = [str(l.get("name")) for l in have.get("looks") or []]
        if name.lower() not in (n.lower() for n in names):
            return _no(f"No look named {name!r}" + (f": the looks are {', '.join(names)}" if names else ": none saved"))
        r = _api_request("DELETE", f"/api/pc-lighting/looks/{urllib.parse.quote(name)}")
    if _bad(r):
        return _failed(r)
    return _out(dict(r, ok=True))


# ── pc_light_setup ───────────────────────────────────────────────────────────
def _connectors(r: dict) -> list:
    segs = (r.get("map") or {}).get("segments") or []
    out = []
    for c in (r.get("live") or {}).get("controllers") or []:
        zones = []
        for z in c.get("zones") or []:
            parts = [{"part": s.get("part"), "index": s.get("index", 0), "start": s.get("start"),
                      "count": s.get("count"), "also": list(s.get("also") or [])}
                     for s in segs if s.get("controller") == c.get("index") and s.get("zone") == z.get("index")]
            zones.append({"zone": z.get("index"), "name": z.get("name"), "leds": z.get("leds"),
                          "resizable": bool(z.get("resizable")), "max": z.get("max"), "parts": parts})
        out.append({"controller": c.get("index"), "name": c.get("name"), "location": c.get("location"),
                    "zones": zones})
    return out


def _zone(r: dict, controller: int, zone: int):
    """(zone dict or None, error). No controllers reported yet = can't check, let the PC decide."""
    ctls = (r.get("live") or {}).get("controllers") or []
    if not ctls:
        return None, None
    c = next((c for c in ctls if c.get("index") == controller), None)
    if c is None:
        return None, f"No controller {controller}: the PC has {', '.join(str(x.get('index')) for x in ctls)}"
    z = next((z for z in c.get("zones") or [] if z.get("index") == zone), None)
    if z is None:
        return None, f"Controller {controller} has no zone {zone}"
    return z, None


def _probe(body: dict, done: str) -> str:
    r = _api_request("POST", "/api/pc-lighting/probe", body, timeout=20.0)
    if _bad(r):
        return _failed(r, "The PC didn't light the test LEDs")
    return _out({"ok": True, "note": done})


def _where(args: dict):
    controller, err = _int(args, "controller", 0, 64)
    if err:
        return None, None, None, err
    zone, err = _int(args, "zone", 0, 64)
    if err:
        return None, None, None, err
    r = _api_request("GET", "/api/pc-lighting")
    if _err(r):
        return None, None, None, _err(r)
    z, err = _zone(r, controller, zone)
    return controller, zone, z, err


def _test_leds(args: dict) -> str:
    start, err = _int(args, "start", 0, 1000, default=0)
    count, err2 = _int(args, "count", 1, 1000, default=1)
    if err or err2:
        return _no(err or err2)
    hexed = _colour(args.get("color") or WHITE)
    if not hexed:
        return _no(f"Unknown colour {args.get('color')!r}: use #rrggbb or a colour name")
    controller, zone, z, err = _where(args)
    if err:
        return _no(err)
    if z is not None and start + count > int(z.get("leds") or 0):
        return _no(f"Controller {controller} zone {zone} has {z.get('leds')} LEDs (0–{int(z.get('leds') or 0) - 1})")
    return _probe({"controller": controller, "zone": zone, "range": [start, count], "color": hexed},
                  f"Lit LEDs {start}–{start + count - 1} on controller {controller} zone {zone}; every other light "
                  "is dark until the test is cleared")


def _led_count(args: dict) -> str:
    count, err = _int(args, "count", 1, 1000)
    if err:
        return _no(err)
    controller, zone, z, err = _where(args)
    if err:
        return _no(err)
    if z is not None:
        if not z.get("resizable"):
            return _no(f"Controller {controller} zone {zone} has a fixed {z.get('leds')} LEDs")
        if z.get("max") and count > int(z["max"]):
            return _no(f"Controller {controller} zone {zone} takes at most {z['max']} LEDs")
    return _probe({"controller": controller, "zone": zone, "resize": count, "range": [0, count]},
                  f"Controller {controller} zone {zone} is set to {count} LEDs and they're all lit: if the last one "
                  "glowing is the strip's real end, that's the count (calibration on the iPhone saves it)")


def pc_light_setup(args=None, **_kw) -> str:
    args = args or {}
    action = str(args.get("action") or "steps")
    ids = [k for k, _ in SETUP_STEPS]
    if action == "steps":
        r = _api_request("GET", "/api/pc-lighting")
        if _err(r):
            return _failed(r)
        have = r.get("setup") or {}
        steps = [{"id": k, "what": what, "state": (have.get(k) or {}).get("state") or "todo",
                  "detail": (have.get(k) or {}).get("detail") or ""} for k, what in SETUP_STEPS]
        return _out({"ok": True, "online": r.get("online"), "steps": steps})
    if action == "run_step":
        step = str(args.get("step") or "")
        if step not in ids:
            return _no(f"step must be one of {', '.join(ids)}")
        if step == "calibrate":
            return _no(CALIBRATE_ON_IPHONE)
        r = _api_request("POST", "/api/pc-lighting/setup", {"step": step})
        if _bad(r):
            return _failed(r, "The PC didn't start the step")
        note = "Running on the PC in the background: read the steps again in a few seconds for the result"
        if step in FACE_ID_STEPS:
            note += "; Face ID on your iPhone asks before anything is installed or stopped"
        return _out({"ok": True, "step": r.get("step"), "note": note})
    if action == "connectors":
        r = _api_request("GET", "/api/pc-lighting")
        if _err(r):
            return _failed(r)
        out = {"ok": True, "online": r.get("online"), "connectors": _connectors(r)}
        if not out["connectors"]:
            live = r.get("live") or {}
            out["note"] = (live.get("error") or "OpenRGB hasn't reported any lighting controllers yet") + \
                ": run the openrgb and detect setup steps (the PC must be awake)"
        return _out(out)
    if action == "test_leds":
        return _test_leds(args)
    if action == "led_count":
        return _led_count(args)
    if action == "clear_test":
        return _probe({"clear": True}, "Test lighting cleared: the PC is back to its lighting")
    if action == "map":
        r = _api_request("GET", "/api/pc-lighting")
        if _err(r):
            return _failed(r)
        m = r.get("map") or {}
        out = {"ok": True, "map": {k: m.get(k) for k in ("rev", "zones", "segments")}, "coverage": r.get("coverage")}
        if not m.get("segments"):
            out["note"] = NOT_SET_UP
        return _out(out)
    if action == "specs":
        r = _api_request("GET", "/api/pc-specs")
        if _err(r):
            return _failed(r)
        out = {"ok": True, "specs": r.get("specs")}
        if not r.get("specs"):
            out["note"] = "The PC hasn't sent its specs yet: refresh_specs reads them now (the PC must be awake)"
        return _out(out)
    if action == "refresh_specs":
        r = _api_request("POST", "/api/pc-specs/refresh", {}, timeout=100.0)
        if _bad(r):
            return _failed(r, "The PC didn't answer")
        return _out({"ok": True, "specs": r.get("specs")})
    return _no("unknown action: use steps, run_step, connectors, test_leds, led_count, clear_test, map, specs "
               "or refresh_specs")


_PART = {"type": "string", "enum": list(PARTS), "description": "Default all"}

registry.register(
    name="pc_lights", toolset="pc_lighting", emoji="🌈",
    schema={
        "name": "pc_lights",
        "description": ("Pranav's gaming PC lighting, one control per action. status: on/off, brightness, each part's "
                        "colour/effect/speed, which parts have their own lights or mirror another, online, OpenRGB "
                        "engine and errors, paused for a game. on / off: the whole PC. brightness: the whole PC, "
                        "0–100. color: one part or all. effect (+ optional speed): one part or all. speed: 1–10 for "
                        "animated effects. set: several of color/effect/speed/brightness/on at once. Parts: top fans, "
                        "rear fans, bottom fans, cooler logo, bottom strip."),
        "parameters": {"type": "object", "properties": {
            "action": {"type": "string",
                       "enum": ["status", "on", "off", "brightness", "color", "effect", "speed", "set"]},
            "part": dict(_PART, description="color / effect / speed / set: which part; default all"),
            "color": {"type": "string", "description": "color / set: #rrggbb or a colour name (red, warm white, "
                                                       "deep pink …)"},
            "effect": {"type": "string", "enum": list(EFFECTS), "description": "effect / set"},
            "speed": {"type": "integer", "description": "speed / effect / set: 1 (slow) – 10 (fast)"},
            "brightness": {"type": "integer", "description": "brightness / set: 0–100, the whole PC"},
            "on": {"type": "boolean", "description": "set only"},
        }, "required": ["action"]},
    },
    handler=lambda args, **kw: pc_lights(args, **kw),
)

registry.register(
    name="pc_light_looks", toolset="pc_lighting", emoji="🎨",
    schema={
        "name": "pc_light_looks",
        "description": ("Saved PC lighting looks (every part's colour/effect/speed + brightness): list them, save the "
                        "current lighting under a name, apply one (also turns the lights on), or delete one."),
        "parameters": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["list", "save", "apply", "delete"]},
            "name": {"type": "string", "description": "save / apply / delete: the look's name"},
        }, "required": ["action"]},
    },
    handler=lambda args, **kw: pc_light_looks(args, **kw),
)

registry.register(
    name="pc_light_setup", toolset="pc_lighting", emoji="🛠️",
    schema={
        "name": "pc_light_setup",
        "description": ("Set up and calibrate the gaming PC's lighting, and read its specs. steps: every setup step "
                        "and its state. run_step: start one (runs in the background; installers ask Face ID on the "
                        "iPhone). connectors: OpenRGB controllers and their zones with LED counts and mapped parts. "
                        "test_leds: light LEDs start..start+count-1 of one zone in a colour, everything else dark. "
                        "led_count: set a resizable zone's LED count and light them all. clear_test: back to normal "
                        "lighting. map: the LED map (read-only; calibration itself is done on the iPhone). specs: the "
                        "PC's hardware. refresh_specs: read the specs from the PC now."),
        "parameters": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["steps", "run_step", "connectors", "test_leds", "led_count",
                                                  "clear_test", "map", "specs", "refresh_specs"]},
            "step": {"type": "string", "enum": [k for k, _ in SETUP_STEPS], "description": "run_step"},
            "controller": {"type": "integer", "description": "test_leds / led_count: controller index (connectors)"},
            "zone": {"type": "integer", "description": "test_leds / led_count: zone index on that controller"},
            "start": {"type": "integer", "description": "test_leds: first LED, default 0"},
            "count": {"type": "integer", "description": "test_leds: how many LEDs, default 1; led_count: the zone's "
                                                        "LED count"},
            "color": {"type": "string", "description": "test_leds: #rrggbb or a colour name, default white"},
        }, "required": ["action"]},
    },
    handler=lambda args, **kw: pc_light_setup(args, **kw),
)
