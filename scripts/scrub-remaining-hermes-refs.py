#!/usr/bin/env python3
"""Second-pass scrub for remaining 'hermes' references the first
rename script left behind.

Targets things the conservative first-pass deliberately skipped:
  - `hermes-agent` and `hermes-acp` package / command names
  - `hermes ` (bare lowercase, followed by a command word) — the
    agent learns CLI commands from these
  - `Hermes Agent` URL hosts (e.g. ``hermes-agent.nousresearch.com``)
  - References to top-level `hermes_constants` etc. in prose

The first-pass rules excluded these on purpose so we wouldn't break
upstream merge resolution. Now that we've merged + landed phases A–E,
it's safe to be aggressive.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SKIP_DIRS = {".git", ".venv", "venv", "node_modules", ".web-old",
             "__pycache__", ".pytest_cache", "dist", "build",
             ".mypy_cache", ".tox", ".idea", ".vscode"}

SKIP_EXTS = {".png", ".jpg", ".jpeg", ".ico", ".woff", ".woff2",
             ".ttf", ".svg", ".onnx", ".bin", ".so", ".exe", ".dll",
             ".pyc", ".pyo", ".pyd", ".gz", ".zip", ".tar", ".whl",
             ".mp3", ".mp4", ".wav", ".ogg", ".webm", ".lock"}

# These files keep "hermes" deliberately:
#   - the back-compat shim
#   - this scrub script + the original rename script (regex literals)
#   - upstream attribution in the top-of-README block
SKIP_FILES = {
    "scripts/scrub-remaining-hermes-refs.py",
    "scripts/rename-hermes-to-jarviscopilot.py",
    "hermes_cli.py",
}

# Match `hermes` as a bare command/word but NOT inside identifiers like
# `hermes_state` (already renamed) or URL hosts unless we explicitly
# target them.
SECOND_PASS_RULES = [
    # Brand: hermes-agent (the upstream package name in URLs, install
    # instructions, etc.) → jarviscopilot
    (r"\bhermes-agent\b", "jarviscopilot"),
    (r"\bhermes-acp\b", "jarviscopilot-acp"),
    (r"\bhermes-webui\b", "jarviscopilot-webui"),
    (r"\bhermes-gateway\b", "jarviscopilot-gateway"),
    # Command-line invocations: `hermes <verb>` → `jarviscopilot <verb>`.
    # The verb list keeps us from rewriting things like "hermes runs".
    (r"\bhermes(\s+(?:chat|gateway|setup|status|cron|kanban|webhook|"
     r"hooks|doctor|dump|debug|backup|checkpoints|import|config|"
     r"pairing|model|fallback|proxy|login|logout|auth|tools|skills|"
     r"sessions|memory|profiles|completion|version|update|uninstall|"
     r"plugins|insights|logs|lsp|mcp|computer-use|claw|acp|dashboard|"
     r"curator|send|whatsapp|slack|pair|devices|restart|postinstall|"
     r"--help|-h|-m\b|-s\b))", r"jarviscopilot\1"),
    # Backticked commands inside markdown: `hermes ...` → `jarviscopilot ...`
    (r"`hermes ", "`jarviscopilot "),
    # Bare 'hermes' as an identifier in prose, EXCLUDING the back-compat
    # shim filename and the cookie name.
    (r"(?<![A-Za-z_/-])hermes(?![A-Za-z_-])(?!_session)(?!_cli\b)", "jarviscopilot"),
    # Bare 'Hermes' (capitalized) in prose.
    (r"(?<![A-Za-z_/-])Hermes(?![A-Za-z_-])", "JarvisCopilot"),
]


def iter_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            p = Path(dirpath) / fn
            if p.suffix.lower() in SKIP_EXTS:
                continue
            rel = str(p.relative_to(ROOT)).replace("\\", "/")
            if rel in SKIP_FILES:
                continue
            yield p


def is_text(p: Path) -> bool:
    try:
        with open(p, "rb") as f:
            chunk = f.read(4096)
        return b"\0" not in chunk
    except OSError:
        return False


def main() -> int:
    files_changed = 0
    total_subs = 0
    for p in iter_files():
        if not is_text(p):
            continue
        try:
            src = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        new = src
        for pat, repl in SECOND_PASS_RULES:
            new, k = re.subn(pat, repl, new)
            total_subs += k
        if new != src:
            p.write_text(new, encoding="utf-8")
            files_changed += 1
    print(f"scrub: {total_subs} substitutions across {files_changed} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
