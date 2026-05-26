#!/usr/bin/env python3
"""Validate a JarvisCopilot session-handoff for completeness, quality, and safety.

Works on the handoff TEXT (the content you'll pass to store_session_handoff) —
since handoffs live in JarvisCopilot's shared code-memory, not in files. Pass a
draft file path, or pipe the text on stdin.

Checks: no [TODO: ...] placeholders, the 3 required sections are present + populated,
no secrets, referenced files exist, recommended sections present. Prints a 0-100
score; exits non-zero if secrets are found or the score is below 70.

Usage:
    python3 validate_handoff.py <draft-file>
    your_command_that_prints_the_handoff | python3 validate_handoff.py -
"""
import re
import sys
from pathlib import Path

SECRET_PATTERNS = [
    (r'["\']?[a-zA-Z_]*api[_-]?key["\']?\s*[:=]\s*["\'][^"\']{10,}["\']', "API key"),
    (r'["\']?[a-zA-Z_]*password["\']?\s*[:=]\s*["\'][^"\']+["\']', "Password"),
    (r'["\']?[a-zA-Z_]*secret["\']?\s*[:=]\s*["\'][^"\']{10,}["\']', "Secret"),
    (r'["\']?[a-zA-Z_]*token["\']?\s*[:=]\s*["\'][^"\']{20,}["\']', "Token"),
    (r'-----BEGIN [A-Z ]+PRIVATE KEY-----', "PEM private key"),
    (r'(mongodb(\+srv)?|postgres|postgresql|mysql)://[^/\s]+:[^@\s]+@', "DB connection string with password"),
    (r'Bearer\s+[a-zA-Z0-9_\-\.]{16,}', "Bearer token"),
    (r'ghp_[a-zA-Z0-9]{36}', "GitHub token"),
    (r'sk-[a-zA-Z0-9]{32,}', "OpenAI-style key"),
    (r'xox[baprs]-[a-zA-Z0-9-]+', "Slack token"),
    (r'AKIA[0-9A-Z]{16}', "AWS access key id"),
]

REQUIRED_SECTIONS = ["Current State Summary", "Important Context", "Immediate Next Steps"]
RECOMMENDED_SECTIONS = ["Critical Files", "Files Modified", "Decisions Made",
                        "Assumptions Made", "Potential Gotchas", "Environment State"]


def check_todos(content):
    todos = re.findall(r'\[TODO:[^\]]*\]', content)
    return len(todos) == 0, todos


def check_required(content):
    missing = []
    for section in REQUIRED_SECTIONS:
        m = re.search(rf'(?:^|\n)#+\s*{re.escape(section)}', content, re.IGNORECASE)
        if not m:
            missing.append(f"{section} (missing)")
            continue
        start = m.end()
        nxt = re.search(r'\n#+\s+', content[start:])
        body = content[start:(start + nxt.start()) if nxt else len(content)].strip()
        if len(body) < 50 or '[TODO' in body:
            missing.append(f"{section} (incomplete)")
    return len(missing) == 0, missing


def check_recommended(content):
    return [s for s in RECOMMENDED_SECTIONS
            if not re.search(rf'(?:^|\n)#+\s*{re.escape(s)}', content, re.IGNORECASE)]


def scan_secrets(content):
    out = []
    for pat, desc in SECRET_PATTERNS:
        n = len(re.findall(pat, content, re.IGNORECASE))
        if n:
            out.append((desc, f"{n} match(es)"))
    return out


def check_files(content, base):
    pats = [r'\|\s*([A-Za-z0-9_\-./]+\.[A-Za-z]+)(?::\d+)?\s*\|',
            r'`([A-Za-z0-9_\-./]+\.[A-Za-z]+(?::\d+)?)`']
    found = set()
    for pat in pats:
        for m in re.findall(pat, content):
            fp = m.split(':')[0]
            if fp and not fp.startswith('http') and '/' in fp:
                found.add(fp)
    existing, missing = [], []
    for fp in found:
        (existing if (Path(base) / fp).exists() else missing).append(fp)
    return existing, missing


def score(todos_clear, missing_required, missing_recommended, secrets, files_missing):
    s = 100
    if not todos_clear:
        s -= 30
    s -= 10 * len(missing_required)
    if secrets:
        s -= 20
    s -= 5 * min(len(files_missing), 4)
    s -= 2 * len(missing_recommended)
    s = max(0, s)
    rating = ("Excellent — ready" if s >= 90 else "Good — minor gaps" if s >= 70
              else "Fair — needs work" if s >= 50 else "Poor — incomplete")
    return s, rating


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "-"
    if arg == "-":
        content = sys.stdin.read()
    else:
        p = Path(arg)
        if not p.exists():
            print(f"Error: file not found: {arg}")
            sys.exit(2)
        content = p.read_text(encoding="utf-8", errors="replace")

    todos_clear, todos = check_todos(content)
    required_ok, missing_required = check_required(content)
    missing_recommended = check_recommended(content)
    secrets = scan_secrets(content)
    _existing, files_missing = check_files(content, ".")
    s, rating = score(todos_clear, missing_required, missing_recommended, secrets, files_missing)

    print("=" * 56)
    print(f"Handoff validation — {s}/100  ({rating})")
    print("=" * 56)
    print("[PASS] no [TODO:] placeholders" if todos_clear
          else f"[FAIL] {len(todos)} [TODO:] placeholder(s) remain: " + ", ".join(t[:32] for t in todos[:5]))
    print("[PASS] required sections complete" if required_ok
          else "[FAIL] required: " + "; ".join(missing_required))
    print("[PASS] no secrets detected" if not secrets
          else "[BLOCK] possible secrets: " + "; ".join(f"{d} ({n})" for d, n in secrets))
    if files_missing:
        print(f"[WARN] {len(files_missing)} referenced file(s) not found: " + ", ".join(files_missing[:5]))
    if missing_recommended:
        print("[INFO] consider adding: " + ", ".join(missing_recommended))

    if secrets:
        print("\nVerdict: BLOCKED — remove secrets (use env-var names only).")
        sys.exit(1)
    if s >= 70 and required_ok:
        print("\nVerdict: READY — store it with store_session_handoff.")
        sys.exit(0)
    print("\nVerdict: NEEDS WORK — complete the required sections.")
    sys.exit(1)


if __name__ == "__main__":
    main()
