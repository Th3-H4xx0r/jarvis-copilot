"""Status summary for the webui Long-term Memory panel (provider/model/info)."""
from __future__ import annotations

from typing import Any, Dict


def memory_status(hermes_home: str) -> Dict[str, Any]:
    from .config import load_config
    from .store import MemoryStore
    from . import ollama_bootstrap as ob

    cfg = load_config(hermes_home)
    embedder = (cfg.get("embedder") or "ollama")
    extract = cfg.get("extract")
    extract_label = extract if extract else "auto (main model)"
    if extract in (None, "model", "auto", "main", "configured"):
        extract_model = cfg.get("extract_model") or "your main model"
    elif extract == "ollama":
        extract_model = cfg.get("extract_ollama_model", "llama3.2:3b")
    else:
        extract_model = "—"
    url = cfg.get("ollama_url", "http://localhost:11434")
    out: Dict[str, Any] = {
        "available": True,
        "embedder": embedder,
        "embed_model": cfg.get("ollama_model") if embedder == "ollama" else embedder,
        "embed_dim": cfg.get("embed_dim"),
        "extract": extract_label,
        "extract_model": extract_model,
        "ollama_url": url,
        "ollama_running": ob.is_running(url, timeout=1.0),
        "capture_roles": cfg.get("capture_roles") or ["user"],
        "count": 0,
        "namespaces": [],
    }
    try:
        s = MemoryStore(cfg["db_path"], cfg["vault_dir"])
        try:
            ns = s.namespaces()
            out["namespaces"] = [{"namespace": n, "count": c} for n, c in ns]
            out["count"] = sum(c for _, c in ns)
        finally:
            s.close()
    except Exception as e:
        out["error"] = str(e)
    return out
