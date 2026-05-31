"""look_at_screen — read-only screen awareness.

Captures the current screen and returns it as a multimodal image so a vision
model can see what the user is looking at ("help with this error", "what's on
my screen?"). Unlike `computer_use` this does NOT control the desktop — it only
looks. Backends: macOS `screencapture` (built-in), else `mss`, else PIL
ImageGrab. Registers itself with tools.registry on import.
"""
from __future__ import annotations

import base64
import logging
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

MAX_WIDTH = 1400  # downscale wide screenshots to keep vision token cost sane


def _region_flag(region: Optional[dict]):
    if not region:
        return None
    try:
        x, y = int(region["x"]), int(region["y"])
        w, h = int(region["width"]), int(region["height"])
        return f"{x},{y},{w},{h}"
    except Exception:
        return None


def _macos_capture(region: Optional[dict]) -> Optional[bytes]:
    if not shutil.which("screencapture"):
        return None
    with tempfile.NamedTemporaryFile(prefix="jc-screen-", suffix=".png", delete=False) as tmp:
        path = tmp.name
    try:
        cmd = ["screencapture", "-x", "-t", "png"]
        rf = _region_flag(region)
        if rf:
            cmd += ["-R", rf]
        cmd.append(path)
        r = subprocess.run(cmd, capture_output=True, timeout=15)
        if r.returncode != 0:
            return None
        data = Path(path).read_bytes()
        return data or None
    except Exception as e:
        logger.debug("macOS screencapture failed: %s", e)
        return None
    finally:
        try:
            Path(path).unlink(missing_ok=True)
        except Exception:
            pass


def _mss_capture(region: Optional[dict]) -> Optional[bytes]:
    try:
        import io
        import mss
        import mss.tools
        with mss.mss() as sct:
            if region:
                mon = {"left": int(region["x"]), "top": int(region["y"]),
                       "width": int(region["width"]), "height": int(region["height"])}
            else:
                mon = sct.monitors[0]
            shot = sct.grab(mon)
            return mss.tools.to_png(shot.rgb, shot.size)
    except Exception as e:
        logger.debug("mss capture failed: %s", e)
        return None


def _pil_capture(region: Optional[dict]) -> Optional[bytes]:
    try:
        import io
        from PIL import ImageGrab
        bbox = None
        if region:
            x, y = int(region["x"]), int(region["y"])
            bbox = (x, y, x + int(region["width"]), y + int(region["height"]))
        img = ImageGrab.grab(bbox=bbox)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return buf.getvalue()
    except Exception as e:
        logger.debug("PIL capture failed: %s", e)
        return None


def capture_png(region: Optional[dict] = None) -> Optional[bytes]:
    """Capture the screen (or a region) as PNG bytes, or None if unavailable."""
    if platform.system() == "Darwin":
        data = _macos_capture(region)
        if data:
            return _maybe_downscale(data)
    for fn in (_mss_capture, _pil_capture):
        data = fn(region)
        if data:
            return _maybe_downscale(data)
    return None


def _maybe_downscale(data: bytes) -> bytes:
    try:
        import io
        from PIL import Image
        img = Image.open(io.BytesIO(data))
        if img.width > MAX_WIDTH:
            ratio = MAX_WIDTH / img.width
            img = img.resize((MAX_WIDTH, max(1, int(img.height * ratio))))
            buf = io.BytesIO()
            img.convert("RGB").save(buf, format="PNG")
            return buf.getvalue()
    except Exception:
        pass
    return data


LOOK_AT_SCREEN_SCHEMA = {
    "name": "look_at_screen",
    "description": (
        "Capture the current screen and return it as an image so you can see what the "
        "user is looking at. Use when the user refers to 'this', 'my screen', an error or "
        "UI on screen, or asks for help with what they're viewing. Read-only — it does NOT "
        "click, type, or control the computer."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "region": {
                "type": "object",
                "description": "Optional region in pixels; omit for the full screen.",
                "properties": {
                    "x": {"type": "integer"}, "y": {"type": "integer"},
                    "width": {"type": "integer"}, "height": {"type": "integer"},
                },
            },
        },
    },
}


def handle_look_at_screen(args: Dict[str, Any], **kwargs) -> Any:
    region = args.get("region") if isinstance(args, dict) else None
    data = capture_png(region)
    if not data:
        return ("Screen capture unavailable. On macOS, grant Screen Recording permission "
                "to the terminal/app; on Linux/Windows, install 'mss' (pip install mss).")
    b64 = base64.b64encode(data).decode("ascii")
    return {
        "_multimodal": True,
        "content": [
            {"type": "text", "text": "Screenshot of the user's current screen:"},
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
        ],
        "text_summary": f"[screen capture — {len(data)} bytes png]",
    }


def check_look_at_screen() -> tuple[bool, str]:
    if platform.system() == "Darwin" and shutil.which("screencapture"):
        return True, ""
    try:
        import mss  # noqa: F401
        return True, ""
    except Exception:
        pass
    try:
        from PIL import ImageGrab  # noqa: F401
        return True, ""
    except Exception:
        pass
    return False, "no screen-capture backend (need macOS screencapture, mss, or Pillow)"


try:
    from tools.registry import registry

    registry.register(
        name="look_at_screen",
        toolset="screen",
        schema=LOOK_AT_SCREEN_SCHEMA,
        handler=lambda args, **kw: handle_look_at_screen(args, **kw),
        check_fn=check_look_at_screen,
        requires_env=[],
        emoji="🖥️",
        description=LOOK_AT_SCREEN_SCHEMA["description"],
    )
except Exception as e:  # registry not importable in some unit-test contexts
    logger.debug("look_at_screen registration skipped: %s", e)
