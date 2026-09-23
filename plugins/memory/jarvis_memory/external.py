"""Writing to Jarvis's long-term memory from outside an agent turn.

Live (the ambient recorder) runs in the web server, not in an agent loop, so it
never reaches ``sync_turn``. This is its way into the SAME store, namespace and
embedder that a chat or voice turn recalls from — so "what did Brenda say about
the lesson?" finds an overheard conversation exactly the way it finds a chat.

Everything here is best-effort and never raises: a memory write must not cost
the recorder anything.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import List, Optional

from .config import load_config
from .embed import make_embedder
from .store import GLOBAL_NS, MemoryStore

logger = logging.getLogger(__name__)

_lock = threading.Lock()
# One store + embedder per HERMES_HOME for the life of the process: opening the
# database and reaching the embedder on every window would be the cost this
# module exists to avoid.
_handles: dict = {}


def _home(hermes_home: Optional[str]) -> str:
    if hermes_home:
        return str(hermes_home)
    from jarviscopilot_constants import get_hermes_home
    return str(get_hermes_home())


def is_active() -> bool:
    """Whether jarvis_memory is the memory agents recall from.

    Writing to a store nobody reads would only fill a disk, so callers check.
    """
    try:
        from jarviscopilot_cli.config import load_config as load_main
        memory = (load_main() or {}).get("memory") or {}
        return str(memory.get("provider") or "").strip() == "jarvis_memory"
    except Exception:
        return False


def _open(hermes_home: Optional[str] = None):
    home = _home(hermes_home)
    with _lock:
        handle = _handles.get(home)
        if handle is None:
            cfg = load_config(home)
            handle = (MemoryStore(cfg["db_path"], cfg["vault_dir"]), make_embedder(cfg),
                      cfg.get("namespace") or GLOBAL_NS,
                      float(cfg.get("dedup_threshold", 0.92)))
            _handles[home] = handle
        return handle


def remember(body: str, *, source: str, tags: str = "", created_at: Optional[float] = None,
             score: float = 1.0, dedup: bool = True,
             hermes_home: Optional[str] = None) -> Optional[str]:
    """Store one memory. Returns its id, or None when skipped or failed.

    ``source`` identifies where it came from and is what ``forget`` matches on;
    ``tags`` is a comma list (``live,conversation,speaker:<id>``); ``created_at``
    is WHEN it happened, not when it was stored. ``dedup`` skips a memory nearly
    identical to one already held, at the threshold chat capture uses.
    """
    body = (body or "").strip()
    if not body:
        return None
    try:
        store, embedder, namespace, threshold = _open(hermes_home)
        embedding = None
        try:
            embedding = embedder.embed_one(body)
        except Exception:
            # Keyword recall still finds it; only the vector half is missing.
            logger.debug("jarvis_memory: no embedding for %s", source, exc_info=True)
        if embedding is not None and not len(embedding):
            embedding = None
        if dedup and embedding is not None:
            hits = store.vector_search(namespace, embedding, embedder.signature, limit=1)
            if hits and hits[0][1] >= threshold:
                return None
        return store.add_chunk(
            namespace, body, source, created_at or time.time(), score, tags,
            embedding=embedding,
            signature=embedder.signature if embedding is not None else None,
            dim=embedder.dim if embedding is not None else None)
    except Exception:
        logger.warning("jarvis_memory: could not remember %s", source, exc_info=True)
        return None


def forget(*, source_prefix: str = "", tag: str = "",
           hermes_home: Optional[str] = None) -> int:
    """Delete every memory whose source starts with ``source_prefix`` or whose
    tags include ``tag``. Returns how many went.

    The other half of every Live delete path: a recording or a voice the user
    deleted must not live on in what Jarvis recalls.
    """
    if not source_prefix and not tag:
        return 0
    try:
        store, _embedder, namespace, _threshold = _open(hermes_home)
        ids: List[str] = []
        with store._lock:
            if source_prefix:
                escaped = (source_prefix.replace("\\", "\\\\")
                           .replace("%", "\\%").replace("_", "\\_"))
                ids += [row["id"] for row in store._conn.execute(
                    "SELECT id FROM chunks WHERE namespace=? AND source LIKE ? ESCAPE '\\'",
                    (namespace, escaped + "%"))]
            if tag:
                ids += [row["id"] for row in store._conn.execute(
                    "SELECT id FROM chunks WHERE namespace=? AND (',' || tags || ',') LIKE ?",
                    (namespace, f"%,{tag},%"))]
        return sum(1 for cid in dict.fromkeys(ids) if store.delete_chunk(cid))
    except Exception:
        logger.warning("jarvis_memory: could not forget %s%s", source_prefix, tag, exc_info=True)
        return 0
