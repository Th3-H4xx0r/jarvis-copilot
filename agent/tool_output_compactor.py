"""Deterministic tool-output compaction (a Python port of openhuman's TokenJuice).

Shrinks verbose command output (test runners, linters, builds, git, grep) before
it re-enters the model's context — a cheap, CPU-only first pass that runs before
any LLM summarizer or blunt char-cap. Pass-through is guaranteed: output is only
replaced when the compacted form is strictly smaller (ratio <= 0.95) and the raw
input is large enough to bother (>= 512 bytes); otherwise the original is
returned untouched. Failure output is preserved (larger tail + error lines).

Safety gates (mirroring openhuman):
- domain tools (no shell command in args) are NOT blindly head/tail-truncated —
  only command-style output is, so structured/JSON payloads aren't mangled;
- file-inspection commands (cat/sed/head/tail/jq/...) are never fallback-compacted.
"""
from __future__ import annotations

import logging
import re
from typing import Any, List, Optional, Tuple

logger = logging.getLogger(__name__)

MIN_COMPACT_BYTES = 512
MIN_KEEP_RATIO = 0.95
MAX_INLINE_CHARS = 1200

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
_FILE_INSPECT = {"cat", "sed", "head", "tail", "nl", "bat", "batcat", "jq", "yq", "less", "more", "awk"}

# Declarative rules. Highest specificity score wins; generic/fallback is last.
RULES: List[dict] = [
    {"id": "tests/pytest", "match": {"command_includes": ["pytest", "py.test"]},
     "strip_ansi": True, "dedupe": True, "trim": True,
     "skip": [r"^\s*platform ", r"^\s*cachedir", r"^\s*rootdir", r"^\s*plugins:", r"^\s*collecting "],
     "head": 12, "tail": 16, "fail_head": 20, "fail_tail": 26, "preserve_on_failure": True},
    {"id": "tests/jest", "match": {"command_includes": ["jest", "vitest", "mocha"]},
     "strip_ansi": True, "dedupe": True, "trim": True,
     "head": 12, "tail": 16, "fail_head": 20, "fail_tail": 26, "preserve_on_failure": True},
    {"id": "vcs/git-status", "match": {"argv0": ["git"], "argv_includes": ["status"]},
     "strip_ansi": True, "trim": True, "head": 50, "tail": 8},
    {"id": "search/grep", "match": {"argv0": ["grep", "rg", "ripgrep", "ag"]},
     "strip_ansi": True, "dedupe": True, "trim": True, "head": 50, "tail": 8},
    {"id": "lint/generic", "match": {"command_includes": ["eslint", "ruff", "flake8", "pylint", "mypy", "tsc"]},
     "strip_ansi": True, "dedupe": True, "trim": True,
     "head": 12, "tail": 16, "fail_head": 18, "fail_tail": 28, "preserve_on_failure": True},
    {"id": "pkg/install", "match": {"command_includes": ["npm install", "pip install", "pnpm install",
                                                          "yarn add", "apt-get", "brew install", "poetry add"]},
     "strip_ansi": True, "dedupe": True, "trim": True,
     "head": 6, "tail": 12, "fail_head": 10, "fail_tail": 22, "preserve_on_failure": True},
    {"id": "build/generic", "match": {"command_includes": ["make ", "cargo build", "cargo test", "npm run build",
                                                            "webpack", "vite build", "gradle", "mvn "]},
     "strip_ansi": True, "dedupe": True, "trim": True,
     "head": 10, "tail": 16, "fail_head": 16, "fail_tail": 26, "preserve_on_failure": True},
    {"id": "generic/fallback", "match": {},
     "strip_ansi": True, "dedupe": True, "trim": True,
     "head": 8, "tail": 10, "fail_head": 12, "fail_tail": 22, "preserve_on_failure": True},
]

for _r in RULES:  # precompile line regexes
    _r["_skip_re"] = [re.compile(p) for p in _r.get("skip", [])]
    _r["_keep_re"] = [re.compile(p) for p in _r.get("keep", [])]


def strip_ansi(s: str) -> str:
    return _ANSI_RE.sub("", s)


def head_tail(lines: List[str], head: int, tail: int) -> List[str]:
    if len(lines) <= head + tail:
        return lines
    omitted = len(lines) - head - tail
    return lines[:head] + [f"... {omitted} lines omitted ..."] + lines[-tail:]


def _dedupe_adjacent(lines: List[str]) -> List[str]:
    out: List[str] = []
    prev = None
    for ln in lines:
        if ln != prev:
            out.append(ln)
        prev = ln
    return out


def _trim_empty_edges(lines: List[str]) -> List[str]:
    i, j = 0, len(lines)
    while i < j and not lines[i].strip():
        i += 1
    while j > i and not lines[j - 1].strip():
        j -= 1
    return lines[i:j]


def _command_argv(tool_name: str, args: Any) -> Tuple[str, List[str], bool]:
    """Return (command_string, argv, has_real_command)."""
    cmd = ""
    if isinstance(args, dict):
        for k in ("command", "cmd", "argv", "code", "script", "query", "pattern"):
            v = args.get(k)
            if isinstance(v, str) and v.strip():
                cmd = v
                break
            if isinstance(v, list) and v:
                cmd = " ".join(str(x) for x in v)
                break
    has_cmd = bool(cmd)
    if not cmd:
        cmd = tool_name or ""
    argv = re.findall(r"\S+", cmd)
    return cmd, argv, has_cmd


def _score_rule(rule: dict, tool_name: str, command: str, argv: List[str]) -> int:
    m = rule.get("match", {})
    if not m:
        return 0  # fallback
    score = 0
    a0 = argv[0] if argv else ""
    if "argv0" in m:
        if a0 not in m["argv0"]:
            return -1
        score += 100
    if "argv_includes" in m:
        if not all(tok in argv for tok in m["argv_includes"]):
            return -1
        score += 40 * len(m["argv_includes"])
    if "command_includes" in m:
        if not any(sub in command for sub in m["command_includes"]):
            return -1
        score += 25
    if "tool_names" in m:
        if tool_name not in m["tool_names"]:
            return -1
        score += 10
    return score


def classify(tool_name: str, command: str, argv: List[str]) -> dict:
    best = None
    best_score = -1
    for rule in RULES:
        s = _score_rule(rule, tool_name, command, argv)
        if s > best_score:
            best, best_score = rule, s
    return best or RULES[-1]


def _apply_rule(rule: dict, text: str, is_error: bool) -> str:
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if rule.get("strip_ansi"):
        lines = strip_ansi("\n".join(lines)).split("\n")
    if rule["_skip_re"]:
        lines = [ln for ln in lines if not any(p.search(ln) for p in rule["_skip_re"])]
    if rule["_keep_re"]:
        kept = [ln for ln in lines if any(p.search(ln) for p in rule["_keep_re"])]
        if kept:
            lines = kept
    if rule.get("trim"):
        lines = _trim_empty_edges(lines)
    if rule.get("dedupe"):
        lines = _dedupe_adjacent(lines)
    if is_error and rule.get("preserve_on_failure"):
        head, tail = rule.get("fail_head", 12), rule.get("fail_tail", 20)
    else:
        head, tail = rule.get("head", 8), rule.get("tail", 8)
    return "\n".join(head_tail(lines, head, tail)).strip()


def _clamp(s: str, n: int = MAX_INLINE_CHARS) -> str:
    if len(s) <= n:
        return s
    head_n = int(n * 0.7)
    tail_n = max(0, n - head_n - 18)
    head = s[:head_n]
    tail = s[-tail_n:] if tail_n else ""
    if "\n" in head:
        head = head[: head.rfind("\n")]
    if tail and "\n" in tail:
        tail = tail[tail.find("\n") + 1:]
    return head + "\n... omitted ...\n" + tail


def compact_tool_output(tool_name: str, args: Any, text: Any, is_error: bool = False) -> Any:
    """Compact one tool's output. Returns the original unchanged unless the
    compacted form is strictly smaller (ratio <= 0.95) and input is >= 512 B."""
    if not isinstance(text, str) or len(text) < MIN_COMPACT_BYTES:
        return text
    command, argv, has_cmd = _command_argv(tool_name, args)
    rule = classify(tool_name, command, argv)
    a0 = argv[0] if argv else ""
    if rule["id"] == "generic/fallback":
        # Don't blindly truncate structured/domain payloads or file dumps.
        if not has_cmd or a0 in _FILE_INSPECT:
            return text
    try:
        compacted = _clamp(_apply_rule(rule, text, is_error))
    except Exception as e:
        logger.debug("tokenjuice apply failed for %s: %s", tool_name, e)
        return text
    if compacted and len(compacted) < len(text) and (len(compacted) / max(1, len(text))) <= MIN_KEEP_RATIO:
        return compacted
    return text


_ENABLED: Optional[bool] = None


def is_compaction_enabled() -> bool:
    """Config gate: tools.compact_tool_output (default True). Cached."""
    global _ENABLED
    if _ENABLED is None:
        try:
            from jarviscopilot_cli.config import load_config, cfg_get
            _ENABLED = bool(cfg_get(load_config(), "tools", "compact_tool_output", default=True))
        except Exception:
            _ENABLED = True
    return _ENABLED
