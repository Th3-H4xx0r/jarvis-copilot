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
    # Through a symlink (dotfiles managers), never over it: the link stays and
    # its target gets the change.
    path = os.path.realpath(path)
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


# ---------------------------------------------------------------------------
# The other coding agents (after coucou's HookServer installers). Each keeps its
# hooks in its own file and shape; the rules are the same as Claude Code's:
# strict parse, foreign entries kept, dated backup, write only if unchanged.

def _hook(cmd: str, timeout: int, **extra) -> dict:
    return {"type": "command", "command": cmd, "timeout": timeout, **extra}


def _js_str(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


@dataclass
class _Agent:
    name: str
    rel_path: str
    kind: str          # "groups" (event -> matcher groups), "namespace", "file", "plugin"
    events: list       # [(file event, argv event or None, timeout, extra)]
    matcher: bool = True


_STATUS_MSG = {"statusMessage": "Waiting for your answer in Jarvis"}

OTHER_AGENTS = {
    "codex": _Agent("codex", ".codex/hooks.json", "groups", [
        ("SessionStart", None, 10, {}), ("UserPromptSubmit", None, 10, {}),
        ("PreToolUse", None, 10, {}), ("PermissionRequest", None, 120, _STATUS_MSG),
        ("PostToolUse", None, 10, {}), ("Stop", None, 10, {}),
        ("SubagentStart", None, 10, {}), ("SubagentStop", None, 10, {}),
        ("Interrupt", None, 3, {}), ("SessionEnd", None, 3, {}),
    ], matcher=False),
    # Timeouts in milliseconds. AfterModel fires once per streamed chunk: left out.
    "gemini": _Agent("gemini", ".gemini/settings.json", "groups", [
        ("SessionStart", "SessionStart", 10000, {}), ("SessionEnd", "SessionEnd", 10000, {}),
        ("BeforeTool", "PreToolUse", 5000, {}), ("AfterTool", "PostToolUse", 5000, {}),
        ("BeforeAgent", "UserPromptSubmit", 5000, {}), ("AfterAgent", "Stop", 5000, {}),
    ]),
    "muse": _Agent("muse", ".config/muse/settings.json", "groups", [
        (e, e, t * 1000, {}) for e, t in (
            ("SessionStart", 10), ("UserPromptSubmit", 5), ("PreToolUse", 5),
            ("PermissionRequest", 120), ("PostToolUse", 5), ("Stop", 5), ("SessionEnd", 3))
    ]),
    "antigravity": _Agent("antigravity", ".gemini/config/hooks.json", "namespace", [
        (e, e, 10, {}) for e in ("PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop")
    ]),
    "copilot": _Agent("copilot", ".copilot/hooks/jarvis.json", "file", [
        (e, e, t, {}) for e, t in (
            ("sessionStart", 10), ("userPromptSubmitted", 10), ("preToolUse", 10),
            ("permissionRequest", 120), ("postToolUse", 10), ("agentStop", 10),
            ("sessionEnd", 3), ("notification", 10))
    ]),
    "opencode": _Agent("opencode", ".config/opencode/plugins/jarvis.js", "plugin", []),
    "amp": _Agent("amp", ".config/amp/plugins/jarvis.ts", "plugin", []),
}
NAMESPACE = "jarvis"


def _home(home: Optional[str]) -> str:
    return home or os.path.expanduser("~")


def agent_path(agent: str, home: Optional[str] = None) -> str:
    return os.path.join(_home(home), OTHER_AGENTS[agent].rel_path)


def _opencode_plugin(python: str, script: str) -> str:
    return f"""// Jarvis hook plugin for OpenCode, written by jc-client (`jc-client hooks uninstall --agent opencode`).
// Forwards every event to jc-hook: fire-and-forget, never blocks OpenCode.
import {{ spawn }} from 'node:child_process';

const PY = {_js_str(python)};
const HOOK = {_js_str(script)};
const EVENT_MAP = {{
  'session.created': 'SessionStart',
  'session.idle': 'Stop',
  'session.error': 'StopFailure',
  'session.deleted': 'SessionEnd',
  'permission.asked': 'PermissionRequest',
}};

function forward(hook_event_name, payload) {{
  try {{
    const p = spawn(PY, ['-I', HOOK, '--agent', 'opencode'],
                    {{ stdio: ['pipe', 'ignore', 'ignore'], detached: true }});
    p.on('error', () => {{}});
    p.stdin.on('error', () => {{}});
    p.stdin.write(JSON.stringify({{ hook_event_name, ...payload }}) + '\\n');
    p.stdin.end();
    p.unref();
  }} catch (_) {{}}
}}

export const JarvisPlugin = async (_ctx) => ({{
  event: async ({{ event }}) => {{
    const hook_event_name = EVENT_MAP[event.type];
    if (!hook_event_name) return;
    const props = event.properties || {{}};
    const payload = {{
      session_id: event.sessionID || event.session_id || props.sessionID || props.session_id || '',
      cwd: event.cwd || event.directory || props.cwd || props.directory || '',
    }};
    if (typeof props.tool === 'string') payload.tool_name = props.tool;
    if (props.input != null) payload.tool_input = props.input;
    forward(hook_event_name, payload);
  }},
  'tool.execute.before': async (input) => {{
    forward('PreToolUse', {{
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
      tool_input: input.input ?? null,
    }});
  }},
  'tool.execute.after': async (input, _output) => {{
    forward('PostToolUse', {{
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
    }});
  }},
}});
"""


def _amp_plugin(python: str, script: str) -> str:
    return f"""// Jarvis hook plugin for Amp, written by jc-client (`jc-client hooks uninstall --agent amp`).
// Display only: forwards events to jc-hook and always lets the tool run.
import {{ spawn }} from 'node:child_process';
import type {{ Writable }} from 'node:stream';

const PY = {_js_str(python)};
const HOOK = {_js_str(script)};

function forward(event_name: string, fields: Record<string, unknown>): void {{
  try {{
    const p = spawn(PY, ['-I', HOOK, '--agent', 'amp'],
                    {{ stdio: ['pipe', 'ignore', 'ignore'], detached: true }});
    p.on('error', () => {{}});
    const stdin = p.stdin as Writable;
    stdin.on('error', () => {{}});
    stdin.write(JSON.stringify({{ hook_event_name: event_name, ...fields }}) + '\\n');
    stdin.end();
    p.unref();
  }} catch (_) {{}}
}}

export default function (amp: any): void {{
  amp.on('session.start', (e: any) => {{ forward('SessionStart',     {{ session_id: e.thread?.id ?? '' }}); }});
  amp.on('agent.start',   (e: any) => {{ forward('UserPromptSubmit', {{ session_id: e.thread?.id ?? '' }}); }});
  amp.on('tool.call',     (e: any) => {{ try {{ forward('PreToolUse', {{ session_id: e.thread?.id ?? '', tool_name: typeof e.tool === 'string' ? e.tool : '' }}); }} finally {{ return {{ action: 'allow' }}; }} }});
  amp.on('tool.result',   (e: any) => {{ forward('PostToolUse',      {{ session_id: e.thread?.id ?? '' }}); }});
  amp.on('agent.end',     (e: any) => {{ forward('Stop',             {{ session_id: e.thread?.id ?? '' }}); }});
}}
"""


def _agent_new_bytes(a: _Agent, path: str, cmd: str, python: str, script: str):
    """(original bytes or None, new bytes or None to delete) for installing."""
    if a.kind == "plugin":
        try:
            with open(path, "rb") as f:
                original = f.read()
        except FileNotFoundError:
            original = None
        body = _opencode_plugin(python, script) if a.name == "opencode" else _amp_plugin(python, script)
        return original, body.encode()
    original, obj = _read(path)
    base = f"{cmd} --agent {a.name}"
    if a.kind == "file":
        hooks = {}
        for event, argv_event, timeout, _ in a.events:
            hooks[event] = [{"type": "command", "bash": f"{base} {argv_event}", "timeoutSec": timeout}]
        return original, _dumps({"version": 1, "hooks": hooks})
    if a.kind == "namespace":
        ours = {}
        for event, argv_event, timeout, _ in a.events:
            h = _hook(f"{base} {argv_event}", timeout)
            ours[event] = [{"matcher": "*", "hooks": [h]}] if event in ("PreToolUse", "PostToolUse") else [h]
        new = dict(obj)
        new[NAMESPACE] = ours
        return original, _dumps(new)
    hooks = _hooks(obj, path)
    new_hooks = {e: [g for g in groups if not _is_ours(g)] for e, groups in hooks.items()}
    for event, argv_event, timeout, extra in a.events:
        h = _hook(f"{base} {argv_event}" if argv_event else base, timeout, **extra)
        group = {"matcher": "*", "hooks": [h]} if a.matcher else {"hooks": [h]}
        new_hooks.setdefault(event, []).append(group)
    new = dict(obj)
    new["hooks"] = {e: g for e, g in new_hooks.items() if g}
    if a.name == "muse" and original is None:
        new.setdefault("schema_version", 1)
    return original, _dumps(new)


def agent_preview(agent: str, cmd: str, home: Optional[str] = None,
                  python: str = "", script: str = "") -> Preview:
    a = OTHER_AGENTS[agent]
    path = agent_path(agent, home)
    original, data = _agent_new_bytes(a, path, cmd, python, script)
    return Preview(new_bytes=data, original=original, diff=_diff(original, data, path),
                   previous_statusline=None, bin_dir="")


def install_agent(agent: str, cmd: str, home: Optional[str] = None,
                  python: str = "", script: str = "", pv: Optional[Preview] = None) -> bool:
    """Write the agent's hooks (the preview's bytes if given). True if anything changed."""
    path = agent_path(agent, home)
    pv = pv or agent_preview(agent, cmd, home, python, script)
    if pv.new_bytes == pv.original:
        return False
    _write(path, pv.new_bytes, pv.original)
    return True


def uninstall_agent(agent: str, home: Optional[str] = None) -> bool:
    a = OTHER_AGENTS[agent]
    path = agent_path(agent, home)
    if a.kind in ("plugin", "file"):
        try:
            with open(path, "rb") as f:
                if MARKER.encode() not in f.read():
                    return False
            os.unlink(path)
            return True
        except FileNotFoundError:
            return False
    original, obj = _read(path)
    if original is None:
        return False
    new = dict(obj)
    if a.kind == "namespace":
        new.pop(NAMESPACE, None)
    else:
        hooks = _without_ours(_hooks(obj, path))
        if hooks:
            new["hooks"] = hooks
        else:
            new.pop("hooks", None)
    data = _dumps(new)
    if data == original:
        return False
    _write(path, data, original)
    return True


def agent_status(agent: str, home: Optional[str] = None) -> dict:
    a = OTHER_AGENTS[agent]
    path = agent_path(agent, home)
    out = {"agent": agent, "path": path, "installed": False}
    try:
        if a.kind in ("plugin", "file"):
            with open(path, "rb") as f:
                out["installed"] = MARKER.encode() in f.read()
            return out
        _, obj = _read(path)
        if a.kind == "namespace":
            out["installed"] = MARKER in json.dumps(obj.get(NAMESPACE) or {})
        else:
            hooks = _hooks(obj, path)
            out["installed"] = any(_is_ours(g) for groups in hooks.values() for g in groups)
    except FileNotFoundError:
        pass
    except SettingsShape as exc:
        out["error"] = str(exc)
    return out
