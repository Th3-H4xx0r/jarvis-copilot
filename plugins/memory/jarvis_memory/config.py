"""Config loader for jarvis_memory — defaults from the design spec, overridable
via ``plugins.jarvis_memory`` in config.yaml."""
from __future__ import annotations

from pathlib import Path

DEFAULTS = {
    "embedder": "ollama",          # "ollama" | "fake" (cloud adapters in later phases)
    "ollama_url": "http://localhost:11434",
    "ollama_model": "bge-m3",
    "embed_dim": 1024,
    "recall_limit": 5,             # openhuman default
    "min_relevance": 0.0,          # Phase-1 fusion uses raw fused score; keep permissive
    "max_context_chars": 2000,     # openhuman default
    "namespace": "global",
    # Which roles to capture. Default user-only: the user supplies the durable
    # facts; assistant turns are mostly echoes/derivable and add noise. Set to
    # ["user", "assistant"] to capture both. (Proper fact-extraction that would
    # let us safely keep both is Phase 2 — LLM triage.)
    "capture_roles": ["user"],
    "ollama_autostart": True,      # start a local Ollama server at runtime if down
    # Phase 2 — LLM fact extraction. None = auto (on when embedder is ollama).
    # Distills turns into clean deduped facts instead of storing raw messages;
    # falls back to raw capture if the extractor model is unavailable.
    "extract": None,               # None|"ollama"|"off"
    "extract_model": "llama3.2:3b",
    "dedup_threshold": 0.92,       # skip a new fact this similar to an existing one
    # When extraction is enabled but fails, do NOT fall back to storing the raw
    # user turn (that's the "raw chat in memory" noise). Set True to capture raw
    # on failure instead of skipping.
    "extract_fallback_raw": False,
    # One-time migration of the builtin MEMORY.md/USER.md into this store.
    "migrate_builtin": True,
    # Proactive reflections (observation cards). None = auto (on when extract on).
    "proactive": None,             # None|True|"off"
    "proactive_interval_min": 30,
    # Auto-fetch external sources into memory (empty = disabled). Folder paths
    # whose text files are ingested incrementally. MCP/email sources plug into
    # the same SyncSource ABC (see autofetch.py).
    "autofetch_folders": [],
    "autofetch_interval_min": 20,
}


def load_config(hermes_home: str) -> dict:
    """Merge DEFAULTS with config.yaml ``plugins.jarvis_memory`` and resolve paths."""
    cfg = dict(DEFAULTS)
    try:
        from jarviscopilot_cli.config import load_config as _load, cfg_get
        section = cfg_get(_load(), "plugins", "jarvis_memory") or {}
        if isinstance(section, dict):
            cfg.update({k: v for k, v in section.items() if v is not None})
    except Exception:
        pass
    base = Path(hermes_home) / "memory"
    cfg["db_path"] = str(cfg.get("db_path") or (base / "memory.db"))
    cfg["vault_dir"] = str(cfg.get("vault_dir") or (base / "namespaces"))
    return cfg
