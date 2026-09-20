"""Resolve HERMES_HOME for standalone skill scripts.

Skill scripts may run outside the JarvisCopilot process (system Python, nix env,
CI) where ``jarviscopilot_constants`` is not importable.  This module provides the
same ``get_hermes_home()`` contract without requiring it on ``sys.path``.

When ``jarviscopilot_constants`` IS available it is used directly so profile
resolution and any future enhancements are picked up automatically.
"""

from __future__ import annotations

import os
from pathlib import Path

try:
    from jarviscopilot_constants import get_hermes_home as get_hermes_home
except (ModuleNotFoundError, ImportError):

    def get_hermes_home() -> Path:
        """Return the JarvisCopilot home directory (default: ``~/.jarviscopilot``)."""
        val = os.environ.get("HERMES_HOME", "").strip()
        return Path(val) if val else Path.home() / ".jarviscopilot"
