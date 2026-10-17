"""Per-agent Live Activities (agent/agent_la_push.py): grouping, the lead, the
idle-end rule, the content-state budget, the settings merge, and the push flow
(push-to-start, push-to-update, push-to-end) against a fake APNs sender."""
from __future__ import annotations

import json

import pytest

from agent import agent_la_push as m


# ── fixtures ───────────────────────────────────────────────────────────────

def tracked(key, agent="claude", state="working", last=1000.0, project="app", step="Bash: ls",
            pending=None, started=900.0):
    return {"key": key, "agent": agent, "state": state, "last_event_at": last,
            "project": project, "step": step, "pending": pending, "started_at": started,
            "turn_summary": {"started_at": started}}


class Clock:
    def __init__(self, t=10_000.0):
        self.t = t

    def __call__(self):
        return self.t


class FakeStore:
    def __init__(self):
        self.settings = {}

    def get_setting(self, key, default=None):
        return json.loads(json.dumps(self.settings[key])) if key in self.settings else default

    def set_setting(self, key, value):
        self.settings[key] = json.loads(json.dumps(value))


class Sender:
    def __init__(self, status=200, failing=()):
        self.calls = []
        self.status = status
        self.failing = set(failing)     # events that fail with a 500 (APNs hiccup)

    def __call__(self, token, cs, *, event="update", priority=10, extra=None,
                 dismissal_after=None, stale_after=3600, expiration=None):
        self.calls.append({"token": token, "cs": cs, "event": event, "priority": priority,
                           "extra": extra, "dismissal_after": dismissal_after,
                           "expiration": expiration})
        if event in self.failing:
            return {"ok": False, "status": 500, "error": "InternalServerError"}
        if self.status == 200:
            return {"ok": True}
        return {"ok": False, "status": self.status, "error": "nope"}

    def alerts(self):
        return [c for c in self.calls if (c["extra"] or {}).get("alert")]

    def events(self):
        return [(c["event"], c["token"]) for c in self.calls]


def pusher(sessions=(), settings=None, pending=(), clock=None, sender=None, store=None):
    clock = clock or Clock()
    st = store or FakeStore()
    box = {"sessions": list(sessions), "settings": settings, "pending": set(pending)}
    p = m.AgentLaPusher(st, tracked=lambda: box["sessions"], settings=lambda: box["settings"],
                        pending=lambda: box["pending"], sender=sender or Sender(),
                        clock=clock, mono=clock)
    return p, box, clock, st


# ── agent groups + logo-free naming ─────────────────────────────────────────

def test_claude_code_and_claude_desktop_share_one_group():
    assert m.group_of("claude") == "claude"
    assert m.group_of("claude-desktop") == "claude"
    assert m.group_of("codex") == "codex"
    assert m.group_of("something-new") is None


def test_every_group_has_a_display_name():
    for g in m.AGENTS:
        assert m.group_title(g)
    assert m.display_name("claude-desktop") == "Claude Desktop"
    assert m.display_name("claude") == "Claude Code"


# ── collecting + grouping ──────────────────────────────────────────────────

def test_hook_sessions_group_by_agent_type():
    groups = m.group_sessions(m.collect_sessions(
        [tracked("a", "claude"), tracked("b", "claude-desktop"), tracked("c", "codex")]))
    assert sorted(groups) == ["claude", "codex"]
    assert {s["key"] for s in groups["claude"]} == {"a", "b"}


# ── the lead ───────────────────────────────────────────────────────────────

def test_the_session_that_needs_you_first_leads():
    sessions = m.collect_sessions([
        tracked("busy", state="working", last=5000),
        tracked("asked-later", state="approval", last=4000,
                pending={"kind": "approval", "fingerprint": "f2"}),
        tracked("asked-first", state="question", last=3000,
                pending={"kind": "question", "fingerprint": "f1"}),
    ])
    assert m.lead_of(sessions)["key"] == "asked-first"


def test_without_a_waiting_session_the_most_recently_active_leads():
    sessions = m.collect_sessions([tracked("old", state="working", last=100),
                                   tracked("new", state="idle", last=900)])
    assert m.lead_of(sessions)["key"] == "new"


def test_no_sessions_no_lead():
    assert m.lead_of([]) is None


# ── idle-end rule ──────────────────────────────────────────────────────────

def test_an_active_session_is_always_wanted():
    s = m.collect_sessions([tracked("a", state="working", last=0)])
    assert m.wanted(s, now=10**9, idle_minutes=10)


def test_idle_sessions_are_wanted_until_the_idle_window_passes():
    s = m.collect_sessions([tracked("a", state="idle", last=1000)])
    assert m.wanted(s, now=1000 + 29 * 60, idle_minutes=30)
    assert not m.wanted(s, now=1000 + 30 * 60, idle_minutes=30)
    assert not m.wanted(s, now=1000 + 11 * 60, idle_minutes=10)


def test_an_errored_or_rate_limited_session_does_not_hold_the_activity_forever():
    for state in ("error", "ratelimit", "finished"):
        s = m.collect_sessions([tracked("a", state=state, last=0)])
        assert not m.wanted(s, now=31 * 60, idle_minutes=30), state


def test_no_sessions_is_never_wanted():
    assert not m.wanted([], now=0, idle_minutes=30)


# ── the content state ───────────────────────────────────────────────────────

def test_content_state_summarises_the_group():
    sessions = m.collect_sessions([
        tracked("a", state="approval", last=300, project="api",
                pending={"kind": "approval", "fingerprint": "fp"}, step="Needs approval: Bash: rm x"),
        tracked("b", state="working", last=500),
        tracked("c", agent="claude-desktop", state="idle", last=100),
    ])
    cs = m.content_state(sessions, actions=True, decidable={"fp"})
    assert cs["count"] == 3 and cs["waiting"] == 1 and cs["working"] == 1
    assert cs["name"] == "Claude Code" and cs["project"] == "api"
    assert cs["state"] == "approval" and cs["kind"] == "approval"
    assert cs["fingerprint"] == "fp" and cs["actions"] is True
    assert cs["bar"] == "p,w,i"
    assert cs["last"] == 500


def test_a_request_nothing_holds_gets_no_buttons():
    sessions = m.collect_sessions([tracked("a", state="approval",
                                           pending={"kind": "approval", "fingerprint": "fp"})])
    cs = m.content_state(sessions, actions=True, decidable=set())
    assert cs["fingerprint"] == "" and cs["kind"] == "approval"


def test_every_content_state_key_is_always_present():
    cs = m.content_state(m.collect_sessions([tracked("a")]), actions=False, decidable=set())
    assert set(cs) == set(m.CONTENT_KEYS)


def test_content_state_stays_far_under_the_4kb_budget():
    huge = "x" * 5000
    sessions = m.collect_sessions(
        [tracked("k" * 400, state="approval", project=huge, step=huge,
                 pending={"kind": "approval", "fingerprint": "f" * 400})
         for _ in range(50)])
    cs = m.content_state(sessions, actions=True, decidable={"f" * 400})
    size = len(json.dumps({"aps": {"content-state": cs, "timestamp": 1, "event": "update"}}))
    assert size < 1024, size
    assert len(cs["bar"].split(",")) <= m.MAX_BAR


# ── settings ───────────────────────────────────────────────────────────────

def test_settings_default_to_on_for_every_agent():
    s = m.merge_settings(None)
    assert s["enabled"] is True and s["actions"] is True and s["idle_minutes"] == 30
    assert set(s["agents"]) == set(m.AGENTS) and all(s["agents"].values())


def test_settings_keep_only_real_bools_and_allowed_idle_choices():
    s = m.merge_settings({"enabled": "no", "idle_minutes": 45, "actions": 0,
                          "agents": {"codex": False, "bogus": False, "gemini": "off"}})
    assert s["enabled"] is True and s["idle_minutes"] == 30 and s["actions"] is True
    assert s["agents"]["codex"] is False and s["agents"]["gemini"] is True
    assert "bogus" not in s["agents"]


def test_a_partial_save_keeps_the_rest():
    base = m.merge_settings({"idle_minutes": 60, "agents": {"codex": False}})
    s = m.merge_settings({"enabled": False}, base=base)
    assert s["enabled"] is False and s["idle_minutes"] == 60 and s["agents"]["codex"] is False
    s = m.merge_settings({"agents": {"gemini": False}}, base=s)
    assert s["agents"]["codex"] is False and s["agents"]["gemini"] is False


def test_desired_states_follow_the_settings():
    sessions = [tracked("a", "claude"), tracked("b", "codex")]
    want = m.desired_states(sessions, m.merge_settings({"agents": {"codex": False}}),
                            now=1000, decidable=set())
    assert list(want) == ["claude"]
    assert m.desired_states(sessions, m.merge_settings({"enabled": False}),
                            now=1000, decidable=set()) == {}


def test_actions_off_hides_the_buttons_everywhere():
    sessions = [tracked("a", state="approval", pending={"kind": "approval", "fingerprint": "fp"})]
    want = m.desired_states(sessions, m.merge_settings({"actions": False}),
                            now=1000, decidable={"fp"})
    assert want["claude"]["actions"] is False


# ── the push flow ──────────────────────────────────────────────────────────

def test_a_new_agent_session_push_starts_an_activity_on_the_phone():
    sender = Sender()
    p, _, _, _ = pusher([tracked("a", "codex")], sender=sender)
    p.register_start_token("phone", "START")
    sender.calls.clear()
    assert p.tick() == 1
    call = sender.calls[-1]
    assert call["event"] == "start" and call["token"] == "START"
    assert call["extra"]["attributes-type"] == "AgentActivityAttributes"
    assert call["extra"]["attributes"] == {"agent": "codex"}
    assert call["extra"]["alert"]["title"]
    assert set(call["cs"]) == set(m.CONTENT_KEYS)


def test_push_to_start_is_sent_once_per_episode():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a")], sender=sender)
    p.register_start_token("phone", "START")
    p.tick()
    clock.t += 60
    p.tick()
    assert [e for e, _ in sender.events()].count("start") == 1


def test_once_the_activity_reports_its_token_updates_go_to_it():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", state="working")], sender=sender)
    p.register_start_token("phone", "START")
    p.tick()
    p.register_activity_token("phone", "claude", "ACT1")
    assert sender.events()[-1] == ("update", "ACT1")      # current state, right away
    box["sessions"] = [tracked("a", state="idle", last=clock.t)]
    clock.t += 20
    p.tick()
    assert sender.events()[-1] == ("update", "ACT1")
    assert sender.calls[-1]["cs"]["state"] == "idle"


def test_an_unchanged_state_is_not_pushed_again():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", step="Bash: ls")], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    n = len(sender.calls)
    box["sessions"] = [tracked("a", step="Read: x.py")]   # only the step moved
    clock.t += 30
    p.tick()
    assert len(sender.calls) == n


def test_flapping_is_rate_limited_but_a_new_approval_goes_out_at_once():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", state="working")], sender=sender,
                              pending={"fp"})
    p.register_activity_token("phone", "claude", "ACT1")
    n = len(sender.calls)
    box["sessions"] = [tracked("a", state="idle", last=clock.t)]
    clock.t += 2
    p.tick()
    assert len(sender.calls) == n                       # inside the window
    box["sessions"] = [tracked("a", state="approval", pending={"kind": "approval", "fingerprint": "fp"})]
    clock.t += 1
    p.tick()
    assert len(sender.calls) == n + 1
    assert sender.calls[-1]["cs"]["fingerprint"] == "fp"
    assert sender.calls[-1]["priority"] == 10


def test_an_idle_group_ends_its_activity_after_the_window():
    sender = Sender()
    p, box, clock, store = pusher([tracked("a", state="working", last=10_000)], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    box["sessions"] = [tracked("a", state="idle", last=10_000)]
    clock.t = 10_000 + 31 * 60
    p.tick()
    assert sender.events()[-1] == ("end", "ACT1")
    assert sender.calls[-1]["dismissal_after"] == 0
    clock.t += 60
    p.tick()
    assert [e for e, _ in sender.events()].count("end") == 1   # the token was dropped


def test_all_sessions_ending_ends_the_activity():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a")], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    box["sessions"] = []
    p.tick()
    assert sender.events()[-1] == ("end", "ACT1")


def test_a_dismissed_activity_is_not_restarted_in_the_same_episode():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a")], sender=sender)
    p.register_start_token("phone", "START")
    p.register_activity_token("phone", "claude", "ACT1")
    p.activity_ended("phone", "claude", "ACT1", dismissed=True)
    sender.calls.clear()
    clock.t += 30
    p.tick()
    assert sender.calls == []
    # The episode ends, a new one starts: the activity comes back.
    box["sessions"] = []
    p.tick()
    box["sessions"] = [tracked("b", last=clock.t)]
    p.tick()
    assert sender.events()[-1] == ("start", "START")


def test_turning_the_feature_off_ends_every_activity():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a"), tracked("b", "codex")], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    p.register_activity_token("phone", "codex", "ACT2")
    box["settings"] = {"enabled": False}
    p.tick()
    ends = {t for e, t in sender.events() if e == "end"}
    assert ends == {"ACT1", "ACT2"}


def test_a_dead_activity_token_is_dropped_and_not_retried():
    sender = Sender(status=410)
    p, box, clock, store = pusher([tracked("a")], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    box["sessions"] = [tracked("a", state="idle", last=clock.t)]
    clock.t += 60
    p.tick()
    n = len(sender.calls)
    clock.t += 60
    p.tick()
    assert len(sender.calls) == n
    assert "claude" not in (store.get_setting(m.REGISTRY_KEY)["phone"].get("activities") or {})


def test_tokens_survive_a_restart():
    store = FakeStore()
    p, _, _, _ = pusher([tracked("a", "codex")], store=store)
    p.register_start_token("phone", "START")
    p.register_activity_token("phone", "codex", "ACT2")
    again, _, _, _ = pusher([tracked("a", "codex", state="approval")], store=store)
    sender = again._sender
    again.tick()
    assert ("update", "ACT2") in sender.events()


def test_forgetting_a_device_drops_its_tokens():
    store = FakeStore()
    p, _, _, _ = pusher(store=store)
    p.register_start_token("phone", "START")
    p.forget_device("phone")
    assert "phone" not in store.get_setting(m.REGISTRY_KEY, {})


def test_snapshot_lists_the_wanted_activities_with_their_episode():
    p, _, _, _ = pusher([tracked("a", "claude"), tracked("b", "gemini")])
    snap = p.snapshot()
    assert snap["settings"]["enabled"] is True
    agents = {a["agent"]: a for a in snap["activities"]}
    assert set(agents) == {"claude", "gemini"}
    assert agents["claude"]["episode"] and set(agents["claude"]["state"]) == set(m.CONTENT_KEYS)
    # The episode id is stable while the group stays wanted.
    assert p.snapshot()["activities"][0]["episode"] == snap["activities"][0]["episode"]


def test_tick_never_raises_when_a_source_fails():
    def boom():
        raise RuntimeError("x")
    p = m.AgentLaPusher(FakeStore(), tracked=boom, settings=lambda: None, sender=Sender())
    assert p.tick() == 0


def test_agent_activities_are_on_unless_turned_off():
    """While they're on, the Jarvis activity stops carrying the coding fleet."""
    store = FakeStore()
    assert m.agent_activities_on(store) is True
    store.set_setting("notifications", {"agent_live": {"enabled": False}})
    assert m.agent_activities_on(store) is False
    assert m.agent_activities_on(object()) is False   # an old store: legacy behaviour


def test_pushes_carry_a_relevance_so_waiting_on_you_wins_the_island():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", state="working")], sender=sender, pending={"fp"})
    p.register_activity_token("phone", "claude", "ACT1")
    working = sender.calls[-1]["extra"]["relevance-score"]
    box["sessions"] = [tracked("a", state="approval", pending={"kind": "approval", "fingerprint": "fp"})]
    p.tick()
    assert sender.calls[-1]["extra"]["relevance-score"] > working


# ── "needs you" alerts ───────────────────────────────────────────────────────

def _question(q="Which region should I deploy to?", options=("us-east", "eu-west"), multi=False):
    return {"kind": "question", "fingerprint": "fq",
            "questions": [{"question": q, "multiSelect": multi,
                           "options": [{"label": o} for o in options]}]}


def test_a_waiting_lead_carries_when_it_started_waiting():
    sessions = m.collect_sessions([tracked("a", state="approval", last=4321,
                                           pending={"kind": "approval", "fingerprint": "fp"})])
    cs = m.content_state(sessions, actions=True, decidable={"fp"})
    assert cs["waitingSince"] == 4321
    cs = m.content_state(m.collect_sessions([tracked("b")]), actions=True, decidable=set())
    assert cs["waitingSince"] == 0 and cs["question"] == "" and cs["options"] == []


def test_a_question_carries_its_text_and_short_options():
    sessions = m.collect_sessions([tracked("a", state="question", pending=_question())])
    cs = m.content_state(sessions, actions=True, decidable={"fq"})
    assert cs["question"] == "Which region should I deploy to?"
    assert cs["options"] == ["us-east", "eu-west"]
    assert cs["kind"] == "question" and cs["fingerprint"] == "fq"


def test_options_that_wont_fit_become_one_answer_button():
    for pending in (_question(options=("a", "b", "c", "d")),
                    _question(options=("a very long option label indeed", "b")),
                    _question(multi=True)):
        sessions = m.collect_sessions([tracked("a", state="question", pending=pending)])
        assert m.content_state(sessions, actions=True, decidable={"fq"})["options"] == []


def test_entering_approval_pushes_an_alert_with_sound():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", state="working")], sender=sender, pending={"fp"})
    p.register_activity_token("phone", "claude", "ACT1")
    assert "alert" not in (sender.calls[-1]["extra"] or {})
    box["sessions"] = [tracked("a", state="approval", project="api",
                               pending={"kind": "approval", "fingerprint": "fp"})]
    p.tick()
    alert = sender.calls[-1]["extra"]["alert"]
    assert alert["sound"] == "default"
    assert "Claude Code" in alert["title"] and "api" in alert["body"]


def test_a_question_alert_says_the_question():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", state="working")], sender=sender, pending={"fq"})
    p.register_activity_token("phone", "claude", "ACT1")
    box["sessions"] = [tracked("a", state="question", pending=_question())]
    p.tick()
    assert "Which region" in sender.calls[-1]["extra"]["alert"]["body"]


def test_still_waiting_does_not_alert_again():
    sender = Sender()
    waiting = tracked("a", state="approval", pending={"kind": "approval", "fingerprint": "fp"})
    p, box, clock, _ = pusher([waiting], sender=sender, pending={"fp"})
    p.register_activity_token("phone", "claude", "ACT1")
    box["sessions"] = [waiting, tracked("b", state="working")]   # something else changed
    clock.t += 30
    p.tick()
    assert "alert" not in (sender.calls[-1]["extra"] or {})


# ── only work starts an activity ─────────────────────────────────────────────

def test_an_idle_group_never_starts_an_activity():
    """Eleven idle Jarvis sessions crowded the island with an "IDLE" activity:
    only a session that works or waits on you starts one."""
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", agent="jarvis", state="idle", last=10_000)], sender=sender)
    p.register_start_token("phone", "START")
    p.tick()
    assert sender.calls == []
    assert p.snapshot()["activities"] == []


def test_a_running_activity_stays_through_the_idle_window():
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", state="working", last=10_000)], sender=sender)
    p.register_start_token("phone", "START")
    p.tick()
    box["sessions"] = [tracked("a", state="idle", last=clock.t)]
    clock.t += 10 * 60
    assert [a["agent"] for a in p.snapshot()["activities"]] == ["claude"]


def test_wanted_needs_work_to_begin():
    s = m.collect_sessions([tracked("a", state="idle", last=1000)])
    assert not m.wanted(s, now=1001, idle_minutes=30, ongoing=False)
    assert m.wanted(s, now=1001, idle_minutes=30, ongoing=True)


# ── an answered request never comes back amber ───────────────────────────────

def test_a_request_answered_on_the_phone_reads_as_working_until_the_hook_catches_up():
    """The phone decides → the server drops the request at once, but the hook's
    "settled" lands a moment later. In between, the session must not flash back
    to amber "waiting" (now without buttons) over the phone's instant update."""
    sender = Sender()
    asks = tracked("a", state="approval", pending={"kind": "approval", "fingerprint": "fp"})
    p, box, clock, _ = pusher([asks], sender=sender, pending={"fp"})
    p.register_activity_token("phone", "claude", "ACT1")
    assert sender.calls[-1]["cs"]["state"] == "approval"
    box["pending"] = set()                 # answered: no longer held
    clock.t += 20                          # past the rate-limit window
    p.tick()
    cs = sender.calls[-1]["cs"]
    assert cs["state"] == "working" and cs["fingerprint"] == "" and cs["waiting"] == 0
    assert "alert" not in (sender.calls[-1]["extra"] or {})


def test_a_request_nothing_ever_held_still_reads_as_waiting():
    sessions = [tracked("a", state="approval", pending={"kind": "approval", "fingerprint": "fp"})]
    p, box, clock, _ = pusher(sessions, pending=set())
    assert p.snapshot()["activities"][0]["state"]["state"] == "approval"


# ── bug sweep: one alert per wait, a steady lead, retries, locked stores ─────

def _asks(key="a", fp="fp", last=10_000, at=None, state="approval"):
    pend = {"kind": "approval" if state == "approval" else "question", "fingerprint": fp}
    if at is not None:
        pend["at"] = at
    return tracked(key, state=state, last=last, pending=pend)


def test_a_request_announced_after_its_hook_alerts_once():
    """With remote approvals on, the hook's permission frame lands first (no
    answerable fingerprint yet), the arbiter's agent_pending a moment later: one
    wait, one alert — not one per fingerprint."""
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", state="working")], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    clock.t += 20
    box["sessions"] = [_asks(last=clock.t)]
    p.tick()                                   # waiting, nothing holds it yet
    clock.t += 1
    box["pending"] = {"fp"}
    box["sessions"] = [_asks(last=clock.t)]    # every hook event bumps last
    p.tick()                                   # now answerable: buttons, no 2nd alert
    assert sender.calls[-1]["cs"]["fingerprint"] == "fp"
    assert len(sender.alerts()) == 1


def test_re_registering_a_token_never_re_alerts():
    """The app re-reports its activity tokens on every launch / rotation."""
    sender = Sender()
    p, box, clock, _ = pusher([tracked("a", state="working")], sender=sender, pending={"fp"})
    p.register_activity_token("phone", "claude", "ACT1")
    clock.t += 20
    box["sessions"] = [_asks()]
    p.tick()
    assert len(sender.alerts()) == 1
    p.register_activity_token("phone", "claude", "ACT1")
    p.register_activity_token("phone", "claude", "ACT2")
    clock.t += 20
    p.tick()
    assert len(sender.alerts()) == 1


def test_two_waiting_sessions_keep_one_lead():
    """The lead is the request that started waiting first — not whichever
    session's last hook event is older, which flipped A/B/A/B (an alert each)."""
    sender = Sender()
    a = lambda last: _asks("a", fp="fa", last=last, at=100)    # noqa: E731
    b = lambda last: _asks("b", fp="fb", last=last, at=200)    # noqa: E731
    p, box, clock, _ = pusher([tracked("w", state="working")], sender=sender,
                              pending={"fa", "fb"})
    p.register_activity_token("phone", "claude", "ACT1")
    leads, starts = set(), set()
    for i, (la, lb) in enumerate([(900, 500), (500, 900), (950, 600), (600, 950)]):
        clock.t += 20
        box["sessions"] = [a(la), b(lb)]
        p.tick()
        leads.add(sender.calls[-1]["cs"]["key"])
        starts.add(sender.calls[-1]["cs"]["waitingSince"])
    assert leads == {"a"} and starts == {100}
    assert len(sender.alerts()) == 1


def test_lead_of_orders_waiting_sessions_by_when_they_started_waiting():
    sessions = m.collect_sessions([_asks("a", fp="fa", last=900, at=100),
                                   _asks("b", fp="fb", last=500, at=200)])
    assert m.lead_of(sessions)["key"] == "a"


def test_a_failed_end_is_retried_and_expires_an_hour_later():
    sender = Sender(failing={"end"})
    p, box, clock, store = pusher([tracked("a")], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    box["sessions"] = []
    p.tick()
    end = [c for c in sender.calls if c["event"] == "end"]
    assert len(end) == 1 and end[0]["expiration"] == clock.t + 3600
    assert store.get_setting(m.REGISTRY_KEY)["phone"]["activities"].get("claude") == "ACT1"
    p.tick()                                   # backing off: not yet
    assert len([c for c in sender.calls if c["event"] == "end"]) == 1
    sender.failing.clear()
    clock.t += 120
    p.tick()
    assert len([c for c in sender.calls if c["event"] == "end"]) == 2
    assert "claude" not in store.get_setting(m.REGISTRY_KEY)["phone"]["activities"]


def test_a_failing_end_gives_up_after_a_few_tries():
    sender = Sender(failing={"end"})
    p, box, clock, store = pusher([tracked("a")], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    box["sessions"] = []
    for _ in range(12):
        p.tick()
        clock.t += 600
    ends = [c for c in sender.calls if c["event"] == "end"]
    assert 2 <= len(ends) <= m.MAX_RETRIES
    assert "claude" not in store.get_setting(m.REGISTRY_KEY)["phone"]["activities"]


def test_a_failed_push_to_start_is_retried():
    sender = Sender(failing={"start"})
    p, box, clock, _ = pusher([tracked("a")], sender=sender)
    p.register_start_token("phone", "START")
    p.tick()
    p.tick()                                   # backing off
    assert [c["event"] for c in sender.calls] == ["start"]
    sender.failing.clear()
    clock.t += 120
    p.tick()
    clock.t += 120
    p.tick()                                   # started now: no more starts
    assert [c["event"] for c in sender.calls] == ["start", "start"]


def test_an_unreadable_source_skips_the_tick_instead_of_ending_everything():
    sender = Sender()
    p, box, clock, store = pusher([tracked("a", state="working", last=10_000)], sender=sender)
    p.register_activity_token("phone", "claude", "ACT1")
    n = len(sender.calls)

    def locked():
        raise RuntimeError("database is locked")
    p._tracked = locked
    clock.t += 30
    assert p.tick() == 0
    assert len(sender.calls) == n                   # no end, no update
    assert store.get_setting(m.REGISTRY_KEY)["phone"]["activities"]["claude"] == "ACT1"
    assert [a["agent"] for a in p.snapshot()["activities"]] == ["claude"]   # last good state


def test_a_failing_pending_list_does_not_strip_the_buttons():
    sender = Sender()
    p, box, clock, _ = pusher([_asks()], sender=sender, pending={"fp"})
    p.register_activity_token("phone", "claude", "ACT1")
    assert sender.calls[-1]["cs"]["fingerprint"] == "fp"

    def boom():
        raise RuntimeError("locked")
    p._pending = boom
    clock.t += 30
    p.tick()
    assert sender.calls[-1]["cs"]["fingerprint"] == "fp"


# ── finished / failed pop the island too ────────────────────────────────────
# Code Master told the glasses and banner'd the phone, but the island only
# popped for waits; a finished or failed turn now pops it once, quietly (the
# phone's banner already chimes), as the phone's own Code Master settings allow.

def _finish(state="finished", started=9_900.0, last=10_020.0, settings=None):
    sender = Sender()
    p, box, clock, st = pusher([tracked("a", state="working", started=started, last=last - 5)], sender=sender)
    st.settings.update(settings or {})
    p.register_activity_token("phone", "claude", "ACT1")
    box["sessions"] = [tracked("a", state=state, project="api", started=started, last=last)]
    clock.t += 30
    p.tick()
    return sender


def test_finishing_pops_the_island_once_quietly():
    sender = _finish()
    alert = sender.calls[-1]["extra"]["alert"]
    assert alert == {"title": "Claude Code finished", "body": "api"}
    assert sender.calls[-1]["priority"] == 10
    assert len(sender.alerts()) == 1


def test_an_error_pops_the_island():
    assert _finish(state="error").calls[-1]["extra"]["alert"]["title"] == "Claude Code hit an error"


def test_a_quick_reply_or_a_muted_finish_does_not_pop_the_island():
    assert not _finish(started=10_000.0).alerts(), "a quick reply: you're probably right there"
    off = {"notifications": {"events": {"finished": {"mobile": False}}}}
    assert not _finish(settings=off).alerts(), "Mobile push off for Finished"
    assert not _finish(settings={"agents_focus": {"only_waiting": True}}).alerts(), "Focus: only what waits on you"
