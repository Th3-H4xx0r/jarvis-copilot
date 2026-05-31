"""One-time migration of the builtin Hermes memory into jarvis_memory.

The builtin store is MEMORY.md (agent notes/lessons) + USER.md (user profile)
under ``$HERMES_HOME/memories/``, with entries delimited by ``\\n§\\n``
(see tools/memory_tool.py). This reads those entries so the provider can ingest
them as semantic facts.
"""
from __future__ import annotations

from pathlib import Path
from typing import List, Tuple

ENTRY_DELIMITER = "\n§\n"


def read_builtin_entries(hermes_home: str) -> List[Tuple[str, str]]:
    """Return [(entry_text, source)] from the builtin MEMORY.md/USER.md."""
    out: List[Tuple[str, str]] = []
    mem_dir = Path(hermes_home) / "memories"
    for fname, source in (("MEMORY.md", "builtin:memory"), ("USER.md", "builtin:user")):
        f = mem_dir / fname
        if not f.is_file():
            continue
        try:
            text = f.read_text(errors="replace")
        except Exception:
            continue
        for entry in text.split(ENTRY_DELIMITER):
            entry = entry.strip()
            if entry:
                out.append((entry, source))
    return out
