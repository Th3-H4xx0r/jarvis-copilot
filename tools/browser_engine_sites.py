"""Which sites need Chrome instead of Lightpanda.

Lightpanda is the fast default browser engine (no graphical renderer). A site
whose page broke on it — or a page known to need a real renderer — is remembered
here so later visits start on Chrome directly instead of paying for a failed
Lightpanda attempt first. Entries expire after two weeks (Lightpanda improves).

State: ``get_hermes_home()/browser/engine_sites.json`` →
``{"<host>": {"engine": "chrome", "reason": str, "ts": epoch_seconds}}``.
"""
from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

from jarviscopilot_constants import get_hermes_home

logger = logging.getLogger(__name__)

TTL_SECONDS = 14 * 86400
# Pages that render their content client-side in ways Lightpanda can't (yet).
SEED = ("google.com/travel", "google.com/flights")

_lock = threading.Lock()


def _path() -> Path:
    return get_hermes_home() / "browser" / "engine_sites.json"


def _host_and_path(url: str) -> tuple[str, str]:
    parsed = urlparse(url if "://" in str(url) else f"https://{url}")
    host = (parsed.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host, parsed.path or "/"


def _load() -> dict:
    try:
        data = json.loads(_path().read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def needs_chrome(url: str, now: Optional[float] = None) -> bool:
    host, path = _host_and_path(url)
    if not host:
        return False
    if any(f"{host}{path}".startswith(seed) for seed in SEED):
        return True
    entry = _load().get(host)
    if not isinstance(entry, dict):
        return False
    return (now if now is not None else time.time()) - float(entry.get("ts") or 0) < TTL_SECONDS


def remember_chrome(url: str, reason: str, now: Optional[float] = None) -> None:
    host, _ = _host_and_path(url)
    if not host:
        return
    with _lock:
        data = _load()
        data[host] = {"engine": "chrome", "reason": str(reason or "")[:200],
                      "ts": now if now is not None else time.time()}
        try:
            p = _path()
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, indent=1, sort_keys=True), encoding="utf-8")
            tmp.replace(p)
        except OSError:
            logger.debug("could not save browser engine sites", exc_info=True)
