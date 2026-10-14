"""Install the jc-hook relay into an agent's settings (Claude Code first).

``~/.claude/settings.json`` belongs to the user, so the rules are strict
(after coucou's ClaudeSettingsFile, github.com/Louis-CFM/coucou, MIT):

* an unreadable file or a ``hooks`` value of a shape we don't know is refused,
  never treated as empty;
* only entries whose command runs ``jc-hook`` are ours — everything else is
  kept exactly;
* ``install`` writes only the bytes ``preview`` showed, and only if the file
  still holds what the preview was computed from; a dated backup comes first;
* the user's own status line keeps running underneath ours (its command is
  saved next to the relay and re-run by ``jc-hook --statusline``).

Standard library only, so the server can load this file by path too.
"""
from __future__ import annotations

import difflib
import json
import os
import shutil
import stat
import time
from dataclasses import dataclass
from typing import Optional

MARKER = "jc-hook"
CLAUDE_EVENTS = [
    ("SessionStart", 10), ("SessionEnd", 10), ("UserPromptSubmit", 10),
    ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
    ("PermissionRequest", 120), ("Notification", 10), ("Stop", 10),
    ("StopFailure", 10), ("SubagentStart", 10), ("SubagentStop", 10),
    ("PreCompact", 10), ("PostCompact", 10),
]
ASK_TIMEOUT = 130
PREVIOUS_STATUSLINE = "statusline-previous.json"
_RELAY_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hook_relay", "jc_hook.py")


class SettingsShape(ValueError):
    """The settings file isn't JSON we understand; nothing was changed."""


class SettingsChanged(RuntimeError):
    """The settings file changed after the preview; nothing was written."""


@dataclass
class Preview:
    new_bytes: bytes
    original: Optional[bytes]
    diff: str
    previous_statusline: Optional[dict]
    bin_dir: str


def default_settings_path() -> str:
    return os.path.join(os.path.expanduser("~"), ".claude", "settings.json")


def command_base(python: str, script: str, socket: Optional[str] = None) -> str:
    cmd = f'"{python}" -I "{script}"'
    if socket:
        cmd += f' --socket "{socket}"'
    return cmd


def install_script(bin_dir: str) -> str:
    """Copy the relay next to the settings it serves; returns its path."""
    os.makedirs(bin_dir, exist_ok=True)
    dest = os.path.join(bin_dir, "jc-hook")
    tmp = dest + ".tmp"
    shutil.copyfile(_RELAY_SOURCE, tmp)
    os.chmod(tmp, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
    os.replace(tmp, dest)
    return dest


def _read(path: str):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return None, {}
    if not raw.strip():
        return raw, {}
    try:
        obj = json.loads(raw)
    except ValueError as exc:
        raise SettingsShape(f"{path} is not valid JSON ({exc}); not touched") from exc
    if not isinstance(obj, dict):
        raise SettingsShape(f"{path} is not a JSON object; not touched")
    return raw, obj


def _hooks(obj: dict, path: str) -> dict:
    hooks = obj.get("hooks", {})
    if not isinstance(hooks, dict):
        raise SettingsShape(f'{path}: "hooks" has an unexpected type; not touched')
    for event, groups in hooks.items():
        if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
            raise SettingsShape(f'{path}: "hooks.{event}" has an unexpected type; not touched')
    return hooks


def _is_ours(group: dict) -> bool:
    return any(MARKER in str(h.get("command") or "")
               for h in (group.get("hooks") or []) if isinstance(h, dict))


def _without_ours(hooks: dict) -> dict:
    out = {}
    for event, groups in hooks.items():
        kept = [g for g in groups if not _is_ours(g)]
        if kept:
            out[event] = kept
    return out


def _dumps(obj: dict) -> bytes:
    return (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode()


def _diff(old: Optional[bytes], new: bytes, path: str) -> str:
    a = (old or b"").decode("utf-8", "replace").splitlines()
    b = new.decode("utf-8", "replace").splitlines()
    return "\n".join(difflib.unified_diff(a, b, fromfile=path, tofile=path + " (new)", lineterm=""))


def _previous_file(bin_dir: str) -> str:
    return os.path.join(bin_dir, PREVIOUS_STATUSLINE)


def preview(settings_path: str, cmd: str, bin_dir: str, statusline: bool = True) -> Preview:
    original, obj = _read(settings_path)
    hooks = _without_ours(_hooks(obj, settings_path))
    for event, timeout in CLAUDE_EVENTS:
        hooks.setdefault(event, []).append(
            {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]})
    hooks["PreToolUse"].append({"matcher": "AskUserQuestion", "hooks": [
        {"type": "command", "command": cmd + " --ask", "timeout": ASK_TIMEOUT}]})
    new = dict(obj)
    new["hooks"] = hooks
    previous = None
    if statusline:
        current = obj.get("statusLine")
        if isinstance(current, dict) and MARKER not in str(current.get("command") or ""):
            previous = dict(current)
            updated = dict(current)
            updated["command"] = cmd + " --statusline"
            updated.setdefault("type", "command")
            new["statusLine"] = updated
        elif isinstance(current, dict):
            updated = dict(current)
            updated["command"] = cmd + " --statusline"
            new["statusLine"] = updated
        else:
            new["statusLine"] = {"type": "command", "command": cmd + " --statusline"}
    data = _dumps(new)
    return Preview(new_bytes=data, original=original, diff=_diff(original, data, settings_path),
                   previous_statusline=previous, bin_dir=bin_dir)


def _write(path: str, data: bytes, original: Optional[bytes]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path, "rb") as f:
            current = f.read()
    except FileNotFoundError:
        current = None
    if current != original:
        raise SettingsChanged(f"{path} changed since the preview; nothing written")
    if current is not None:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        backup = f"{path}.jc-backup-{stamp}"
        n = 1
        while os.path.exists(backup):
            n += 1
            backup = f"{path}.jc-backup-{stamp}-{n}"
        with open(backup, "wb") as f:
            f.write(current)
    mode = stat.S_IMODE(os.stat(path).st_mode) if current is not None else 0o600
    tmp = path + ".jc-tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def install(settings_path: str, pv: Preview) -> None:
    if pv.new_bytes == pv.original:
        return
    _write(settings_path, pv.new_bytes, pv.original)
    if pv.previous_statusline is not None:
        os.makedirs(pv.bin_dir, exist_ok=True)
        with open(_previous_file(pv.bin_dir), "w") as f:
            json.dump(pv.previous_statusline, f, indent=2)


def uninstall(settings_path: str, bin_dir: str) -> bool:
    """Remove our hook entries; put the user's own status line back. True if changed."""
    original, obj = _read(settings_path)
    if original is None:
        return False
    hooks = _without_ours(_hooks(obj, settings_path))
    new = dict(obj)
    if hooks:
        new["hooks"] = hooks
    else:
        new.pop("hooks", None)
    current = obj.get("statusLine")
    prev_path = _previous_file(bin_dir)
    restored = False
    if isinstance(current, dict) and MARKER in str(current.get("command") or ""):
        try:
            with open(prev_path) as f:
                new["statusLine"] = json.load(f)
            restored = True
        except (OSError, ValueError):
            new.pop("statusLine", None)
    data = _dumps(new)
    if data == original:
        return False
    _write(settings_path, data, original)
    if restored:
        try:
            os.unlink(prev_path)
        except OSError:
            pass
    return True


def status(settings_path: str) -> dict:
    try:
        _, obj = _read(settings_path)
        hooks = _hooks(obj, settings_path)
    except SettingsShape as exc:
        return {"installed": False, "outdated": False, "statusline": False, "error": str(exc)}
    ours = {event for event, groups in hooks.items() if any(_is_ours(g) for g in groups)}
    has_ask = any(g.get("matcher") == "AskUserQuestion" and _is_ours(g)
                  for g in hooks.get("PreToolUse", []))
    sl = obj.get("statusLine")
    installed = bool(ours)
    wanted = {event for event, _ in CLAUDE_EVENTS}
    return {"installed": installed,
            "outdated": installed and (not wanted <= ours or not has_ask),
            "statusline": isinstance(sl, dict) and MARKER in str(sl.get("command") or ""),
            "events": sorted(ours)}
