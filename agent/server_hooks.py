"""The hooks the server gives the Claude sessions it starts.

They are the Mac's hooks (jc-client's installer builds the same block, and its
relay script carries each event), pointed at the server's own hook socket, so
a session running here reports working, approvals, questions and every step
exactly as one on the Mac does. They go in a settings file handed to each
session at start, never in the server's global settings: Jarvis's own Claude
chats run on this machine too and must not show up as agents.
"""
from __future__ import annotations

import os
import sys
import tempfile
from typing import Optional

from agent.agent_engine_shim import load_hook_install


def write_hook_settings(path: str, *, socket: str, python: Optional[str] = None) -> str:
    """Write (or refresh) the settings file; returns its path."""
    hi = load_hook_install()
    cmd = hi.command_base(python or sys.executable, hi._RELAY_SOURCE, socket)
    # Built from empty (the file is all ours): merged with itself, the
    # installer wouldn't know these as its own and would add them twice.
    data = hi.preview(os.devnull, cmd, os.path.dirname(path), statusline=False).new_bytes
    try:
        with open(path, "rb") as fh:
            if fh.read() == data:
                return path
    except OSError:
        pass
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".claude-hooks.")
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)
    return path
