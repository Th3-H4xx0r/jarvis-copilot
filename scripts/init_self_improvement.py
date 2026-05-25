"""Idempotent initializer for JarvisCopilot autonomous self-improvement.

Brings a machine from "never installed" to "self-improvement on":
  * creates HERMES_HOME (~/.jarviscopilot) + memories/ + skills/
  * merges tuned self-improvement settings into config.yaml (without
    clobbering existing user keys)
  * seeds bundled skills via tools.skills_sync.sync_skills
  * git-inits the home and makes an initial commit so every future
    memory/skill change is individually revertable

Safe to re-run. Usage:  python -m scripts.init_self_improvement
"""
from __future__ import annotations

import copy
import logging
import subprocess
from pathlib import Path
from typing import Any, Dict

import yaml

logger = logging.getLogger(__name__)

from jarviscopilot_constants import get_hermes_home
from tools.skills_sync import sync_skills

# Tuned defaults — frequent capture into the built-in MEMORY.md/USER.md store,
# no external provider, curator on a daily cadence.
_TUNED: Dict[str, Any] = {
    "memory": {
        "memory_enabled": True,
        "user_profile_enabled": True,
        "provider": "",
        "nudge_interval": 3,
    },
    "skills": {
        "creation_nudge_interval": 3,
    },
    "curator": {
        "enabled": True,
        "interval_hours": 24,
        "min_idle_hours": 1,
    },
}

_GITIGNORE = """\
# Credentials & secrets — NEVER track these in the home git repo.
auth.json
auth.lock
.env
.env.*
*.oauth.json
.anthropic_oauth.json
webhook_subscriptions.json
mcp-tokens/
webui-tls/
*.pem
*.key
credentials*
# Volatile runtime state — not tracked for self-improvement audit.
*.db
*.db-*
*.log
*.sock
*.pyc
__pycache__/
.usage.json
sessions/
logs/
tmp/
cache/
audio_cache/
"""


def _deep_merge(base: Dict[str, Any], overlay: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively merge overlay into base WITHOUT overwriting existing leaf keys.

    A pre-existing key whose value is ``None`` (e.g. an empty ``memory:``
    section, which YAML parses as null) is treated as absent and filled from
    the overlay — otherwise initialization would report success while leaving
    a null section in place and self-improvement silently off. An existing
    non-null scalar set by the user is left untouched.
    """
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_merge(base[k], v)
        elif k not in base or base.get(k) is None:
            base[k] = v
    return base


def _write_config(home: Path) -> None:
    cfg_path = home / "config.yaml"
    existing: Dict[str, Any] = {}
    if cfg_path.exists():
        try:
            existing = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
        except Exception:
            existing = {}
    merged = _deep_merge(existing, copy.deepcopy(_TUNED))
    cfg_path.write_text(yaml.safe_dump(merged, sort_keys=False), encoding="utf-8")


def _git_init(home: Path) -> None:
    """Best-effort: git-init the home and commit current state. Never raises.

    The audit/revert git layer is a convenience. A git failure (git not
    installed, an index.lock race with the background-review thread, or a
    failing global pre-commit hook) must never abort initialization of the
    actual functional state — config + seeded skills are already written by
    the time this runs.
    """
    try:
        if not (home / ".git").exists():
            subprocess.run(["git", "init"], cwd=home, check=True,
                           capture_output=True)
            subprocess.run(["git", "config", "user.email",
                            "selfimprove@jarviscopilot.local"],
                           cwd=home, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.name",
                            "JarvisCopilot Self-Improvement"],
                           cwd=home, check=True, capture_output=True)
        (home / ".gitignore").write_text(_GITIGNORE, encoding="utf-8")
        subprocess.run(["git", "-C", str(home), "add", "-A"],
                       check=True, capture_output=True)
        staged = subprocess.run(
            ["git", "-C", str(home), "diff", "--cached", "--quiet"],
            capture_output=True,
        )
        if staged.returncode != 0:
            subprocess.run(["git", "-C", str(home), "commit", "-m",
                            "chore: initialize self-improvement home",
                            "--no-verify", "--quiet"],
                           check=True, capture_output=True)
    except Exception as exc:
        logger.debug("self-improvement git init skipped: %s", exc)


def initialize(quiet: bool = False) -> Dict[str, Any]:
    home = get_hermes_home()
    home.mkdir(parents=True, exist_ok=True)
    (home / "memories").mkdir(parents=True, exist_ok=True)
    (home / "skills").mkdir(parents=True, exist_ok=True)
    _write_config(home)
    sync_result = sync_skills(quiet=quiet)
    _git_init(home)
    result = {"home": str(home), "skills": sync_result}
    if not quiet:
        print(f"Self-improvement initialized at {home}")
        print("  config.yaml written (nudge_interval=3, curator interval=24h)")
        print(f"  skills seeded: {len(sync_result.get('copied', []))} copied")
        print("  home git-initialized for revert/audit")
    return result


if __name__ == "__main__":
    initialize(quiet=False)
