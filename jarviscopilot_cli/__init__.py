"""
JarvisCopilot CLI - Unified command-line interface for JarvisCopilot.

Provides subcommands for:
- jarviscopilot chat          - Interactive chat (same as ./hermes)
- jarviscopilot gateway       - Run gateway in foreground
- jarviscopilot gateway start - Start gateway service
- jarviscopilot gateway stop  - Stop gateway service
- jarviscopilot setup         - Interactive setup wizard
- jarviscopilot status        - Show status of all components
- jarviscopilot cron          - Manage cron jobs
"""

import os
import sys

# Mirror HERMES_* ↔ JARVISCOPILOT_* env vars before anything else imports
# them. Idempotent; safe to run at module-import time.
try:
    from jarviscopilot_cli.env_compat import apply as _apply_env_compat
    _apply_env_compat()
except Exception:
    pass

# One-shot rename ~/.jarviscopilot/ → ~/.jarviscopilot/ with a back-compat link
# at the old path. No-op if already migrated or no legacy dir exists.
try:
    from jarviscopilot_cli.data_migration import apply as _apply_data_migration
    _apply_data_migration(quiet=True)
except Exception:
    pass

__version__ = "0.14.0"
__release_date__ = "2026.5.16"


def _ensure_utf8():
    """Force UTF-8 stdout/stderr on Windows to prevent UnicodeEncodeError.

    Windows services and terminals default to cp1252, which cannot encode
    box-drawing characters used in CLI output. This causes unhandled
    UnicodeEncodeError crashes on gateway startup.
    """
    if sys.platform != "win32":
        return
    os.environ.setdefault("PYTHONUTF8", "1")
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        if stream is None:
            continue
        try:
            if getattr(stream, "encoding", "").lower().replace("-", "") != "utf8":
                new_stream = open(
                    stream.fileno(), "w", encoding="utf-8",
                    buffering=1, closefd=False,
                )
                setattr(sys, stream_name, new_stream)
        except (AttributeError, OSError):
            pass


_ensure_utf8()
