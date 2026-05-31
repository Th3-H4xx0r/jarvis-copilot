"""Auto-fetch: pull external data into the memory tree on a schedule.

Port of openhuman's 20-minute sync loop, distilled to the part MCP doesn't give
you: a pluggable SyncSource + a scheduler that walks active sources, tracks a
per-source incremental cursor, and ingests new items into jarvis_memory with
content-hash idempotency.

A working `FolderSyncSource` is included (drop notes into a folder and they
become searchable memory). Email/GitHub/Slack/MCP sources plug into the same
`SyncSource` ABC — e.g. an MCP source would call the agent's MCP fetch tool in
`sync()` and return the results; the scheduler/ingest/cursor logic is unchanged.
"""
from __future__ import annotations

import logging
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

from .ingest import chunk_text
from .store import GLOBAL_NS

logger = logging.getLogger(__name__)

_CURSOR_NS = "__autofetch__"


@dataclass
class SyncItem:
    id: str
    text: str
    source: str       # short label, e.g. "file:notes.md", "email:alice@x"
    ts: float         # source timestamp (used for the cursor)


class SyncSource(ABC):
    @property
    @abstractmethod
    def name(self) -> str:
        """Stable source id (cursor is keyed on this)."""

    @abstractmethod
    def sync(self, cursor: float) -> Tuple[List[SyncItem], Optional[float]]:
        """Return (new items since `cursor`, new_cursor). Raise on transient failure."""


class FakeSyncSource(SyncSource):
    def __init__(self, name: str, batches):
        self._name = name
        self._batches = list(batches)  # list of (items, new_cursor)
        self._i = 0

    @property
    def name(self):
        return self._name

    def sync(self, cursor):
        if self._i >= len(self._batches):
            return [], cursor
        out = self._batches[self._i]
        self._i += 1
        return out


class FolderSyncSource(SyncSource):
    """Ingest text files from a folder, incrementally by mtime."""

    DEFAULT_EXTS = (".md", ".txt", ".markdown", ".rst", ".org")

    def __init__(self, folder: str, exts=None, max_bytes: int = 50_000):
        self._folder = Path(folder).expanduser()
        self._exts = tuple(e.lower() for e in (exts or self.DEFAULT_EXTS))
        self._max_bytes = max_bytes

    @property
    def name(self):
        return f"folder:{self._folder}"

    def sync(self, cursor: float):
        items: List[SyncItem] = []
        new_cursor = cursor
        if not self._folder.is_dir():
            return items, cursor
        for f in sorted(self._folder.rglob("*")):
            if not f.is_file() or f.suffix.lower() not in self._exts:
                continue
            try:
                mtime = f.stat().st_mtime
            except Exception:
                continue
            if mtime <= cursor:
                continue
            try:
                text = f.read_text(errors="replace")[: self._max_bytes].strip()
            except Exception:
                continue
            if text:
                items.append(SyncItem(id=str(f), text=text, source=f"file:{f.name}", ts=mtime))
            new_cursor = max(new_cursor, mtime)
        return items, new_cursor


class AutoFetchScheduler:
    def __init__(self, sources: List[SyncSource], memory_store, embedder, namespace: str = GLOBAL_NS):
        self.sources = sources
        self.store = memory_store
        self.embedder = embedder
        self.namespace = namespace

    def _ingest(self, item: SyncItem) -> int:
        n = 0
        for piece in chunk_text(item.text):
            emb = None
            try:
                emb = self.embedder.embed_one(piece)
            except Exception:
                pass
            use_emb = emb if (emb and len(emb)) else None
            self.store.add_chunk(
                self.namespace, piece, f"autofetch:{item.source}", item.ts or time.time(), 0.8, "autofetch",
                embedding=use_emb, signature=self.embedder.signature if use_emb else None,
                dim=self.embedder.dim if use_emb else None,
            )
            n += 1
        return n

    def run_once(self) -> int:
        """Walk all sources once; ingest new items. Returns chunks ingested."""
        total = 0
        for src in self.sources:
            raw = self.store.kv_get(_CURSOR_NS, src.name)
            cursor = float(raw) if raw else 0.0
            try:
                items, new_cursor = src.sync(cursor)
            except Exception as e:
                logger.warning("autofetch source %s failed: %s", src.name, e)
                continue
            for it in items:
                try:
                    total += self._ingest(it)
                except Exception as e:
                    logger.warning("autofetch ingest failed (%s): %s", it.id, e)
            if new_cursor is not None and new_cursor != cursor:
                self.store.kv_set(_CURSOR_NS, src.name, str(new_cursor))
        return total


def build_sources(cfg: dict) -> List[SyncSource]:
    """Build sources from config. Currently: autofetch_folders: [paths]."""
    sources: List[SyncSource] = []
    for folder in (cfg.get("autofetch_folders") or []):
        if folder:
            sources.append(FolderSyncSource(folder))
    return sources
