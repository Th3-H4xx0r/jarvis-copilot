"""Per-agent Live Activities on the iPhone: one ActivityKit activity per agent TYPE.

Claude (Claude Code and Claude Desktop together), Codex, Gemini, Copilot, Cursor,
OpenCode, Amp, Antigravity, Muse and Jarvis each get their own activity, grouping
that agent's live sessions: the lead session (the one that needs you first, else
the most recently active), its state and current step, how many others there
are, and the Allow / Deny buttons for a request the phone can actually answer.

The server owns the content: the app reads the same states from
``GET /api/coding/agent-la/state`` while it is in the foreground, and this module
pushes them over APNs while it is suspended or closed —

* **push-to-start** (iOS 17.2+): the phone registers its
  ``Activity<AgentActivityAttributes>.pushToStartTokenUpdates`` token; the first
  live session of an agent starts that agent's activity even with the app closed;
* **push-to-update**: every activity reports its own push token, tagged with its
  agent; state TRANSITIONS go out (never the per-tool step ticker), deduped and
  rate-limited per activity like ``coding_la_push``;
* **push-to-end**: when every session of the agent has ended, or the group has been
  idle for the "End after idle for" setting (default 30 min).

Content-state keys MUST match the Swift ``AgentActivityAttributes.ContentState``
(``CONTENT_KEYS``); every key is always sent. The whole state stays far under the
4 KB ActivityKit budget (strings are clamped; asserted by the tests).
"""
from __future__ import annotations

import hashlib
import json
import logging
import threading
import time
from typing import Callable, Iterable, Optional

from agent.coding_la_push import _folder, _is_live, _live_state, _recency, _sanitize

log = logging.getLogger(__name__)

#: Every agent type that gets its own activity, in settings order.
AGENTS = ("claude", "codex", "gemini", "copilot", "cursor", "opencode", "amp",
          "antigravity", "muse", "jarvis")
_GROUP_OF = {a: a for a in AGENTS}
_GROUP_OF["claude-desktop"] = "claude"

_DISPLAY = {"claude": "Claude Code", "claude-desktop": "Claude Desktop", "codex": "Codex",
            "gemini": "Gemini CLI", "copilot": "Copilot CLI", "cursor": "Cursor",
            "opencode": "OpenCode", "amp": "Amp", "antigravity": "Antigravity",
            "muse": "Muse Code", "jarvis": "Jarvis"}
_GROUP_TITLE = {"claude": "Claude", "codex": "Codex", "gemini": "Gemini", "copilot": "Copilot",
                "cursor": "Cursor", "opencode": "OpenCode", "amp": "Amp",
                "antigravity": "Antigravity", "muse": "Muse", "jarvis": "Jarvis"}

#: The Swift ``ActivityAttributes`` type a push-to-start names.
ATTRIBUTES_TYPE = "AgentActivityAttributes"
#: Where the phone's tokens live (Code Master key/value store, so profile-scoped).
REGISTRY_KEY = "agent_la_tokens"
#: The Code Master settings document and its key for these settings.
SETTINGS_DOC = "notifications"
SETTINGS_KEY = "agent_live"

IDLE_CHOICES = (10, 30, 60)
DEFAULT_IDLE_MINUTES = 30

#: States that keep an activity up regardless of the idle window.
ACTIVE_STATES = frozenset({"working", "thinking", "approval", "question"})
WAITING_STATES = frozenset({"approval", "question"})

CONTENT_KEYS = ("count", "waiting", "working", "name", "project", "state", "step",
                "fingerprint", "kind", "since", "key", "bar", "actions", "last",
                "waitingSince", "question", "options")
MAX_BAR = 8
_STEP_LIMIT = 60
_KEY_LIMIT = 120
_FP_LIMIT = 64
_QUESTION_LIMIT = 90
#: A question's options become Lock Screen buttons only when they fit.
MAX_OPTIONS = 3
OPTION_LIMIT = 20

#: Between two non-urgent pushes to one activity (a Live Activity is
#: last-write-wins, so a burst collapses into the next push). Same as coding_la_push.
MIN_PUSH_INTERVAL = 15.0


# ── naming ────────────────────────────────────────────────────────────────────

def group_of(agent) -> Optional[str]:
    """The activity an agent's sessions live in, or None for an agent we don't know."""
    return _GROUP_OF.get(str(agent or "").strip().lower())


def display_name(agent) -> str:
    a = str(agent or "").strip().lower()
    return _DISPLAY.get(a) or (a.capitalize() if a else "Agent")


def group_title(group) -> str:
    return _GROUP_TITLE.get(group) or display_name(group)


# ── settings ──────────────────────────────────────────────────────────────────

def default_settings() -> dict:
    return {"enabled": True, "agents": {a: True for a in AGENTS},
            "idle_minutes": DEFAULT_IDLE_MINUTES, "actions": True}


def merge_settings(stored, base=None) -> dict:
    """Overlay ``stored`` on ``base`` (the defaults when None). Only real bools
    count and the idle window must be one of ``IDLE_CHOICES``, so a stray value can
    never flip a switch; keys a client leaves out keep their ``base`` value, so a
    partial save (the Dynamic Island tab, an older app) changes only what it sent."""
    out = default_settings()
    if isinstance(base, dict):
        out = merge_settings(base)
    if not isinstance(stored, dict):
        return out
    for key in ("enabled", "actions"):
        if isinstance(stored.get(key), bool):
            out[key] = stored[key]
    idle = stored.get("idle_minutes")
    if isinstance(idle, int) and not isinstance(idle, bool) and idle in IDLE_CHOICES:
        out["idle_minutes"] = idle
    agents = stored.get("agents")
    if isinstance(agents, dict):
        for a in AGENTS:
            if isinstance(agents.get(a), bool):
                out["agents"][a] = agents[a]
    return out


def _stored_settings(store) -> Optional[dict]:
    doc = store.get_setting(SETTINGS_DOC, None)
    return doc.get(SETTINGS_KEY) if isinstance(doc, dict) else None


def agent_activities_on(store) -> bool:
    """True while per-agent activities are on — the Jarvis activity then stops
    carrying the coding fleet. A store without settings (an old one) keeps the
    legacy behaviour: coding stays on the Jarvis activity."""
    try:
        return bool(merge_settings(_stored_settings(store))["enabled"])
    except Exception:  # noqa: BLE001
        return False


# ── sessions ──────────────────────────────────────────────────────────────────

def _num(v, default=0.0) -> float:
    try:
        n = float(v)
    except (TypeError, ValueError):
        return default
    return n / 1000.0 if n > 1e12 else n


def _clamp(text, limit) -> str:
    t = " ".join(str(text or "").split())
    return t if len(t) <= limit else t[: limit - 1] + "…"


def _from_tracked(s: dict) -> Optional[dict]:
    if group_of(s.get("agent")) is None:
        return None
    pend = s.get("pending") or {}
    kind = pend.get("kind")
    turn = s.get("turn_summary") or {}
    question, options = _first_question(pend.get("questions"))
    return {"question": question, "options": options,
            "key": str(s.get("key") or ""), "agent": str(s.get("agent") or "claude").lower(),
            "project": str(s.get("project") or "session"),
            "state": str(s.get("state") or "idle"), "step": str(s.get("step") or ""),
            "fingerprint": str(pend.get("fingerprint") or ""),
            "kind": kind if kind in ("approval", "question") else "",
            "since": _num(turn.get("started_at") or s.get("started_at")),
            "last": _num(s.get("last_event_at"))}


def _first_question(questions):
    """(question text, option labels) of an AskUserQuestion. The labels come
    back only when they can be Lock Screen buttons — one single-select question
    with a few short options — else [] and the activity shows one Answer button."""
    if not isinstance(questions, list) or not questions or not isinstance(questions[0], dict):
        return "", []
    q = questions[0]
    text = _clamp(q.get("question"), _QUESTION_LIMIT)
    labels = [str((o or {}).get("label") or "").strip() for o in (q.get("options") or [])
              if isinstance(o, dict)]
    fits = (len(questions) == 1 and not q.get("multiSelect") and 0 < len(labels) <= MAX_OPTIONS
            and all(0 < len(lbl) <= OPTION_LIMIT for lbl in labels))
    return text, labels if fits else []


_ROW_STATE = {"waiting": "approval", "working": "working"}


def _from_row(r: dict, projects: dict) -> dict:
    """A live coding_sessions row no hook is talking for — a Claude Code session
    whose state comes from the pane scraper. Waiting has no fingerprint: nothing
    holds that prompt, so it gets no buttons."""
    proj = projects.get(r.get("project_id")) if r.get("project_id") else None
    state = _ROW_STATE.get(_live_state(r), "idle")
    return {"key": "row:" + str(r.get("id") or ""), "agent": "claude",
            "project": (proj or {}).get("name") or _folder(r.get("cwd")),
            "state": state, "step": "", "fingerprint": "",
            "kind": "approval" if state == "approval" else "",
            "since": _num(r.get("created_at")), "last": _recency(r),
            "question": "", "options": []}


def collect_sessions(tracked: Iterable[dict], rows: Iterable[dict], projects: dict) -> list:
    """Hook-tracked sessions of every agent, plus live coding rows no hook owns."""
    out, linked = [], set()
    for s in tracked or ():
        if not isinstance(s, dict):
            continue
        if s.get("coding_session_id"):
            linked.add(s["coding_session_id"])
        n = _from_tracked(s)
        if n is not None:
            out.append(n)
    for r in rows or ():
        if isinstance(r, dict) and _is_live(r) and r.get("id") not in linked:
            out.append(_from_row(r, projects or {}))
    return out


def group_sessions(sessions) -> dict:
    groups: dict = {}
    for s in sessions:
        g = group_of(s.get("agent"))
        if g:
            groups.setdefault(g, []).append(s)
    return groups


def is_active(s) -> bool:
    return s.get("state") in ACTIVE_STATES


def lead_of(sessions) -> Optional[dict]:
    """The one that needs you first (the earliest still waiting), else the most
    recently active."""
    if not sessions:
        return None
    waiting = [s for s in sessions if s.get("state") in WAITING_STATES]
    if waiting:
        return min(waiting, key=lambda s: (s.get("last") or 0, s.get("key") or ""))
    return max(sessions, key=lambda s: (s.get("last") or 0, s.get("key") or ""))


def idle_since(sessions) -> float:
    return max((s.get("last") or 0 for s in sessions), default=0.0)


def wanted(sessions, now: float, idle_minutes: int, ongoing: bool = True) -> bool:
    """An activity shows while any session works or waits on you, and — once it
    is up (``ongoing``) — for ``idle_minutes`` after the group's last activity.
    Idle sessions alone never START one (eleven idle Jarvis sessions put an
    "IDLE" activity in the island for nothing)."""
    if not sessions:
        return False
    if any(is_active(s) for s in sessions):
        return True
    return ongoing and now - idle_since(sessions) < idle_minutes * 60


_URGENCY = {"approval": 0, "question": 0, "error": 1, "ratelimit": 2, "working": 3,
            "thinking": 3, "finished": 4, "idle": 5}
_SHORT = {"approval": "p", "question": "p", "working": "w", "thinking": "w", "error": "e"}


def content_state(sessions, *, actions: bool, decidable) -> dict:
    """The ``AgentActivityAttributes.ContentState`` for one agent's sessions."""
    lead = lead_of(sessions) or {}
    fp = lead.get("fingerprint") or ""
    if fp not in (decidable or ()):
        fp = ""   # nothing holds that request: a tap could not reach it
    ordered = sorted(sessions, key=lambda s: (_URGENCY.get(s.get("state"), 9), -(s.get("last") or 0)))
    return {
        "count": len(sessions),
        "waiting": sum(1 for s in sessions if s.get("state") in WAITING_STATES),
        "working": sum(1 for s in sessions if s.get("state") in ("working", "thinking")),
        "name": display_name(lead.get("agent")) if lead else "",
        "project": _sanitize(lead.get("project") or ""),
        "state": str(lead.get("state") or "idle"),
        "step": _clamp(lead.get("step"), _STEP_LIMIT),
        "fingerprint": fp[:_FP_LIMIT],
        "kind": str(lead.get("kind") or ""),
        "since": float(lead.get("since") or 0),
        "key": str(lead.get("key") or "")[:_KEY_LIMIT],
        "bar": ",".join(_SHORT.get(s.get("state"), "i") for s in ordered[:MAX_BAR]),
        "actions": bool(actions),
        "last": float(idle_since(sessions)),
        # When the lead started waiting on you (its last event is the request).
        "waitingSince": float(lead.get("last") or 0) if lead.get("state") in WAITING_STATES else 0.0,
        "question": str(lead.get("question") or "") if lead.get("state") == "question" else "",
        "options": list(lead.get("options") or []) if lead.get("state") == "question" else [],
    }


def desired_states(tracked, rows, projects, settings, *, now: float, decidable,
                   ongoing=None) -> dict:
    """{group: content_state} for every agent whose activity should be up now.
    ``ongoing`` names the groups whose activity is already up (None = all, for
    callers that don't track it)."""
    cfg = merge_settings(settings)
    if not cfg["enabled"]:
        return {}
    out = {}
    groups = group_sessions(collect_sessions(tracked, rows, projects))
    for g in AGENTS:
        sessions = groups.get(g) or []
        running = True if ongoing is None else g in ongoing
        if cfg["agents"].get(g) and wanted(sessions, now, cfg["idle_minutes"], ongoing=running):
            out[g] = content_state(sessions, actions=cfg["actions"], decidable=decidable)
    return out


def _sig(cs: dict) -> str:
    # The step and timestamps move on every tool call; leaving them out keeps the
    # activity on state changes only (the next real push carries the current step).
    src = {k: v for k, v in cs.items() if k not in ("step", "since", "last")}
    return hashlib.sha1(json.dumps(src, sort_keys=True).encode()).hexdigest()


def relevance(cs: dict) -> int:
    """How strongly iOS should prefer this activity for the Dynamic Island when
    several run (APNs ``relevance-score``). Mirrors the Swift
    ``AgentActivityAttributes.ContentState.relevance``; the Jarvis activity is 0
    when idle and 100 during a voice turn."""
    if cs.get("state") in WAITING_STATES:
        return 80
    if cs.get("state") in ("working", "thinking"):
        return 40
    return 5


def _alert(group: str, cs: dict) -> dict:
    who = cs.get("name") or group_title(group)
    body = cs.get("project") or ""
    if cs.get("state") in WAITING_STATES:
        return needs_you_alert(group, cs)
    return {"title": who, "body": body or "Working"}


def needs_you_alert(group: str, cs: dict) -> dict:
    """The banner (with sound) an update carries when the lead starts waiting on
    you: it lights the screen and pops the island open on the Allow / Deny view."""
    who = cs.get("name") or group_title(group)
    project = cs.get("project") or "session"
    if cs.get("state") == "question":
        title = f"{who} has a question"
        body = f"{project}: {cs.get('question') or cs.get('step') or 'tap to answer'}"
    else:
        title = f"{who} is waiting for your OK"
        step = str(cs.get("step") or "")
        if step.lower().startswith("needs approval:"):
            step = step.split(":", 1)[1].strip()
        body = f"{project}: {step}" if step else project
    return {"title": title, "body": body[:180], "sound": "default"}


# ── the pusher ────────────────────────────────────────────────────────────────

class AgentLaPusher:
    """Keeps every phone's per-agent activities in step with the sessions.

    ``tracked`` returns the hook tracker's compact sessions, ``settings`` the
    stored ``agent_live`` dict (or None), ``pending`` the fingerprints the phone
    can actually answer (requests an arbiter holds). Never raises from ``tick``."""

    def __init__(self, store, *, tracked: Callable[[], list] = lambda: [],
                 settings: Callable[[], Optional[dict]] = lambda: None,
                 pending: Callable[[], Iterable[str]] = lambda: (),
                 sender=None, clock=time.time, mono=time.monotonic) -> None:
        self.store = store
        self._tracked = tracked
        self._settings = settings
        self._pending = pending
        self._sender = sender
        self._clock = clock
        self._mono = mono
        self._lock = threading.RLock()
        # group -> {"id": episode id, "started": {device}, "suppressed": {device}}
        self._episodes: dict = {}
        # (device, group) -> {"sig", "ts", "cs"}
        self._pushed: dict = {}

    # ── tokens ───────────────────────────────────────────────────────────
    def _registry(self) -> dict:
        try:
            reg = self.store.get_setting(REGISTRY_KEY, None)
        except Exception:  # noqa: BLE001
            return {}
        return reg if isinstance(reg, dict) else {}

    def _save(self, reg: dict) -> None:
        try:
            self.store.set_setting(REGISTRY_KEY, reg)
        except Exception:  # noqa: BLE001
            log.debug("agent LA token save failed", exc_info=True)

    @staticmethod
    def _device(reg, device_id) -> dict:
        dev = reg.setdefault(device_id or "unknown", {})
        if not isinstance(dev.get("activities"), dict):
            dev["activities"] = {}
        return dev

    def register_start_token(self, device_id: str, token: str) -> None:
        """The phone's push-to-start token (one per app install, rotates)."""
        token = (token or "").strip()
        with self._lock:
            reg = self._registry()
            dev = self._device(reg, device_id)
            if token:
                dev["start"] = token
            else:
                dev.pop("start", None)
            self._save(reg)

    def forget_device(self, device_id: str) -> None:
        """The phone turned Live Activities off: stop pushing to it at all."""
        with self._lock:
            reg = self._registry()
            reg.pop(device_id or "unknown", None)
            self._save(reg)
            for key in [k for k in self._pushed if k[0] == (device_id or "unknown")]:
                self._pushed.pop(key, None)

    def register_activity_token(self, device_id: str, agent: str, token: str) -> int:
        """One running activity's push token. Sends it the current state at once
        (or ends it, if its agent isn't wanted any more)."""
        group, token = group_of(agent), (token or "").strip()
        if group is None or not token:
            return 0
        device = device_id or "unknown"
        with self._lock:
            reg = self._registry()
            self._device(reg, device)["activities"][group] = token
            self._save(reg)
            self._pushed.pop((device, group), None)
            desired = self._desired()
            ep = self._episodes.get(group)
            if ep is not None:
                ep["started"].add(device)
            if group in desired:
                return self._push_update(reg, device, group, token, desired[group], force=True)
            return self._push_end(reg, device, group, token)

    def activity_ended(self, device_id: str, agent: str, token: str = "",
                       dismissed: bool = False) -> None:
        """An activity ended on the phone. ``dismissed`` (swiped away by you) keeps
        it from being started again until that agent's next episode."""
        group, device = group_of(agent), device_id or "unknown"
        if group is None:
            return
        with self._lock:
            reg = self._registry()
            acts = self._device(reg, device)["activities"]
            if not token or acts.get(group) == token:
                acts.pop(group, None)
                self._save(reg)
                self._pushed.pop((device, group), None)
            if dismissed and group in self._episodes:
                self._episodes[group]["suppressed"].add(device)

    # ── state ────────────────────────────────────────────────────────────
    def _source(self, fn, default):
        try:
            v = fn()
            return default if v is None else v
        except Exception:  # noqa: BLE001
            log.debug("agent LA source failed", exc_info=True)
            return default

    def _desired(self) -> dict:
        tracked = self._source(self._tracked, [])
        rows, projects = [], {}
        try:
            rows = self.store.list_sessions()
            projects = {p["id"]: p for p in self.store.list_projects()}
        except Exception:  # noqa: BLE001
            pass
        decidable = set(self._source(self._pending, ()))
        desired = desired_states(tracked, rows, projects, self._source(self._settings, None),
                                 now=self._clock(), decidable=decidable,
                                 ongoing=set(self._episodes))
        # Episodes: one per stretch of time an agent's activity is wanted.
        for g in desired:
            if g not in self._episodes:
                self._episodes[g] = {"id": f"{g}-{int(self._clock() * 1000)}",
                                     "started": set(), "suppressed": set()}
        for g in [g for g in self._episodes if g not in desired]:
            self._episodes.pop(g, None)
        return desired

    def snapshot(self) -> dict:
        """What the app shows while it's in the foreground (``/agent-la/state``)."""
        with self._lock:
            desired = self._desired()
            return {"settings": merge_settings(self._source(self._settings, None)),
                    "activities": [{"agent": g, "episode": self._episodes[g]["id"], "state": cs}
                                   for g, cs in desired.items()]}

    # ── pushing ──────────────────────────────────────────────────────────
    def _send(self, token, cs, **kw) -> dict:
        sender = self._sender
        if sender is None:
            try:
                from api.push.apns import send_live_activity as sender  # noqa: PLC0415
            except Exception:  # noqa: BLE001
                return {"ok": False, "error": "no APNs sender"}
        try:
            return sender(token, cs, **kw) or {}
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": f"raised: {exc}"}

    @staticmethod
    def _dead(res) -> bool:
        return res.get("status") in (400, 410)

    def _push_update(self, reg, device, group, token, cs, force=False) -> int:
        key = (device, group)
        prev = self._pushed.get(key) or {}
        sig = _sig(cs)
        if not force and sig == prev.get("sig"):
            return 0
        last_cs = prev.get("cs") or {}
        urgent = bool(cs["fingerprint"] and cs["fingerprint"] != last_cs.get("fingerprint")) \
            or cs["waiting"] > int(last_cs.get("waiting") or 0)
        now = self._mono()
        if not force and not urgent and now - prev.get("ts", -1e18) < MIN_PUSH_INTERVAL:
            return 0   # rate-limited: the next tick re-sends once the window passes
        extra = {"relevance-score": relevance(cs)}
        newly_waiting = cs["state"] in WAITING_STATES and (
            last_cs.get("state") not in WAITING_STATES
            or cs["fingerprint"] != last_cs.get("fingerprint", ""))
        if newly_waiting:
            extra["alert"] = needs_you_alert(group, cs)
        res = self._send(token, cs, event="update", priority=10 if (urgent or force) else 5,
                         extra=extra)
        if res.get("ok"):
            self._pushed[key] = {"sig": sig, "ts": now, "cs": cs}
            return 1
        log.warning("agent LA update failed (%s, token …%s): %s", group, str(token)[-6:],
                    res.get("error"))
        if self._dead(res):
            # The activity is gone (ended on the phone while the app was closed):
            # forget it, and don't start a new one this episode.
            self._device(reg, device)["activities"].pop(group, None)
            self._save(reg)
            self._pushed.pop(key, None)
            if group in self._episodes:
                self._episodes[group]["suppressed"].add(device)
        return 0

    def _push_end(self, reg, device, group, token) -> int:
        last = (self._pushed.get((device, group)) or {}).get("cs")
        cs = dict(last) if last else content_state([], actions=False, decidable=())
        cs.update({"fingerprint": "", "actions": False})
        res = self._send(token, cs, event="end", priority=10, dismissal_after=0)
        self._device(reg, device)["activities"].pop(group, None)
        self._save(reg)
        self._pushed.pop((device, group), None)
        return 1 if res.get("ok") else 0

    def _push_start(self, reg, device, group, token, cs) -> int:
        extra = {"attributes-type": ATTRIBUTES_TYPE, "attributes": {"agent": group},
                 "alert": _alert(group, cs), "input-push-token": 1,
                 "relevance-score": relevance(cs)}
        res = self._send(token, cs, event="start", priority=10, extra=extra)
        self._episodes[group]["started"].add(device)
        if res.get("ok"):
            return 1
        log.warning("agent LA push-to-start failed (%s, token …%s): %s", group,
                    str(token)[-6:], res.get("error"))
        if self._dead(res):
            self._device(reg, device).pop("start", None)
            self._save(reg)
        return 0

    def tick(self, force: bool = False) -> int:
        """Start, update and end every phone's activities. Returns pushes sent."""
        try:
            with self._lock:
                return self._tick(force)
        except Exception:  # noqa: BLE001
            log.debug("agent LA tick failed", exc_info=True)
            return 0

    def _tick(self, force) -> int:
        desired = self._desired()
        reg = self._registry()
        sent = 0
        for device in list(reg):
            dev = self._device(reg, device)
            acts = dev["activities"]
            for group in list(acts):
                if group not in desired:
                    sent += self._push_end(reg, device, group, acts[group])
            for group, cs in desired.items():
                token = acts.get(group)
                if token:
                    sent += self._push_update(reg, device, group, token, cs, force=force)
                    continue
                ep = self._episodes[group]
                if dev.get("start") and device not in ep["started"] \
                        and device not in ep["suppressed"]:
                    sent += self._push_start(reg, device, group, dev["start"], cs)
        return sent


# ── the process-wide pusher (set by webui/api/agent_hooks.start) ─────────────
_PUSHER: Optional[AgentLaPusher] = None


def set_pusher(p: Optional[AgentLaPusher]) -> None:
    global _PUSHER
    _PUSHER = p


def pusher() -> Optional[AgentLaPusher]:
    return _PUSHER
