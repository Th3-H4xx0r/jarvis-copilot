"""Server-side safety checks for coding-session file syncs.

A sync mirrors a Mac folder (alpha) <-> a server folder (beta). Without guards it
will happily mirror an entire home directory or a huge tree, or point a Mac path
at the Linux server — which is exactly how the server disk got filled. These are
PURE predicates (no I/O) so they're trivially unit-tested.

Each endpoint is validated where its ``~`` resolves: the SERVER validates the beta
path (server ``~``), the CLIENT validates the alpha path (Mac ``~``) + tree size
(``jc_client.sync_safety.check_local_sync``). ``is_dangerous_path`` is
host-agnostic (pattern-based) so either side catches a home/system dir even when
``~`` would expand to the wrong machine.

The shared predicates (``is_home_like``, ``is_dangerous_path``,
``under_allowed_root``) are jc-client's own ``sync_safety.py``, loaded by path —
the server has no ``jc_client`` install (same approach as
``agent/agent_engine_shim.py``). One definition, so the two sides cannot drift.
"""
from __future__ import annotations

import importlib.util
import os
import sys
from dataclasses import dataclass

_SHARED_NAME = "jarvis_sync_safety"
_SHARED_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "desktop_client", "jc_client", "sync_safety.py")


def _load_shared():
    if _SHARED_NAME not in sys.modules:
        spec = importlib.util.spec_from_file_location(_SHARED_NAME, _SHARED_PATH)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[_SHARED_NAME] = mod
        try:
            spec.loader.exec_module(mod)
        except BaseException:
            sys.modules.pop(_SHARED_NAME, None)
            raise
    return sys.modules[_SHARED_NAME]


shared = _load_shared()
_norm = shared._norm
is_home_like = shared.is_home_like
is_dangerous_path = shared.is_dangerous_path
under_allowed_root = shared.under_allowed_root

# Sync is only allowed UNDER one of these server roots. Configurable via env
# so a different layout doesn't require a code change.
_DEFAULT_SERVER_ROOTS = ["~/codingprojects"]


@dataclass
class SyncSafetyConfig:
    allowed_server_roots: list

    @classmethod
    def from_env(cls, env=None) -> "SyncSafetyConfig":
        env = env if env is not None else os.environ
        return cls(allowed_server_roots=shared.roots_from_env(
            env, "JC_SYNC_ALLOWED_SERVER_ROOTS", _DEFAULT_SERVER_ROOTS))


def looks_like_local_path_on_server(server_path) -> bool:
    """A macOS path used as the SERVER (Linux) destination. ``/Users/...`` does not
    exist on the Linux server — it only got created because a Mac path leaked into
    the server cwd. (``/home`` is a real Linux path, so it is NOT flagged here.)"""
    p = _norm(server_path)
    return p == "/Users" or p.startswith("/Users/")


def validate_server_path(server_path, cfg: SyncSafetyConfig) -> tuple:
    """Validate the SERVER (beta) endpoint. Run ON THE SERVER (``~`` = server home).
    Returns ``(ok, reason)``."""
    if is_dangerous_path(server_path):
        return False, f"refusing to sync a home/system directory on the server: {server_path!r}"
    if looks_like_local_path_on_server(server_path):
        return False, (f"server destination {server_path!r} looks like a Mac path "
                       "(it must be a server folder, e.g. under ~/codingprojects)")
    if not under_allowed_root(server_path, cfg.allowed_server_roots):
        return False, (f"server path {server_path!r} is outside the allowed roots "
                       f"{cfg.allowed_server_roots}")
    return True, ""


def validate_endpoints_for_server_gate(local_path, server_path,
                                       cfg: SyncSafetyConfig) -> tuple:
    """The SERVER-side gate: fully validate the server path, and reject a clearly
    dangerous LOCAL path (home/``/``) by pattern (the allowed-local-root check is
    deferred to the client where Mac ``~`` resolves). Returns ``(ok, reason)``."""
    ok, reason = validate_server_path(server_path, cfg)
    if not ok:
        return ok, reason
    if is_dangerous_path(local_path):
        return False, f"refusing to sync a home/system directory: {local_path!r}"
    return True, ""
