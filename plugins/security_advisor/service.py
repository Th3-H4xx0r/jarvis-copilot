"""The Security Advisor worker, running inside the webui process.

Every 2 s it evaluates events after the last processed id with the rules, acts
on blocks (IP deny list), records alerts, pushes to the phones, and asks the
model for an explanation off-thread. It also polls the file watch, follows the
SSH journal, checks the log's hash chain hourly, prunes daily and sends the daily
digest. Blocks never wait for the model.
"""
from __future__ import annotations

import logging
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from plugins.security_advisor import rules, triage

logger = logging.getLogger(__name__)

TICK_S = 2.0
SESSION_TRUST_DAYS = 7
ALERT_DEDUP_S = 1800
REPO_ROOT = Path(__file__).resolve().parents[2]


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ip_had_session(log, ip: str, days: int = SESSION_TRUST_DAYS) -> bool:
    """Whether ``ip`` presented a valid session in the last ``days`` days (never auto-block it)."""
    since = _iso(datetime.now(timezone.utc) - timedelta(days=days))
    return log.ip_seen(["session.seen"], ip, since)


def snapshot(log, blocklist, ssh_state: str = "stopped", files_ts: float | None = None,
             chain_ok: bool = True) -> dict:
    """The status line data: open alerts, active blocks, last event, sources, chain."""
    open_alerts = len(log.list_alerts(status="open", limit=1000))
    last = log.query(limit=1)
    return {
        "state": "alerts" if open_alerts else "quiet",
        "open_alerts": open_alerts,
        "blocks": len(blocklist.active()),
        "last_event": last[0].ts if last else None,
        "sources": {
            "ssh": ssh_state,
            "files": (datetime.fromtimestamp(files_ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                      if files_ts else None),
        },
        "chain_ok": chain_ok,
    }


class SecurityService:
    _instance: "SecurityService | None" = None
    _instance_lock = threading.Lock()

    @classmethod
    def instance(cls) -> "SecurityService":
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    def __init__(self, log=None, blocklist=None, notifier=None, settings=None, cursor_path=None,
                 executor=None, now=None, file_watch=None, ssh=None):
        from jarviscopilot_constants import get_hermes_home
        from security.blocklist import default_blocklist
        from security.events import default_log
        from plugins.security_advisor import alerts
        from plugins.security_advisor import settings as settings_mod
        self.log = log or default_log()
        self.blocklist = blocklist or default_blocklist()
        self.settings = settings or settings_mod.load
        self.notifier = notifier or alerts.Notifier(
            settings=self.settings, log=self.log, summarize=triage.summarize_digest,
            deliver_chat=alerts.deliver_chat_note)
        if getattr(self.notifier, "log", None) is None:
            self.notifier.log = self.log
        state_dir = get_hermes_home() / "security"
        self.cursor_path = Path(cursor_path or state_dir / "cursor")
        self.executor = executor or ThreadPoolExecutor(max_workers=1,
                                                       thread_name_prefix="security-triage")
        self.now = now or datetime.now
        self.file_watch = file_watch
        self.ssh = ssh
        self.chain_ok = True
        self._reported_chain_break: int | None = None
        self._cursor: int | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._tick_lock = threading.Lock()
        self._digest_future = None

    # ── cursor ────────────────────────────────────────────────────────────
    def _load_cursor(self) -> int:
        if self._cursor is not None:
            return self._cursor
        try:
            self._cursor = int(self.cursor_path.read_text().strip())
        except (OSError, ValueError):
            # First run: start at the end so history from before the advisor was on
            # does not fire stale alerts or blocks.
            self._cursor = self.log.last_id()
            self._save_cursor(self._cursor)
        return self._cursor

    def _save_cursor(self, value: int) -> None:
        self._cursor = value
        try:
            self.cursor_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.cursor_path.with_suffix(".tmp")
            tmp.write_text(str(value))
            tmp.replace(self.cursor_path)
        except OSError as e:
            logger.debug("security cursor save failed: %s", e)

    # ── rule context ──────────────────────────────────────────────────────
    def ip_has_valid_session(self, ip: str) -> bool:
        return bool(ip) and ip_had_session(self.log, ip)

    def _context(self, cfg: dict) -> rules.RuleContext:
        """Rule inputs for one tick. Lookups are cached for the tick: a burst of 500 events
        costs one query per kind, not three per event. Every event of the tick is already
        in the log when the cache fills, so nothing in the batch is missed."""
        recent_cache: dict = {}
        session_cache: dict = {}

        def recent(kind: str, window_s: int):
            key = (kind, window_s)
            if key not in recent_cache:
                since = _iso(datetime.now(timezone.utc) - timedelta(seconds=window_s))
                recent_cache[key] = self.log.query(since=since, kinds=[kind], limit=5000)
            return recent_cache[key]

        def has_session(ip: str) -> bool:
            if ip not in session_cache:
                session_cache[ip] = self.ip_has_valid_session(ip)
            return session_cache[ip]
        now_ts = time.time()
        exceptions = {ip for ip, exp in (cfg.get("exceptions") or {}).items()
                      if float(exp or 0) > now_ts}
        return rules.RuleContext(
            recent=recent, ip_has_valid_session=has_session,
            known_ssh_ips=set(cfg.get("known_ssh_ips") or []),
            usual_hours=tuple(cfg.get("usual_hours") or (6, 23)),
            disabled_rules=set(cfg.get("disabled_rules") or []),
            now=self.now(), exceptions=exceptions)

    # ── one pass ──────────────────────────────────────────────────────────
    def tick(self) -> int:
        """Evaluate events after the cursor. Returns how many were processed."""
        with self._tick_lock:
            cursor = self._load_cursor()
            events = self.log.query(after_id=cursor, limit=500)
            if not events:
                return 0
            cfg = self.settings()
            ctx = self._context(cfg)
            for event in events:
                try:
                    self._handle(event, ctx, cfg)
                except Exception:
                    logger.exception("security advisor failed on event %s", event.id)
                self._save_cursor(event.id)
            return len(events)

    def _handle(self, event, ctx, cfg) -> None:
        decision = rules.evaluate(event, ctx)
        if decision.outcome == "block" and decision.action and decision.action.get("type") == "block_ip":
            ip = decision.action.get("ip") or ""
            if not ip or ctx.ip_has_valid_session(ip) or ip in ctx.exceptions:
                decision = rules.Decision("alert", decision.rule, decision.title,
                                          decision.summary + " Not blocked: it has a valid session.",
                                          decision.dedup_key, None)
            elif not self.blocklist.is_blocked(ip):  # already blocked: no file rewrite
                ttl = int(cfg.get("block_ttl_hours", 24)) * 3600
                self.blocklist.block(ip, reason=decision.title, ttl_s=ttl, event_id=event.id)
        self.log.set_outcome(event.id, decision.outcome, note=decision.title[:200])
        if decision.outcome not in ("alert", "block"):
            return
        if self.log.bump_alert(decision.dedup_key, ALERT_DEDUP_S) is not None:
            return
        alert_id = self.log.add_alert(event.id, decision)
        alert = self.log.get_alert(alert_id)
        self.notifier.notify(alert)
        related = [e for e in self.log.query(limit=10, after_id=max(0, event.id - 10))
                   if e.id != event.id]
        self.executor.submit(self._explain, alert_id, decision, event, related)

    def _explain(self, alert_id, decision, event, related) -> None:
        try:
            out = triage.explain(decision, event, related)
            self.log.set_explanation(alert_id, out["explanation"], out["severity"])
        except Exception:
            logger.exception("security triage store failed")

    # ── periodic jobs ─────────────────────────────────────────────────────
    def check_chain(self) -> None:
        bad = self.log.verify_chain()
        self.chain_ok = bad is None
        if bad is not None and bad != self._reported_chain_break:
            self._reported_chain_break = bad
            from security.events import emit
            emit("host", "log.chain_broken", {}, first_bad_id=bad)

    def poll_files(self) -> None:
        if self.file_watch is None:
            return
        from security.events import emit
        for kind, detail in self.file_watch.poll():
            emit("host", kind, {}, **detail)

    def run_digest(self) -> None:
        """Queue the daily-digest check on the triage executor: its model call must not
        hold up the worker loop (blocks, alerts). At most one is queued at a time."""
        pending = self._digest_future
        if pending is not None and not pending.done():
            return
        self._digest_future = self.executor.submit(self._digest)

    def _digest(self) -> None:
        try:
            self.notifier.digest(self.now())
        except Exception:
            logger.exception("security advisor digest failed")

    def status(self) -> dict:
        return snapshot(self.log, self.blocklist,
                        ssh_state=getattr(self.ssh, "state", "stopped") if self.ssh else "stopped",
                        files_ts=getattr(self.file_watch, "last_poll", None), chain_ok=self.chain_ok)

    # ── lifecycle ─────────────────────────────────────────────────────────
    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        from jarviscopilot_constants import get_hermes_home
        from plugins.security_advisor.sources import files, ssh
        if self.file_watch is None:
            self.file_watch = files.FileWatch(REPO_ROOT, files.default_watched(),
                                              get_hermes_home() / "security" / "filewatch.json")
        if self.ssh is None:
            self.ssh = ssh.SshFollower()
        self.ssh.start()
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="security-advisor", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self.ssh:
            self.ssh.stop()
        if self._thread:
            self._thread.join(timeout=5)

    def _run(self) -> None:
        last = {"files": float("-inf"), "chain": float("-inf"), "prune": float("-inf"),
                "digest": float("-inf")}
        while not self._stop.is_set():
            now = time.monotonic()
            try:
                file_poll_s = int(self.settings().get("file_poll_s", 300))
            except Exception:
                file_poll_s = 300
            jobs = [("tick", 0, self.tick),
                    ("files", file_poll_s, self.poll_files),
                    ("chain", 3600, self.check_chain),
                    ("prune", 86400, lambda: self.log.prune(90)),
                    ("digest", 60, self.run_digest)]
            for name, every, job in jobs:
                if every and now - last[name] < every:
                    continue
                if every:
                    last[name] = now
                try:
                    job()
                except Exception:
                    logger.exception("security advisor %s failed", name)
            self._stop.wait(TICK_S)
