"""The services hub: ONE background thread polls every configured service on its own
interval, keeps the latest snapshot (and detail) per service, turns changes into
notifications, and publishes each topic once per change:

* ``services``  → ``{"services": [snapshot, …], "ts": …}``
* ``portfolio`` → ``{"crypto": board | None, "portfolio": board | None, "ts": …}``

A service without credentials is never polled; with nothing configured the thread
only re-reads the config every 10 minutes (or when woken by a config change). No
service error, notification or publish failure ever escapes into the thread.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import dataclasses
import logging
import threading
import time
from typing import Callable, Optional

from jarvis_services import actions
from jarvis_services.base import (
    ActionResult, Detail, HttpError, ServiceError, plain, backoff_delay,
)

log = logging.getLogger(__name__)

IDLE_RECHECK = 600.0
DETAIL_MAX_AGE = 60.0
#: A second identical action this soon after the first is a double tap.
REPEAT_GUARD = 10.0
SETTLE = 2.0
PORTFOLIO_KEYS = ("crypto", "portfolio")


class ServicesHub:
    def __init__(self, services: list, config, *, http=None, publish: Optional[Callable] = None,
                 notify: Optional[Callable] = None, clock: Callable[[], float] = time.time,
                 sleep: Callable[[float], None] = time.sleep, settle: float = SETTLE):
        if http is None:
            from jarvis_services.base import Http
            http = Http()
        self.services = list(services)
        self.config = config
        self.http = http
        self._publish = publish
        self._notify = notify
        self._clock = clock
        self._sleep = sleep
        self._settle = settle
        self._by_id = {s.id: s for s in self.services}
        self._latest: dict = {}
        self._details: dict = {}
        self._due: dict = {}
        self._failures: dict = {}
        self._recent_actions: dict = {}
        self._lock = threading.RLock()
        self._action_lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    # ── thread ──

    def start(self) -> None:
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
            self._thread = threading.Thread(target=self._run, name="services-hub", daemon=True)
            self._thread.start()

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        self._wake.set()
        thread = self._thread
        if thread is not None:
            thread.join(timeout)

    def wake(self, service_id: Optional[str] = None) -> None:
        """Re-read the config now (and poll ``service_id`` now, when given)."""
        if service_id:
            with self._lock:
                if service_id in self._by_id:
                    self._due[service_id] = self._clock()
        self._wake.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                delay = self.tick()
            except Exception:  # noqa: BLE001 — keep the thread alive whatever happens
                log.exception("services hub: tick failed")
                delay = 60.0
            timeout = IDLE_RECHECK if delay is None else min(max(delay, 0.2), IDLE_RECHECK)
            self._wake.wait(timeout)
            self._wake.clear()

    # ── polling ──

    def tick(self) -> Optional[float]:
        """Poll every configured service that is due, publish what changed. Returns
        seconds until the next one is due, or None when nothing is configured."""
        now = self._clock()
        view = self.config.load()
        changed: set = set()
        for svc in self.services:
            try:
                configured = svc.configured(view)
            except Exception:  # noqa: BLE001
                log.exception("services hub: %s.configured failed", svc.id)
                configured = False
            if not configured:
                if self._forget(svc.id):
                    changed.add(svc.topic)
                continue
            with self._lock:
                due = self._due.setdefault(svc.id, now + svc.first_delay)
            if due <= now and self._poll(svc, view, now):
                changed.add(svc.topic)
        for topic in sorted(changed):
            self._send(topic, self._payload(topic, now))
        with self._lock:
            pending = list(self._due.values())
        return max(0.0, min(pending) - self._clock()) if pending else None

    def _forget(self, service_id: str) -> bool:
        with self._lock:
            self._due.pop(service_id, None)
            self._failures.pop(service_id, None)
            self._details.pop(service_id, None)
            return self._latest.pop(service_id, None) is not None

    def _poll(self, svc, view, now: float) -> bool:
        """One fetch. Returns whether the published content changed."""
        prev = self._latest.get(svc.id)
        try:
            new = svc.fetch(self.http, view, prev, now)
        except Exception as e:  # noqa: BLE001 — every failure becomes an error on the pill
            failures = self._failures.get(svc.id, 0) + 1
            if isinstance(e, ServiceError):
                message = svc.describe(e)
            else:
                log.exception("services hub: %s.fetch failed", svc.id)
                message = f"{svc.display_name}: something went wrong reading it ({e.__class__.__name__})."
            retry_after = e.retry_after if isinstance(e, HttpError) else None
            new = dataclasses.replace(prev, error=message) if prev is not None else svc.error_snapshot(message, now)
            with self._lock:
                self._failures[svc.id] = failures
                self._due[svc.id] = now + backoff_delay(svc.interval, failures, retry_after)
                self._latest[svc.id] = new
            return not new.same_content(prev)
        try:
            events = svc.events(prev.state if prev is not None else None, new.state)
        except Exception:  # noqa: BLE001
            log.exception("services hub: %s.events failed", svc.id)
            events = []
        try:
            interval = float(svc.next_interval(new))
        except Exception:  # noqa: BLE001
            interval = float(svc.interval)
        with self._lock:
            self._failures[svc.id] = 0
            self._due[svc.id] = now + interval
            self._latest[svc.id] = new
        for event in events:
            self._tell(svc, event)
        return not new.same_content(prev)

    def _tell(self, svc, event) -> None:
        if self._notify is None:
            return
        try:
            self._notify(event.title, event.body, {"service": svc.id, "kind": event.kind, **event.data})
        except Exception:  # noqa: BLE001
            log.warning("services hub: notify failed for %s", svc.id, exc_info=True)

    def _send(self, topic: str, payload: dict) -> None:
        if self._publish is None:
            return
        try:
            self._publish(topic, payload)
        except Exception:  # noqa: BLE001
            log.warning("services hub: publish %s failed", topic, exc_info=True)

    def _payload(self, topic: str, now: float) -> dict:
        if topic == "portfolio":
            return {**self.portfolio(), "ts": now}
        return {"services": self.snapshots(topic), "ts": now}

    # ── reads (any thread) ──

    def snapshots(self, topic: str = "services") -> list:
        with self._lock:
            return [self._latest[s.id].to_dict() for s in self.services
                    if s.topic == topic and s.id in self._latest]

    def pending(self) -> list:
        """Configured services with no snapshot yet (first poll still to come)."""
        with self._lock:
            return [s.id for s in self.services
                    if s.topic == "services" and s.id in self._due and s.id not in self._latest]

    def portfolio(self) -> dict:
        with self._lock:
            return {key: (self._latest[key].to_dict() if key in self._latest else None) for key in PORTFOLIO_KEYS}

    def service(self, service_id: str):
        """A pill service (one with a detail); KeyError otherwise."""
        svc = self._by_id[service_id]
        if svc.topic != "services":
            raise KeyError(service_id)
        return svc

    def detail(self, service_id: str, max_age: float = DETAIL_MAX_AGE) -> dict:
        svc = self.service(service_id)
        now = self._clock()
        with self._lock:
            cached = self._details.get(service_id)
        if cached is not None and cached.error is None and now - cached.fetched_at < max_age:
            return cached.to_dict()
        return self._refresh_detail(svc, self.config.load(), now, cached.last_action if cached else None).to_dict()

    def _refresh_detail(self, svc, view, now: float, last_action: Optional[ActionResult]) -> Detail:
        if not svc.configured(view):
            detail = svc.missing_key_detail(now)
        else:
            try:
                detail = svc.detail(self.http, view, now)
            except ServiceError as e:
                detail = Detail(svc.id, svc.display_name, fetched_at=now, error=svc.describe(e))
            except Exception as e:  # noqa: BLE001
                log.exception("services hub: %s.detail failed", svc.id)
                detail = Detail(svc.id, svc.display_name, fetched_at=now,
                                error=f"Something went wrong reading {svc.display_name} ({e.__class__.__name__}).")
        detail.last_action = last_action
        with self._lock:
            self._details[svc.id] = detail
        return detail

    # ── actions ──

    def action(self, service_id: str, kind: str, target: str, *, confirmed: bool = False,
               requested_at: Optional[float] = None) -> dict:
        """Run one allowlisted action that the latest detail offered. Returns
        ``{ok, result, error, confirm, detail}``; ``result`` is None when refused."""
        svc = self.service(service_id)
        with self._action_lock:
            now = self._clock()
            view = self.config.load()
            with self._lock:
                current = self._details.get(service_id)
            try:
                if not svc.configured(view):
                    raise actions.Refused(f"No {svc.display_name} key yet.")
                offered = actions.check(svc, current, kind, target, now=now, requested_at=requested_at,
                                        confirmed=confirmed)
                last = self._recent_actions.get((kind, target))
                if last is not None and now - last < REPEAT_GUARD:
                    raise actions.Refused("Already done a moment ago.")
            except actions.Refused as refused:
                if refused.confirm is not None and current is not None:
                    return {"ok": False, "result": None, "error": refused.message, "confirm": refused.confirm,
                            "detail": current.to_dict()}
                note = ActionResult("Not done", False, refused.message, now)
                fresh = self._refresh_detail(svc, view, now, note)
                return {"ok": False, "result": None, "error": refused.message, "confirm": None,
                        "detail": fresh.to_dict()}
            self._recent_actions[(kind, target)] = now
            log.info("services hub: %s (%s) %s", offered.title, service_id, kind)
            result = actions.perform(svc, self.http, view, offered, now)
        self._sleep(self._settle)            # give the service a moment, then show where things are
        fresh = self._refresh_detail(svc, view, self._clock(), result)
        self.wake(service_id)
        return {"ok": result.ok, "result": plain(result), "error": None if result.ok else result.message,
                "confirm": None, "detail": fresh.to_dict()}
