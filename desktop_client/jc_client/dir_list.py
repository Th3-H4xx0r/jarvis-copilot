"""List this machine's folders for the server's folder typeahead.

The server's ``/api/coding/dir-suggest`` (the launch sheet's folder field, a
project's Mac folder) asks a paired Mac to list a directory. Wire protocol::

    S->D  {"type": "coding_dir_list_get", "req_id": <str>, "path": <str>}
    D->S  {"type": "coding_dir_list_data", "req_id": <str>, "ok": true, "dirs": [...]}
          {"type": "coding_dir_list_data", "req_id": <str>, "ok": false, "error": <str>}

Pure stdlib; never raises into the bridge's read loop.
"""
from __future__ import annotations

import logging
import os
from typing import Callable, Optional

log = logging.getLogger(__name__)

FRAME = "coding_dir_list_get"
REPLY = "coding_dir_list_data"
MAX_DIRS = 50


def suggest_dirs(prefix: str, *, home: str, limit: int = MAX_DIRS) -> list:
    """Immediate sub-directories matching ``prefix`` on THIS device. Mirrors
    ``agent.coding_dir_suggest.suggest_dirs`` on the server:

      * ``""`` / ``"~"``            -> subdirs of ``home``
      * a dir / a path ending "/"   -> that dir's subdirs (drill in)
      * any other partial path      -> sibling dirs starting with the basename

    Hidden dirs only when the fragment starts with ".". Dirs only; never raises.
    """
    raw = (prefix or "").strip()
    if raw == "~":
        raw = home + os.sep
    elif raw.startswith("~/") or raw.startswith("~" + os.sep):
        raw = home + raw[1:]
    elif raw == "":
        raw = home + os.sep
    if raw.endswith(os.sep) or os.path.isdir(raw):
        base, frag = raw, ""
    else:
        base = os.path.dirname(raw) or os.sep
        frag = os.path.basename(raw)
    try:
        names = os.listdir(base)
    except OSError:
        return []
    show_hidden = frag.startswith(".")
    out = []
    for name in names:
        if not show_hidden and name.startswith("."):
            continue
        if frag and not name.startswith(frag):
            continue
        full = os.path.join(base, name)
        try:
            if os.path.isdir(full):
                out.append(full)
        except OSError:
            continue
    out.sort()
    out = out[:limit]
    # Fold home back to "~" when the user typed a ~-relative prefix, so the
    # server's native <datalist> (substring match) still shows the options.
    if (prefix or "").strip().startswith("~"):
        folded = []
        for p in out:
            if p == home:
                folded.append("~")
            elif p.startswith(home + os.sep):
                folded.append("~" + p[len(home):])
            else:
                folded.append(p)
        out = folded
    return out


def handle_frame(frame: dict, send: Callable[[dict], None], *,
                 home: Optional[str] = None) -> None:
    """Answer one ``coding_dir_list_get``. Never raises."""
    req_id = str((frame or {}).get("req_id") or "")
    if not req_id:
        return
    try:
        dirs = suggest_dirs(str(frame.get("path") or ""),
                            home=home if home is not None else os.path.expanduser("~"))
        reply = {"type": REPLY, "req_id": req_id, "ok": True, "dirs": dirs}
    except Exception as exc:  # noqa: BLE001
        reply = {"type": REPLY, "req_id": req_id, "ok": False, "error": str(exc)}
    try:
        send(reply)
    except Exception as exc:  # noqa: BLE001 — a closed socket must not break the loop
        log.debug("dir list reply failed: %s", exc)
