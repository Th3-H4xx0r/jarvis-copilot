"""The engines this server knows. A new engine is one module calling `register_engine`."""
from __future__ import annotations

import importlib
import logging
import threading
from typing import Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

_BUILTIN = ("jarvis_speech.engines.local", "jarvis_speech.engines.soniox")
_factories: Dict[str, Callable[[], object]] = {}
_instances: Dict[str, object] = {}
_lock = threading.Lock()
_builtin_loaded = False


def register_engine(name: str, factory: Callable[[], object]) -> None:
    with _lock:
        _factories[name] = factory
        _instances.pop(name, None)


def _ensure_builtin() -> None:
    global _builtin_loaded
    if _builtin_loaded:
        return
    _builtin_loaded = True
    for module in _BUILTIN:
        try:
            importlib.import_module(module)
        except Exception:
            logger.warning("speech: could not load engine module %s", module, exc_info=True)


def names() -> List[str]:
    """Registered engines, the current flow first (pickers list them in this order)."""
    _ensure_builtin()
    with _lock:
        return sorted(_factories, key=lambda name: name != "local")


def get(name: str) -> Optional[object]:
    _ensure_builtin()
    with _lock:
        if name in _instances:
            return _instances[name]
        factory = _factories.get(name)
    if factory is None:
        return None
    try:
        engine = factory()
    except Exception:
        logger.warning("speech: engine %s could not start", name, exc_info=True)
        return None
    with _lock:
        return _instances.setdefault(name, engine)


def engines() -> List[dict]:
    """Every engine with whether it can run now — what the settings pickers list."""
    rows = []
    for name in names():
        engine = get(name)
        if engine is None:
            rows.append({"name": name, "label": name, "streams": False,
                         "available": False, "reason": "could not start"})
            continue
        try:
            ok, reason = engine.available()
        except Exception as exc:
            ok, reason = False, f"error: {type(exc).__name__}"
        rows.append({"name": name, "label": getattr(engine, "label", name),
                     "streams": bool(getattr(engine, "streams", False)),
                     "available": bool(ok), "reason": "" if ok else str(reason or "")})
    return rows
