"""Proactive 'subconscious' reflections (port of openhuman's subconscious tick).

On a periodic tick it reads NEW memories since the last tick, asks an LLM "what
should the user know?", and produces up to 5 observation cards. Load-bearing
guardrails (copied from openhuman, the reason a continuous loop is trustworthy):
  - cap of MAX_CARDS per tick;
  - last_tick_at cutoff so it only considers memories newer than the last run;
  - recent reflections fed back as anti-double-emit context + dedup on title;
  - OBSERVATION-ONLY — cards are never auto-posted into chat and never act; any
    follow-up is an explicit user tap.
Uses a local Ollama chat model by default (private/free); degrades to no-op if
unavailable.
"""
from __future__ import annotations

import json
import logging
import re
import sqlite3
import threading
from abc import ABC, abstractmethod
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

MAX_CARDS = 5
KINDS = {"due_item", "pattern", "risk", "opportunity", "reminder"}

REFLECT_SYSTEM = (
    "You review a user's recent personal-assistant memory and surface a few brief "
    "OBSERVATION cards — things they may want to know, follow up on, or be reminded of "
    "(patterns across notes, due/time-sensitive items, risks, opportunities). "
    "Observation-only: never instructions, never actions. Output ONLY a JSON array of "
    "objects {\"title\": str, \"body\": str, \"kind\": one of "
    "[due_item, pattern, risk, opportunity, reminder]}. At most 5. Do NOT repeat anything "
    "already in 'Recent cards'. If nothing is noteworthy, output []."
)


def _norm_key(title: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", (title or "").lower())).strip()


def parse_cards(content: str) -> List[dict]:
    if not content:
        return []
    m = re.search(r"\[.*\]", content, re.DOTALL)
    try:
        data = json.loads(m.group(0) if m else content)
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    cards = []
    for it in data:
        if not isinstance(it, dict):
            continue
        title = str(it.get("title") or "").strip()
        body = str(it.get("body") or "").strip()
        kind = str(it.get("kind") or "pattern").strip().lower()
        if kind not in KINDS:
            kind = "pattern"
        if title:
            cards.append({"title": title, "body": body, "kind": kind})
    return cards[:MAX_CARDS]


class Reflector(ABC):
    @abstractmethod
    def reflect(self, report: str, recent_titles: List[str]) -> List[dict]:
        """Return observation cards. Raise on unavailability."""


class FakeReflector(Reflector):
    def __init__(self, cards=None, raises=False):
        self._cards = cards or []
        self._raises = raises

    def reflect(self, report, recent_titles):
        if self._raises:
            raise RuntimeError("reflector unavailable")
        return list(self._cards)


class OllamaReflector(Reflector):
    def __init__(self, model="llama3.2:3b", url="http://localhost:11434", timeout=30.0):
        self._model = model
        self._url = url.rstrip("/")
        self._timeout = timeout

    def reflect(self, report, recent_titles):
        import urllib.request
        user = f"Recent memory:\n{report}\n\nRecent cards (do not repeat):\n"
        user += "\n".join(f"- {t}" for t in recent_titles) or "- (none)"
        payload = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": REFLECT_SYSTEM},
                {"role": "user", "content": user},
            ],
            "stream": False, "options": {"temperature": 0.2},
        }
        req = urllib.request.Request(
            f"{self._url}/api/chat",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self._timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return parse_cards((data.get("message") or {}).get("content", ""))


class AuxiliaryReflector(Reflector):
    """Reflect via the user's configured model (e.g. gpt-5.5) — same path as
    fact extraction. Better than a weak local model and needs no Ollama."""

    def __init__(self, model: str = None, provider: str = None, timeout: float = 30.0):
        self._model = model or None
        self._provider = provider or None
        self._timeout = timeout

    def reflect(self, report, recent_titles):
        from agent.auxiliary_client import call_llm
        user = f"Recent memory:\n{report}\n\nRecent cards (do not repeat):\n"
        user += "\n".join(f"- {t}" for t in recent_titles) or "- (none)"
        resp = call_llm(
            task="memory_reflection",
            provider=self._provider, model=self._model,
            messages=[{"role": "system", "content": REFLECT_SYSTEM},
                      {"role": "user", "content": user}],
            max_tokens=600, temperature=0.2, timeout=self._timeout,
        )
        content = (resp.choices[0].message.content or "") if resp and resp.choices else ""
        return parse_cards(content)


def make_reflector(cfg: dict):
    """Pick a reflector matching the extraction backend (configured model by
    default; local Ollama or off as configured). Returns None when disabled."""
    kind = cfg.get("extract")
    if kind is None:
        kind = "off" if (cfg.get("embedder") or "ollama").lower() == "fake" else "model"
    kind = str(kind).lower()
    if kind in ("off", "none", "false", "0"):
        return None
    if kind in ("model", "aux", "configured", "main"):
        return AuxiliaryReflector(model=cfg.get("extract_model") or None)
    if kind == "ollama":
        return OllamaReflector(model=cfg.get("extract_ollama_model", "llama3.2:3b"),
                               url=cfg.get("ollama_url", "http://localhost:11434"))
    return None


class ReflectionStore:
    def __init__(self, db_path):
        self.db_path = str(db_path)
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(self.db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        with self._lock:
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS reflections(
                  id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT,
                  title TEXT NOT NULL, body TEXT, status TEXT NOT NULL DEFAULT 'new',
                  dedup_key TEXT
                );
                CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value REAL);
                """
            )
            self._conn.commit()

    def get_last_tick(self) -> float:
        with self._lock:
            r = self._conn.execute("SELECT value FROM state WHERE key='last_tick'").fetchone()
        return float(r["value"]) if r else 0.0

    def set_last_tick(self, ts: float):
        with self._lock:
            self._conn.execute("INSERT OR REPLACE INTO state(key,value) VALUES('last_tick',?)", (ts,))
            self._conn.commit()

    def recent_keys(self, limit=20) -> set:
        with self._lock:
            rows = self._conn.execute(
                "SELECT dedup_key FROM reflections ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
        return {r["dedup_key"] for r in rows if r["dedup_key"]}

    def recent_titles(self, limit=10) -> List[str]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT title FROM reflections ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
        return [r["title"] for r in rows]

    def add(self, cards: List[dict], ts: float) -> List[int]:
        ids = []
        with self._lock:
            for c in cards:
                cur = self._conn.execute(
                    "INSERT INTO reflections(ts,kind,title,body,status,dedup_key) "
                    "VALUES (?,?,?,?, 'new', ?)",
                    (ts, c.get("kind", "pattern"), c["title"], c.get("body", ""), _norm_key(c["title"])),
                )
                ids.append(cur.lastrowid)
            self._conn.commit()
        return ids

    def list(self, status: Optional[str] = None, limit=50) -> List[dict]:
        with self._lock:
            if status:
                rows = self._conn.execute(
                    "SELECT * FROM reflections WHERE status=? ORDER BY id DESC LIMIT ?",
                    (status, limit),
                ).fetchall()
            else:
                rows = self._conn.execute(
                    "SELECT * FROM reflections ORDER BY id DESC LIMIT ?", (limit,)
                ).fetchall()
        return [dict(r) for r in rows]

    def dismiss(self, rid) -> bool:
        with self._lock:
            cur = self._conn.execute("UPDATE reflections SET status='dismissed' WHERE id=?", (rid,))
            self._conn.commit()
            return cur.rowcount > 0

    def count(self, status: Optional[str] = None) -> int:
        with self._lock:
            if status:
                return self._conn.execute(
                    "SELECT COUNT(*) FROM reflections WHERE status=?", (status,)
                ).fetchone()[0]
            return self._conn.execute("SELECT COUNT(*) FROM reflections").fetchone()[0]

    def close(self):
        with self._lock:
            try:
                self._conn.close()
            except Exception:
                pass


class ProactiveEngine:
    def __init__(self, reflect_store: ReflectionStore, memory_store, reflector: Reflector,
                 namespace: str = "global", max_cards: int = MAX_CARDS):
        self.reflect_store = reflect_store
        self.memory_store = memory_store
        self.reflector = reflector
        self.namespace = namespace
        self.max_cards = max_cards

    def tick(self, now_ts: float) -> List[dict]:
        last = self.reflect_store.get_last_tick()
        recent = [c for c in self.memory_store.recent_chunks(self.namespace, 60)
                  if c.created_at > last]
        if not recent:
            self.reflect_store.set_last_tick(now_ts)
            return []
        report = "\n".join(f"- {' '.join(c.body.split())}" for c in recent)[:2000]
        try:
            cards = self.reflector.reflect(report, self.reflect_store.recent_titles(10))
        except Exception as e:
            logger.warning("jarvis_memory reflector unavailable: %s", e)
            return []  # don't advance the cutoff — retry next tick
        seen = self.reflect_store.recent_keys(40)
        fresh = [c for c in cards[: self.max_cards] if _norm_key(c["title"]) not in seen]
        if fresh:
            self.reflect_store.add(fresh, now_ts)
        self.reflect_store.set_last_tick(now_ts)
        return fresh


def run_tick(hermes_home: str, now_ts: float) -> List[dict]:
    """Open stores + a local reflector and run one tick. Best-effort; returns the
    fresh cards (or [] if nothing/unavailable). Safe to call from a timer/cron."""
    from .config import load_config
    from .store import MemoryStore
    from . import ollama_bootstrap as ob

    cfg = load_config(hermes_home)
    reflector = make_reflector(cfg)
    if reflector is None:
        return []
    # Only a LOCAL Ollama reflector needs Ollama up; the configured-model
    # reflector (call_llm) doesn't.
    if isinstance(reflector, OllamaReflector) and not ob.is_running(
            cfg.get("ollama_url", "http://localhost:11434")):
        return []
    mem = MemoryStore(cfg["db_path"], cfg["vault_dir"])
    rstore = ReflectionStore(str(Path(hermes_home) / "memory" / "reflections.db"))
    try:
        engine = ProactiveEngine(rstore, mem, reflector, namespace=cfg.get("namespace") or "global")
        cards = engine.tick(now_ts)
        if cards:
            try:
                from .mem_log import log_event
                log_event("generated %d insight card(s)", len(cards))
            except Exception:
                pass
        return cards
    finally:
        mem.close()
        rstore.close()
