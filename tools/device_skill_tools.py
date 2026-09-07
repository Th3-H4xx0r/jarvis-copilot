"""Native, in-process agent tools built from the device-bridge skill registry.

Previously the only way to reach a device's own skills (open_app, send_sms,
flashlight, ...) was the generic ``terminal → python devices.py invoke`` round
trip described in ``skills/jarviscopilot/devices/SKILL.md`` — the model had to
shell out, parse stdout, and pay a full terminal-tool turn for every call.
This module builds one first-class agent tool per skill a connected device
advertises (``device_<skill>``), the same pattern ``tools/chrome_device_tool.py``
uses for the Mac's ``chrome_*`` skills, but generic and dynamic: rebuilt
whenever a device registers its catalogue or disconnects (via
``api.device_bridge.on_registry_change``).

Toolset: ``devices`` (see ``toolsets.py``).

Interface for other callers (model_tools.py / lazy_tools.py):
    get_device_tools() -> list[{"name","toolset","schema","handler","description"}]

Topology: when this process IS the webui (``device_bridge.in_process_available()``
is True) skills are invoked directly via ``device_bridge.invoke_skill()``.
Otherwise (e.g. a gateway-spawned agent process) we fall back to the same
host-signed HTTP loopback ``tools/chrome_device_tool.py`` uses.
"""
from __future__ import annotations

import base64
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

from tools.registry import registry

logger = logging.getLogger(__name__)

# plan 3.1/3.4 — tool results are capped to 1 KB unless the skill is a
# "reader" whose entire point is returning a large payload (a page snapshot,
# a screenshot, a directory listing, ...). Mirrors tools/chrome_device_tool.py's
# server-side truncation for the chrome_* skills.
_RESULT_TRIM_CHARS = 1024  # plan 3.1
_READER_PREFIXES = ("chrome_snapshot", "screenshot", "read_", "list_", "get_",
                    "recent_photo", "pick_photo", "take_photo")

# Photos / screenshots from a device come back as base64. The model reads
# text, so the pixels are written to disk and — because the whole point of
# "what is my latest photo" is to SEE it — described through the vision tool,
# with the caller's question (or a default) as the prompt.
_IMAGE_DIR = Path(os.path.expanduser("~/.jarviscopilot/webui/device_images"))
_IMAGE_KEEP = 40
_IMAGE_EXT = {"image/jpeg": ".jpg", "image/png": ".png", "image/heic": ".heic",
              "image/webp": ".webp", "image/gif": ".gif"}
_DEFAULT_IMAGE_PROMPT = ("Describe this photo in two or three sentences: the subject, the setting, "
                         "any text, and anything notable.")


def _describe_image(path: str, prompt: str) -> Any:
    """Hand a local image to the vision layer, exactly as an attached image is
    handled: a multimodal envelope (the main model sees the pixels itself) when
    the provider supports images in tool results, else the aux model's text
    description. Raises on failure."""
    import asyncio
    from concurrent.futures import ThreadPoolExecutor
    from tools.vision_tools import _handle_vision_analyze

    awaitable = _handle_vision_analyze({"image_url": path, "question": prompt})
    # The tool handler runs on the agent's worker thread; there may or may not
    # be a running loop, so always drive the coroutine on a fresh one.
    with ThreadPoolExecutor(max_workers=1) as pool:
        raw = pool.submit(asyncio.run, awaitable).result(timeout=120)
    if isinstance(raw, dict):
        return raw          # _multimodal envelope — pixels go to the model
    try:
        parsed = json.loads(raw)
    except Exception:
        return str(raw)
    if isinstance(parsed, dict) and parsed.get("success") is False:
        raise RuntimeError(str(parsed.get("analysis") or parsed.get("error") or "vision failed"))
    if isinstance(parsed, dict):
        return str(parsed.get("analysis") or parsed.get("result") or raw)
    return str(raw)


def _prune_images() -> None:
    try:
        files = sorted(_IMAGE_DIR.glob("*"), key=lambda p: p.stat().st_mtime, reverse=True)
        for stale in files[_IMAGE_KEEP:]:
            stale.unlink(missing_ok=True)
    except Exception:
        pass


def _materialize_image(result: dict, skill_name: str, call_args: dict) -> dict:
    """If `result` carries an image (`base64` + image `mime`), swap the blob for
    an `image_path` and add a `description` from the vision model."""
    b64 = result.get("base64")
    mime = str(result.get("mime") or "").lower()
    if not isinstance(b64, str) or not b64 or not mime.startswith("image/"):
        return result
    out = {k: v for k, v in result.items() if k != "base64"}
    try:
        _IMAGE_DIR.mkdir(parents=True, exist_ok=True)
        data = base64.b64decode(b64, validate=False)
        name = f"{skill_name}-{int(time.time() * 1000)}{_IMAGE_EXT.get(mime, '.img')}"
        path = _IMAGE_DIR / name
        path.write_bytes(data)
        out["image_path"] = str(path)
        out["bytes"] = len(data)
        _prune_images()
    except Exception as exc:
        out["error"] = f"could not save image: {exc}"
        return out
    prompt = str((call_args or {}).get("question") or (call_args or {}).get("prompt") or "").strip()
    try:
        seen = _describe_image(str(path), prompt or _DEFAULT_IMAGE_PROMPT)
    except Exception as exc:
        out["vision_error"] = str(exc)
        return out
    if _is_multimodal(seen):
        # The model sees the photo itself. Carry the skill's metadata (when it
        # was taken, how many photos there are) in the envelope's text part so
        # nothing is lost, and hand the envelope back untouched.
        envelope = dict(seen)
        facts = ", ".join(f"{k}: {v}" for k, v in out.items()
                          if k in ("taken_at", "index", "library_count", "width", "height"))
        if facts:
            content = list(envelope.get("content") or [])
            content.insert(0, {"type": "text", "text": f"Photo from the user's device ({facts})."})
            envelope["content"] = content
        envelope["meta"] = {**(envelope.get("meta") or {}),
                            **{k: v for k, v in out.items() if k != "error"}}
        return envelope
    out["description"] = seen
    return out


def _is_multimodal(value: Any) -> bool:
    return (isinstance(value, dict) and value.get("_multimodal") is True
            and isinstance(value.get("content"), list))

_LOCK = threading.Lock()
_current_tools: list[dict] = []
_registered_names: set = set()


# ── skill classification / trimming ─────────────────────────────────────────

def _is_reader_skill(skill_name: str) -> bool:
    name = (skill_name or "").lower()
    return any(name == p or name.startswith(p) for p in _READER_PREFIXES)


def _trim_value(value: Any) -> Any:
    if isinstance(value, str) and len(value) > _RESULT_TRIM_CHARS:
        return value[:_RESULT_TRIM_CHARS] + f"... [truncated, {len(value)} chars total]"
    if isinstance(value, dict):
        return {k: _trim_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_trim_value(v) for v in value]
    return value


def _trim_result(result: dict, skill_name: str) -> dict:
    if _is_reader_skill(skill_name):
        return result
    return _trim_value(result)


# ── invocation (in-process vs HTTP fallback — plan 3.2) ─────────────────────

def _invoke(device_id: str, skill_name: str, args: dict) -> dict:
    """Invoke a device skill, never raising — 3.4: errors come back as a
    ``{"ok": False, "error": ...}`` dict, never an exception into the model loop."""
    try:
        from api import device_bridge
    except Exception as exc:
        return {"ok": False, "error": f"device bridge unavailable: {exc}"}

    try:
        if device_bridge.in_process_available():
            return device_bridge.invoke_skill(device_id, skill_name, args or {})
    except Exception as exc:
        return {"ok": False, "error": str(exc)}

    # HTTP loopback fallback (gateway-spawned agents, etc.) — reuses the
    # generic invoke_skill_safe() helper from chrome_device_tool.py.
    try:
        from tools.chrome_device_tool import invoke_skill_safe
        return invoke_skill_safe(device_id, skill_name, args or {})
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def _resolve_device(args: dict, candidates: list[dict]) -> tuple[Optional[str], Optional[str]]:
    """Return ``(device_id, error)`` for a skill offered by one or more devices."""
    if not candidates:
        return None, "no device currently offers this skill"
    if len(candidates) == 1:
        return candidates[0]["device_id"], None
    wanted = str((args or {}).get("device") or "").strip()
    if not wanted:
        # No preference given — default to the first connected match rather
        # than erroring, so the common single-relevant-device case still works
        # without forcing the model to always pass `device`.
        return candidates[0]["device_id"], None
    wanted_l = wanted.lower()
    for c in candidates:
        if c["device_id"] == wanted or wanted_l in (c.get("device_name") or "").lower():
            return c["device_id"], None
    return None, f"no connected device matches {wanted!r}"


# ── tool building ────────────────────────────────────────────────────────────

def _make_handler(skill_name: str, candidates: list[dict]) -> Callable:
    def _handler(args=None, **_kw):
        device_id, err = _resolve_device(args or {}, candidates)
        if err:
            return json.dumps({"ok": False, "error": err})
        call_args = dict(args or {})
        call_args.pop("device", None)
        try:
            result = _invoke(device_id, skill_name, call_args)
        except Exception as exc:  # 3.4 — never raise into the model loop
            return json.dumps({"ok": False, "error": str(exc)})
        if not isinstance(result, dict):
            result = {"ok": True, "result": result}
        result = _materialize_image(result, skill_name, call_args)
        if _is_multimodal(result):
            # Returned as a dict, not JSON: the agent loop unwraps this into a
            # tool result carrying the image itself.
            return result
        result = _trim_result(result, skill_name)
        return json.dumps(result, ensure_ascii=False)

    return _handler


def _build_schema(skill_name: str, candidates: list[dict]) -> tuple[dict, str]:
    base_schema = candidates[0].get("input_schema")
    if not isinstance(base_schema, dict):
        base_schema = {}
    properties = dict(base_schema.get("properties") or {})
    required = list(base_schema.get("required") or [])
    schema_type = base_schema.get("type") or "object"

    multi = len(candidates) > 1
    device_names = sorted({c.get("device_name") or "device" for c in candidates})
    base_description = (candidates[0].get("description") or f"Device skill '{skill_name}'").strip()

    if multi:
        properties = dict(properties)
        properties["device"] = {
            "type": "string",
            "description": (
                "Which device to target, by id or a substring of its name. "
                f"Available: {', '.join(device_names)}. Defaults to the first "
                "connected match if omitted."
            ),
        }
        description = f"{base_description} (available on: {', '.join(device_names)})"
    else:
        description = f"{base_description} (on {device_names[0]})"

    schema = {"type": schema_type, "properties": properties}
    if required:
        schema["required"] = required
    return schema, description


def _build_tool_entry(skill_name: str, candidates: list[dict]) -> dict:
    tool_name = f"device_{skill_name}"
    parameters, description = _build_schema(skill_name, candidates)
    handler = _make_handler(skill_name, candidates)
    return {
        "name": tool_name,
        "toolset": "devices",
        "schema": {"name": tool_name, "description": description, "parameters": parameters},
        "handler": handler,
        "description": description,
    }


# ── registry rebuild ─────────────────────────────────────────────────────────

def _deregister_all_locked() -> None:
    for name in _registered_names:
        try:
            registry.deregister(name)
        except Exception:
            logger.debug("failed to deregister stale device tool %s", name, exc_info=True)
    _registered_names.clear()


def rebuild_device_tools() -> list[dict]:
    """Rebuild the native ``device_<skill>`` tools from the bridge registry.

    Safe to call any time (module import, device register/disconnect via
    ``device_bridge.on_registry_change``, or a test wanting a synchronous
    refresh). Never raises — falls back to an empty tool list.
    """
    try:
        from api import device_bridge
        flat = device_bridge.all_device_skills()
    except Exception:
        flat = []

    grouped: dict[str, list[dict]] = {}
    for entry in flat:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "").strip()
        if not name:
            continue
        grouped.setdefault(name, []).append({
            "device_id": entry.get("device_id"),
            "device_name": entry.get("device_name") or "device",
            "description": entry.get("description") or "",
            "input_schema": entry.get("input_schema"),
        })

    tools = [_build_tool_entry(name, cands) for name, cands in grouped.items()]

    with _LOCK:
        _deregister_all_locked()
        for t in tools:
            try:
                registry.register(
                    name=t["name"],
                    toolset=t["toolset"],
                    schema=t["schema"],
                    handler=t["handler"],
                    description=t["description"],
                    emoji="\U0001F4F1",  # 📱
                )
                _registered_names.add(t["name"])
            except Exception:
                logger.warning("failed to register device tool %s", t["name"], exc_info=True)
        _current_tools = tools
        globals()["_current_tools"] = tools

    return tools


def get_device_tools() -> list[dict]:
    """Current list of native device-skill tools.

    Each entry: ``{"name","toolset","schema","handler","description"}``.
    Rebuilt automatically on device register/disconnect; call
    ``rebuild_device_tools()`` directly for a synchronous refresh (e.g. right
    after pairing a device in a test, before any bridge event has fired).
    """
    with _LOCK:
        return list(_current_tools)


# Subscribe to bridge registry changes (register/disconnect) so the tool list
# always reflects currently-connected devices. device_bridge does NOT import
# this module — it only calls back into whatever subscribed via
# on_registry_change(), so there is no import cycle.
try:
    from api import device_bridge as _device_bridge

    _device_bridge.on_registry_change(rebuild_device_tools)
except Exception:
    logger.debug("device_bridge unavailable at import time; device tools start empty", exc_info=True)

# Build the initial snapshot so any devices already connected (or the module
# being reloaded) are reflected immediately rather than waiting for the next
# register/disconnect event.
rebuild_device_tools()
