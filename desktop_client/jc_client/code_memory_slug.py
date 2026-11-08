"""Which code-memory project a folder belongs to: the one slug rule.

Same repo => same slug (normalized git remote) => same memory on every surface.
A desktop Claude session (jc-client's MCP server and CLI) and a server-host one
(``agent/code_memory.py``, which loads THIS file by path because the server has
no ``jc_client`` install) must compute the same slug, or they write to two
different project memories. So there is one definition, here. Pure stdlib.
"""
from __future__ import annotations

import os
import re
import subprocess


def sanitize(seg: str) -> str:
    """A safe slug / path segment: lowercase, spaces to hyphens, anything else
    odd to ``_``, no leading/trailing ``_`` or ``.``."""
    seg = seg.strip().lower()
    seg = seg.replace(" ", "-")  # spaces to hyphens for readability
    return re.sub(r"[^a-z0-9._-]+", "_", seg).strip("_.")


def slugify_remote(remote: str) -> str:
    r = remote.strip()
    r = re.sub(r"^[a-z]+://", "", r, flags=re.I)      # strip scheme
    r = re.sub(r"^[^@/]+@", "", r)                     # strip user@
    r = r.replace(":", "/")                            # scp-style host:path -> host/path
    r = re.sub(r"\.git$", "", r, flags=re.I)
    parts = [p for p in r.split("/") if p]
    return sanitize("_".join(parts))


def project_slug(root: str, remote: str | None) -> str:
    """The git remote's slug, else the folder name's, else ``"project"``.

    The folder is named after normalizing, so ``/code/app/src/..`` is ``app``
    (the desktop and server copies disagreed on exactly this before)."""
    if remote and slugify_remote(remote):
        return slugify_remote(remote)
    return sanitize(os.path.basename(os.path.normpath(root))) or "project"


def git_remote(root: str) -> str:
    """``origin``'s URL for the repo at ``root``, or ``""``."""
    try:
        out = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=5)
        if out.returncode == 0:
            return (out.stdout or "").strip()
    except Exception:
        pass
    return ""


def current_slug(root: str | None = None) -> str:
    """The slug for ``root`` (default: the current directory)."""
    root = root or os.getcwd()
    return project_slug(root, git_remote(root) or None)
