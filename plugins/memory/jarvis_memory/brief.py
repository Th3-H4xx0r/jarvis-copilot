"""The "now" brief: what's going on in his life, ready before he asks.

Built in the background (every 10 minutes, and ~20 s after new memories, a
calendar snapshot or a location arrive) and read from a cache, so a turn never
waits for it. It rides at the top of the turn's memory block, so "navigate to
the venue" already knows the venue.

Sections come from sources: built in here (now, coming up, active lately,
people lately, pinned) and registered by the web server for what only it can
reach (where he is, health, inbox, messages, home, tasks). A source that fails
or runs past its timeout is left out; the brief still builds.
"""
from __future__ import annotations

import logging
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

HEADER = "[Now — what's going on in his life]"
MAX_CHARS = 3200
HORIZON_DAYS = 14
LOOKBACK_DAYS = 3


@dataclass
class BriefCtx:
    now: datetime
    zone: object
    store: object
    namespace: str
    horizon_days: int = HORIZON_DAYS
    lookback_days: int = LOOKBACK_DAYS
    data: Dict[str, list] = field(default_factory=dict)


_lock = threading.Lock()
_sources: Dict[str, tuple] = {}     # name -> (order, fn, timeout)
_data: Dict[str, tuple] = {}        # name -> (fn, timeout): items for "coming up"
# One brief per namespace: the gateway keeps each user in user:<id>, and one
# user's plans must never show up in another's turns.
_states: Dict[str, dict] = {}
_pool = ThreadPoolExecutor(max_workers=6, thread_name_prefix="jarvis-brief")


def register_source(name: str, fn: Callable[[BriefCtx], Optional[str]], order: int,
                    timeout_s: float = 3.0) -> None:
    with _lock:
        _sources[name] = (order, fn, timeout_s)


def register_data(name: str, fn: Callable[[BriefCtx], list], timeout_s: float = 3.0) -> None:
    """Items ``{title, start, end?, all_day?, location?}`` merged into Coming up."""
    with _lock:
        _data[name] = (fn, timeout_s)


def reset() -> None:
    """Back to the built-in sources and an empty cache (tests)."""
    with _lock:
        _sources.clear()
        _data.clear()
        for st in _states.values():
            st["stop"].set()
            st["dirty"].set()
        _states.clear()
    _register_builtins()


def _state_for(namespace: str) -> dict:
    with _lock:
        st = _states.get(namespace)
        if st is None:
            st = {"text": "", "built_at": 0.0, "store": None, "thread": None,
                  "stop": threading.Event(), "dirty": threading.Event()}
            _states[namespace] = st
        return st


def _set_text(text: str, namespace: str = "global") -> None:
    st = _state_for(namespace)
    st.update(text=text, built_at=time.time())


def current_text(namespace: str = "global") -> str:
    """The cached brief, with its "Now:" line made current (the rest can be
    up to ten minutes old; the clock can't)."""
    st = _states.get(namespace)
    text = st["text"] if st else ""
    if not text:
        return ""
    lines = text.split("\n")
    for i, line in enumerate(lines[:3]):
        if line.startswith("Now: "):
            try:
                from . import tz
                zone = tz.user_zone()
                lines[i] = _now_line(datetime.now(zone))
            except Exception:
                pass
            break
    return "\n".join(lines)


def mark_dirty() -> None:
    for st in list(_states.values()):
        st["dirty"].set()


# ── formatting helpers ────────────────────────────────────────────────────
def _day(ts: float, zone) -> str:
    d = datetime.fromtimestamp(ts, zone)
    return f"{d:%a} {d.day} {d:%b}"


def _clock(d: datetime) -> str:
    return d.strftime("%I:%M %p").lstrip("0")


def _span(start: float, end: Optional[float], zone, all_day: bool = False) -> str:
    a = datetime.fromtimestamp(start, zone)
    text = _day(start, zone)
    if end and end - start > 86400 - 60:
        b = datetime.fromtimestamp(end, zone)
        if b.date() != a.date():
            text = f"{a:%a} {a.day}–{b:%a} {b.day} {b:%b}" if a.month == b.month else \
                f"{_day(start, zone)} – {_day(end, zone)}"
    elif not all_day and (a.hour or a.minute):
        text += f" {_clock(a)}"
    return text


def _names(store, ids) -> List[str]:
    ents = store.get_entities(ids)
    return [ents[i]["canonical"] for i in ids if i in ents]


# ── built-in sources ──────────────────────────────────────────────────────
def _now_line(n: datetime) -> str:
    return f"Now: {n:%a} {n.day} {n:%b}, {_clock(n)} {n:%Z}"


def _now_source(ctx: BriefCtx) -> str:
    return _now_line(ctx.now)


def _coming_up(ctx: BriefCtx) -> Optional[str]:
    s, ns, zone = ctx.store, ctx.namespace, ctx.zone
    start = ctx.now.timestamp()
    end = (ctx.now + timedelta(days=ctx.horizon_days)).timestamp()
    rows = []  # (start, line, title_key)
    for eid in s.event_entities_in_window(ns, start, end):
        ent = s.get_entities([eid]).get(eid)
        if not ent:
            continue
        mems = s.memories_for_entities([eid], 30)
        if not mems:
            continue  # every memory about it was forgotten or hidden
        links = s.entities_for(mems)
        places, people = [], []
        for mid in mems:
            for other, role in links.get(mid, []):
                if other == eid:
                    continue
                if role in ("venue", "place", "location") and other not in places:
                    places.append(other)
                elif role in ("with", "organizer") and other not in people:
                    people.append(other)
        line = f"- {_span(ent['event_start'], ent.get('event_end'), zone)}: {ent['canonical']}"
        place_names = _names(s, places[:1])
        if place_names:
            line += f" @ {place_names[0]}"
        people_names = _names(s, people[:4])
        if people_names:
            line += f" — with {', '.join(people_names)}"
        notes = [c for c in s.get_chunks(mems[:8]) if not c.valid_to and c.kind in ("plan", "fact", "event")]
        notes.sort(key=lambda c: -(c.importance or 5))
        extra = "; ".join(" ".join(c.body.split())[:90] for c in notes[:2])
        if extra:
            line += f" ({extra})"
        rows.append((ent["event_start"], line, ent["canonical"].lower()))
    seen = {key for _, _, key in rows}
    # Memories about something upcoming that no event entity covers yet.
    for c in s.get_chunks(s.ids_in_window(ns, start, end, 20)):
        if not c.event_start or c.valid_to or s.entities_for([c.id]).get(c.id):
            continue
        rows.append((c.event_start, f"- {_span(c.event_start, c.event_end, zone)}: "
                                    f"{' '.join(c.body.split())[:140]}", c.body.lower()[:60]))
    for item in ctx.data.get("calendar", []):
        title = str(item.get("title") or "").strip()
        at = item.get("start")
        if not title or at is None or not (start - 86400 <= float(at) <= end):
            continue
        if title.lower() in seen:
            continue
        seen.add(title.lower())
        line = f"- {_span(float(at), item.get('end'), zone, bool(item.get('all_day')))}: {title}"
        if item.get("location"):
            line += f" @ {item['location']}"
        rows.append((float(at), line + " (calendar)", title.lower()))
    if not rows:
        return None
    rows.sort(key=lambda r: r[0])
    return "Coming up (next two weeks)\n" + "\n".join(r[1] for r in rows[:12])


def _active_lately(ctx: BriefCtx) -> Optional[str]:
    since = (ctx.now - timedelta(days=ctx.lookback_days)).timestamp()
    horizon = (ctx.now + timedelta(days=ctx.horizon_days)).timestamp()
    rows = ctx.store.recent_entity_counts(ctx.namespace, since, ["event", "topic"])
    ents = ctx.store.get_entities([eid for eid, _ in rows])
    names = []
    for eid, _n in rows:
        e = ents.get(eid)
        if not e:
            continue
        upcoming = e.get("event_start") and ctx.now.timestamp() <= e["event_start"] <= horizon
        if not upcoming:  # already listed under Coming up
            names.append(e["canonical"])
    return "Active lately: " + ", ".join(names[:8]) if names else None


def _people_lately(ctx: BriefCtx) -> Optional[str]:
    since = (ctx.now - timedelta(days=ctx.lookback_days)).timestamp()
    rows = ctx.store.recent_entity_counts(ctx.namespace, since, ["person"])
    names = _names(ctx.store, [eid for eid, _ in rows[:6]])
    return "People lately: " + ", ".join(names) if names else None


def _pinned(ctx: BriefCtx) -> Optional[str]:
    chunks = ctx.store.pinned_chunks(ctx.namespace)
    if not chunks:
        return None
    return "Pinned\n" + "\n".join(f"- {' '.join(c.body.split())[:160]}" for c in chunks)


def _register_builtins() -> None:
    register_source("now", _now_source, order=0)
    register_source("coming_up", _coming_up, order=10)
    register_source("active_lately", _active_lately, order=20)
    register_source("people_lately", _people_lately, order=30)
    register_source("pinned", _pinned, order=95)


_register_builtins()


# ── building ──────────────────────────────────────────────────────────────
def build(store, namespace, *, now: Optional[datetime] = None, zone=None) -> str:
    from . import tz
    zone = zone or (now.tzinfo if now is not None else None) or tz.user_zone()
    now = now or datetime.now(zone)
    ctx = BriefCtx(now=now, zone=zone, store=store, namespace=namespace)
    with _lock:
        sources = sorted(_sources.items(), key=lambda kv: kv[1][0])
        data = dict(_data)
    futures = {name: (_pool.submit(fn, ctx), timeout) for name, (fn, timeout) in data.items()}
    for name, (fut, timeout) in futures.items():
        try:
            ctx.data[name] = list(fut.result(timeout=timeout) or [])
        except Exception:
            ctx.data[name] = []
    started = {name: (_pool.submit(fn, ctx), timeout) for name, (_o, fn, timeout) in sources}
    parts = []
    deadline = time.monotonic() + max((t for _n, (_o, _f, t) in sources), default=3.0)
    for name, (_order, _fn, timeout) in sources:
        fut, _t = started[name]
        try:
            text = fut.result(timeout=max(0.0, min(timeout, deadline - time.monotonic())))
        except FutureTimeout:
            logger.info("jarvis_memory brief: %s took too long; left out", name)
            continue
        except Exception as exc:
            logger.info("jarvis_memory brief: %s failed (%s); left out", name, exc)
            continue
        text = (text or "").strip()
        if text:
            parts.append(text)
    out = HEADER
    for part in parts:
        if len(out) + 2 + len(part) > MAX_CHARS:
            room = MAX_CHARS - len(out) - 3
            if room > 80:
                out += "\n" + part[:room].rsplit("\n", 1)[0]
            break
        out += "\n" + part
    return out[:MAX_CHARS]


def rebuild(namespace: str = "global") -> str:
    st = _state_for(namespace)
    store = st["store"]
    if store is None:
        return st["text"]
    try:
        text = build(store, namespace)
    except Exception:
        logger.warning("jarvis_memory brief build failed", exc_info=True)
        return st["text"]
    _set_text(text, namespace)
    return text


def start(store, namespace, *, interval: float = 600.0, debounce: float = 20.0) -> None:
    """Build now, then every ``interval`` s and ``debounce`` s after ``mark_dirty``."""
    st = _state_for(namespace)
    with _lock:
        st["store"] = store
        thread = st["thread"]
        if thread is not None and thread.is_alive():
            st["dirty"].set()
            return
        stop, dirty = st["stop"], st["dirty"]

        def run():
            rebuild(namespace)
            while not stop.is_set():
                fired = dirty.wait(interval)
                if stop.is_set():
                    return
                if fired:
                    time.sleep(debounce)
                    dirty.clear()
                rebuild(namespace)

        thread = threading.Thread(target=run, daemon=True, name=f"jarvis-mem-brief-{namespace}")
        st["thread"] = thread
        thread.start()
