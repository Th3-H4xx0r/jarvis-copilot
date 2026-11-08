"""The native voice panel: the phone's own voice stack, built for macOS by ``mac_app/build.sh``,
loaded out of a dylib. ``voice_popup`` shows it; ``status`` and ``update`` say whether it works.
"""
from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# `None` is a real answer here ("looked, not there"), so the not-yet-looked state
# needs a value of its own.
_UNSET = object()
_panel_class = _UNSET
# Why the last look failed, for `voice_panel_health` to report. Kept because the
# fallback is silent by design: the user gets the web panel either way, so the
# only way "the native panel is not running" ever reaches them is if something
# asks.
_panel_error: Optional[str] = None


def _voice_panel_class():
    """The Swift panel's class, or None when the dylib isn't there.

    ``ctypes.CDLL`` is the whole load: a dylib registers its ``@objc`` classes
    with the Obj-C runtime as it loads, so the class is then reachable by name.
    Cached because dlopen is idempotent but the lookup is not free.
    """
    global _panel_class, _panel_error
    if _panel_class is not _UNSET:
        return _panel_class
    _panel_class = None
    # Checked before anything is imported, so "never built" is answered the same
    # way on a machine without PyObjC as on one with it.
    dylib = _dylib_path()
    if not dylib.exists():
        _panel_error = f"{dylib.name} is not in this checkout — run mac_app/build.sh"
        logger.info("voice panel: no %s — run mac_app/build.sh; using the web panel",
                    dylib.name)
        return None
    try:
        import ctypes

        import objc

        ctypes.CDLL(str(dylib))
        cls = objc.lookUpClass("JarvisVoicePanel")
    except Exception as exc:
        # Typically PyObjC missing, or a dylib built for another architecture —
        # ctypes says which, and it is the whole diagnosis, so keep the text.
        _panel_error = str(exc)
        logger.info("voice panel: native panel unavailable (%s); using the web panel", exc)
        return None
    # A missing shader draws an empty rectangle where the orb should be and
    # reports nothing, so say it here rather than leave it to be noticed.
    try:
        if not cls.orbShaderAvailable():
            logger.warning("voice panel: the orb's shader bundle is missing "
                           "next to the dylib — re-run mac_app/build.sh")
    except Exception:
        pass
    _panel_class = cls
    return cls


def _dylib_path() -> Path:
    return Path(__file__).with_name("assets") / "libJarvisVoiceUI.dylib"


def voice_panel_health() -> tuple[bool, str]:
    """Is the native voice panel usable on this machine? (ok, one line to print)

    `jc-client status` and `jc-client update` both show this. Worth surfacing
    because every failure here is a SILENT downgrade to the web panel: voice
    still works, so nothing complains, and the only symptom is that the Mac
    stopped looking like the phone.
    """
    if sys.platform != "darwin":
        return False, "n/a (macOS only)"
    dylib = _dylib_path()
    if not dylib.exists():
        return False, f"web panel — {dylib.name} is missing (run mac_app/build.sh)"
    if _voice_panel_class() is None:
        return False, f"web panel — {dylib.name} would not load: {_panel_error}"
    try:
        if not _panel_class.orbShaderAvailable():
            return True, ("native panel, but the orb has no shader "
                          "(re-run mac_app/build.sh)")
    except Exception:  # pragma: no cover - an older dylib without the check
        pass
    return True, "native panel"
