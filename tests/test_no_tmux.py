"""No tmux anywhere: not required, not used, not a fallback.

Coding sessions run in whatever terminal Pranav opens (or as Claude's own
background sessions on the server) and Jarvis follows them through their hooks.
This walks the code that runs on the server, the Mac client, the Mac app and the
code-assist plugin, and fails on any line outside a comment that mentions tmux.
"""
from __future__ import annotations

import io
import re
import tokenize
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCANNED = ("agent", "webui/api", "tools", "desktop_client/jc_client",
           "mac_app/JarvisMac/Sources", "plugins/jarviscopilot-code-assist")
CODE_SUFFIXES = {".py", ".sh", ".bash", ".zsh", ".swift", ".js", ".mjs", ".ts", ".json"}
SKIP_DIRS = {"__pycache__", "node_modules", ".build", "build", "tests", "Tests"}
WORD = re.compile("tmux", re.IGNORECASE)


def _is_test_file(path: Path) -> bool:
    name = path.name
    return name.startswith("test_") or name.endswith(("_test.py", "Tests.swift", ".test.js"))


def _python_code_lines(text: str):
    """(line number, line) with ``#`` comments removed; strings and docstrings stay."""
    lines = text.splitlines()
    comments: dict[int, int] = {}
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT:
                comments[tok.start[0]] = tok.start[1]
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    for n, line in enumerate(lines, 1):
        yield n, line[:comments[n]] if n in comments else line


def _shell_code_lines(text: str):
    for n, line in enumerate(text.splitlines(), 1):
        yield n, re.sub(r"(^|\s)#.*$", "", line)


def _slash_code_lines(text: str):
    for n, line in enumerate(text.splitlines(), 1):
        yield n, line.split("//", 1)[0]


def _code_lines(path: Path, text: str):
    if path.suffix == ".py":
        return _python_code_lines(text)
    if path.suffix in (".sh", ".bash", ".zsh"):
        return _shell_code_lines(text)
    if path.suffix in (".swift", ".js", ".mjs", ".ts"):
        return _slash_code_lines(text)
    return enumerate(text.splitlines(), 1)


def _files():
    for rel in SCANNED:
        base = ROOT / rel
        if not base.exists():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or path.suffix not in CODE_SUFFIXES:
                continue
            if SKIP_DIRS & set(path.relative_to(ROOT).parts) or _is_test_file(path):
                continue
            yield path


def test_no_tmux_outside_comments():
    offending = []
    for path in _files():
        text = path.read_text(encoding="utf-8", errors="replace")
        if not WORD.search(text):
            continue
        for n, code in _code_lines(path, text):
            if WORD.search(code):
                offending.append(f"{path.relative_to(ROOT)}:{n}: {code.strip()[:120]}")
    assert not offending, "tmux in code:\n" + "\n".join(offending)


def test_the_scan_sees_code():
    """Guards the guard: the walk must actually reach each tree."""
    seen = {next((r for r in SCANNED if str(p.relative_to(ROOT)).startswith(r)), None)
            for p in _files()}
    for rel in ("agent", "webui/api", "tools", "desktop_client/jc_client"):
        assert rel in seen, rel


def test_comment_stripping():
    py = 'x = 1  # tmux here is fine\ny = "tmux"\n'
    assert [c for _n, c in _python_code_lines(py) if WORD.search(c)] == ['y = "tmux"']
    assert not [c for _n, c in _shell_code_lines("echo hi # tmux\n") if WORD.search(c)]
    assert not [c for _n, c in _slash_code_lines("let a = 1 // tmux\n") if WORD.search(c)]
