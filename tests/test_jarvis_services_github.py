"""GitHub: GraphQL pulse (PRs, reviews, default-branch CI), REST stats, contribution
calendar; coucou's event rules; the detail's safe actions."""
from __future__ import annotations

import pytest

from jarvis_services.base import ServiceError
from jarvis_services.config import ConfigView
from jarvis_services.github import GitHubService, parse_pulse, pulse_events
from jarvis_services.testing import FakeHttp

NOW = 1_791_936_000.0  # 2026-10-14 00:00 UTC
TOKEN = "ghp_testtoken123"
CFG = ConfigView({"SERVICES_GITHUB_TOKEN": TOKEN}, {}, environ={})
GQL = "https://api.github.com/graphql"


def pr(number, ci="SUCCESS", sha="a1", draft=False, review="REVIEW_REQUIRED", repo="p/jarvis"):
    return {"number": number, "title": f"PR {number}", "url": f"https://github.com/{repo}/pull/{number}",
            "isDraft": draft, "reviewDecision": review,
            "repository": {"nameWithOwner": repo, "url": f"https://github.com/{repo}"},
            "commits": {"nodes": [{"commit": {"oid": sha, "statusCheckRollup": {"state": ci} if ci else None}}]}}


def repo(name, ci="SUCCESS", sha="m1", archived=False):
    return {"nameWithOwner": name, "url": f"https://github.com/{name}", "isArchived": archived,
            "defaultBranchRef": {"name": "main",
                                 "target": {"oid": sha, "statusCheckRollup": {"state": ci} if ci else None}}}


def review(number, repo_name="ada/lib"):
    return {"number": number, "title": f"Review {number}", "url": f"https://github.com/{repo_name}/pull/{number}",
            "isDraft": False, "author": {"login": "ada"},
            "repository": {"nameWithOwner": repo_name, "url": f"https://github.com/{repo_name}"}}


def pulse_body(prs=(), repos=(), reviews=()):
    return {"data": {"viewer": {"login": "pranav", "pullRequests": {"nodes": list(prs)},
                                "repositories": {"nodes": list(repos)}},
                     "reviewRequested": {"issueCount": len(reviews), "nodes": list(reviews)}}}


ACTIVITY = {"data": {"viewer": {"login": "pranav", "contributionsCollection": {"contributionCalendar": {
    "totalContributions": 812,
    "weeks": [{"contributionDays": [
        {"date": "2026-10-11", "contributionCount": 0, "contributionLevel": "NONE", "weekday": 0},
        {"date": "2026-10-12", "contributionCount": 9, "contributionLevel": "THIRD_QUARTILE", "weekday": 1}]}],
}}}}}


def gql_answer(pulse):
    def answer(call):
        from jarvis_services.base import Response
        import json
        body = ACTIVITY if "contributionsCollection" in call.json["query"] else pulse
        return Response(200, json.dumps(body).encode())
    return answer


def http_for(pulse):
    return (FakeHttp()
            .add("POST", GQL, gql_answer(pulse))
            .add("GET", "https://api.github.com/user", {"login": "pranav", "public_repos": 10,
                                                         "owned_private_repos": 4})
            .add("GET", "https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=pushed",
                 [{"stargazers_count": 5}, {"stargazers_count": 7}]))


def poll(body, prev=None, now=NOW, http=None):
    return GitHubService().fetch(http or http_for(body), CFG, prev, now)


# ── parsing ─────────────────────────────────────────────────────────────────────

def test_parse_pulse_dedupes_and_skips_archived():
    p = parse_pulse(pulse_body(prs=[pr(1), pr(1), pr(2, ci=None, draft=True)],
                               repos=[repo("p/jarvis"), repo("p/old", archived=True)],
                               reviews=[review(7), review(7)]), NOW)
    assert [x.id for x in p.my_prs] == ["p/jarvis#1", "p/jarvis#2"]
    assert p.my_prs[0].ci == "success" and p.my_prs[0].head_sha == "a1"
    assert p.my_prs[1].ci == "unknown" and p.my_prs[1].is_draft
    assert [r.repo for r in p.main_ci] == ["p/jarvis"]
    assert [x.id for x in p.to_review] == ["ada/lib#7"]


def test_graphql_without_data_is_an_error():
    http = FakeHttp().add("POST", GQL, {"data": None, "errors": [{"message": "Bad credentials"}]})
    with pytest.raises(ServiceError) as e:
        GitHubService().fetch(http, CFG, None, NOW)
    assert "Bad credentials" in str(e.value)


def test_pulse_request_headers():
    http = http_for(pulse_body())
    poll(pulse_body(), http=http)
    gql = http.called("POST", GQL)[0]
    assert gql.headers["Authorization"] == f"Bearer {TOKEN}"
    assert gql.headers["Content-Type"] == "application/json"
    rest = http.called("GET", "https://api.github.com/user")[0]
    assert rest.headers["Accept"] == "application/vnd.github+json"


# ── events (coucou's GitHubPulse.events) ────────────────────────────────────────

def ev(old_body, new_body):
    old = parse_pulse(old_body, NOW) if old_body else None
    return pulse_events(old, parse_pulse(new_body, NOW))


def test_first_poll_is_silent():
    assert ev(None, pulse_body(prs=[pr(1, ci="FAILURE")])) == []


def test_same_commit_transitions():
    assert ev(pulse_body(prs=[pr(1, ci="PENDING")]), pulse_body(prs=[pr(1)])) == [("ci_passed", "p/jarvis#1")]
    assert ev(pulse_body(prs=[pr(1)]), pulse_body(prs=[pr(1, ci="FAILURE")])) == [("ci_failed", "p/jarvis#1")]
    assert ev(pulse_body(prs=[pr(1, ci="FAILURE")]), pulse_body(prs=[pr(1, ci="FAILURE")])) == []
    assert ev(pulse_body(prs=[pr(1)]), pulse_body(prs=[pr(1)])) == []      # success→success: quiet


def test_new_commit_fires_only_when_ci_already_done():
    assert ev(pulse_body(prs=[pr(1, sha="a")]), pulse_body(prs=[pr(1, sha="b")])) == [("ci_passed", "p/jarvis#1")]
    assert ev(pulse_body(prs=[pr(1, sha="a")]), pulse_body(prs=[pr(1, sha="b", ci="PENDING")])) == []
    assert ev(pulse_body(), pulse_body(prs=[pr(3, ci="FAILURE")])) == [("ci_failed", "p/jarvis#3")]


def test_default_branch_only_alerts_on_failure():
    assert ev(pulse_body(repos=[repo("p/x", ci="PENDING")]), pulse_body(repos=[repo("p/x")])) == []
    assert ev(pulse_body(repos=[repo("p/x")]), pulse_body(repos=[repo("p/x", ci="FAILURE")])) == [("main_failed", "p/x")]
    assert ev(pulse_body(repos=[repo("p/x", sha="1")]),
              pulse_body(repos=[repo("p/x", sha="2", ci="ERROR")])) == [("main_failed", "p/x")]


def test_new_review_request():
    assert ev(pulse_body(reviews=[review(7)]), pulse_body(reviews=[review(7), review(8)])) == [
        ("review_requested", "ada/lib#8")]


def test_one_notification_by_priority_failure_then_review_then_success():
    s = GitHubService()
    old = poll(pulse_body(prs=[pr(1, ci="PENDING"), pr(2)], repos=[repo("p/x")]))
    new = poll(pulse_body(prs=[pr(1), pr(2, ci="FAILURE")], repos=[repo("p/x")], reviews=[review(9)]), old)
    events = s.events(old.state, new.state)
    assert len(events) == 1
    assert events[0].kind == "ci_failed" and events[0].title == "CI failed"
    assert events[0].body == "p/jarvis #2: PR 2 (+2 more)"
    review_only = poll(pulse_body(prs=[pr(1)], repos=[repo("p/x")], reviews=[review(9), review(10)]), new)
    assert [e.kind for e in s.events(new.state, review_only.state)] == ["review_requested"]
    assert s.events(None, new.state) == []


# ── cadence ─────────────────────────────────────────────────────────────────────

def test_pulse_interval_is_60s_when_pending_else_300s():
    s = GitHubService()
    assert s.next_interval(poll(pulse_body(prs=[pr(1, ci="PENDING")]))) == 60
    assert s.next_interval(poll(pulse_body(repos=[repo("p/x", ci="PENDING")]))) == 60
    assert s.next_interval(poll(pulse_body(prs=[pr(1)]))) == 300


def test_stats_every_300s_activity_every_1800s():
    first = poll(pulse_body())
    assert first.extra["stats"] == {"repos": 14, "stars": 12}
    assert first.extra["activity"]["total"] == 812
    assert first.extra["activity"]["weeks"][0][1] == {"date": "2026-10-12", "count": 9, "level": 3, "weekday": 1}

    http = http_for(pulse_body())
    poll(pulse_body(), first, NOW + 60, http)
    assert http.called("GET", "https://api.github.com/user") == []
    assert len(http.called("POST", GQL)) == 1                       # pulse only

    http = http_for(pulse_body())
    poll(pulse_body(), first, NOW + 301, http)
    assert len(http.called("GET", "https://api.github.com/user")) == 2   # /user + /user/repos
    assert len(http.called("POST", GQL)) == 1

    http = http_for(pulse_body())
    poll(pulse_body(), first, NOW + 1801, http)
    assert len(http.called("POST", GQL)) == 2                       # pulse + activity


# ── snapshot ────────────────────────────────────────────────────────────────────

def test_snapshot_tone_and_reason():
    failing_main = poll(pulse_body(prs=[pr(1, ci="FAILURE")], repos=[repo("p/x", ci="FAILURE")]))
    assert failing_main.tone == "error" and failing_main.reason == "CI failing on p/x · main"
    failing_pr = poll(pulse_body(prs=[pr(1, ci="FAILURE")]))
    assert failing_pr.reason == "Checks failing on p/jarvis #1: PR 1"
    assert poll(pulse_body(prs=[pr(1, ci="PENDING")])).tone == "warning"
    waiting = poll(pulse_body(reviews=[review(7)]))
    assert waiting.tone == "warning" and waiting.reason == "1 pull request waits for your review"
    green = poll(pulse_body(prs=[pr(1, review="APPROVED")]))
    assert green.tone == "ok" and green.reason == "All checks passed"
    assert green.headline == "1 open pull request · 812 contributions this year"
    mine = green.sections[0]
    assert mine.title == "Your pull requests"
    assert mine.items[0].title == "#1 PR 1"
    assert mine.items[0].subtitle == "p/jarvis · checks passed · approved"
    assert poll(pulse_body()).tone == "idle"


# ── detail + actions ────────────────────────────────────────────────────────────

def detail_http():
    from jarvis_services.base import Response
    import json

    def search(call):
        q = call.params["q"]
        if "author:pranav" in q:
            items = [{"title": "Mine", "number": 12, "draft": False, "html_url": "https://github.com/p/jarvis/pull/12",
                      "repository_url": "https://api.github.com/repos/p/jarvis", "updated_at": "2026-10-13T10:00:00Z"},
                     {"title": "Draft", "number": 13, "draft": True, "html_url": "u",
                      "repository_url": "https://api.github.com/repos/p/jarvis"}]
        else:
            items = [{"title": "Theirs", "number": 7, "user": {"login": "ada"},
                      "repository_url": "https://api.github.com/repos/ada/lib", "html_url": "u"}]
        return Response(200, json.dumps({"items": items}).encode())

    runs = {"workflow_runs": [
        {"id": 111, "name": "CI", "status": "completed", "conclusion": "failure", "head_branch": "main",
         "html_url": "u", "created_at": "2026-10-13T09:00:00Z"},
        {"id": 112, "name": "CI", "status": "completed", "conclusion": "success", "head_branch": "dev"},
        {"id": 113, "name": "CI", "status": "in_progress", "conclusion": None, "head_branch": "x"}]}
    return (FakeHttp()
            .add("GET", "https://api.github.com/user", {"login": "pranav"})
            .add("GET", "https://api.github.com/search/issues", search)
            .add("GET", "https://api.github.com/user/repos?sort=pushed&per_page=5&affiliation=owner%2Ccollaborator",
                 [{"full_name": "p/jarvis"}])
            .add("GET", "https://api.github.com/repos/p/jarvis/actions/runs?per_page=3", runs))


def test_detail_offers_merge_approve_and_rerun_only_where_safe():
    http = detail_http()
    d = GitHubService().detail(http, CFG, NOW)
    assert all(c.headers["X-GitHub-Api-Version"] == "2022-11-28" for c in http.calls)
    titles = [s.title for s in d.sections]
    assert titles == ["Reviews asked of you", "Your pull requests", "CI on your latest repos"]
    assert d.offered("github.approve", "ada/lib#7") is not None
    merge = d.offered("github.merge", "p/jarvis#12")
    assert merge is not None and merge.confirm
    assert d.offered("github.merge", "p/jarvis#13") is None                 # never drafts
    assert d.offered("github.rerun", "p/jarvis/111") is not None
    assert d.offered("github.rerun", "p/jarvis/112") is None
    assert d.offered("github.rerun", "p/jarvis/113") is None
    stats = {s.label: s.value for s in d.stats}
    assert stats == {"Your PRs": "2", "Reviews": "1", "CI failing": "1"}


@pytest.mark.parametrize("kind,target,method,url,body", [
    ("github.rerun", "p/jarvis/111", "POST",
     "https://api.github.com/repos/p/jarvis/actions/runs/111/rerun-failed-jobs", None),
    ("github.approve", "ada/lib#7", "POST", "https://api.github.com/repos/ada/lib/pulls/7/reviews",
     {"event": "APPROVE"}),
    ("github.merge", "p/jarvis#12", "PUT", "https://api.github.com/repos/p/jarvis/pulls/12/merge",
     {"merge_method": "squash"}),
])
def test_perform(kind, target, method, url, body):
    http = FakeHttp().add(method, url, {"merged": True})
    GitHubService().perform(http, CFG, kind, target)
    assert http.calls[0].method == method and http.calls[0].url == url
    assert http.calls[0].json == body


def test_perform_rejects_malformed_targets():
    with pytest.raises(ServiceError):
        GitHubService().perform(FakeHttp(), CFG, "github.merge", "../../evil#1")


def test_null_nodes_are_skipped_not_fatal():
    """GraphQL returns null for PRs in SAML-protected orgs the token isn't
    authorised for; the rest of the pulse must still show (sweep finding)."""
    from jarvis_services.github import parse_pulse
    good = {"number": 7, "title": "Fix", "url": "https://github.com/o/r/pull/7",
            "repository": {"nameWithOwner": "o/r"}, "commits": {"nodes": []}}
    root = {"data": {"viewer": {"pullRequests": {"nodes": [None, good]},
                                "repositories": {"nodes": [None]}},
                     "reviewRequested": {"nodes": [None, dict(good, number=8, url="https://github.com/o/r/pull/8")]}}}
    pulse = parse_pulse(root, 1_791_936_000.0)
    assert pulse is not None
    assert [p.number for p in pulse.my_prs] == [7]
