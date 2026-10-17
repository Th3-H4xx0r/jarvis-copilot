"""A sync stopped for a conflict inside .git alerts the phone (once per stop)."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from api import coding_desktop  # noqa: E402


def test_git_conflict_error_alerts_the_phone(monkeypatch):
    alerts = []
    import api.push as push
    monkeypatch.setattr(push, "alert_phones",
                        lambda title, body, **kw: alerts.append((title, body)) or 1)
    s = coding_desktop.MutagenSyncSession(sync_id="sync-1", device_id="d1",
                                          local_path="/Users/p/code/app",
                                          remote_path="/root/codingprojects/app", bridge=None)
    s.on_error("git_conflict", "Conflicting changes inside .git (.git/index). Sync paused.")
    s.on_error("git_conflict", "Conflicting changes inside .git (.git/index). Sync paused.")
    assert s.status == "error"
    assert alerts == [("Sync paused: app", "Conflicting changes inside .git (.git/index). Sync paused.")]


def test_other_sync_errors_do_not_alert(monkeypatch):
    alerts = []
    import api.push as push
    monkeypatch.setattr(push, "alert_phones", lambda *a, **kw: alerts.append(a) or 1)
    s = coding_desktop.MutagenSyncSession(sync_id="sync-2", device_id="d1", local_path="/x/y",
                                          remote_path="/root/y", bridge=None)
    s.on_error("mutagen", "connection refused")
    assert alerts == []
