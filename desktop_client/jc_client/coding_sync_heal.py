"""Self-heal Mutagen sync conflicts — newest edit wins, loser is backed up.

Two-Way-Safe Mutagen never resolves a conflict by itself (the same path
changed/created on both sides), so conflicted paths silently stop syncing
until a human intervenes. This module resolves them automatically WITHOUT
data loss:

  1. Pull the conflicted relative paths out of the session's raw JSON.
  2. stat both copies (local fs; one batched ``ssh jc-hermes stat`` for the
     server side — the same key/alias/relay Mutagen itself uses).
  3. NEWEST mtime wins (tie -> the Mac). The losing copy is MOVED into a
     backup tree on the host where it lives, then a flush propagates the
     winner. Nothing is ever deleted without a confirmed backup move.
  4. Conflicts where one side has no regular file (delete-vs-modify, special
     files) are SKIPPED — those stay visible for a human.

Backups: Mac losers -> ``<state_dir>/sync-conflicts/<session>/<UTC ts>/<rel>``;
server losers -> ``~/.jc-sync-conflicts/<session>/<UTC ts>/<rel>`` on the
server. Backup trees older than ``BACKUP_RETENTION_DAYS`` are pruned.
"""
from __future__ import annotations

import logging
import os
import shlex
import shutil
import subprocess
import time
from typing import Callable, Optional, Tuple

log = logging.getLogger(__name__)

Runner = Callable[..., Tuple[Optional[int], str, str]]

# Resolve at most this many conflicted paths per pass (Mutagen reports up to
# ~10 per cycle anyway; the poll loop drains the rest over later passes).
MAX_HEAL_PER_PASS = 10
# Don't run heal passes for a session more often than this.
HEAL_MIN_INTERVAL = 30.0
# Prune backup trees older than this.
BACKUP_RETENTION_DAYS = 30
# Remote-side backup root (under the server account's home).
REMOTE_BACKUP_ROOT = ".jc-sync-conflicts"

_SSH_BASE = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]


def _default_runner(argv, timeout=30.0):
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           timeout=timeout)
        return p.returncode, p.stdout or "", p.stderr or ""
    except Exception as exc:  # noqa: BLE001
        return 1, "", str(exc)


def extract_conflict_paths(session: dict) -> list:
    """Sorted unique conflicted relative paths from a raw session dict."""
    paths = set()
    for c in (session.get("conflicts") or []):
        if not isinstance(c, dict):
            continue
        for side in ("alphaChanges", "betaChanges"):
            for ch in (c.get(side) or []):
                if isinstance(ch, dict):
                    p = ch.get("path")
                    if isinstance(p, str) and p:
                        paths.add(p)
    return sorted(paths)


def safe_relpath(rel: str) -> bool:
    """True iff ``rel`` is a plain relative path that stays INSIDE the root —
    no absolute paths, no drive letters, no '..' segments, no empty parts."""
    if not rel or rel.startswith(("/", "\\")) or ":" in rel.split("/", 1)[0]:
        return False
    parts = rel.split("/")
    return all(p not in ("", ".", "..") for p in parts)


def parse_endpoint_urls(session: dict):
    """(alpha_root, beta_host, beta_root) from the session's endpoint URLs —
    alpha is the local path, beta is ``host:/abs/path``. None on any surprise."""
    alpha = ((session.get("alpha") or {}).get("url") or "").strip()
    beta = ((session.get("beta") or {}).get("url") or "").strip()
    if not alpha.startswith("/"):
        return None
    if ":" not in beta:
        return None
    host, _, broot = beta.partition(":")
    if not host or "/" in host or not broot.startswith("/"):
        return None
    return alpha.rstrip("/") or "/", host, broot.rstrip("/") or "/"


class ConflictHealer:
    """Resolves a session's conflicts newest-edit-wins with backups.

    All side effects go through injectable runners so tests never touch ssh
    or a real tree. ``heal`` is synchronous and bounded (MAX_HEAL_PER_PASS).
    """

    def __init__(self, state_dir: str, *, runner: Runner = _default_runner,
                 now: Callable[[], float] = time.time):
        self._state_dir = state_dir
        self._run = runner
        self._now = now
        self._last_pass: dict = {}      # session name -> wall-clock ts (rate limit)

    # ── public ──────────────────────────────────────────────────────────

    def due(self, name: str) -> bool:
        last = self._last_pass.get(name, 0.0)
        return (self._now() - last) >= HEAL_MIN_INTERVAL

    def heal(self, session: dict, name: str) -> dict:
        """One bounded heal pass. Returns {"healed": n, "skipped": n}."""
        self._last_pass[name] = self._now()
        out = {"healed": 0, "skipped": 0}
        ends = parse_endpoint_urls(session)
        if ends is None:
            return out
        alpha_root, host, beta_root = ends
        rels = [r for r in extract_conflict_paths(session)
                if safe_relpath(r)][:MAX_HEAL_PER_PASS]
        if not rels:
            return out

        beta_stats = self._stat_beta(host, beta_root, rels)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(self._now()))
        for rel in rels:
            try:
                ok = self._heal_one(rel, alpha_root=alpha_root, host=host,
                                    beta_root=beta_root, name=name,
                                    stamp=stamp, beta=beta_stats.get(rel))
            except Exception as exc:  # noqa: BLE001
                log.warning("sync heal[%s]: %s failed: %s", name, rel, exc)
                ok = False
            out["healed" if ok else "skipped"] += 1
        if out["healed"]:
            log.info("sync heal[%s]: resolved %d conflict(s), %d skipped "
                     "(backups under sync-conflicts/%s/%s)",
                     name, out["healed"], out["skipped"], name, stamp)
            self._prune(name, host)
        return out

    # ── one path ────────────────────────────────────────────────────────

    def _heal_one(self, rel, *, alpha_root, host, beta_root, name, stamp,
                  beta) -> bool:
        apath = os.path.join(alpha_root, rel)
        # Containment + regular-file checks on the LOCAL side.
        root_real = os.path.realpath(alpha_root)
        if not os.path.realpath(apath).startswith(root_real + os.sep):
            return False
        alpha_m: Optional[float] = None
        if os.path.lexists(apath):
            if os.path.islink(apath) or not os.path.isfile(apath):
                return False
            alpha_m = os.stat(apath).st_mtime
        if beta is not None and not beta[1]:
            return False               # beta side exists but isn't a regular file
        beta_m = beta[0] if beta is not None else None

        # Only the both-sides-regular-files case is healed automatically; a
        # delete-vs-modify conflict stays for a human (deleting the surviving
        # copy to honor a deletion is exactly the data loss we must not risk).
        if alpha_m is None or beta_m is None:
            return False

        if alpha_m >= beta_m:
            return self._backup_beta(host, beta_root, rel, name, stamp)
        return self._backup_alpha(alpha_root, rel, name, stamp)

    # ── side effects ────────────────────────────────────────────────────

    def _backup_alpha(self, alpha_root, rel, name, stamp) -> bool:
        src = os.path.join(alpha_root, rel)
        dst = os.path.join(self._state_dir, "sync-conflicts", name, stamp, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.move(src, dst)           # move: atomic-ish, never half-loses
        return True

    def _backup_beta(self, host, beta_root, rel, name, stamp) -> bool:
        # rel is an attacker/repo-controlled filename (only safe_relpath-checked,
        # which still permits spaces, $, quotes, backticks). $HOME must stay
        # shell-expanded, but EVERYTHING else is shlex-quoted — an unquoted dst
        # would both break spaced filenames AND allow `$(…)` RCE on the server.
        src = shlex.quote(f"{beta_root.rstrip('/')}/{rel}")
        tail = shlex.quote(f"{REMOTE_BACKUP_ROOT}/{name}/{stamp}/{rel}")
        dst = f'"$HOME"/{tail}'
        cmd = (f'mkdir -p "$(dirname {dst})" && '
               f'mv -- {src} {dst} && echo HEALED')
        rc, out, _err = self._run(_SSH_BASE + [host, cmd])
        return rc in (0, None) and "HEALED" in out

    def _stat_beta(self, host, beta_root, rels) -> dict:
        """{rel: (mtime, is_regular_file)} for paths that EXIST on beta."""
        beta_root = beta_root.rstrip("/")
        quoted = " ".join(
            shlex.quote(f"{beta_root}/{r}") for r in rels)
        # %Y epoch mtime, %F file type, %n name — GNU stat (server is Linux).
        rc, out, _err = self._run(
            _SSH_BASE + [host, f"stat -c '%Y|%F|%n' -- {quoted} 2>/dev/null"])
        stats: dict = {}
        if rc not in (0, None) and not out:
            return stats
        prefix = beta_root.rstrip("/") + "/"
        for line in out.splitlines():
            parts = line.split("|", 2)
            if len(parts) != 3:
                continue
            mts, ftype, path = parts
            if not path.startswith(prefix):
                continue
            try:
                m = float(mts)
            except ValueError:
                continue
            stats[path[len(prefix):]] = (m, ftype.strip() == "regular file")
        return stats

    def _prune(self, name, host) -> None:
        """Drop backup trees older than the retention window (best-effort)."""
        cutoff = self._now() - BACKUP_RETENTION_DAYS * 86400
        base = os.path.join(self._state_dir, "sync-conflicts", name)
        try:
            for d in os.listdir(base):
                p = os.path.join(base, d)
                if os.path.isdir(p) and os.stat(p).st_mtime < cutoff:
                    shutil.rmtree(p, ignore_errors=True)
        except OSError:
            pass
        self._run(_SSH_BASE + [host, (
            f"find $HOME/{REMOTE_BACKUP_ROOT}/{shlex.quote(name)} "
            f"-mindepth 1 -maxdepth 1 -type d -mtime +{BACKUP_RETENTION_DAYS} "
            "-exec rm -rf {} + 2>/dev/null; true")])
