"""Shared pieces of the service pills: models, the HTTP wrapper, error hints, backoff.

A service turns a third-party API (Stripe, GitHub, Vercel…) into a ``Snapshot``: a
state dot, one line saying why, and the latest items. Up close it gives a
``Detail``: figures, longer lists and the few safe actions it offers on items.
Keys never leave the server; snapshots and details carry none.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import dataclasses
import json as _json
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Mapping, Optional

import httpx

OK, WARNING, ERROR, INFO, IDLE = "ok", "warning", "error", "info", "idle"
TONES = (OK, WARNING, ERROR, INFO, IDLE)


# ── models ──────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Action:
    """Something the server can do on an item, e.g. ``vercel.redeploy``."""
    kind: str
    title: str
    target: str
    symbol: str = ""
    destructive: bool = False
    #: Asked before doing it, when it can't be undone.
    confirm: Optional[str] = None


@dataclass
class Item:
    title: str
    subtitle: str = ""
    value: Optional[str] = None
    url: Optional[str] = None
    tone: str = IDLE
    date: Optional[float] = None
    #: A short tag on the right ("Production", "Draft", "Active"…).
    badge: Optional[str] = None
    actions: list = field(default_factory=list)


@dataclass
class Section:
    title: str
    items: list
    footer: Optional[str] = None


@dataclass
class Stat:
    label: str
    value: str
    tone: str = IDLE


@dataclass
class ActionResult:
    title: str
    ok: bool
    message: str
    at: float


def plain(value: Any) -> Any:
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return {f.name: plain(getattr(value, f.name)) for f in dataclasses.fields(value)
                if f.name != "state"}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    return value


@dataclass
class Snapshot:
    """What a pill shows: its dot, why it has that color, the latest items."""
    id: str
    display_name: str
    tone: str
    headline: str
    reason: str
    sections: list = field(default_factory=list)
    updated_at: float = 0.0
    error: Optional[str] = None
    #: Service-specific data a section can't hold (GitHub's contribution calendar).
    extra: Optional[dict] = None
    #: Parsed model the next poll diffs against for events. Never serialized.
    state: Any = field(default=None, compare=False, repr=False)

    def to_dict(self) -> dict:
        return plain(self)

    def same_content(self, other: Optional["Snapshot"]) -> bool:
        return same_content(self, other)


def same_content(a: Any, b: Any) -> bool:
    """Equal apart from ``updated_at`` (and the never-serialized ``state``)."""
    if a is None or b is None:
        return False
    da, db = plain(a), plain(b)
    da.pop("updated_at", None)
    db.pop("updated_at", None)
    return da == db


@dataclass
class Detail:
    """A service seen up close: figures, lists, and the actions offered on items."""
    id: str
    display_name: str
    stats: list = field(default_factory=list)
    sections: list = field(default_factory=list)
    fetched_at: float = 0.0
    #: Why the API couldn't be read (no key, 401…).
    error: Optional[str] = None
    last_action: Optional[ActionResult] = None

    def offered(self, kind: str, target: str) -> Optional[Action]:
        for section in self.sections:
            for item in section.items:
                for action in item.actions:
                    if action.kind == kind and action.target == target:
                        return action
        return None

    def to_dict(self) -> dict:
        return plain(self)


@dataclass(frozen=True)
class Event:
    """Something worth a notification: a payment, a failed deploy, a review request."""
    kind: str
    title: str
    body: str
    data: dict = field(default_factory=dict)


# ── HTTP ────────────────────────────────────────────────────────────────────────

class ServiceError(Exception):
    """A failure with a message fit to show as is."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class HttpError(ServiceError):
    """A non-2xx answer (``status``) or no answer at all (``status`` 0)."""

    def __init__(self, status: int, message: str = "", retry_after: Optional[float] = None):
        super().__init__(message)
        self.status = status
        self.retry_after = retry_after

    def __str__(self) -> str:
        return f"HTTP {self.status}: {self.message}" if self.status else (self.message or "no connection")


@dataclass
class Response:
    status: int
    content: bytes = b""
    headers: Mapping[str, str] = field(default_factory=dict)

    def json(self) -> Any:
        return _json.loads(self.content) if self.content else {}

    @property
    def text(self) -> str:
        return self.content.decode("utf-8", "replace")


class Http:
    """The one HTTP client the services use: a thin wrapper around ``httpx`` that
    tests replace with a fake answering canned JSON (see ``jarvis_services.testing``)."""

    def __init__(self, client: Optional[httpx.Client] = None, timeout: float = 15.0):
        self._client = client
        self._timeout = timeout

    def _get_client(self) -> httpx.Client:
        if self._client is None:
            self._client = httpx.Client(timeout=self._timeout, headers={"User-Agent": "Jarvis"})
        return self._client

    def request(self, method: str, url: str, *, headers: Optional[dict] = None,
                params: Optional[dict] = None, json: Any = None, data: Any = None,
                timeout: Optional[float] = None) -> Response:
        try:
            r = self._get_client().request(method, url, headers=headers, params=params, json=json,
                                           content=data, timeout=timeout or self._timeout)
        except httpx.HTTPError as e:
            raise HttpError(0, str(e) or e.__class__.__name__) from None
        return Response(r.status_code, r.content, dict(r.headers))

    def close(self) -> None:
        if self._client is not None:
            self._client.close()


def _error_message(r: Response) -> str:
    try:
        body = r.json()
    except ValueError:
        body = None
    if isinstance(body, dict):
        if isinstance(body.get("message"), str):
            return body["message"]
        err = body.get("error")
        if isinstance(err, dict) and isinstance(err.get("message"), str):
            return err["message"]
        if isinstance(err, str):
            return err
    return r.text[:200]


def _retry_after(r: Response) -> Optional[float]:
    raw = next((v for k, v in r.headers.items() if k.lower() == "retry-after"), None)
    try:
        return float(raw) if raw is not None else None
    except ValueError:
        return None


def call_json(http, method: str, url: str, **kwargs) -> Any:
    """Send a request and return its JSON, or raise ``HttpError`` on a non-2xx answer."""
    r = http.request(method, url, **kwargs)
    if not 200 <= r.status < 300:
        raise HttpError(r.status, _error_message(r), retry_after=_retry_after(r))
    if not r.content:
        return {}
    try:
        return r.json()
    except ValueError:
        raise HttpError(r.status, "The answer couldn't be read.") from None


# ── errors and backoff ──────────────────────────────────────────────────────────

def describe(err: BaseException, service: str = "", hints: Optional[Mapping[int, str]] = None) -> str:
    """One line a person can act on, e.g. "The key was refused (401)…"."""
    if isinstance(err, HttpError):
        s, msg = err.status, (err.message or "").strip()
        if hints and s in hints:
            return hints[s]
        if s == 0:
            return f"Can't reach {service}: {msg}" if msg else f"Can't reach {service}."
        if s == 401:
            if "restricted" in msg.lower():
                # Resend `restricted_api_key`: a Sending-access key can't read emails or domains.
                return "This key can only send emails. Use a Full access key to see them here."
            return "The key was refused (401). Check it in Settings → Services."
        if s == 403:
            return f"Not allowed with this key (403). {msg[:160]}".strip()
        if s == 404:
            return "Not found (404)."
        if s == 429:
            return "Rate limited (429). Trying again later."
        if s >= 500:
            return f"{service} is having trouble ({s}). Trying again later."
        return msg[:160] or f"Error {s}"
    if isinstance(err, ServiceError):
        return err.message
    return str(err) or err.__class__.__name__


MAX_BACKOFF = 900.0


def backoff_delay(interval: float, failures: int, retry_after: Optional[float] = None) -> float:
    """Seconds before the next try after ``failures`` errors in a row: doubling, capped
    at 15 minutes (or the interval when that is longer), never before a ``Retry-After``."""
    delay = min(interval * (2 ** max(1, min(failures, 10))), max(MAX_BACKOFF, interval))
    if retry_after:
        delay = max(delay, retry_after)
    return float(delay)


# ── small parsing helpers ───────────────────────────────────────────────────────

def parse_date(value: Any) -> Optional[float]:
    """Epoch seconds from what APIs send: epoch s/ms, ISO 8601, Resend's
    ``2024-05-01 10:00:00.123456+00``."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value) / 1000 if value > 1e11 else float(value)
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip().replace("Z", "+00:00")
    if len(text) > 3 and text[-3] in "+-" and text[-3:][1:].isdigit() and ":" not in text[-6:]:
        text += ":00"   # "+00" → "+00:00"
    if " " in text and "T" not in text:
        text = text.replace(" ", "T", 1)
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def num(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def as_id(value: Any) -> Optional[str]:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str) and value:
        return value
    return None


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


def first_line(text: str) -> str:
    return text.split("\n", 1)[0] if text else ""


# ── the Service base ────────────────────────────────────────────────────────────

class Service:
    """One polled API. Subclasses set the class attributes and implement ``fetch``.

    Services are stateless: what a poll needs from the last one (the last charge
    seen, runs kept…) comes back through ``prev.state``, so the hub holds all state
    and ``events(old, new)`` is a pure diff.
    """

    id: str = ""
    display_name: str = ""
    #: Seconds between polls (``next_interval`` can adapt it).
    interval: float = 60.0
    #: Seconds before the first poll once configured.
    first_delay: float = 5.0
    #: Bridge topic the snapshot is published on.
    topic: str = "services"
    #: field name → env var holding the secret, all required.
    secrets: Mapping[str, str] = {}
    secret_labels: Mapping[str, str] = {}
    #: Non-secret settings (services.json) and their defaults.
    settings: Mapping[str, Any] = {}
    required_settings: tuple = ()
    #: Action kinds this service can perform (subset of ``actions.ALLOWED``).
    actions: frozenset = frozenset()
    #: status → hint shown instead of the generic one.
    hints: Mapping[int, str] = {}

    def configured(self, cfg) -> bool:
        return (all(cfg.secret(env) for env in self.secrets.values())
                and all(cfg.setting(self.id, k) for k in self.required_settings))

    def fetch(self, http, cfg, prev: Optional[Snapshot] = None, now: Optional[float] = None) -> Snapshot:
        raise NotImplementedError

    def detail(self, http, cfg, now: Optional[float] = None) -> Detail:
        return Detail(self.id, self.display_name, fetched_at=now or time.time(),
                      error="Not available up close yet.")

    def perform(self, http, cfg, kind: str, target: str) -> str:
        raise ServiceError("This action isn't available.")

    def events(self, old_state: Any, new_state: Any) -> list:
        return []

    def next_interval(self, snapshot: Snapshot) -> float:
        return self.interval

    def describe(self, err: BaseException) -> str:
        return describe(err, self.display_name, self.hints)

    def error_snapshot(self, message: str, now: float) -> Snapshot:
        return Snapshot(self.id, self.display_name, ERROR, f"Can't reach {self.display_name}",
                        message, [], now, error=message)

    def missing_key_detail(self, now: float) -> Detail:
        return Detail(self.id, self.display_name, fetched_at=now,
                      error=f"No {self.display_name} key yet. Add it in Settings → Services.")
