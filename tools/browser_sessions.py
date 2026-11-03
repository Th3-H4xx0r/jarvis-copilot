"""Browser sessions the chat can show: one row per browser task, live.

Every browser_* tool result carries ``card: {"kind": "browser_session", "session": id}``;
the phone and the web draw one card per id from ``GET /api/browser/sessions/<id>``
(webui/api/browser_routes.py), which reads this store.

A *session* is one browser task's lifetime: from its first browser call until the
task's browsers are closed. Moving between engines (Lightpanda → server Chrome →
cloud) keeps the id; the card follows the move.

Stored in SQLite under ``get_hermes_home()/browser/sessions.db`` so the agent (webui
chat turns, gateway cron jobs) and the webui routes see the same rows from different
processes. Each write touches only its own columns, so the tool updating the page and
the card flipping ``takeover`` never overwrite each other.
"""
from __future__ import annotations

import logging
import os
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterator, Optional

from jarviscopilot_constants import get_hermes_home

logger = logging.getLogger(__name__)

ENGINES = ("lightpanda", "chrome", "cloud")
REPLAY_STATUSES = ("none", "recording", "encoding", "ready", "failed")
# A running row nobody has touched for this long belongs to a process that died.
STALE_AFTER_S = 30 * 60
# A take-over nobody handed back (the page closed, the server restarted, the cloud
# browser hit its own 15-minute limit) stops pausing Jarvis after this long.
TAKEOVER_EXPIRE_S = 15 * 60
# "Run on cloud browser" tapped after the task's browser closed: the next session of
# that task (the turn the client starts) starts on the cloud, if it comes soon.
MOVE_CARRY_S = 30 * 60
REPLAY_RETENTION_DAYS = 14
# Longer than any encode (tools/browser_recorder.ENCODE_TIMEOUT_S): a replay still
# "recording"/"encoding" this long after its session ended never will be.
STUCK_REPLAY_S = 10 * 60

_COLUMNS = (
    "id", "task_id", "engine", "provider", "provider_name", "status", "url", "title",
    "live_url", "live_interactive_url", "takeover", "takeover_at", "move_requested", "replay_status",
    "replay_error", "created_at", "updated_at", "ended_at",
)
_SETTABLE = frozenset(_COLUMNS) - {"id", "task_id", "created_at"}

_schema_lock = threading.Lock()
_schema_ready: set = set()


def browser_dir() -> Path:
    path = get_hermes_home() / "browser"
    path.mkdir(parents=True, exist_ok=True)
    return path


def replays_dir() -> Path:
    path = browser_dir() / "replays"
    path.mkdir(parents=True, exist_ok=True)
    return path


def replay_path(session_id: str) -> Path:
    return replays_dir() / f"{session_id}.mp4"


def _db_path() -> Path:
    return browser_dir() / "sessions.db"


@contextmanager
def _conn() -> Iterator[sqlite3.Connection]:
    path = _db_path()
    conn = sqlite3.connect(str(path), timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    try:
        key = str(path)
        if key not in _schema_ready:
            with _schema_lock:
                if key not in _schema_ready:
                    conn.execute("PRAGMA journal_mode=WAL")
                    conn.execute(
                        "CREATE TABLE IF NOT EXISTS sessions ("
                        " id TEXT PRIMARY KEY, task_id TEXT NOT NULL, engine TEXT NOT NULL DEFAULT 'lightpanda',"
                        " provider TEXT, provider_name TEXT, status TEXT NOT NULL DEFAULT 'running',"
                        " url TEXT, title TEXT, live_url TEXT, live_interactive_url TEXT,"
                        " takeover INTEGER NOT NULL DEFAULT 0, takeover_at REAL,"
                        " move_requested INTEGER NOT NULL DEFAULT 0,"
                        " replay_status TEXT NOT NULL DEFAULT 'none', replay_error TEXT,"
                        " created_at REAL NOT NULL, updated_at REAL NOT NULL, ended_at REAL)")
                    columns = {r[1] for r in conn.execute("PRAGMA table_info(sessions)")}
                    if "takeover_at" not in columns:   # a store from before take-over expiry
                        conn.execute("ALTER TABLE sessions ADD COLUMN takeover_at REAL")
                    conn.execute("CREATE INDEX IF NOT EXISTS sessions_task ON sessions(task_id, status)")
                    _schema_ready.add(key)
        yield conn
    finally:
        conn.close()


def _new_id() -> str:
    return "b_" + secrets.token_hex(6)


def _row(row: Optional[sqlite3.Row]) -> Optional[Dict[str, Any]]:
    return dict(row) if row is not None else None


# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

def get(session_id: str) -> Optional[Dict[str, Any]]:
    if not session_id:
        return None
    with _conn() as conn:
        return _row(conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone())


def current_id(task_id: str) -> Optional[str]:
    """The task's running session, if any."""
    with _conn() as conn:
        row = conn.execute(
            "SELECT id FROM sessions WHERE task_id = ? AND status = 'running' "
            "ORDER BY created_at DESC LIMIT 1", (task_id,)).fetchone()
    return row["id"] if row else None


def ensure(task_id: str, engine: str = "lightpanda") -> str:
    """The task's running session, created when it has none.

    A "Run on cloud browser" tapped on the task's previous (ended) session in the
    last :data:`MOVE_CARRY_S` carries over to the new one.
    """
    now = time.time()
    with _conn() as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            # A running row idle this long belongs to a browser that is gone (a
            # restarted server, a take-over left behind): end it, start fresh.
            conn.execute(
                "UPDATE sessions SET status = 'ended', takeover = 0, ended_at = ?, updated_at = ? "
                "WHERE task_id = ? AND status = 'running' AND updated_at < ?",
                (now, now, task_id, now - STALE_AFTER_S))
            row = conn.execute(
                "SELECT id FROM sessions WHERE task_id = ? AND status = 'running' "
                "ORDER BY created_at DESC LIMIT 1", (task_id,)).fetchone()
            if row:
                conn.execute("COMMIT")
                return row["id"]
            carried = conn.execute(
                "SELECT id FROM sessions WHERE task_id = ? AND status = 'ended' AND move_requested = 1 "
                "AND updated_at > ? ORDER BY updated_at DESC LIMIT 1",
                (task_id, now - MOVE_CARRY_S)).fetchone()
            sid = _new_id()
            conn.execute(
                "INSERT INTO sessions (id, task_id, engine, status, created_at, updated_at, move_requested)"
                " VALUES (?, ?, ?, 'running', ?, ?, ?)",
                (sid, task_id, engine if engine in ENGINES else "lightpanda", now, now, 1 if carried else 0))
            if carried:
                conn.execute("UPDATE sessions SET move_requested = 0 WHERE id = ?", (carried["id"],))
            conn.execute("COMMIT")
            return sid
        except Exception:
            conn.execute("ROLLBACK")
            raise


def update(session_id: str, **fields: Any) -> None:
    """Set some columns (unknown ones are ignored); bumps ``updated_at``."""
    clean = {k: v for k, v in fields.items() if k in _SETTABLE}
    if not session_id or not clean:
        return
    if "takeover" in clean:
        clean["takeover"] = 1 if clean["takeover"] else 0
    if "move_requested" in clean:
        clean["move_requested"] = 1 if clean["move_requested"] else 0
    clean.setdefault("updated_at", time.time())
    assignments = ", ".join(f"{k} = ?" for k in clean)
    with _conn() as conn:
        conn.execute(f"UPDATE sessions SET {assignments} WHERE id = ?", (*clean.values(), session_id))


def touch(session_id: str) -> None:
    update(session_id, updated_at=time.time())


def end(session_id: str) -> None:
    now = time.time()
    with _conn() as conn:
        conn.execute(
            "UPDATE sessions SET status = 'ended', takeover = 0, ended_at = ?, updated_at = ? "
            "WHERE id = ? AND status = 'running'", (now, now, session_id))


def set_takeover(session_id: str, active: bool) -> None:
    update(session_id, takeover=bool(active), takeover_at=time.time() if active else None)


def request_move(session_id: str) -> None:
    update(session_id, move_requested=True)


def _takeover_live(row: Optional[Dict[str, Any]], now: float) -> bool:
    if not row or not row.get("takeover") or row.get("status") != "running":
        return False
    since = float(row.get("takeover_at") or row.get("updated_at") or 0)
    return now - since < TAKEOVER_EXPIRE_S


def takeover_active(session_id: Optional[str]) -> bool:
    """Is Pranav holding this session's browser? An expired take-over is cleared."""
    row = get(session_id) if session_id else None
    if not row or not row.get("takeover"):
        return False
    if _takeover_live(row, time.time()):
        return True
    if row.get("takeover"):
        set_takeover(session_id, False)
    return False


def _is_stale(row: Dict[str, Any], now: float) -> bool:
    return row.get("status") == "running" and now - float(row.get("updated_at") or 0) > STALE_AFTER_S


# ---------------------------------------------------------------------------
# Cloud browser readiness (shared by the tool and the card)
# ---------------------------------------------------------------------------

def _browser_config() -> Dict[str, Any]:
    try:
        from jarviscopilot_cli.config import read_raw_config
        cfg = read_raw_config().get("browser")
        return cfg if isinstance(cfg, dict) else {}
    except Exception:
        return {}


def cloud_for_interactive() -> bool:
    """``browser.cloud_for_interactive`` (default on)."""
    value = _browser_config().get("cloud_for_interactive", True)
    if isinstance(value, str):
        return value.strip().lower() not in {"0", "false", "no", "off"}
    return value is not False


def live_provider_name() -> Optional[str]:
    """The cloud browser a session moves to: ``browser.cloud_provider`` when one is
    set (``local``/``none`` = no cloud browser), otherwise Steel when its key is there."""
    raw = str(_browser_config().get("cloud_provider") or "").strip().lower()
    if raw in {"local", "none"}:
        return None          # picked "None" in Settings → Web & browser
    if raw:
        return raw
    if (os.environ.get("STEEL_API_KEY") or "").strip():
        return "steel"
    return None


def live_provider():
    """The ready cloud provider instance (configured and keyed), or None."""
    name = live_provider_name()
    if not name:
        return None
    try:
        from jarviscopilot_cli.plugins import _ensure_plugins_discovered
        _ensure_plugins_discovered()
    except Exception as exc:
        logger.debug("browser plugin discovery failed: %s", exc)
    try:
        from agent.browser_registry import get_provider
        provider = get_provider(name)
        if provider is not None and provider.is_available():
            return provider
    except Exception as exc:
        logger.debug("live cloud provider %s unavailable: %s", name, exc)
    return None


def provider_display_name(name: Optional[str]) -> Optional[str]:
    if not name:
        return None
    try:
        from agent.browser_registry import get_provider
        provider = get_provider(name)
        if provider is not None:
            return provider.display_name
    except Exception:
        pass
    return {"steel": "Steel", "browserbase": "Browserbase", "browser-use": "Browser Use",
            "firecrawl": "Firecrawl"}.get(name, name)


def cloud_status() -> Dict[str, Any]:
    """``{ready, provider, provider_name, hint}`` for the card's Run on cloud button."""
    name = live_provider_name()
    ready = live_provider() is not None
    display = provider_display_name(name or "steel")
    hint = None if ready else f"Add a {display} key in Settings → Providers"
    return {"ready": ready, "provider": name if ready else None,
            "provider_name": display if ready else None, "hint": hint}


# ---------------------------------------------------------------------------
# The card's view (Contract A)
# ---------------------------------------------------------------------------

def _iso(ts: Any) -> Optional[str]:
    try:
        return datetime.fromtimestamp(float(ts), tz=timezone.utc).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError):
        return None


def view(session_id: str, *, turn_running: Optional[bool] = None) -> Optional[Dict[str, Any]]:
    """The session as ``GET /api/browser/sessions/<id>`` returns it."""
    row = get(session_id)
    if row is None:
        return None
    now = time.time()
    status = "ended" if row["status"] != "running" or _is_stale(row, now) else "running"
    engine = row["engine"] if row["engine"] in ENGINES else "lightpanda"
    replay_status = row["replay_status"] if row["replay_status"] in REPLAY_STATUSES else "none"
    ready = replay_status == "ready" and replay_path(session_id).exists()
    if replay_status == "ready" and not ready:
        replay_status = "none"   # pruned after its 14 days
    if (status == "ended" and replay_status in ("recording", "encoding")
            and now - float(row.get("ended_at") or row["updated_at"] or 0) > STUCK_REPLAY_S):
        replay_status = "failed"  # the process that was encoding it went away
        row["replay_error"] = row.get("replay_error") or "the replay was not finished"
    cloud = cloud_status()
    on_cloud = engine == "cloud"
    out = {
        "id": row["id"],
        "engine": engine,
        "provider": row["provider"] if on_cloud else None,
        "provider_name": row["provider_name"] if on_cloud else None,
        "status": status,
        "url": row["url"] or "",
        "title": row["title"] or "",
        "live_url": row["live_url"] if on_cloud and status == "running" else None,
        "live_interactive_url": row["live_interactive_url"] if on_cloud and status == "running" else None,
        "takeover": status == "running" and _takeover_live(row, now),
        "move_requested": bool(row["move_requested"]),
        "replay_url": f"/api/browser/replays/{row['id']}.mp4" if ready else None,
        "replay_status": replay_status,
        "can_move_to_cloud": not on_cloud,
        "cloud_ready": cloud["ready"],
        "cloud_hint": None if cloud["ready"] else cloud["hint"],
        "updated_at": _iso(row["updated_at"]),
    }
    if row.get("replay_error") and replay_status == "failed":
        out["replay_error"] = row["replay_error"]
    if turn_running is not None:
        out["turn_running"] = bool(turn_running)
    return out


def task_id_of(session_id: str) -> Optional[str]:
    row = get(session_id)
    return row["task_id"] if row else None


# ---------------------------------------------------------------------------
# Replays
# ---------------------------------------------------------------------------

def prune_replays(max_age_days: int = REPLAY_RETENTION_DAYS) -> int:
    """Delete replays older than ``max_age_days``; returns how many went."""
    cutoff = time.time() - max_age_days * 86400
    removed = 0
    try:
        for path in replays_dir().glob("*.mp4"):
            try:
                if path.stat().st_mtime < cutoff:
                    path.unlink()
                    removed += 1
            except OSError:
                continue
    except OSError:
        return removed
    return removed
