#!/usr/bin/env python3
"""Bulk rename Hermes references to JarvisCopilot.

Runs case-preserving substitutions over the working tree. Designed to
be safe to re-run: the substitutions are stable (running twice produces
the same output as running once).

Usage:
    python scripts/rename-hermes-to-jarviscopilot.py --phase=<name> [--dry-run]

Phases (run in order; each commits before the next):
    docs           Markdown, txt, frontmatter descriptions. No code.
    user-strings   Quoted prose inside .py files (banners, log msgs,
                   error messages, CLI help). NOT import lines.
    env-vars       HERMES_FOO env-var reads/writes -> JARVISCOPILOT_FOO,
                   with backwards-compat fallback.
    paths          ~/.hermes/ paths -> ~/.jarviscopilot/, with migration.
    modules        hermes_cli/ -> jarviscopilot_cli/ etc.

The script skips: .git, .venv, node_modules, .web-old, __pycache__,
*.pyc, *.png, *.jpg, *.ico, *.woff*, *.svg, *.onnx, *.bin, *.so, *.exe.
"""
from __future__ import annotations

import argparse
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

# Files that intentionally retain "Hermes" for fork attribution.
# The README still wants to say "fork of Hermes Agent" at the top.
SKIP_FILES = {
    "scripts/rename-hermes-to-jarviscopilot.py",  # this file
}


def iter_files(roots):
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                p = Path(dirpath) / fn
                if p.suffix.lower() in SKIP_EXTS:
                    continue
                rel = str(p.relative_to(ROOT)).replace("\\", "/")
                if rel in SKIP_FILES:
                    continue
                yield p


def is_text(p: Path, sample: int = 4096) -> bool:
    try:
        with open(p, "rb") as f:
            chunk = f.read(sample)
        if b"\0" in chunk:
            return False
        return True
    except OSError:
        return False


# ── Substitution rules per phase ───────────────────────────────────────────

# Phase: docs — markdown/text files, no code paths.
DOCS_EXTS = {".md", ".txt", ".rst", ".html"}
DOCS_RULES = [
    # Brand names in prose / titles
    (r"\bHermes Gateway\b", "JarvisCopilot Gateway"),
    (r"\bHermes WebUI\b", "JarvisCopilot WebUI"),
    (r"\bHermes Web UI\b", "JarvisCopilot Web UI"),
    (r"\bHermes Agent\b", "JarvisCopilot"),
    (r"\bHermes Dashboard\b", "JarvisCopilot Dashboard"),
    (r"\bHermes core\b", "JarvisCopilot core"),
    (r"\bHermes CLI\b", "JarvisCopilot CLI"),
    # Conservative: bare "Hermes" word in markdown text (not part of an
    # identifier).
    (r"(?<![A-Za-z_/-])Hermes(?![A-Za-z_-])", "JarvisCopilot"),
    # Bare "hermes" word in prose (lowercase) — typical of error msgs.
    (r"(?<![A-Za-z_/-])hermes(?![A-Za-z_])(?!-agent)(?!_cli)(?!_agent)(?!-webui)(?!-gateway)", "jarviscopilot"),
]

# Phase: user-strings — quoted strings inside Python files.
# Only literal English prose inside quotes; we leave identifiers alone.
USER_STRING_PATTERNS = [
    # Inside-quotes Brand names
    (r"\bHermes Gateway\b", "JarvisCopilot Gateway"),
    (r"\bHermes WebUI\b", "JarvisCopilot WebUI"),
    (r"\bHermes Web UI\b", "JarvisCopilot Web UI"),
    (r"\bHermes Agent\b", "JarvisCopilot"),
    (r"\bHermes Dashboard\b", "JarvisCopilot Dashboard"),
    (r"\bHermes core\b", "JarvisCopilot core"),
    (r"\bHermes CLI\b", "JarvisCopilot CLI"),
]

# Phase: env-vars — HERMES_FOO → JARVISCOPILOT_FOO in env-var reads/writes.
# Match in os.getenv/os.environ contexts to avoid touching unrelated
# uppercase constants. Keep BACKWARD_COMPAT_ENV (we read both names).
ENV_VAR_PATTERN = re.compile(
    r'(os\.(?:getenv|environ(?:\.get)?)\(\s*[\'"])HERMES_([A-Z][A-Z0-9_]*)',
)
ENV_VAR_ASSIGN_PATTERN = re.compile(
    r'(os\.environ\[\s*[\'"])HERMES_([A-Z][A-Z0-9_]*)',
)

# Phase: paths — ~/.hermes/ → ~/.jarviscopilot/
PATH_PATTERN = re.compile(r'(\.hermes)(/|\\|"|\'|\b)')


def apply_rules_to_text(text: str, rules) -> tuple[str, int]:
    n = 0
    for pat, repl in rules:
        text, k = re.subn(pat, repl, text)
        n += k
    return text, n


def edit_file(p: Path, rules) -> int:
    try:
        if not is_text(p):
            return 0
        original = p.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return 0
    new, n = apply_rules_to_text(original, rules)
    if n == 0 or new == original:
        return 0
    p.write_text(new, encoding="utf-8")
    return n


def phase_docs(dry: bool) -> int:
    total = 0
    files_changed = 0
    for p in iter_files([ROOT]):
        if p.suffix.lower() not in DOCS_EXTS:
            continue
        if dry:
            try:
                if not is_text(p):
                    continue
                src = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            _, n = apply_rules_to_text(src, DOCS_RULES)
            if n:
                print(f"[dry] {p.relative_to(ROOT)} — {n} replacements")
                total += n
                files_changed += 1
        else:
            n = edit_file(p, DOCS_RULES)
            if n:
                total += n
                files_changed += 1
    print(f"docs: {total} replacements across {files_changed} files")
    return total


def phase_user_strings(dry: bool) -> int:
    total = 0
    files_changed = 0
    for p in iter_files([ROOT]):
        if p.suffix.lower() not in {".py", ".pyi"}:
            continue
        if dry:
            try:
                src = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            _, n = apply_rules_to_text(src, USER_STRING_PATTERNS)
            if n:
                print(f"[dry] {p.relative_to(ROOT)} — {n} replacements")
                total += n
                files_changed += 1
        else:
            n = edit_file(p, USER_STRING_PATTERNS)
            if n:
                total += n
                files_changed += 1
    print(f"user-strings: {total} replacements across {files_changed} files")
    return total


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", required=True,
                    choices=["docs", "user-strings", "env-vars", "paths", "modules"])
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    phase = args.phase
    if phase == "docs":
        return 0 if phase_docs(args.dry_run) >= 0 else 1
    if phase == "user-strings":
        return 0 if phase_user_strings(args.dry_run) >= 0 else 1
    print(f"Phase {phase!r} not implemented yet.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
