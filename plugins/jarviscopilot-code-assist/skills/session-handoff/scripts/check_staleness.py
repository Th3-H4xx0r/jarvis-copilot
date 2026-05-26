#!/usr/bin/env python3
"""Assess how stale a handoff is before resuming from it.

Parses the handoff's `Created:`, `Branch:`, and `HEAD:` metadata (from
gather_git_context.sh) and compares them to the current git state.

Usage:
    python3 check_staleness.py <handoff-file>
    recall_session_handoff_output | python3 check_staleness.py -
"""
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def git(*args):
    try:
        r = subprocess.run(["git", *args], capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "-"
    content = sys.stdin.read() if arg == "-" else Path(arg).read_text(encoding="utf-8", errors="replace")

    head = re.search(r'(?im)^\s*-?\s*HEAD:\s*([0-9a-f]{7,40})\b', content)
    created = re.search(r'(?im)^\s*-?\s*Created:\s*([0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]{4,8})', content)
    branch = re.search(r'(?im)^\s*-?\s*Branch:\s*([^\s(]+)', content)

    reasons, level = [], "FRESH"

    def bump(to):
        nonlocal level
        order = ["FRESH", "SLIGHTLY_STALE", "STALE", "VERY_STALE"]
        if order.index(to) > order.index(level):
            level = to

    if created:
        try:
            dt = datetime.strptime(created.group(1).strip()[:16].replace("T", " "), "%Y-%m-%d %H:%M")
            hours = (datetime.now(timezone.utc).replace(tzinfo=None) - dt).total_seconds() / 3600
            reasons.append(f"~{hours:.0f}h since created")
            bump("VERY_STALE" if hours > 24 * 14 else "STALE" if hours > 24 * 3 else "SLIGHTLY_STALE" if hours > 24 else "FRESH")
        except ValueError:
            reasons.append("could not parse Created:")
    else:
        reasons.append("no Created: metadata")

    if git("rev-parse", "--git-dir") is None:
        reasons.append("not a git repo here")
    else:
        if head:
            sha = head.group(1)
            if git("cat-file", "-e", sha + "^{commit}") is None:
                reasons.append(f"HEAD {sha[:8]} not in this repo — branch/clone diverged")
                bump("VERY_STALE")
            else:
                n = git("rev-list", "--count", f"{sha}..HEAD")
                if n is not None:
                    n = int(n)
                    reasons.append(f"{n} commit(s) since handoff")
                    bump("VERY_STALE" if n > 50 else "STALE" if n > 15 else "SLIGHTLY_STALE" if n > 3 else "FRESH")
        else:
            reasons.append("no HEAD: metadata")
        if branch:
            now = git("branch", "--show-current")
            if now and now != branch.group(1):
                reasons.append(f"on branch '{now}', handoff was '{branch.group(1)}'")
                bump("STALE")

    advice = {
        "FRESH": "Safe to resume.",
        "SLIGHTLY_STALE": "Review recent changes, then resume.",
        "STALE": "Verify context carefully before resuming.",
        "VERY_STALE": "Re-explore the codebase; consider a fresh handoff.",
    }[level]
    print(f"Staleness: {level} — {advice}")
    for r in reasons:
        print(f"  - {r}")


if __name__ == "__main__":
    main()
