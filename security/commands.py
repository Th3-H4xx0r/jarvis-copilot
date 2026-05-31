"""Deterministic shell-command classification + an escalate-only gate.

A coding agent's deterministic floor: classify each `;|&&||`-separated segment,
take the highest risk, and never let an LLM-declared class *lower* it. Also
detects hidden execution (command substitution / background) that could smuggle
a command past an approval prompt.
"""
from __future__ import annotations

import re
import shlex
from typing import List

# Risk ordering (low -> high).
ORDER = ["read", "write", "network", "install", "destructive"]

_NETWORK = {"curl", "wget", "ssh", "scp", "sftp", "nc", "ncat", "netcat", "telnet", "ftp", "rsync"}
_INSTALLERS = {"apt", "apt-get", "yum", "dnf", "pacman", "brew", "pip", "pip3",
               "npm", "pnpm", "yarn", "gem", "cargo", "go", "poetry"}
_HIGH_RISK = {"mkfs", "dd", "sudo", "su", "mount", "umount", "iptables", "passwd",
              "shutdown", "reboot", "halt", "fdisk", "mkswap", "chown", "chmod"}
_DESTRUCTIVE_RE = [
    re.compile(r"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r)\b"),  # rm -rf / -fr
    re.compile(r":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"),  # forkbomb
    re.compile(r"\bdd\s+.*of=/dev/"),
    re.compile(r">\s*/dev/sd[a-z]"),
]
_WRITE_RE = re.compile(r"(^|\s)(>>?|tee)(\s|$)")
_HIDDEN_RE = [
    re.compile(r"\$\("), re.compile(r"`"), re.compile(r"<\("), re.compile(r">\("),
    re.compile(r"&\s*$"),
]


def _segments(command: str) -> List[str]:
    return [s for s in re.split(r"&&|\|\||[;\n|&]", command) if s.strip()]


def has_hidden_execution(command: str) -> bool:
    return any(rx.search(command) for rx in _HIDDEN_RE)


def is_high_risk(command: str) -> bool:
    for seg in _segments(command):
        try:
            toks = shlex.split(seg)
        except ValueError:
            toks = seg.split()
        if toks and toks[0] in _HIGH_RISK:
            return True
    return any(rx.search(command) for rx in _DESTRUCTIVE_RE)


def _classify_segment(seg: str) -> str:
    if any(rx.search(seg) for rx in _DESTRUCTIVE_RE):
        return "destructive"
    try:
        toks = shlex.split(seg)
    except ValueError:
        toks = seg.split()
    a0 = toks[0] if toks else ""
    if a0 in _INSTALLERS and any(t in ("install", "add", "i") for t in toks[1:3]):
        return "install"
    if a0 in _NETWORK:
        return "network"
    if a0 in _HIGH_RISK:
        return "destructive"
    if _WRITE_RE.search(seg) or a0 in {"rm", "mv", "cp", "mkdir", "touch", "ln", "truncate"}:
        return "write"
    return "read"


def classify_command(command: str) -> str:
    """Highest risk class across all segments (read|write|network|install|destructive)."""
    worst = "read"
    for seg in _segments(command):
        c = _classify_segment(seg)
        if ORDER.index(c) > ORDER.index(worst):
            worst = c
    return worst


def gate_decision(command: str, mode: str = "supervised", declared_class: str = None) -> str:
    """Return 'allow' | 'prompt' | 'block'.

    mode: 'readonly' | 'supervised' | 'full'. The LLM-declared class may only
    *escalate* the deterministic floor, never lower it. Hidden execution in
    non-full modes is blocked so an approval prompt can't be bypassed.
    """
    floor = classify_command(command)
    cls = floor
    if declared_class in ORDER and ORDER.index(declared_class) > ORDER.index(floor):
        cls = declared_class

    if mode != "full" and has_hidden_execution(command):
        return "block"

    if mode == "readonly":
        return "allow" if cls == "read" else "block"
    if mode == "full":
        return "allow" if cls in ("read", "write") else "prompt"
    # supervised (default): read silent, everything that acts prompts
    return "allow" if cls == "read" else "prompt"
