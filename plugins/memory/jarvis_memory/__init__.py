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

    # -- setup / config (jarviscopilot memory setup) -------------------------
    def get_config_schema(self) -> List[Dict[str, Any]]:
        return [
            {"key": "embedder", "description": "Embedding backend",
             "default": "ollama", "choices": ["ollama", "fake"]},
            {"key": "ollama_model", "description": "Ollama embedding model",
             "default": "bge-m3", "when": {"embedder": "ollama"}},
            {"key": "embed_dim", "description": "Embedding dimensions",
             "default": "1024", "when": {"embedder": "ollama"}},
            {"key": "recall_limit", "description": "Max memories injected per turn",
             "default": "5"},
        ]

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        """Persist non-secret config to config.yaml under plugins.jarvis_memory
        (the location config.load_config reads)."""
        from pathlib import Path
        config_path = Path(hermes_home) / "config.yaml"
        try:
            import yaml
            existing = {}
            if config_path.exists():
                with open(config_path, encoding="utf-8-sig") as f:
                    existing = yaml.safe_load(f) or {}
            existing.setdefault("plugins", {})
            existing["plugins"]["jarvis_memory"] = values
            with open(config_path, "w", encoding="utf-8") as f:
                yaml.dump(existing, f, default_flow_style=False)
        except Exception as e:
            logger.warning("jarvis_memory save_config failed: %s", e)

    def post_setup(self, hermes_home: str, config: dict) -> None:
        """Called by `jarviscopilot memory setup` — provisions Ollama (install +
        start + pull bge-m3), saves config, and activates the provider."""
        print("\n  Setting up jarvis_memory (semantic long-term memory)…\n")
        extract_model = "llama3.2:3b"
        values = {"embedder": "ollama", "ollama_model": "bge-m3",
                  "embed_dim": 1024, "recall_limit": 5,
                  "extract": "ollama", "extract_model": extract_model}
        try:
            from .ollama_bootstrap import setup as ollama_setup, pull_model
            ok = ollama_setup(model="bge-m3", printer=lambda m: print(f"  {m}"))
            if ok:
                print("  ✓ Ollama ready (bge-m3 embeddings).")
                # Phase-2 fact extraction model (optional — degrades to raw capture).
                if pull_model(extract_model, printer=lambda m: print(f"  {m}")):
                    print(f"  ✓ Fact-extraction model ready ({extract_model}).")
                else:
                    print(f"  ⚠ Could not pull {extract_model}; memory will store raw turns "
                          "until it's available (or set extract: off).")
            else:
                print("  ⚠ Ollama not fully provisioned — recall will run keyword-only\n"
                      "    until Ollama + bge-m3 are available (or set embedder: fake).")
        except Exception as e:
            print(f"  ⚠ Ollama setup error: {e} — continuing with keyword-only recall.")
        self.save_config(values, hermes_home)
        # Activate this provider in config.yaml.
        try:
            import yaml
            from pathlib import Path
            cfgp = Path(hermes_home) / "config.yaml"
            existing = {}
            if cfgp.exists():
                with open(cfgp, encoding="utf-8-sig") as f:
                    existing = yaml.safe_load(f) or {}
            existing.setdefault("memory", {})["provider"] = "jarvis_memory"
            with open(cfgp, "w", encoding="utf-8") as f:
                yaml.dump(existing, f, default_flow_style=False)
            print("\n  ✓ jarvis_memory activated. Turns are captured automatically and\n"
                  "    searchable in the webui 'Long-term Memory' panel.\n")
        except Exception as e:
            logger.warning("jarvis_memory activation failed: %s", e)

    def initialize(self, session_id: str, **kwargs) -> None:
        self._session_id = session_id
        hermes_home = kwargs.get("hermes_home") or "."
        cfg = load_config(hermes_home)
        cfg.update(kwargs.get("_config_override") or {})  # test hook
        self._cfg = cfg
        ns = cfg.get("namespace") or GLOBAL_NS
        user_id = kwargs.get("user_id")
        if user_id and ns == GLOBAL_NS:
            # Gateway multi-user: scope by user so turns don't bleed across users.
            ns = f"user:{user_id}"
        self._namespace = ns
        roles = cfg.get("capture_roles") or ["user"]
        self._capture_roles = tuple(r for r in roles if r in ("user", "assistant")) or ("user",)
        self._store = MemoryStore(cfg["db_path"], cfg["vault_dir"])
        self._embedder = make_embedder(cfg)
        from .extract import make_extractor
        self._extractor = make_extractor(cfg)  # None => Phase-1 raw capture
        self._dedup_threshold = float(cfg.get("dedup_threshold", 0.92))
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="jarvis-mem")
        self._pending: list = []
        self._lock = threading.Lock()
        self._prefetch_lock = threading.Lock()
        self._prefetch_cache = ""
        # Auto-start a local Ollama server (background, best-effort) so the
        # default embedder works without manual setup. Never installs/pulls at
        # runtime — that happens once in post_setup.
        if (cfg.get("embedder") or "ollama").lower() == "ollama" and cfg.get("ollama_autostart", True):
            self._pool.submit(self._ensure_ollama)
        # Proactive reflections: a periodic background tick (default on when
        # extraction is on). Observation-only; skips on battery / when offline.
        self._proactive_stop = threading.Event()
        proactive = cfg.get("proactive")
        if proactive is None:
            proactive = self._extractor is not None
        if proactive and str(proactive).lower() not in ("off", "false", "0"):
            interval = max(5, int(cfg.get("proactive_interval_min", 30))) * 60
            t = threading.Thread(target=self._proactive_loop, args=(hermes_home, interval),
                                 daemon=True, name="jarvis-mem-reflect")
            t.start()
        # Auto-fetch: ingest configured external sources (folders, later MCP/email)
        # into memory on a schedule. Only runs if sources are configured.
        self._autofetch = None
        try:
            from .autofetch import AutoFetchScheduler, build_sources
            sources = build_sources(cfg)
            if sources:
                self._autofetch = AutoFetchScheduler(sources, self._store, self._embedder, self._namespace)
                self._pool.submit(self._autofetch_safe)  # initial pass (pick up existing files)
                af_interval = max(5, int(cfg.get("autofetch_interval_min", 20))) * 60
                threading.Thread(target=self._autofetch_loop, args=(af_interval,),
                                 daemon=True, name="jarvis-mem-autofetch").start()
        except Exception as e:
            logger.debug("jarvis_memory autofetch setup skipped: %s", e)

    def _autofetch_safe(self):
        try:
            if self._autofetch:
                self._autofetch.run_once()
        except Exception as e:
            logger.debug("jarvis_memory autofetch run failed: %s", e)

    def _autofetch_loop(self, interval: int):
        while not self._proactive_stop.wait(interval):
            if self._on_battery():
                continue
            self._autofetch_safe()

    @staticmethod
    def _on_battery() -> bool:
        try:
            import psutil
            b = psutil.sensors_battery()
            return bool(b) and not b.power_plugged
        except Exception:
            return False

    def _proactive_loop(self, hermes_home: str, interval: int):
        import time as _t
        from .proactive import run_tick
        while not self._proactive_stop.wait(interval):  # wait first -> no tick at startup
            try:
                if self._on_battery():
                    continue
                run_tick(hermes_home, _t.time())
            except Exception as e:
                logger.debug("jarvis_memory proactive tick failed: %s", e)

    def _ensure_ollama(self):
        try:
            from .ollama_bootstrap import ensure_running
            ensure_running(self._cfg.get("ollama_url", "http://localhost:11434"))
        except Exception as e:
            logger.debug("jarvis_memory ollama autostart skipped: %s", e)

    # -- capture --------------------------------------------------------------
    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "") -> None:
        if not (user_content or assistant_content):
            return
        fut = self._pool.submit(self._ingest_safe, user_content, assistant_content)
        with self._lock:
            self._pending = [f for f in self._pending if not f.done()]  # prune
            self._pending.append(fut)

    def _ingest_safe(self, user_content: str, assistant_content: str):
        try:
            if self._extractor is not None:
                try:
                    facts = self._extractor.extract(user_content, assistant_content)
                except Exception as e:
                    logger.warning("jarvis_memory extraction unavailable; raw-capture fallback: %s", e)
                    return ingest_turn(self._store, self._embedder, self._namespace,
                                       user_content, assistant_content, source="chat",
                                       roles=self._capture_roles)
                return self._store_facts(facts)  # extraction ran (possibly []): store distilled facts only
            return ingest_turn(self._store, self._embedder, self._namespace,
                               user_content, assistant_content, source="chat",
                               roles=self._capture_roles)
        except Exception as e:
            logger.warning("jarvis_memory ingest failed: %s", e)
            return []

    def _store_facts(self, facts):
        """Store distilled facts, skipping near-duplicates (vector dedup)."""
        ids = []
        for fact in facts or []:
            fact = (fact or "").strip()
            if not fact:
                continue
            emb = None
            try:
                emb = self._embedder.embed_one(fact)
            except Exception:
                pass
            if emb:
                try:
                    hits = self._store.vector_search(self._namespace, emb, self._embedder.signature, limit=1)
                    if hits and hits[0][1] >= self._dedup_threshold:
                        continue  # already remembered
                except Exception:
                    pass
            use_emb = emb if (emb and len(emb)) else None
            ids.append(self._store.add_chunk(
                self._namespace, fact, "fact:extracted", time.time(), 1.0, "fact",
                embedding=use_emb, signature=self._embedder.signature if use_emb else None,
                dim=self._embedder.dim if use_emb else None,
            ))
        return ids

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
    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        """Warm recall in the background after a turn so prefetch() stays off the
        turn-start hot path (the embed is a network call — see bug-sweep M1)."""
        if not query or not query.strip():
            return
        fut = self._pool.submit(self._warm_prefetch, query)
        with self._lock:
            self._pending = [f for f in self._pending if not f.done()]
            self._pending.append(fut)

    def _warm_prefetch(self, query: str):
        try:
            hits = hybrid_recall(
                self._store, self._embedder, query, self._namespace,
                limit=int(self._cfg.get("recall_limit", 5)),
                min_relevance=float(self._cfg.get("min_relevance", 0.0)),
            )
            block = format_recall_block(hits, int(self._cfg.get("max_context_chars", 2000)))
        except Exception as e:
            logger.warning("jarvis_memory prefetch warm failed: %s", e)
            block = ""
        with self._prefetch_lock:
            self._prefetch_cache = block

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        # Return the block warmed by the previous turn's queue_prefetch — never a
        # synchronous network embed on the hot path. (The model can still call
        # the memory_recall tool for an explicit current-query lookup.)
        with self._prefetch_lock:
            block = self._prefetch_cache
            self._prefetch_cache = ""
        return block

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
                                     self._namespace, limit=int(args.get("limit", 5)),
                                     min_relevance=float(self._cfg.get("min_relevance", 0.0)))
                return json.dumps({"ok": True, "results": [
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
                except Exception as e:
                    logger.warning("jarvis_memory memory_store embed failed (storing without vector): %s", e)
                use_emb = emb if (emb and len(emb)) else None
                cid = self._store.add_chunk(
                    self._namespace, content, "tool:memory_store", time.time(), 1.0, "fact",
                    embedding=use_emb, signature=self._embedder.signature if use_emb else None,
                    dim=self._embedder.dim if use_emb else None,
                )
                return json.dumps({"ok": True, "id": cid})
            if tool_name == "memory_forget":
                ok = self._store.delete_chunk(args.get("id", ""))
                return json.dumps({"ok": True, "deleted": bool(ok)})
        except Exception as e:
            return json.dumps({"ok": False, "error": str(e)})
        return json.dumps({"ok": False, "error": f"unknown tool {tool_name}"})

    def shutdown(self) -> None:
        try:
            if getattr(self, "_proactive_stop", None) is not None:
                self._proactive_stop.set()
            self._flush()
            self._pool.shutdown(wait=True)
            self._store.close()
        except Exception:
            pass


def register(ctx) -> None:
    """Plugin entry point — called by the plugins.memory loader."""
    ctx.register_memory_provider(JarvisMemoryProvider())
