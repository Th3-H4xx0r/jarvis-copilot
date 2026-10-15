"""The weekly recap: what the coding agents did over the last seven days
(after coucou's weekly recap). Pure: turns + decisions in, numbers out."""
from agent import agent_recap as rc

MON = 1_791_158_400.0  # 2026-10-05 00:00 UTC, a Monday
H = 3600.0


def turn(key, start, end, agent="claude", project="app", **kw):
    t = {"key": key, "agent": agent, "project": project, "started_at": start, "ended_at": end,
         "actions": 0, "files": 0, "added": 0, "removed": 0, "commands": 0, "failed": 0}
    t.update(kw)
    return t


def test_overlapping_turns_count_once():
    turns = [turn("a", MON + 9 * H, MON + 10 * H), turn("b", MON + 9.5 * H, MON + 11 * H),
             turn("c", MON + 12 * H, MON + 12.5 * H)]
    r = rc.build_recap(turns, [], now=MON + 2 * 86400)
    assert r["minutes"] == 150  # 9:00-11:00 merged + 12:00-12:30
    assert r["sessions"] == 3


def test_totals_and_decisions():
    turns = [turn("a", MON, MON + H, files=3, added=40, removed=5, commands=7),
             turn("a", MON + 2 * H, MON + 3 * H, files=1, added=2, removed=1, commands=1)]
    decisions = [{"kind": "permission", "decision": "allow"}, {"kind": "permission", "decision": "always"},
                 {"kind": "permission", "decision": "deny"}, {"kind": "ask", "decision": "answer"},
                 {"kind": "permission", "decision": "ask"}]
    r = rc.build_recap(turns, decisions, now=MON + 86400)
    assert (r["files"], r["added"], r["removed"], r["commands"]) == (4, 42, 6, 8)
    assert (r["approved"], r["denied"], r["answered"]) == (2, 1, 1)
    assert r["sessions"] == 1


def test_top_agent_project_busiest_day_longest_session():
    turns = [turn("a", MON + 1 * H, MON + 2 * H, agent="claude", project="web"),
             turn("b", MON + 86400, MON + 86400 + 3 * H, agent="codex", project="api"),
             turn("b", MON + 86400 + 4 * H, MON + 86400 + 5 * H, agent="codex", project="api"),
             turn("c", MON + 2 * 86400, MON + 2 * 86400 + 0.5 * H, agent="claude", project="web")]
    r = rc.build_recap(turns, [], now=MON + 3 * 86400)
    assert r["top_agent"] == {"agent": "codex", "minutes": 240}
    assert r["top_project"] == {"project": "api", "minutes": 240}
    assert r["busiest_day"]["weekday"] == "Tuesday" and r["busiest_day"]["minutes"] == 240
    assert r["longest_session"]["project"] == "api"
    assert r["longest_session"]["minutes"] == 240


def test_busiest_day_follows_the_viewers_timezone():
    # 23:30-00:30 UTC Monday night is all Tuesday in UTC+2.
    turns = [turn("a", MON + 23.5 * H, MON + 24.5 * H)]
    assert rc.build_recap(turns, [], now=MON + 2 * 86400, tz_offset_min=120)["busiest_day"]["weekday"] == "Tuesday"
    assert rc.build_recap(turns, [], now=MON + 2 * 86400, tz_offset_min=0)["busiest_day"]["minutes"] == 30


def test_only_the_window_counts_and_empty_is_zeroes():
    old = turn("x", MON - 10 * 86400, MON - 10 * 86400 + H)
    r = rc.build_recap([old], [], now=MON + 86400)
    assert r["minutes"] == 0 and r["sessions"] == 0
    assert r["top_agent"] is None and r["busiest_day"] is None and r["longest_session"] is None


def test_a_turn_straddling_the_window_start_is_clipped():
    now = MON + 7 * 86400
    t = turn("a", MON - H, MON + H)  # an hour before the window, an hour inside
    assert rc.build_recap([t], [], now=now)["minutes"] == 60


def test_summary_line_for_the_notification():
    r = rc.build_recap([turn("a", MON, MON + 2 * H, files=5, added=10)], [], now=MON + 86400)
    line = rc.summary_line(r)
    assert "2h" in line and "1 session" in line and "5 files" in line
    assert rc.summary_line(rc.build_recap([], [], now=MON)) is None


def test_monday_notification_is_due_once_a_week():
    sent = None
    tue_noon = MON + 86400 + 12 * H
    assert rc.recap_due(MON + 12 * H, last_sent=sent) is False      # Monday, before 13:00 UTC
    assert rc.recap_due(MON + 13.5 * H, last_sent=sent) is True
    assert rc.recap_due(tue_noon, last_sent=MON + 13.5 * H) is False  # already sent this week
    assert rc.recap_due(MON + 7 * 86400 + 14 * H, last_sent=MON + 13.5 * H) is True
