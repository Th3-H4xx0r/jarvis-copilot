#!/usr/bin/env python3
"""jc-hook — the Jarvis relay coding agents run for every hook event.

Reads the hook JSON on stdin, adds where the session runs (terminal app, tab,
tmux), and hands it to jc-client over a UNIX socket as one JSON line:

    {"jc": 1, "kind": "event"|"permission"|"ask"|"statusline",
     "agent": "claude", "payload": {...}}

Ordinary events are fire-and-forget (0.3 s, then give up). A PermissionRequest
and the dedicated AskUserQuestion hook (``--ask``) wait for one reply line
``{"decision": "allow"|"deny"|"always"|"ask"|"answer", ...}`` and print the
hook output Claude Code expects. ``--statusline`` forwards ``rate_limits`` and
then runs the status line command that was there before ours — once: if that
command leads back to ``jc-hook --statusline`` (another status line tool saved
ours as its own previous one), the inner run does nothing, and on the deadline
everything the command started is killed with it.

Never blocks the agent: every failure path prints nothing (or the agent's
"ask" form) and exits 0. Standard library only, so ``python3 -I`` starts it
fast. Event-name and field normalisation follows coucou's nb-hook.py
(github.com/Louis-CFM/coucou, MIT).
"""
import json
import os
import signal
import socket
import subprocess
import sys

VERSION = 1
MAX_FRAME = 48 * 1024
FIRE_TIMEOUT = 0.3
PERMISSION_WAIT = 118.0
ASK_WAIT = 125.0
# Asking jc-client whether a phone message waits for this session's next step.
STOP_WAIT = 0.8
_STOP_DELIVERY_AGENTS = ("claude", "claude-desktop")
# The previous status line's deadline.
STATUSLINE_TIMEOUT = 10.0
# Set for the previous status line's process tree. Seeing it means our own
# --statusline runs inside that command, and chaining again would never end.
_IN_STATUSLINE_CHAIN = "JC_HOOK_IN_STATUSLINE"

_EVENT_NAMES = {
    "BeforeTool": "PreToolUse", "BeforeToolSelection": "PreToolUse",
    "AfterTool": "PostToolUse", "AfterModel": "PostToolUse",
    "BeforeAgent": "UserPromptSubmit", "AfterAgent": "Stop",
    "startup": "SessionStart", "exit": "SessionEnd",
    "PreInvocation": "UserPromptSubmit", "PostInvocation": "PostToolUse",
    "pre_tool_use": "PreToolUse", "post_tool_use": "PostToolUse",
    "user_prompt_submit": "UserPromptSubmit", "session_start": "SessionStart",
    "session_end": "SessionEnd", "stop": "Stop",
    "sessionStart": "SessionStart", "userPromptSubmitted": "UserPromptSubmit",
    "agentStop": "Stop", "notification": "Notification",
    "preToolUse": "PreToolUse", "postToolUse": "PostToolUse",
    "permissionRequest": "PermissionRequest", "sessionEnd": "SessionEnd",
}

# Agents whose hooks expect a JSON object on stdout even when nothing is decided.
_EMPTY_OBJECT_AGENTS = ("gemini", "antigravity", "muse", "copilot")
# Agents that read a flat {"permissionDecision": ...} instead of hookSpecificOutput.
_FLAT_DECISION_AGENTS = ("copilot", "muse")


def _previous_statusline_file():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "statusline-previous.json")


def _default_socket(env):
    home = env.get("HOME") or os.path.expanduser("~")
    return os.path.join(home, ".jarviscopilot-client", "hook.sock")


def _parse_args(argv):
    opts = {"socket": "", "agent": "", "event": "", "ask": False, "statusline": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--socket" and i + 1 < len(argv):
            opts["socket"] = argv[i + 1]
            i += 2
            continue
        if a == "--agent" and i + 1 < len(argv):
            opts["agent"] = argv[i + 1]
            i += 2
            continue
        if a == "--ask":
            opts["ask"] = True
        elif a == "--statusline":
            opts["statusline"] = True
        elif not a.startswith("--") and not opts["event"]:
            opts["event"] = a
        i += 1
    return opts


def _normalize(payload):
    """Map other agents' field names onto Claude Code's (coucou normalize_tool_fields)."""
    if "tool_name" not in payload:
        if payload.get("toolName"):
            payload["tool_name"] = payload["toolName"]
        else:
            call = payload.get("toolCall") if isinstance(payload.get("toolCall"), dict) else {}
            name = call.get("name") or payload.get("tool") or ""
            if name:
                payload["tool_name"] = name
    if "tool_input" not in payload:
        args = payload.get("toolArgs")
        if isinstance(args, dict):
            payload["tool_input"] = args
        else:
            call = payload.get("toolCall") if isinstance(payload.get("toolCall"), dict) else {}
            if isinstance(call.get("args"), dict):
                flat = dict(call["args"])
                for src, dst in (("CommandLine", "command"), ("FilePath", "file_path"),
                                 ("Path", "path"), ("Url", "url"), ("Query", "query"),
                                 ("Pattern", "pattern")):
                    if src in flat:
                        flat[dst] = flat[src]
                payload["tool_input"] = flat
    if not payload.get("session_id"):
        for key in ("conversationId", "conversation_id", "sessionId"):
            if payload.get(key):
                payload["session_id"] = payload[key]
                break
    if not payload.get("cwd") and payload.get("workdir"):
        payload["cwd"] = payload["workdir"]


def _tmux_session(env):
    pane = env.get("TMUX_PANE") or ""
    if not env.get("TMUX") or not pane:
        return ""
    try:
        out = subprocess.run(["tmux", "display-message", "-p", "-t", pane, "#S"],
                             capture_output=True, text=True, timeout=0.3)
        return out.stdout.strip()
    except Exception:
        return ""


def _add_context(payload, env, event):
    payload.setdefault("term_program", env.get("TERM_PROGRAM", ""))
    payload.setdefault("bundle_id", env.get("__CFBundleIdentifier", ""))
    payload.setdefault("iterm_session_id", env.get("ITERM_SESSION_ID", ""))
    payload.setdefault("term_session_id", env.get("TERM_SESSION_ID", ""))
    payload.setdefault("tmux_pane", env.get("TMUX_PANE", ""))
    # Tool events fire many times a turn; the terminal can't change mid-turn,
    # so only the turn-level events pay for the tmux lookup.
    if event not in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
        payload.setdefault("tmux_session", _tmux_session(env))
    payload.setdefault("entrypoint", env.get("CLAUDE_CODE_ENTRYPOINT", ""))
    if not payload.get("cwd"):
        roots = payload.get("workspacePaths") or payload.get("workspace_roots")
        if isinstance(roots, list) and roots:
            payload["cwd"] = roots[0]
        else:
            payload["cwd"] = os.getcwd()


# What a trimmed event keeps whole: who sent it, what happened, to which tool.
_KEEP = ("hook_event_name", "session_id", "cwd", "tool_name", "tool_use_id", "transcript_path",
         "permission_mode", "jc_agent", "notification_type", "model")


def _cap(node, n, k):
    """``node`` with every string cut to ``n`` chars and every list to ``k`` items."""
    if isinstance(node, str):
        return node if len(node) <= n else node[:n] + "…"
    if isinstance(node, list):
        out = [_cap(v, n, k) for v in node[:k]]
        if len(node) > k:
            out.append(f"…{len(node) - k} more")
        return out
    if isinstance(node, dict):
        out = {}
        for i, (key, v) in enumerate(node.items()):
            if i >= k:
                out["…"] = f"{len(node) - k} more"
                break
            out[key if not isinstance(key, str) or len(key) <= 80 else key[:80] + "…"] = _cap(v, n, k)
        return out
    return node


def _longest(node) -> int:
    if isinstance(node, str):
        return len(node)
    items = node.values() if isinstance(node, dict) else node if isinstance(node, list) else ()
    return max((_longest(v) for v in items), default=0)


def _widest(node) -> int:
    if isinstance(node, (list, dict)):
        items = node.values() if isinstance(node, dict) else node
        return max([len(node)] + [_widest(v) for v in items])
    return 0


def _fits(frame, payload):
    text = json.dumps(dict(frame, payload=payload))
    return text if len(text) < MAX_FRAME else None


def _search(lo, hi, make):
    """The largest value in [lo, hi] whose frame fits, with its text (or None)."""
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        text = make(mid)
        if text is not None:
            best, lo = text, mid + 1
        else:
            hi = mid - 1
    return best


def _trim(frame):
    """The frame as JSON under MAX_FRAME. Long strings are cut first (a binary
    search on one cap for all of them, so a few big ones go and small ones
    stay), then long lists and dicts, then whole non-essential fields."""
    text = json.dumps(frame)
    if len(text) < MAX_FRAME:
        return text
    payload = dict(frame["payload"], jc_trimmed=True)
    wide = 10 ** 9
    best = _search(32, max(32, _longest(payload)), lambda n: _fits(frame, _cap(payload, n, wide)))
    if best is not None:
        return best
    best = _search(1, max(1, _widest(payload)), lambda k: _fits(frame, _cap(payload, 32, k)))
    if best is not None:
        return best
    slim = {key: payload[key] for key in _KEEP if key in payload}
    slim["jc_trimmed"] = True
    return _fits(frame, _cap(slim, 200, 20)) or json.dumps(dict(frame, payload={"jc_trimmed": True}))


def _send(sock_path, frame, wait):
    """Send one frame; with ``wait`` read one reply line. None on any failure."""
    line = (_trim(frame) + "\n").encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(FIRE_TIMEOUT)
        s.connect(sock_path)
        s.sendall(line)
        if not wait:
            return None
        s.settimeout(wait)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        text = buf.split(b"\n", 1)[0].decode("utf-8", "replace").strip()
        if not text:
            return None
        reply = json.loads(text)
        return reply if isinstance(reply, dict) else None
    except Exception:
        return None
    finally:
        try:
            s.close()
        except Exception:
            pass


def _permission_output(agent, reply, payload):
    decision = (reply or {}).get("decision", "")
    if agent in _FLAT_DECISION_AGENTS:
        if decision in ("allow", "always"):
            return {"permissionDecision": "allow"}
        if decision == "deny":
            return {"permissionDecision": "deny"}
        return {"permissionDecision": "ask"} if agent == "copilot" else None
    if decision == "allow" or (decision == "always" and agent == "codex"):
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                       "decision": {"behavior": "allow"}}}
    if decision == "always":
        rules = reply.get("updated_permissions")
        if not isinstance(rules, list):
            rules = payload.get("permission_suggestions") or []
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                       "decision": {"behavior": "allow",
                                                    "updatedPermissions": rules}}}
    if decision == "deny":
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                       "decision": {"behavior": "deny",
                                                    "message": reply.get("message") or "Denied from Jarvis"}}}
    if decision == "answer":
        questions = (payload.get("tool_input") or {}).get("questions", [])
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                       "decision": {"behavior": "allow", "updatedInput": {
                                           "questions": questions,
                                           "answers": reply.get("answers") or {}}}}}
    return None


def _run_previous_statusline(raw, env):
    try:
        with open(_previous_statusline_file()) as f:
            cmd = (json.load(f) or {}).get("command", "")
    except Exception:
        return ""
    if not cmd:
        return ""
    child_env = dict(os.environ)
    child_env.update(env)
    child_env[_IN_STATUSLINE_CHAIN] = "1"
    try:
        # Its own process group: killing only the shell would leave whatever it
        # started running on its own after we gave up.
        proc = subprocess.Popen(["/bin/sh", "-c", cmd], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=child_env, start_new_session=True)
    except Exception:
        return ""
    try:
        out, _ = proc.communicate(raw, timeout=STATUSLINE_TIMEOUT)
        return out.decode("utf-8", "replace")
    except Exception:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=1)
        except Exception:
            pass
        return ""


def main(argv, raw, env):
    """Pure entry point: returns (stdout_text, exit_code). Never raises."""
    try:
        return _main(argv, raw, env)
    except Exception:
        return ("", 0)


def _main(argv, raw, env):
    opts = _parse_args(list(argv))
    sock_path = opts["socket"] or env.get("JC_HOOK_SOCKET") or _default_socket(env)
    agent = opts["agent"] or ("claude-desktop" if env.get("CLAUDE_CODE_ENTRYPOINT") == "claude-desktop"
                              else "claude")

    payload = {}
    if raw:
        try:
            payload = json.loads(raw)
        except Exception:
            payload = None
    if not isinstance(payload, dict):
        return ("", 0)

    if opts["statusline"]:
        if env.get(_IN_STATUSLINE_CHAIN):
            # The outer run already forwarded this frame and prints the output.
            return ("", 0)
        frame = {"jc": VERSION, "kind": "statusline", "agent": agent, "payload": {
            "session_id": payload.get("session_id", ""),
            "rate_limits": payload.get("rate_limits") or {},
            "model": payload.get("model"),
            "cwd": payload.get("cwd") or (payload.get("workspace") or {}).get("current_dir", ""),
        }}
        _send(sock_path, frame, wait=0)
        return (_run_previous_statusline(raw, env), 0)

    # An empty body still counts when the event comes from argv (Copilot's
    # fail-closed permissionRequest must answer "ask" even then).
    if not payload and not opts["event"]:
        return ("", 0)

    if opts["ask"]:
        if payload.get("tool_name") != "AskUserQuestion":
            return ("", 0)
        _add_context(payload, env, "PreToolUse")
        reply = _send(sock_path, {"jc": VERSION, "kind": "ask", "agent": agent,
                                  "payload": payload}, wait=ASK_WAIT)
        if (reply or {}).get("decision") != "answer":
            return ("", 0)
        questions = (payload.get("tool_input") or {}).get("questions", [])
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "allow",
                                      "updatedInput": {"questions": questions,
                                                       "answers": reply.get("answers") or {}}}}
        return (json.dumps(out), 0)

    event = payload.get("hook_event_name") or opts["event"]
    if event:
        payload["hook_event_name"] = _EVENT_NAMES.get(event, event)
    event = payload.get("hook_event_name", "")
    _normalize(payload)
    _add_context(payload, env, event)
    payload["jc_agent"] = agent

    if event == "PermissionRequest":
        reply = _send(sock_path, {"jc": VERSION, "kind": "permission", "agent": agent,
                                  "payload": payload}, wait=PERMISSION_WAIT)
        out = _permission_output(agent, reply, payload)
        return (json.dumps(out) if out is not None else "", 0)

    if event == "Stop" and agent in _STOP_DELIVERY_AGENTS:
        # A message from the phone may be waiting for this session's next step:
        # answering the Stop hook with decision "block" makes Claude carry on
        # with it, in the same window.
        reply = _send(sock_path, {"jc": VERSION, "kind": "stop", "agent": agent, "payload": payload},
                      wait=STOP_WAIT)
        if isinstance(reply, dict) and reply.get("decision") == "block" and reply.get("reason"):
            return (json.dumps({"decision": "block", "reason": str(reply["reason"])}), 0)
        return ("", 0)

    _send(sock_path, {"jc": VERSION, "kind": "event", "agent": agent, "payload": payload}, wait=0)
    if agent == "antigravity" and event == "PreToolUse":
        return (json.dumps({"decision": "ask"}), 0)
    if agent in _EMPTY_OBJECT_AGENTS:
        return ("{}", 0)
    return ("", 0)


if __name__ == "__main__":
    data = b""
    try:
        data = sys.stdin.buffer.read()
    except Exception:
        pass
    text, code = main(sys.argv[1:], data, dict(os.environ))
    if text:
        sys.stdout.write(text + ("" if text.endswith("\n") else "\n"))
        sys.stdout.flush()
    sys.exit(0)
