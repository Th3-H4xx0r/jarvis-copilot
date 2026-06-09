"""Parse a Claude Code transcript (``~/.claude/projects/<dir>/<csid>.jsonl``)
into a compact chat-message list for the mobile/web "chat" view of a coding
session.

The transcript is the canonical record of EVERY message (user text, assistant
text, tool calls + results) — richer and more reliable than trying to capture
messages via hooks. Output shape (one dict per rendered message):

    {"i": int, "role": "user"|"assistant", "text": str,
     "tools": [{"name": str, "summary": str, "output": str, "ok": bool}],
     "ts": float|None}

Consecutive assistant lines (Claude Code writes one JSONL line per content
block) are merged into a single message; tool_result blocks (which arrive in
later "user" lines) are attached back onto their tool_use entry.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

from agent.coding_session_capture import claude_projects_dir, encode_project_dir

# Caps keep a huge session renderable + the API payload bounded.
MAX_MESSAGES = 400        # tail-capped; `total` still reports the full count
MAX_TEXT = 6000           # per message text
MAX_TOOL_OUTPUT = 800     # per tool result snippet
MAX_SUMMARY = 160


def _iso_ts(s) -> float | None:
    if not s:
        return None
    try:
        import datetime as _dt
        return _dt.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _clip(s: str, n: int) -> str:
    s = s or ""
    return s if len(s) <= n else s[: n - 1] + "…"


def _tool_summary(name: str, inp) -> str:
    """One-line human summary of a tool call's input."""
    if not isinstance(inp, dict):
        return _clip(str(inp or ""), MAX_SUMMARY)
    for key in ("command", "file_path", "pattern", "query", "prompt", "url",
                "description", "path"):
        v = inp.get(key)
        if isinstance(v, str) and v.strip():
            return _clip(v.strip().splitlines()[0], MAX_SUMMARY)
    for v in inp.values():
        if isinstance(v, str) and v.strip():
            return _clip(v.strip().splitlines()[0], MAX_SUMMARY)
    return _clip(json.dumps(inp)[1:-1], MAX_SUMMARY)


def _result_text(content) -> str:
    """Flatten a tool_result block's content into a short text snippet."""
    if isinstance(content, str):
        return _clip(content, MAX_TOOL_OUTPUT)
    parts = []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                parts.append(str(b.get("text") or ""))
            elif isinstance(b, str):
                parts.append(b)
    return _clip("\n".join(p for p in parts if p), MAX_TOOL_OUTPUT)


def parse_transcript_text(text: str) -> list[dict]:
    """Parse raw transcript JSONL into the chat-message list (full, uncapped —
    callers slice; each message carries its absolute index ``i``)."""
    out: list[dict] = []
    tools_by_id: dict[str, dict] = {}

    def _new(role: str, ts) -> dict:
        m = {"i": len(out), "role": role, "text": "", "tools": [], "ts": ts}
        out.append(m)
        return m

    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get("type")
        if t not in ("user", "assistant"):
            continue
        if d.get("isSidechain"):
            continue                       # subagent traffic — not this chat
        msg = d.get("message") or {}
        content = msg.get("content")
        ts = _iso_ts(d.get("timestamp"))

        if t == "user":
            if isinstance(content, str):
                if d.get("isMeta"):
                    continue
                txt = content.strip()
                # Skip harness/meta envelopes (command echoes, reminders).
                if not txt or txt.startswith("<"):
                    continue
                m = _new("user", ts)
                m["text"] = _clip(txt, MAX_TEXT)
                continue
            if isinstance(content, list):
                user_texts = []
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    bt = b.get("type")
                    if bt == "tool_result":
                        tool = tools_by_id.get(str(b.get("tool_use_id") or ""))
                        if tool is not None:
                            tool["output"] = _result_text(b.get("content"))
                            tool["ok"] = not bool(b.get("is_error"))
                    elif bt == "text" and not d.get("isMeta"):
                        txt = str(b.get("text") or "").strip()
                        if txt and not txt.startswith("<"):
                            user_texts.append(txt)
                if user_texts:
                    m = _new("user", ts)
                    m["text"] = _clip("\n".join(user_texts), MAX_TEXT)
            continue

        # assistant — merge into the previous assistant message (Claude Code
        # writes one line per content block) unless a user message intervened.
        if not isinstance(content, list):
            continue
        m = out[-1] if (out and out[-1]["role"] == "assistant") else None
        for b in content:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "text":
                txt = str(b.get("text") or "").strip()
                if not txt:
                    continue
                if m is None:
                    m = _new("assistant", ts)
                m["text"] = _clip((m["text"] + "\n\n" + txt).strip(), MAX_TEXT)
            elif bt == "tool_use":
                if m is None:
                    m = _new("assistant", ts)
                tool = {"name": str(b.get("name") or "tool"),
                        "summary": _tool_summary(b.get("name"), b.get("input")),
                        "output": "", "ok": None}
                m["tools"].append(tool)
                tid = str(b.get("id") or "")
                if tid:
                    tools_by_id[tid] = tool
            # thinking blocks deliberately skipped
    return out


def find_transcript_file(cwd: str, csid: str,
                         projects_dir: str | None = None) -> Path | None:
    """Locate ``<csid>.jsonl`` — first under the cwd-encoded project dir, then
    (cwd moved/renamed) anywhere under the projects root."""
    base = Path(projects_dir) if projects_dir else claude_projects_dir()
    name = f"{csid}.jsonl"
    p = base / encode_project_dir(cwd or "") / name
    if p.is_file():
        return p
    try:
        for d in base.iterdir():
            f = d / name
            if f.is_file():
                return f
    except OSError:
        pass
    return None


def read_local_messages(cwd: str, csid: str,
                        projects_dir: str | None = None):
    """(messages, mtime) parsed from the local transcript, or (None, None)."""
    f = find_transcript_file(cwd, csid, projects_dir=projects_dir)
    if f is None:
        return None, None
    try:
        return parse_transcript_text(f.read_text(errors="replace")), f.stat().st_mtime
    except OSError:
        return None, None


def slice_messages(messages: list[dict], after: int) -> dict:
    """API payload: total + the tail from absolute index ``after`` (bounded)."""
    total = len(messages)
    start = max(int(after or 0), total - MAX_MESSAGES)
    return {"messages": messages[start:total], "total": total}
