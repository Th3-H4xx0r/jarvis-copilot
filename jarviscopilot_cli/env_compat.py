"""Env-var compatibility bootstrap.

Mirrors ``HERMES_*`` ↔ ``JARVISCOPILOT_*`` so existing code that reads
either name keeps working through the rebrand. Idempotent — safe to
call multiple times.

Resolution rules:
- If both ``HERMES_FOO`` and ``JARVISCOPILOT_FOO`` are set, the
  JARVISCOPILOT_ value wins (the new name is authoritative).
- If only one is set, the other is mirrored to match. Existing values
  already in ``os.environ`` (including from a parent shell) are not
  clobbered if both are set.

Call ``apply()`` once, as early as possible at every process entry
point (CLI ``main()``, webui ``server.main()``, gateway, ACP adapter).
The webui/agent then reads either name and gets the same value.
"""
from __future__ import annotations

import os


_PREFIX_OLD = "HERMES_"
_PREFIX_NEW = "JARVISCOPILOT_"

# Vars that exist with HERMES_ prefix but belong to OTHER tools (JarvisCopilot
# Messenger, etc.) — never auto-mirror these. None known yet; placeholder
# for the day a collision turns up.
_BLOCKLIST: frozenset[str] = frozenset()


def apply() -> int:
    """Mirror HERMES_* ↔ JARVISCOPILOT_* in os.environ. Returns the
    count of variables that were synthesized (added). Already-set values
    are preserved."""
    added = 0
    snapshot = dict(os.environ)
    # Pass 1: JARVISCOPILOT_X exists, HERMES_X doesn't → mirror new → old.
    # This is the "new name authoritative" direction: an operator who set
    # the rebranded var expects code reading the legacy var to see the
    # same value.
    for k, v in snapshot.items():
        if not k.startswith(_PREFIX_NEW):
            continue
        if k in _BLOCKLIST:
            continue
        legacy = _PREFIX_OLD + k[len(_PREFIX_NEW):]
        if legacy not in os.environ:
            os.environ[legacy] = v
            added += 1
    # Pass 2: HERMES_X exists, JARVISCOPILOT_X doesn't → mirror old → new.
    # Backwards-compat for users who still set HERMES_*. Done after pass 1
    # so a JARVISCOPILOT_X that was just mirrored to HERMES_X doesn't get
    # bounced back.
    for k, v in snapshot.items():
        if not k.startswith(_PREFIX_OLD):
            continue
        if k in _BLOCKLIST:
            continue
        new = _PREFIX_NEW + k[len(_PREFIX_OLD):]
        if new not in os.environ:
            os.environ[new] = v
            added += 1
    return added


__all__ = ["apply"]
