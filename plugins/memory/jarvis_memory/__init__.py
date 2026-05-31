"""jarvis_memory — semantic long-term memory provider (Phase 1 foundation).

Automatic per-turn capture + hybrid (vector + keyword) recall, backed by SQLite
+ a markdown vault, with a pluggable embedder (Ollama bge-m3 default). Foundation
for the full memory tree (docs/superpowers/specs/2026-05-30-memory-tree-design.md).
"""
from __future__ import annotations

import json
import logging
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List

from agent.memory_provider import MemoryProvider

from .config import load_config
from .embed import make_embedder
from .ingest import ingest_turn
from .recall import format_recall_block, hybrid_recall
from .store import GLOBAL_NS, MemoryStore

logger = logging.getLogger(__name__)

_RECALL_SCHEMA = {
    "name": "memory_recall",
    "description": (
        "Search your long-term memory for relevant facts, decisions, people, "
        "projects, or prior context. Call this before answering questions about "
        "the user or anything discussed in earlier sessions."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "What to recall."},
            "limit": {"type": "integer", "description": "Max results (default 5)."},
        },
        "required": ["query"],
    },
}
_STORE_SCHEMA = {
    "name": "memory_store",
    "description": (
        "Save a durable fact to long-term memory (a preference, decision, or fact "
        "about the user/project). Write one declarative sentence."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "content": {"type": "string", "description": "The fact to remember."},
        },
        "required": ["content"],
    },
}
_FORGET_SCHEMA = {
    "name": "memory_forget",
    "description": "Delete a memory item by its id (from a prior memory_recall result).",
    "parameters": {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "The chunk id to delete."},
        },
        "required": ["id"],
    },
}


class JarvisMemoryProvider(MemoryProvider):
    @property
    def name(self) -> str:
        return "jarvis_memory"

    def is_available(self) -> bool:
        try:
            import numpy  # noqa: F401
            return True
        except Exception:
            return False

    def initialize(self, session_id: str, **kwargs) -> None:
        self._session_id = session_id
        hermes_home = kwargs.get("hermes_home") or "."
        cfg = load_config(hermes_home)
        cfg.update(kwargs.get("_config_override") or {})  # test hook
        self._cfg = cfg
        self._namespace = cfg.get("namespace") or GLOBAL_NS
        self._store = MemoryStore(cfg["db_path"], cfg["vault_dir"])
        self._embedder = make_embedder(cfg)
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="jarvis-mem")
        self._pending: list = []
        self._lock = threading.Lock()

    # -- capture --------------------------------------------------------------
    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "") -> None:
        if not (user_content or assistant_content):
            return
        fut = self._pool.submit(self._ingest_safe, user_content, assistant_content)
        with self._lock:
            self._pending.append(fut)

    def _ingest_safe(self, user_content: str, assistant_content: str):
        try:
            return ingest_turn(self._store, self._embedder, self._namespace,
                               user_content, assistant_content, source="chat")
        except Exception as e:
            logger.warning("jarvis_memory ingest failed: %s", e)
            return []

    def _flush(self):
        """Drain pending background ingests (used by tests and shutdown)."""
        with self._lock:
            pending = list(self._pending)
            self._pending.clear()
        for f in pending:
            try:
                f.result(timeout=30)
            except Exception:
                pass

    # -- recall ---------------------------------------------------------------
    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if not query:
            return ""
        try:
            hits = hybrid_recall(
                self._store, self._embedder, query, self._namespace,
                limit=int(self._cfg.get("recall_limit", 5)),
                min_relevance=float(self._cfg.get("min_relevance", 0.0)),
            )
            return format_recall_block(hits, int(self._cfg.get("max_context_chars", 2000)))
        except Exception as e:
            logger.warning("jarvis_memory prefetch failed: %s", e)
            return ""

    def system_prompt_block(self) -> str:
        try:
            n = self._store.count_chunks(self._namespace)
        except Exception:
            n = 0
        if not n:
            return ""
        return (
            f"# Long-term memory (jarvis_memory) — {n} items stored.\n"
            "Call `memory_recall` before answering questions about the user, "
            "people, projects, or prior decisions.\n"
        )

    # -- tools ----------------------------------------------------------------
    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        return [_RECALL_SCHEMA, _STORE_SCHEMA, _FORGET_SCHEMA]

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        try:
            if tool_name == "memory_recall":
                hits = hybrid_recall(self._store, self._embedder, args.get("query", ""),
                                     self._namespace, limit=int(args.get("limit", 5)))
                return json.dumps({"results": [
                    {"id": h.chunk.id, "body": h.chunk.body, "score": round(h.score, 4)}
                    for h in hits
                ]})
            if tool_name == "memory_store":
                content = (args.get("content") or "").strip()
                if not content:
                    return json.dumps({"ok": False, "error": "empty content"})
                emb = None
                try:
                    emb = self._embedder.embed_one(content)
                except Exception:
                    pass
                cid = self._store.add_chunk(
                    self._namespace, content, "tool:memory_store", time.time(), 1.0, "fact",
                    embedding=emb, signature=self._embedder.signature if emb else None,
                    dim=self._embedder.dim if emb else None,
                )
                return json.dumps({"ok": True, "id": cid})
            if tool_name == "memory_forget":
                ok = self._store.delete_chunk(args.get("id", ""))
                return json.dumps({"deleted": bool(ok)})
        except Exception as e:
            return json.dumps({"ok": False, "error": str(e)})
        return json.dumps({"ok": False, "error": f"unknown tool {tool_name}"})

    def shutdown(self) -> None:
        try:
            self._flush()
            self._pool.shutdown(wait=True)
            self._store.close()
        except Exception:
            pass


def register(ctx) -> None:
    """Plugin entry point — called by the plugins.memory loader."""
    ctx.register_memory_provider(JarvisMemoryProvider())
