"""Parse a Codex CLI rollout (``~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl``)
into the SAME chat-message list the Claude transcript reader produces
(agent/coding_transcript_read.py), so the coding chat UIs render a Codex
session without branching:

    {"i": int, "role": "user"|"assistant", "text": str,
     "tools": [{"name", "summary", "output", "ok", "diff"?}], "ts": float|None}

Rollout lines are ``{"timestamp", "type", "payload"}``. Codex 0.14x–0.163
writes each turn twice: model-level ``response_item`` lines (messages,
``function_call``/``custom_tool_call`` + ``*_output`` joined by ``call_id``)
and UI-level ``event_msg``/``item_completed`` items (UserMessage,
AgentMessage, CommandExecution, FileChange, McpToolCall, ...). A rollout
with any ``item_completed`` line is read from those items alone (clean user
text, commands with their output, real diffs); one without falls back to the
response items. Tools take the Claude names the UIs already know: a shell
command is ``Bash``, an edited file ``Edit``, a new file ``Write``, an MCP
call ``mcp__<server>__<tool>``.
"""
from __future__ import annotations

import json
import os
import shlex
from pathlib import Path
from typing import Optional

from agent.coding_transcript_read import (_DIFF_CAP, _DIFF_LINE_MAX, MAX_TEXT,
                                          MAX_TOOL_OUTPUT, _clip, _iso_ts,
                                          _tool_summary, slice_messages)

_SHELLS = ("bash", "zsh", "sh")
_SHELL_TOOLS = ("exec_command", "shell", "local_shell", "container.exec", "exec")
_ENVELOPE_PREFIXES = ("<", "# AGENTS.md instructions")


def _is_envelope(text: str) -> bool:
    """Harness text injected as a 'user' message (AGENTS.md, environment
    context, task notifications, slash-command echoes) — never chat."""
    return not text or text.startswith(_ENVELOPE_PREFIXES)


def _command_text(cmd) -> str:
    """The script a CommandExecution ran, without the ``zsh -lc`` wrapper."""
    if isinstance(cmd, str):
        try:
            cmd = shlex.split(cmd)
        except ValueError:
            return cmd
    if not isinstance(cmd, list):
        return ""
    argv = [str(a) for a in cmd]
    if (len(argv) == 3 and os.path.basename(argv[0]) in _SHELLS
            and argv[1] in ("-lc", "-c")):
        return argv[2]
    return shlex.join(argv)


def _summary(text: str) -> str:
    text = (text or "").strip()
    return _clip(text.splitlines()[0], 160) if text else ""


def _cap_diff(lines: list[str]) -> list[str]:
    out = [ln[:_DIFF_LINE_MAX] for ln in lines[:_DIFF_CAP]]
    if len(lines) > _DIFF_CAP:
        out.append(f"… +{len(lines) - _DIFF_CAP} more lines")
    return out


def _unified_lines(diff: str) -> list[str]:
    return _cap_diff([ln for ln in (diff or "").splitlines()
                      if not ln.startswith(("---", "+++"))])


def _blocks_text(blocks, kinds=("text", "Text", "input_text", "output_text")) -> str:
    """Joined text of a content-block list (anything else is malformed)."""
    if not isinstance(blocks, list):
        return ""
    return "\n".join(str(b.get("text") or "") for b in blocks
                     if isinstance(b, dict) and b.get("type") in kinds
                     and b.get("text"))


def _file_change_tools(item: dict) -> list[dict]:
    """One Edit/Write row per file a FileChange touched (rollouts store a
    {path: change} map; the live protocol a [{path, kind, diff}] list)."""
    changes = item.get("changes")
    if isinstance(changes, list):
        changes = {str(c.get("path") or ""): {
            "type": (c.get("kind") or {}).get("type") if isinstance(c.get("kind"), dict)
            else c.get("kind"), "unified_diff": c.get("diff")}
            for c in changes if isinstance(c, dict)}
    if not isinstance(changes, dict):
        return []
    ok = None if item.get("status") in (None, "inProgress") else item.get("status") == "completed"
    out = []
    for path, ch in changes.items():
        if not isinstance(ch, dict):
            continue
        kind = ch.get("type")
        if kind == "add":
            name, diff = "Write", _cap_diff(
                ["+" + ln for ln in str(ch.get("content") or "").splitlines()])
        elif kind == "delete":
            name, diff = "Edit", _cap_diff(
                ["-" + ln for ln in str(ch.get("content") or "").splitlines()])
        else:
            name, diff = "Edit", _unified_lines(str(ch.get("unified_diff") or ""))
        tool = {"name": name, "summary": _clip(str(path), 160),
                "output": _clip(str(item.get("stderr") or ""), MAX_TOOL_OUTPUT),
                "ok": ok}
        if diff:
            tool["diff"] = diff
        out.append(tool)
    return out


def _item_tools(item: dict) -> list[dict]:
    t = item.get("type")
    if t == "CommandExecution":
        code = item.get("exit_code")
        ok = (code == 0) if isinstance(code, int) else (
            None if item.get("status") == "inProgress" else item.get("status") == "completed")
        out = item.get("aggregated_output") or item.get("formatted_output") or item.get("stdout")
        return [{"name": "Bash", "summary": _summary(_command_text(item.get("command"))),
                 "output": _clip(str(out or ""), MAX_TOOL_OUTPUT), "ok": ok}]
    if t == "FileChange":
        return _file_change_tools(item)
    if t == "McpToolCall":
        res = item.get("result")
        text = _blocks_text(res.get("content")) if isinstance(res, dict) else str(res or "")
        err = item.get("error")
        return [{"name": f"mcp__{item.get('server') or 'mcp'}__{item.get('tool') or 'tool'}",
                 "summary": _tool_summary("", item.get("arguments")),
                 "output": _clip(str(err) if err else text, MAX_TOOL_OUTPUT),
                 "ok": not err and item.get("status") != "failed"}]
    if t == "WebSearch":
        return [{"name": "WebSearch", "summary": _summary(str(item.get("query") or "")),
                 "output": "", "ok": True}]
    if t == "ImageView":
        return [{"name": "Read", "summary": _summary(str(item.get("path") or "")),
                 "output": "", "ok": True}]
    return []


def _patch_tool(patch: str) -> dict:
    """An apply_patch envelope → an Edit/Write row with its +/- lines."""
    path, name, body = "", "Edit", []
    for ln in (patch or "").splitlines():
        for marker, kind in (("*** Update File: ", "Edit"), ("*** Add File: ", "Write"),
                             ("*** Delete File: ", "Edit")):
            if ln.startswith(marker):
                if not path:
                    path, name = ln[len(marker):].strip(), kind
                break
        else:
            if ln.startswith(("+", "-")) or (ln.startswith("@@") and body):
                body.append(ln)
    tool = {"name": name, "summary": _clip(path, 160), "output": "", "ok": None}
    if body:
        tool["diff"] = _cap_diff(body)
    return tool


def _response_tool(p: dict) -> dict:
    name = str(p.get("name") or "tool")
    if p.get("type") == "custom_tool_call" and name == "apply_patch":
        return _patch_tool(str(p.get("input") or ""))
    raw = p.get("arguments") if p.get("type") == "function_call" else p.get("input")
    args = raw
    if isinstance(raw, str):
        try:
            args = json.loads(raw)
        except ValueError:
            args = raw
    if name in _SHELL_TOOLS:
        cmd = args.get("cmd") or args.get("command") if isinstance(args, dict) else args
        return {"name": "Bash", "summary": _summary(
            _command_text(cmd) if isinstance(cmd, list) else str(cmd or "")),
            "output": "", "ok": None}
    ns = p.get("namespace")
    full = f"{ns}__{name}" if isinstance(ns, str) and ns.startswith("mcp__") else name
    return {"name": full, "summary": _tool_summary(full, args), "output": "", "ok": None}


def _output_ok(output) -> Optional[bool]:
    """Exit status from a tool output when it carries one (older rollouts
    wrap shell output as {"output", "metadata": {"exit_code"}})."""
    if isinstance(output, str):
        try:
            meta = json.loads(output).get("metadata") or {}
            code = meta.get("exit_code")
            return code == 0 if isinstance(code, int) else True
        except (ValueError, AttributeError):
            return True
    return True


def _output_text(output) -> str:
    if isinstance(output, str):
        try:
            d = json.loads(output)
            if isinstance(d, dict) and isinstance(d.get("output"), str):
                output = d["output"]
        except ValueError:
            pass
        return _clip(output, MAX_TOOL_OUTPUT)
    return _clip(_blocks_text(output), MAX_TOOL_OUTPUT)


def _parse(text: str) -> tuple[list[dict], dict | None]:
    """(messages, context gauge) from rollout JSONL."""
    rows = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict) and isinstance(d.get("payload"), dict):
            rows.append(d)
    items_mode = any(r.get("type") == "event_msg"
                     and r["payload"].get("type") == "item_completed" for r in rows)

    out: list[dict] = []
    calls: dict[str, dict] = {}
    model, usage, window = "", None, 0

    def _assistant(ts) -> dict:
        if out and out[-1]["role"] == "assistant":
            return out[-1]
        m = {"i": len(out), "role": "assistant", "text": "", "tools": [], "ts": ts}
        out.append(m)
        return m

    def _say(role: str, txt: str, ts) -> None:
        txt = (txt or "").strip()
        if not txt:
            return
        if role == "user":
            out.append({"i": len(out), "role": "user", "text": _clip(txt, MAX_TEXT),
                        "tools": [], "ts": ts})
            return
        m = _assistant(ts)
        m["text"] = _clip((m["text"] + "\n\n" + txt).strip(), MAX_TEXT)

    for r in rows:
        typ, p, ts = r.get("type"), r["payload"], _iso_ts(r.get("timestamp"))
        pt = p.get("type")
        if typ == "turn_context" and p.get("model"):
            model = str(p["model"])
            continue
        if typ == "event_msg" and pt == "token_count":
            info = p.get("info")
            if isinstance(info, dict) and isinstance(info.get("last_token_usage"), dict):
                usage = info["last_token_usage"]
                window = info.get("model_context_window") or window
            continue
        if items_mode:
            if not (typ == "event_msg" and pt == "item_completed"):
                continue
            item = p.get("item")
            if not isinstance(item, dict):
                continue
            it = item.get("type")
            if it == "UserMessage":
                txt = _blocks_text(item.get("content"))
                if not _is_envelope(txt.strip()):
                    _say("user", txt, ts)
            elif it == "AgentMessage":
                _say("assistant", _blocks_text(item.get("content")), ts)
            else:
                tools = _item_tools(item)
                if tools:
                    _assistant(ts)["tools"].extend(tools)
            continue
        if typ != "response_item":
            continue
        if pt == "message" and p.get("role") in ("user", "assistant"):
            txt = _blocks_text(p.get("content"))
            if p["role"] == "user" and _is_envelope(txt.strip()):
                continue
            _say(p["role"], txt, ts)
        elif pt in ("function_call", "custom_tool_call"):
            tool = _response_tool(p)
            _assistant(ts)["tools"].append(tool)
            if p.get("call_id"):
                calls[str(p["call_id"])] = tool
        elif pt in ("function_call_output", "custom_tool_call_output"):
            tool = calls.get(str(p.get("call_id") or ""))
            if tool is not None:
                tool["output"] = _output_text(p.get("output"))
                tool["ok"] = _output_ok(p.get("output"))

    ctx = None
    if usage is not None:
        try:
            used = int(usage.get("total_tokens") or 0) or (
                int(usage.get("input_tokens") or 0) + int(usage.get("output_tokens") or 0))
            win = int(window or 0)
            ctx = {"used": used, "window": win,
                   "pct": round(100 * used / win) if win else 0, "model": model}
        except (TypeError, ValueError):
            ctx = None
    return out, ctx


def parse_codex_rollout_text(text: str) -> list[dict]:
    """Rollout JSONL → the chat-message list (full, uncapped; each message
    carries its absolute index ``i``). Malformed lines are skipped."""
    return _parse(text)[0]


def read_codex_page(path: str, *, after: int | None = None,
                    before: int | None = None, limit: int = 50,
                    lite: bool = False) -> dict:
    """One page of a rollout as the Claude chat endpoint's envelope —
    ``{"messages", "total", "start", "context"}`` with slice_messages' paging
    (``after`` live tail, ``before`` page back, ``limit`` page size, ``lite``
    tools without output/diff). The context gauge uses Codex's own window
    and latest token count. Raises OSError when the file can't be read."""
    msgs, ctx = _parse(Path(path).read_text(errors="replace"))
    page = slice_messages(msgs, int(after or 0), before=before, limit=limit, lite=lite)
    page["context"] = ctx
    return page


def default_codex_home() -> Path:
    """``$CODEX_HOME`` or ``~/.codex`` (where Codex keeps auth + sessions)."""
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


def find_codex_rollout(session_id: str, codex_home: str | None = None) -> Path | None:
    """The rollout file for a Codex session/thread id (newest if several),
    under ``<codex_home>/sessions/YYYY/MM/DD/``; None when absent."""
    sid = (session_id or "").strip()
    if not sid or "/" in sid or "*" in sid:
        return None
    base = (Path(codex_home) if codex_home else default_codex_home()) / "sessions"
    try:
        hits = sorted(base.glob(f"*/*/*/rollout-*-{sid}.jsonl"))
    except OSError:
        return None
    return hits[-1] if hits else None
