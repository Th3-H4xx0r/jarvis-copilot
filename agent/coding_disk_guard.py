"""Pure decision helpers for the server disk-guard.

A runaway sync (or anything) filling the server root partition cascades into pip /
edge / sqlite failures. The guard (wired into the coding status loop) periodically
reads ``shutil.disk_usage("/")`` and uses these PURE functions to decide whether to
warn, to block/stop syncs, and which leaked Mutagen staging dirs to GC. Keeping the
policy pure makes the thresholds + hysteresis unit-testable without touching disk.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

_GiB = 1024 ** 3


@dataclass
class DiskGuardConfig:
    warn_pct: float = 85.0
    critical_pct: float = 92.0
    resume_pct: float = 80.0          # unblock only after dropping below this
    min_free_bytes: int = 3 * _GiB
    staging_max_age_s: int = 1800     # a staging dir untouched this long = stale

    @classmethod
    def from_env(cls, env=None) -> "DiskGuardConfig":
        env = env if env is not None else os.environ

        def _f(key, default):
            try:
                return float(env.get(key) or default)
            except (TypeError, ValueError):
                return default

        def _i(key, default):
            try:
                return int(env.get(key) or default)
            except (TypeError, ValueError):
                return default

        return cls(
            warn_pct=_f("JC_DISK_WARN_PCT", 85.0),
            critical_pct=_f("JC_DISK_CRITICAL_PCT", 92.0),
            resume_pct=_f("JC_DISK_RESUME_PCT", 80.0),
            min_free_bytes=_i("JC_DISK_MIN_FREE_BYTES", 3 * _GiB),
            staging_max_age_s=_i("JC_DISK_STAGING_MAX_AGE_S", 1800),
        )


def used_pct(used: int, total: int) -> float:
    return (100.0 * used / total) if total else 0.0


def classify(used: int, total: int, cfg: DiskGuardConfig) -> str:
    """``critical`` | ``warn`` | ``ok`` from the used percentage."""
    pct = used_pct(used, total)
    if pct >= cfg.critical_pct:
        return "critical"
    if pct >= cfg.warn_pct:
        return "warn"
    return "ok"


def should_block_new_syncs(free_bytes: int, used: int, total: int,
                           cfg: DiskGuardConfig, *, currently_blocked: bool) -> bool:
    """Hysteresis: enter the blocked state at ``critical_pct`` or below
    ``min_free_bytes``; once blocked, STAY blocked until usage drops below
    ``resume_pct`` (so we don't flap right at the threshold)."""
    pct = used_pct(used, total)
    if pct >= cfg.critical_pct or free_bytes < cfg.min_free_bytes:
        return True
    if currently_blocked and pct >= cfg.resume_pct:
        return True
    return False


def stale_staging_dirs(entries, now: float, cfg: DiskGuardConfig) -> list:
    """Pick leaked staging dirs to GC. ``entries`` = ``[(path, mtime), ...]``.
    A dir untouched for ``staging_max_age_s`` is considered orphaned (a live
    transfer touches its staging continuously)."""
    out = []
    for path, mtime in entries or ():
        try:
            if (now - float(mtime)) >= cfg.staging_max_age_s:
                out.append(path)
        except (TypeError, ValueError):
            continue
    return out
