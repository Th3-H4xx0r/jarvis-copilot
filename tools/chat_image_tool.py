"""chat_image — put one image in the chat, saved and checked.

The model hands it a web image (or a file on the server) plus what the picture
should show. It downloads/copies the image into the chat's media folder
(agent/chat_media.py), asks the cheap auxiliary vision model whether it really
shows that (a logo, banner or the wrong product is refused so the model picks
another), and returns ``show_with``: the exact line the reply puts right after
the text the image illustrates.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

from agent import chat_media
from agent.chat_media import ImageRejected, fetch_image, save_image_bytes
from gateway.session_context import get_session_env

logger = logging.getLogger(__name__)

_CHECK_PROMPT = (
    "Does this image clearly show: {expect}? Answer NO if it is a logo, banner, ad, "
    "mostly text, a placeholder, a collage, or shows something else. Reply with one "
    "line: MATCH, or NO: <short reason>."
)

CHAT_IMAGE_SCHEMA = {
    "name": "chat_image",
    "description": (
        "Show one image in the chat. Saves a web image (or a server file) into this "
        "chat, checks it shows `expect`, and returns show_with: put that line on its "
        "own right after the text it illustrates. If ok is false, try another image."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "source": {"type": "string", "description": "Image URL or absolute server path."},
            "caption": {"type": "string", "description": "Short caption."},
            "expect": {"type": "string", "description": "What the image must show."},
        },
        "required": ["source"],
    },
}


def _check_image(path: Path, expect: str) -> str:
    """'matches', 'mismatch: <why>', or 'unchecked: <why>' when the check can't run."""
    try:
        from agent.auxiliary_client import call_llm
        from tools.vision_tools import _image_to_base64_data_url

        resp = call_llm(
            task="vision",
            messages=[{"role": "user", "content": [
                {"type": "text", "text": _CHECK_PROMPT.format(expect=expect)},
                {"type": "image_url", "image_url": {"url": _image_to_base64_data_url(path)}},
            ]}],
            max_tokens=60,
            timeout=20,
        )
        text = resp if isinstance(resp, str) else resp.choices[0].message.content
        text = str(text or "").strip()
        line = text.splitlines()[0].strip() if text else ""
    except Exception as exc:
        logger.info("chat_image check unavailable: %s", exc)
        return f"unchecked: {exc.__class__.__name__}"
    upper = line.upper()
    if upper.startswith("MATCH"):
        return "matches"
    if upper.startswith("NO"):
        reason = line[2:].lstrip(" :-").strip() or "it doesn't show that"
        return f"mismatch: {reason}"
    return "unchecked: unclear answer from the checker"


def chat_image_tool(args: dict) -> str:
    source = str((args or {}).get("source") or "").strip()
    caption = " ".join(str((args or {}).get("caption") or "").split())[:120]
    expect = " ".join(str((args or {}).get("expect") or "").split())[:200]
    session_id = get_session_env("HERMES_SESSION_ID", "")
    if not session_id:
        return json.dumps({"ok": False, "error": "no chat session"})
    if not source:
        return json.dumps({"ok": False, "error": "source is required"})

    is_web = source.lower().startswith(("http://", "https://"))
    try:
        if is_web:
            data = fetch_image(source)
            hint = caption or source.split("?", 1)[0].rstrip("/").rsplit("/", 1)[-1]
        else:
            p = Path(source).expanduser()
            if not p.is_absolute() or not p.is_file():
                return json.dumps({"ok": False, "error": "no such file on the server"})
            if p.suffix.lower() not in chat_media._LOCAL_IMAGE_EXTS:
                return json.dumps({"ok": False, "error": "not an image file"})
            if p.stat().st_size > chat_media.MAX_BYTES:
                return json.dumps({"ok": False, "error": "image is larger than 15 MB"})
            data = p.read_bytes()
            hint = caption or p.stem
        saved = save_image_bytes(data, session_id, name_hint=hint, caption=caption,
                                 source=source, worker_session=session_id)
    except ImageRejected as exc:
        return json.dumps({"ok": False, "error": str(exc)})

    check = ""
    if expect or is_web:
        check = _check_image(saved.path, expect or caption or "a relevant photo")
        if check.startswith("mismatch"):
            saved.path.unlink(missing_ok=True)
            return json.dumps({"ok": False, "error": f"wrong image — {check[len('mismatch: '):]}"})

    path = str(saved.path)
    platform = get_session_env("HERMES_SESSION_PLATFORM", "")
    show_with = f"![{caption.replace(']', ')')}]({path})" if platform == "webui" else f"MEDIA:{path}"
    out = {"ok": True, "show_with": show_with, "caption": caption,
           "width": saved.width, "height": saved.height, "check": check}
    if check.startswith("unchecked"):
        out["note"] = "The image was not verified; don't say it matches."
    return json.dumps(out)


try:
    from tools.registry import registry

    registry.register(
        name="chat_image",
        toolset="chat_image",
        schema=CHAT_IMAGE_SCHEMA,
        handler=lambda args, **kw: chat_image_tool(args),
        check_fn=lambda: True,
        requires_env=[],
        emoji="🖼️",
        description=CHAT_IMAGE_SCHEMA["description"],
    )
except Exception as e:  # registry not importable in some unit-test contexts
    logger.debug("chat_image registration skipped: %s", e)
