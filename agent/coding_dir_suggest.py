"""Pure directory-suggestion helper for the coding-session Working Directory /
sync-folder-path autocomplete.

Given a path prefix the user is typing, returns immediate sub-directories to
suggest — the standard typeahead/drill-down behavior:

  * ``""`` / ``"~"``            -> immediate subdirs of ``home``
  * a dir, or a path ending "/" -> that dir's immediate subdirs (drill in)
  * any other partial path      -> sibling dirs in the parent whose name starts
                                    with the typed basename

This is the SERVER-side lister (the host the webui runs on). The desktop
``jc-client`` carries its own copy (``coding_discover._suggest_dirs``) for
listing a paired device's filesystem over the bridge, so both sides behave
identically. Pure stdlib; directories only; never raises.
"""
from __future__ import annotations

import os

_MAX = 50


def _to_tilde(path: str, home: str) -> str:
    """Re-fold ``home`` back to ``~`` so a returned path keeps the style the user
    typed (a native <datalist> only shows options whose value contains the typed
    value — a ``~``-relative prefix won't match an absolute path)."""
    if path == home:
        return "~"
    if path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


def suggest_dirs(prefix: str, *, home: str | None = None,
                 limit: int = _MAX) -> list[str]:
    """Return up to ``limit`` absolute directory paths suggested for ``prefix``.

    Hidden dirs (``.*``) are included only when the typed fragment itself starts
    with ``.``. Unreadable/missing base dirs degrade to ``[]``. Never raises.
    """
    home = home or os.path.expanduser("~")
    raw = (prefix or "").strip()
    # Expand a leading ~ (``~`` or ``~/...``) to the home dir.
    if raw == "~":
        raw = home + os.sep
    elif raw.startswith("~/") or raw.startswith("~" + os.sep):
        raw = home + raw[1:]
    elif raw == "":
        raw = home + os.sep

    # Decide the base directory to list + the name fragment to filter by.
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
    out: list[str] = []
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
    if (prefix or "").strip().startswith("~"):
        out = [_to_tilde(p, home) for p in out]
    return out
