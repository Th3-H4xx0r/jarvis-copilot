"""Unit tests for agent/coding_disk_guard.py (pure threshold + GC policy)."""
from agent.coding_disk_guard import (
    DiskGuardConfig,
    used_pct,
    classify,
    should_block_new_syncs,
    stale_staging_dirs,
)

GiB = 1024 ** 3


def _cfg(**kw):
    base = dict(warn_pct=85.0, critical_pct=92.0, resume_pct=80.0,
                min_free_bytes=3 * GiB, staging_max_age_s=1800)
    base.update(kw)
    return DiskGuardConfig(**base)


def test_used_pct():
    assert used_pct(50, 100) == 50.0
    assert used_pct(0, 0) == 0.0  # no div-by-zero


def test_classify_thresholds():
    cfg = _cfg()
    assert classify(80, 100, cfg) == "ok"
    assert classify(85, 100, cfg) == "warn"
    assert classify(91, 100, cfg) == "warn"
    assert classify(92, 100, cfg) == "critical"
    assert classify(99, 100, cfg) == "critical"


def test_block_at_critical_or_low_free():
    cfg = _cfg()
    # critical pct → block
    assert should_block_new_syncs(10 * GiB, 95, 100, cfg, currently_blocked=False)
    # low free bytes (even if pct ok) → block
    assert should_block_new_syncs(1 * GiB, 50, 100, cfg, currently_blocked=False)
    # healthy → no block
    assert not should_block_new_syncs(10 * GiB, 50, 100, cfg, currently_blocked=False)


def test_block_hysteresis():
    cfg = _cfg()
    # once blocked, stay blocked between resume_pct and critical_pct
    assert should_block_new_syncs(10 * GiB, 88, 100, cfg, currently_blocked=True)
    # ...but unblock once below resume_pct
    assert not should_block_new_syncs(10 * GiB, 79, 100, cfg, currently_blocked=True)
    # not-yet-blocked at 88% (between warn and critical) stays unblocked
    assert not should_block_new_syncs(10 * GiB, 88, 100, cfg, currently_blocked=False)


def test_stale_staging_selection():
    cfg = _cfg(staging_max_age_s=1800)
    now = 10_000.0
    entries = [
        ("/root/.mutagen/staging/fresh", now - 60),     # 1 min old → keep
        ("/root/.mutagen/staging/stale", now - 3600),   # 1 h old → GC
        ("/root/.mutagen/staging/edge", now - 1800),    # exactly threshold → GC
        ("/root/.mutagen/staging/bad", "notanumber"),   # ignored
    ]
    out = stale_staging_dirs(entries, now, cfg)
    assert out == ["/root/.mutagen/staging/stale", "/root/.mutagen/staging/edge"]


def test_config_from_env():
    cfg = DiskGuardConfig.from_env({"JC_DISK_CRITICAL_PCT": "95",
                                    "JC_DISK_MIN_FREE_BYTES": "1024"})
    assert cfg.critical_pct == 95.0
    assert cfg.min_free_bytes == 1024
    assert cfg.warn_pct == 85.0  # default preserved
