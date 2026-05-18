#!/usr/bin/env python3
"""Merge JarvisCopilot personalities into ~/.jarviscopilot/config.yaml.

Reads every *.yaml under installer/personalities/ and adds entries to
config.yaml's ``agent.personalities`` ONLY if a personality of that name
isn't already present. Existing user personalities are never overwritten
or reordered, and everything else in config.yaml is left untouched.

Called by install-jarviscopilot.{sh,ps1} after the pip-install step.
Also safe to run manually after pulling new code:

    /root/JarvisCopilot/.venv/bin/python /root/JarvisCopilot/installer/merge-personalities.py

Exit codes:
  0 — success (one or more personalities added OR everything already
      present, both report as success)
  2 — pyyaml not importable (shouldn't happen since pyyaml is a base dep)
  3 — config.yaml unreadable / unparseable (we refuse to overwrite a
      file we can't parse — manual intervention required)
"""

from __future__ import annotations

import os
import shutil
import sys
import time
from pathlib import Path

try:
    import yaml  # type: ignore
except Exception:
    print(f"[merge-personalities] pyyaml not available: {sys.exc_info()[1]}", file=sys.stderr)
    sys.exit(2)


def _hermes_home() -> Path:
    """Resolve the JarvisCopilot state dir, honoring HERMES_HOME."""
    home = os.environ.get("HERMES_HOME")
    if home:
        return Path(home).expanduser()
    return Path.home() / ".jarviscopilot"


def _personalities_dir() -> Path:
    """Directory holding the per-personality YAML files in the repo."""
    return Path(__file__).resolve().parent / "personalities"


def main() -> int:
    src_dir = _personalities_dir()
    cfg_path = _hermes_home() / "config.yaml"
    cfg_path.parent.mkdir(parents=True, exist_ok=True)

    # Load current config (empty dict if missing)
    cfg: dict = {}
    if cfg_path.exists():
        try:
            raw = cfg_path.read_text(encoding="utf-8")
            cfg = yaml.safe_load(raw) or {}
            if not isinstance(cfg, dict):
                print(f"[merge-personalities] {cfg_path} top level is not a mapping; refusing to merge.", file=sys.stderr)
                return 3
        except Exception as exc:
            print(f"[merge-personalities] failed to parse {cfg_path}: {exc}", file=sys.stderr)
            return 3

    agent = cfg.get("agent")
    if not isinstance(agent, dict):
        agent = {}
        cfg["agent"] = agent

    existing = agent.get("personalities")
    if not isinstance(existing, dict):
        existing = {}
        agent["personalities"] = existing

    added: list = []
    skipped: list = []
    if not src_dir.is_dir():
        print(f"[merge-personalities] source dir not found: {src_dir}", file=sys.stderr)
        return 0  # nothing to do; not fatal

    for yml in sorted(src_dir.glob("*.yaml")):
        name = yml.stem
        try:
            payload = yaml.safe_load(yml.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"[merge-personalities] skipping malformed {yml.name}: {exc}", file=sys.stderr)
            continue
        if not isinstance(payload, dict):
            continue
        if name in existing:
            skipped.append(name)
            continue
        existing[name] = payload
        added.append(name)

    if not added:
        print(f"[merge-personalities] no changes — already had: {', '.join(skipped) or '(none)'}")
        return 0

    # Safety backup before write so a botched merge is recoverable.
    if cfg_path.exists():
        backup = cfg_path.with_suffix(
            cfg_path.suffix + f".merge-bak.{time.strftime('%Y%m%d-%H%M%S')}"
        )
        try:
            shutil.copy2(cfg_path, backup)
        except Exception as exc:
            print(f"[merge-personalities] backup failed: {exc}", file=sys.stderr)

    # Atomic write via .tmp + replace so a crash mid-write doesn't truncate
    # the user's config.
    tmp = cfg_path.with_suffix(cfg_path.suffix + ".tmp")
    tmp.write_text(
        yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )
    tmp.replace(cfg_path)

    print(
        f"[merge-personalities] added {len(added)} personalit"
        f"{'y' if len(added) == 1 else 'ies'}: {', '.join(added)}"
    )
    if skipped:
        print(f"[merge-personalities] skipped (already present): {', '.join(skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
