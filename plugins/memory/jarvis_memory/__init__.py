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
from .mem_log import install_handler, log_event
from .recall import parse_when
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
            "query": {"type": "string", "description": (
                "What to recall. May be empty when filtering: you then get the "
                "matching memories in time order.")},
            "limit": {"type": "integer", "description": "Max results (default 5)."},
            "source": {"type": "string", "description": (
                "Only memories from 'imessage' (his text chats) or 'live' "
                "(overheard conversations).")},
            "person": {"type": "string", "description": (
                "Only conversations with this person (name or number) — use with "
                "since/until to look up what was said with someone on a day.")},
            "since": {"type": "string", "description": "ISO date or datetime, his local time."},
            "until": {"type": "string", "description": (
                "ISO date or datetime, his local time; a bare date includes that whole day.")},
            "entity": {"type": "string", "description": (
                "Only memories linked to this person, place or event (e.g. 'COTA', 'Arnav').")},
            "when": {"type": "string", "description": (
                "Plain-words time: 'this weekend', 'last Tuesday', 'Oct 24' — matches when "
                "things happen, not just when they were said.")},
        },
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
        """Called by `jarviscopilot memory setup` — provisions Ollama embeddings,
        lets the user choose the fact-extraction model, saves config, activates."""
        print("\n  Setting up jarvis_memory (semantic long-term memory)…\n")
        pull_model = None
        try:
            from .ollama_bootstrap import setup as ollama_setup, pull_model as _pull
            pull_model = _pull
            if ollama_setup(model="bge-m3", printer=lambda m: print(f"  {m}")):
                print("  ✓ Ollama ready (bge-m3 embeddings).")
            else:
                print("  ⚠ Ollama not fully provisioned — recall will run keyword-only.")
        except Exception as e:
            print(f"  ⚠ Ollama setup error: {e} — continuing with keyword-only recall.")

        def _ask(prompt, default=""):
            try:
                v = input(f"  {prompt}: ").strip()
                return v or default
            except Exception:
                return default

        print("\n  How should conversations be distilled into memory facts?")
        print("    1) Your main model — best quality (e.g. gpt-5.5)   [recommended]")
        print("    2) A specific model id")
        print("    3) Local model via Ollama (private/offline)")
        print("    4) Off — capture raw user turns only")
        choice = _ask("Choose [1]", "1")

        values = {"embedder": "ollama", "ollama_model": "bge-m3",
                  "embed_dim": 1024, "recall_limit": 5}
        if choice == "2":
            mid = _ask("Model id (e.g. gpt-5.5, gpt-4o, claude-...)", "")
            values["extract"] = "model"
            values["extract_model"] = mid
            print(f"  ✓ Extraction via configured model: {mid or 'auto (main model)'}")
        elif choice == "3":
            mid = _ask("Ollama model", "llama3.2:3b") or "llama3.2:3b"
            values["extract"] = "ollama"
            values["extract_ollama_model"] = mid
            if pull_model and pull_model(mid, printer=lambda m: print(f"  {m}")):
                print(f"  ✓ Local extraction model ready ({mid}).")
            else:
                print(f"  ⚠ Could not pull {mid}; run 'ollama pull {mid}' manually.")
        elif choice == "4":
            values["extract"] = "off"
            print("  ✓ Extraction off — capturing user turns (trivial-filtered).")
        else:
            values["extract"] = "model"
            values["extract_model"] = ""
            print("  ✓ Extraction via your main model (auto-detected).")

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
        install_handler()  # memory-only log ring for the webui panel (idempotent)
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
        self._extract_fallback_raw = bool(cfg.get("extract_fallback_raw", False))
        self._migrate_builtin = bool(cfg.get("migrate_builtin", True))
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="jarvis-mem")
        self._pending: list = []
        self._lock = threading.Lock()
        self._recent: list = []
        self._now = time.time
        self._entity_index = None
        # Auto-start a local Ollama server (background, best-effort) so the
        # default embedder works without manual setup. Never installs/pulls at
        # runtime — that happens once in post_setup.
        if (cfg.get("embedder") or "ollama").lower() == "ollama" and cfg.get("ollama_autostart", True):
            self._pool.submit(self._ensure_ollama)
        self._pool.submit(self._warm)
        # One-time migration of the builtin MEMORY.md/USER.md into this store
        # (queued after ensure_ollama so embeddings are available).
        if self._migrate_builtin:
            self._pool.submit(self._migrate_safe, hermes_home)
        # One-time cleanup of clearly-transient extracted memories (endpoints/
        # ports/health-checks/fragments) created before the transient filter.
        if cfg.get("sweep_transient", True):
            self._pool.submit(self._sweep_transient_once)
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
        # Map pass: a background loop gives new memories their dates, people,
        # places and roles. One per database, on the process-wide store handle
        # (an agent's own store closes when the agent goes away).
        enrich = cfg.get("map_enrich")
        if enrich is None:
            enrich = (cfg.get("embedder") or "ollama").lower() != "fake"
        if enrich and str(enrich).lower() not in ("off", "false", "0"):
            try:
                from . import external
                from .enrich import start_loop
                store, embedder, _ns, _th = external._open(hermes_home)
                start_loop(store, embedder, interval=float(cfg.get("map_interval_sec", 30)))
                from . import brief
                brief.start(store, self._namespace)
            except Exception as e:
                logger.warning("jarvis_memory map loop / brief not started: %s", e)
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
                    # Only feed the assistant's turn to extraction when assistant
                    # capture is enabled — otherwise the model distills the agent's
                    # transient operational narration ("server stopped", "form
                    # loads") into junk "facts". Default is user-only.
                    asst_for_extract = assistant_content if "assistant" in self._capture_roles else ""
                    facts = self._extractor.extract(user_content, asst_for_extract)
                except Exception as e:
                    # Extraction enabled but failed. By default DON'T store the
                    # raw user turn (that's the "raw chat in memory" noise) —
                    # skip it. Set extract_fallback_raw=true to capture raw.
                    if self._extract_fallback_raw:
                        logger.warning("jarvis_memory extraction unavailable; raw-capture fallback: %s", e)
                        return ingest_turn(self._store, self._embedder, self._namespace,
                                           user_content, assistant_content, source="chat",
                                           roles=self._capture_roles)
                    logger.warning("jarvis_memory extraction unavailable; skipping turn (no raw capture): %s", e)
                    log_event("skipped a turn — extraction model unavailable")
                    return []
                return self._store_facts(facts)  # extraction ran (possibly []): store distilled facts only
            return ingest_turn(self._store, self._embedder, self._namespace,
                               user_content, assistant_content, source="chat",
                               roles=self._capture_roles)
        except Exception as e:
            logger.warning("jarvis_memory ingest failed: %s", e)
            return []

    def _store_fact(self, content, source="fact:extracted", tag="fact"):
        """Store one fact, skipping near-duplicates (vector dedup). Returns id or None."""
        content = (content or "").strip()
        if not content:
            return None
        emb = None
        try:
            emb = self._embedder.embed_one(content)
        except Exception:
            pass
        if emb:
            try:
                hits = self._store.vector_search(self._namespace, emb, self._embedder.signature, limit=1)
                if hits and hits[0][1] >= self._dedup_threshold:
                    # Already remembered: this source now backs it too.
                    self._store.merge_source(hits[0][0], source, tag)
                    return None
            except Exception:
                pass
        use_emb = emb if (emb and len(emb)) else None
        return self._store.add_chunk(
            self._namespace, content, source, time.time(), 1.0, tag,
            embedding=use_emb, signature=self._embedder.signature if use_emb else None,
            dim=self._embedder.dim if use_emb else None,
        )

    def _store_facts(self, facts):
        from .extract import is_transient_fact
        ids = []
        for fact in facts or []:
            if is_transient_fact(fact):  # drop endpoints/ports/health-checks/fragments
                continue
            cid = self._store_fact(fact, source="fact:extracted", tag="fact")
            if cid:
                ids.append(cid)
        if ids:
            log_event("captured %d fact(s): %s", len(ids), facts[0][:80] if facts else "")
        return ids

    def _migrate_safe(self, hermes_home: str):
        """One-time import of the builtin MEMORY.md/USER.md entries (incl. any
        self-learning lessons already saved there) into the semantic store."""
        try:
            if self._store.kv_get("__migrate__", "builtin_done"):
                return
            from .migrate import read_builtin_entries
            n = 0
            for content, source in read_builtin_entries(hermes_home):
                if self._store_fact(content, source=source, tag="builtin"):
                    n += 1
            self._store.kv_set("__migrate__", "builtin_done", "1")
            if n:
                logger.info("jarvis_memory: migrated %d builtin memory entr(ies) into the store", n)
        except Exception as e:
            logger.debug("jarvis_memory builtin migration skipped: %s", e)

    def _sweep_transient_once(self):
        """Remove already-stored extracted memories that are clearly transient
        (endpoints/ports/health-checks/fragments). One-time, kv-flagged."""
        try:
            if self._store.kv_get("__sweep__", "transient_done"):
                return
            from .extract import is_transient_fact
            removed = 0
            for ch in self._store.recent_chunks(self._namespace, 2000):
                if ch.source == "fact:extracted" and is_transient_fact(ch.body):
                    if self._store.delete_chunk(ch.id):
                        removed += 1
            self._store.kv_set("__sweep__", "transient_done", "1")
            if removed:
                logger.info("jarvis_memory: swept %d transient extracted memor(ies)", removed)
        except Exception as e:
            logger.debug("jarvis_memory transient sweep skipped: %s", e)

    def on_memory_write(self, action, target, content, metadata=None):
        """Mirror builtin MEMORY.md/USER.md writes — including self-learning
        lessons saved via memory(action='add', target='memory') — into the
        semantic store so they're recallable here too."""
        if action not in ("add", "replace"):
            return
        source = "builtin:user" if target == "user" else "builtin:memory"
        origin = (metadata or {}).get("write_origin")
        tag = "lesson" if origin in ("retrospective", "background_review") else "builtin"
        try:
            if self._store_fact(content, source=source, tag=tag):
                log_event("mirrored a builtin %s write (%s)", target, tag)
        except Exception as e:
            logger.debug("jarvis_memory on_memory_write failed: %s", e)

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
    def on_turn_start(self, turn_number: int, message: str, **kwargs) -> None:
        recent = kwargs.get("recent_messages")
        if isinstance(recent, list):
            self._recent = [m for m in recent if isinstance(m, dict)]

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        """Keep the next turn's recall fast: the embedder loaded and the
        entity index current. The recall itself runs on the turn's own words."""
        fut = self._pool.submit(self._warm)
        with self._lock:
            self._pending = [f for f in self._pending if not f.done()]
            self._pending.append(fut)

    def _warm(self):
        try:
            self._embedder.embed_one("warm")
            self._entities().refresh()
        except Exception as e:
            logger.debug("jarvis_memory warm-up failed: %s", e)

    def _recall_context(self) -> str:
        """What the recent turns add to a short follow-up ("parking there?"):
        the previous user message and the names in Jarvis's last reply."""
        recent = getattr(self, "_recent", None) or []
        from .textq import strip_injected
        last_user = strip_injected(next((m.get("content") for m in reversed(recent)
                                         if m.get("role") == "user" and m.get("content")), ""))
        last_reply = next((m.get("content") for m in reversed(recent)
                           if m.get("role") == "assistant" and m.get("content")), "")
        names = []
        if last_reply:
            try:
                names = [m[1] for m in self._entities().match(str(last_reply))]
            except Exception:
                names = []
        return " ".join([str(last_user)[:600]] + names).strip()

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        """The brief of what's going on now + memories for THIS message.

        Computed on the turn's own words every time (it used to return a block
        warmed on the previous message, so a first turn got nothing)."""
        from . import tz
        from .recall import RecallQuery, recall
        from .textq import strip_injected

        query = strip_injected(query)  # voice / board rules aren't what he asked
        t0 = time.perf_counter()
        brief_text = ""
        try:
            from . import brief as _brief
            brief_text = _brief.current_text(self._namespace)
        except Exception:
            brief_text = ""
        block = ""
        trace = {}
        if (query or "").strip():
            try:
                res = recall(
                    self._store, self._embedder,
                    RecallQuery(text=query, context=self._recall_context(), now=self._now(),
                                zone=tz.user_zone(),
                                limit=int(self._cfg.get("recall_limit", 6)),
                                budget_chars=int(self._cfg.get("max_context_chars", 2400)),
                                embed_timeout=1.5),
                    entity_index=self._entities(), namespace=self._namespace)
                block, trace = res.block, res.trace
                block += self._resolve_vague(query, brief_text, res.hits, trace)
            except Exception as e:
                logger.warning("jarvis_memory prefetch recall failed: %s", e)
        out = (brief_text + "\n\n" if brief_text else "") + block
        ms = round((time.perf_counter() - t0) * 1000, 1)
        trace["total_ms"] = ms
        logger.info("jarvis_memory prefetch %.0f ms, %d hits", ms, len(trace.get("hits", [])))
        try:
            self._store.add_trace(session_id or getattr(self, "_session_id", ""), query, out, trace)
        except Exception as e:
            logger.debug("jarvis_memory trace write failed: %s", e)
        return out

    def _resolve_vague(self, query: str, brief_text: str, hits, trace: dict) -> str:
        """Only when nothing named what "the venue" / "him" means: one quick
        memory-model call (≤ ~1 s) — act if it's clear, ask if not."""
        from . import vague
        context = self._recall_context()
        phrase = vague.needs_resolution(query, brief_text, context, hits)
        if not phrase:
            return ""
        res = vague.resolve(phrase, query, brief_text, context, hits,
                            timeout_s=float(self._cfg.get("vague_timeout_sec", 1.2)))
        trace["vague"] = {"phrase": phrase, "resolved": bool(res)}
        if res is None:
            return ""
        lines = [vague.note(phrase, res)]
        shown = {h.chunk.id for h in hits}
        for c in self._store.get_chunks([i for i in res.memory_ids if i not in shown]):
            lines.append(f"- {' '.join(c.body.split())}")
        return "\n".join(lines) + "\n\n"

    def system_prompt_block(self) -> str:
        try:
            n = self._store.count_chunks(self._namespace)
        except Exception:
            n = 0
        if not n:
            return ""
        # No item count: it changed with every saved memory, and this block is
        # part of the prompt every agent sends (and the provider caches).
        return (
            "# Long-term memory (jarvis_memory)\n"
            "Call `memory_recall` before answering questions about the user, "
            "people, projects, or prior decisions.\n"
        )

    # -- tools ----------------------------------------------------------------
    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        return [_RECALL_SCHEMA, _STORE_SCHEMA, _FORGET_SCHEMA]

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        try:
            if tool_name == "memory_recall":
                return json.dumps({"ok": True, "results": self._recall_tool(args)})
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

    def _recall_tool(self, args: Dict[str, Any]) -> List[Dict[str, Any]]:
        """memory_recall: the same multi-channel recall a turn gets, optionally
        inside a source / person / entity / time window. Filters with no query
        list the window in time order — the "what did Sam and I talk about
        yesterday" path, which ranking by similarity to an empty query could
        not answer."""
        from datetime import datetime

        from . import tz
        from .recall import RecallQuery, recall
        from .timeparse import window as time_window

        query = str(args.get("query") or "")
        limit = max(1, int(args.get("limit") or 5))
        source = str(args.get("source") or "").strip().lower()
        person = str(args.get("person") or "").strip()
        entity = str(args.get("entity") or "").strip()
        when = str(args.get("when") or "").strip()
        zone = tz.user_zone()
        now = self._now()
        since = parse_when(args.get("since"), end_of_day=False, zone=zone)
        until = parse_when(args.get("until"), end_of_day=True, zone=zone)
        candidates = None
        if source or person or since is not None or until is not None:
            # Ranking a query needs every match (an old fact must still be
            # findable); a time-ordered listing only needs the newest few.
            candidates = self._store.filtered_ids(
                self._namespace, source_prefix=f"{source}:" if source else "",
                since=since, until=until, person=person,
                limit=None if query.strip() else max(limit, 50))
        if entity:
            eid = self._entities().resolve(entity)
            ent = self._store.memories_for_entities([eid], 500) if eid else []
            keep = set(ent)
            candidates = ent if candidates is None else [c for c in candidates if c in keep]
        if when:
            win = time_window(when, datetime.fromtimestamp(now, zone))
            if win is not None:
                timed = self._store.ids_in_window(self._namespace, win.start, win.end, 500)
                keep = set(timed)
                candidates = timed if candidates is None else [c for c in candidates if c in keep]
        if candidates is not None and not query.strip():
            # A listing: the newest few, shown in time order.
            listed = sorted(self._store.get_chunks(list(candidates)), key=lambda c: c.created_at)
            chunks = [(c, 1.0) for c in listed[-limit:]]
        else:
            res = recall(self._store, self._embedder,
                         RecallQuery(text=query, now=now, zone=zone, limit=limit),
                         entity_index=self._entities(), namespace=self._namespace,
                         candidate_ids=set(candidates) if candidates is not None else None)
            chunks = [(h.chunk, h.score) for h in res.hits]

        def iso(t):
            return datetime.fromtimestamp(float(t), zone).isoformat(timespec="minutes") if t else None

        out = []
        for c, s in chunks:
            row = {"id": c.id, "body": c.body, "score": round(s, 4), "source": c.source,
                   "created_at": iso(c.created_at)}
            if c.event_start:
                row["event_start"] = iso(c.event_start)
            if c.kind:
                row["kind"] = c.kind
            if c.source_ref:
                row["source_ref"] = c.source_ref
            row["past"] = bool(c.valid_to)
            out.append(row)
        return out

    def _entities(self):
        from .entities import EntityIndex
        idx = getattr(self, "_entity_index", None)
        if idx is None:
            idx = self._entity_index = EntityIndex(self._store, self._namespace)
        return idx

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
