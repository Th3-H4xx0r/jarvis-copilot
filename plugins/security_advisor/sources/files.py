"""Watch sensitive server files and the repo checkout for changes.

Each ``poll()`` hashes the watched files (a watched directory contributes every
file under it), compares against the last poll's state, and reports what moved.
The first poll only records a baseline. State lives in a JSON file so a webui
restart does not hide a change made while it was down.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

ADVISOR_PATHS = ("plugins/security_advisor", "security")
MAX_FILES_PER_DIR = 2000


def default_watched() -> list[Path]:
    from jarviscopilot_constants import get_hermes_home
    home = get_hermes_home()
    return [
        Path("/root/.ssh/authorized_keys"),
        Path("/etc/ssh/sshd_config"),
        Path("/etc/ssh/sshd_config.d"),
        Path("/etc/systemd/system"),
        Path("/etc/cron.d"),
        Path("/var/spool/cron/crontabs"),
        home / ".env",
        home / "auth.json",
        home / "edge" / "nginx.conf",
    ]


def _hash_file(path: Path) -> str:
    try:
        if path.is_symlink():
            return "link:" + os.readlink(path)
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return "unreadable"


def _snapshot(paths: list[Path]) -> dict[str, str]:
    out: dict[str, str] = {}
    for p in paths:
        p = Path(p)
        try:
            if p.is_dir() and not p.is_symlink():
                count = 0
                for root, dirs, names in os.walk(p):
                    dirs.sort()
                    for name in sorted(names):
                        fp = Path(root) / name
                        out[str(fp)] = _hash_file(fp)
                        count += 1
                        if count >= MAX_FILES_PER_DIR:
                            break
                    if count >= MAX_FILES_PER_DIR:
                        break
            elif p.exists() or p.is_symlink():
                out[str(p)] = _hash_file(p)
        except OSError:
            continue
    return out


def _git(repo: Path, *args: str) -> str | None:
    try:
        r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                           timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def _porcelain(repo: Path, *paths: str) -> list[str]:
    out = _git(repo, "status", "--porcelain", "--untracked-files=normal", "--", *paths)
    if out is None:
        return []
    return sorted({line[3:].strip() for line in out.splitlines() if len(line) > 3})


class FileWatch:
    def __init__(self, repo: Path, watched: list[Path], state_path: Path):
        self.repo = Path(repo)
        self.watched = [Path(p) for p in watched]
        self.state_path = Path(state_path)
        self.last_poll: float | None = None

    def _load(self) -> dict | None:
        try:
            data = json.loads(self.state_path.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else None
        except (OSError, ValueError):
            return None

    def _save(self, state: dict) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.state_path.parent, suffix=".fw.tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(state, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.state_path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def poll(self) -> list[tuple[str, dict]]:
        import time
        self.last_poll = time.time()
        head = (_git(self.repo, "rev-parse", "HEAD") or "").strip()
        state = {
            "files": _snapshot(self.watched),
            "porcelain": _porcelain(self.repo),
            "head": head,
            "advisor": _porcelain(self.repo, *ADVISOR_PATHS),
        }
        prev = self._load()
        self._save(state)
        if prev is None:
            return []
        changes: list[tuple[str, dict]] = []
        old_files, new_files = prev.get("files") or {}, state["files"]
        for path in sorted(set(old_files) | set(new_files)):
            if path not in old_files:
                changes.append(("file.changed", {"path": path, "change": "added"}))
            elif path not in new_files:
                changes.append(("file.changed", {"path": path, "change": "removed"}))
            elif old_files[path] != new_files[path]:
                changes.append(("file.changed", {"path": path, "change": "modified"}))
        new_dirty = sorted(set(state["porcelain"]) - set(prev.get("porcelain") or []))
        if new_dirty:
            changes.append(("repo.changed", {"files": new_dirty[:50]}))
        if head and prev.get("head") and head != prev.get("head"):
            on_origin = _git(self.repo, "merge-base", "--is-ancestor", head, "origin/main") is not None
            changes.append(("repo.head_moved", {"from": prev["head"], "to": head, "on_origin": on_origin}))
        if state["advisor"] and state["advisor"] != (prev.get("advisor") or []):
            changes.append(("advisor.code_changed", {"files": state["advisor"][:50]}))
        return changes
