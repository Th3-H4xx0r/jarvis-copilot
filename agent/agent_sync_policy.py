"""When a project's folder starts syncing to the server by itself.

Pranav chose (2026-10-17) that any folder a Claude or Codex session runs in
syncs automatically, so "Continue on server" works for it when the Mac sleeps.
Never the home folder or a system folder, never a project he switched off.
The size limit and allowed-root checks run on the Mac when the sync starts
(``jc_client.coding_sync_mutagen`` / ``check_local_sync``), where the tree is.
"""
from __future__ import annotations

import os

SWITCHED_OFF_SETTING = "sync_off_projects"


def should_auto_sync(project: dict, cwd: str, *, home: str, switched_off) -> tuple:
    if (project or {}).get("sync_enabled"):
        return False, "already_on"
    if (project or {}).get("id") in (switched_off or ()):
        return False, "switched_off"
    path = os.path.normpath(cwd) if cwd else ""
    if path and home and path == os.path.normpath(home):
        return False, "home"
    try:
        from agent.coding_sync_safety import is_dangerous_path
        unsafe = is_dangerous_path(path)
    except Exception:  # noqa: BLE001
        unsafe = path in ("", "/")
    if not path or unsafe:
        return False, "unsafe"
    return True, ""
