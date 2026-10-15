"""GitHub: the "pulse" (your open PRs with review decision and CI of their last
commit, PRs asking for your review, default-branch CI of your 10 most recently
pushed repos) over GraphQL every 60 s while anything is pending, else 300 s; repo
and star counts every 300 s; the contribution calendar every 30 min.

Events follow coucou's rules: the first poll is silent; a failure, a pass after
pending, or a new review request fires; default branches only alert on failure.
One notification per poll, by priority failure > review > success.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Optional

from jarvis_services.base import (
    ERROR, IDLE, INFO, OK, WARNING, Action, Detail, Event, HttpError, Item, Section, Service,
    ServiceError, Snapshot, Stat, call_json, parse_date, plural,
)

API = "https://api.github.com"
GRAPHQL = f"{API}/graphql"
ENV = "SERVICES_GITHUB_TOKEN"
STATS_EVERY = 300
ACTIVITY_EVERY = 1800

PULSE_QUERY = """
query {
  viewer {
    login
    pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number title url isDraft reviewDecision
        repository { nameWithOwner url }
        commits(last: 1) {
          nodes { commit { oid statusCheckRollup { state } } }
        }
      }
    }
    repositories(first: 10, ownerAffiliations: [OWNER], orderBy: {field: PUSHED_AT, direction: DESC}) {
      nodes {
        nameWithOwner url isArchived
        defaultBranchRef {
          name
          target { ... on Commit { oid statusCheckRollup { state } } }
        }
      }
    }
  }
  reviewRequested: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 20) {
    issueCount
    nodes {
      ... on PullRequest {
        number title url isDraft
        author { login }
        repository { nameWithOwner url }
      }
    }
  }
}
"""

ACTIVITY_QUERY = """
query {
  viewer {
    login
    contributionsCollection {
      contributionCalendar {
        totalContributions
        weeks {
          contributionDays {
            date contributionCount contributionLevel weekday
          }
        }
      }
    }
  }
}
"""

_LEVELS = {"FIRST_QUARTILE": 1, "SECOND_QUARTILE": 2, "THIRD_QUARTILE": 3, "FOURTH_QUARTILE": 4}
_REPO = r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"
_PULL_RE = re.compile(rf"^({_REPO})#(\d+)$")
_RUN_RE = re.compile(rf"^({_REPO})/(\d+)$")


def ci_state(raw: Optional[str]) -> str:
    s = (raw or "").upper()
    if s in ("PENDING", "EXPECTED"):
        return "pending"
    if s == "SUCCESS":
        return "success"
    if s in ("ERROR", "FAILURE"):
        return "failure"
    return "unknown"


def review_state(raw: Optional[str]) -> str:
    return {"APPROVED": "approved", "CHANGES_REQUESTED": "changes_requested",
            "REVIEW_REQUIRED": "pending"}.get((raw or "").upper(), "unknown")


@dataclass(frozen=True)
class PR:
    id: str          # "owner/repo#12"
    title: str
    url: str
    repo: str
    number: int
    is_draft: bool
    ci: str
    review: str
    head_sha: Optional[str] = None


@dataclass(frozen=True)
class RepoCI:
    repo: str
    url: str
    branch: str
    ci: str
    head_sha: Optional[str] = None


@dataclass(frozen=True)
class Pulse:
    login: str
    my_prs: tuple
    to_review: tuple
    main_ci: tuple
    fetched_at: float

    @property
    def has_pending(self) -> bool:
        return any(p.ci == "pending" for p in self.my_prs) or any(r.ci == "pending" for r in self.main_ci)


@dataclass(frozen=True)
class GitHubState:
    pulse: Pulse
    stats: Optional[dict] = None
    stats_at: float = 0.0
    activity: Optional[dict] = None
    activity_at: float = 0.0


def _rollup(commit: object) -> tuple[Optional[str], Optional[str]]:
    if not isinstance(commit, dict):
        return None, None
    rollup = commit.get("statusCheckRollup")
    return (rollup.get("state") if isinstance(rollup, dict) else None), commit.get("oid")


def parse_pulse(root: object, now: float) -> Optional[Pulse]:
    data = root.get("data") if isinstance(root, dict) else None
    viewer = data.get("viewer") if isinstance(data, dict) else None
    if not isinstance(viewer, dict):
        return None
    my_prs, seen = [], set()
    for node in ((viewer.get("pullRequests") or {}).get("nodes") or []):
        if not isinstance(node, dict):   # null for PRs the token can't see (SAML orgs)
            continue
        repo = (node.get("repository") or {}).get("nameWithOwner")
        number, title, url = node.get("number"), node.get("title"), node.get("url")
        if not (isinstance(number, int) and isinstance(title, str) and isinstance(url, str) and repo):
            continue
        pid = f"{repo}#{number}"
        if pid in seen:
            continue
        seen.add(pid)
        commits = ((node.get("commits") or {}).get("nodes") or [])
        raw_ci, sha = _rollup((commits[-1] or {}).get("commit") if commits else None)
        my_prs.append(PR(pid, title, url, repo, number, bool(node.get("isDraft")), ci_state(raw_ci),
                         review_state(node.get("reviewDecision")), sha))
    main_ci = []
    for node in ((viewer.get("repositories") or {}).get("nodes") or []):
        if not isinstance(node, dict) or node.get("isArchived"):
            continue
        ref = node.get("defaultBranchRef")
        repo, url = node.get("nameWithOwner"), node.get("url")
        if not (isinstance(ref, dict) and isinstance(ref.get("name"), str) and repo and url):
            continue
        raw_ci, sha = _rollup(ref.get("target"))
        main_ci.append(RepoCI(repo, url, ref["name"], ci_state(raw_ci), sha))
    to_review, seen = [], set()
    for node in ((data.get("reviewRequested") or {}).get("nodes") or []):
        if not isinstance(node, dict):
            continue
        repo = (node.get("repository") or {}).get("nameWithOwner")
        number, title, url = node.get("number"), node.get("title"), node.get("url")
        if not (isinstance(number, int) and isinstance(title, str) and isinstance(url, str) and repo):
            continue
        pid = f"{repo}#{number}"
        if pid in seen:
            continue
        seen.add(pid)
        to_review.append(PR(pid, title, url, repo, number, bool(node.get("isDraft")), "unknown", "pending"))
    return Pulse(str(viewer.get("login") or ""), tuple(my_prs), tuple(to_review), tuple(main_ci), now)


def parse_activity(root: object) -> Optional[dict]:
    try:
        cal = root["data"]["viewer"]["contributionsCollection"]["contributionCalendar"]
        total, weeks_raw = cal["totalContributions"], cal["weeks"]
    except (KeyError, TypeError):
        return None
    if not isinstance(total, int) or not isinstance(weeks_raw, list):
        return None
    weeks = []
    for week in weeks_raw:
        days = []
        for d in (week or {}).get("contributionDays") or []:
            if not (isinstance(d.get("date"), str) and isinstance(d.get("contributionCount"), int)
                    and isinstance(d.get("weekday"), int)):
                continue
            days.append({"date": d["date"], "count": d["contributionCount"],
                         "level": _LEVELS.get(d.get("contributionLevel"), 0), "weekday": d["weekday"]})
        if days:
            weeks.append(days)
    return {"total": total, "weeks": weeks}


def pulse_events(old: Optional[Pulse], new: Pulse) -> list:
    """``[(kind, id)]`` comparing two polls. Same commit: state transitions; new PR
    or commit: fire if CI already finished (a pending one is caught next poll)."""
    if old is None:
        return []
    out = []
    old_prs = {}
    for p in old.my_prs:
        old_prs.setdefault(p.id, p)
    for p in new.my_prs:
        prev = old_prs.get(p.id)
        if prev is not None and prev.head_sha == p.head_sha:
            if p.ci == "failure" and prev.ci != "failure":
                out.append(("ci_failed", p.id))
            elif p.ci == "success" and prev.ci == "pending":
                out.append(("ci_passed", p.id))
        elif p.ci == "success":
            out.append(("ci_passed", p.id))
        elif p.ci == "failure":
            out.append(("ci_failed", p.id))
    old_repos = {}
    for r in old.main_ci:
        old_repos.setdefault(r.repo, r)
    for r in new.main_ci:
        prev = old_repos.get(r.repo)
        if prev is not None and prev.head_sha == r.head_sha:
            if r.ci == "failure" and prev.ci != "failure":
                out.append(("main_failed", r.repo))
        elif r.ci == "failure":
            out.append(("main_failed", r.repo))
    old_reviews = {p.id for p in old.to_review}
    out += [("review_requested", p.id) for p in new.to_review if p.id not in old_reviews]
    return out


_PRIORITY = {"ci_failed": 3, "main_failed": 3, "review_requested": 2, "ci_passed": 1}
_ACTIVE = {"ci_failed": "CI failed", "main_failed": "CI failed", "review_requested": "Review requested",
           "ci_passed": "CI passed"}
_CI_LABEL = {"success": "checks passed", "failure": "checks failing", "pending": "checks running",
             "unknown": "no checks"}
_REVIEW_LABEL = {"approved": " · approved", "changes_requested": " · changes requested",
                 "pending": " · review required", "unknown": ""}
_CI_TONE = {"success": OK, "failure": ERROR, "pending": WARNING, "unknown": IDLE}


class GitHubService(Service):
    id = "github"
    display_name = "GitHub"
    interval = 300
    first_delay = 10
    secrets = {"token": ENV}
    secret_labels = {"token": "Personal access token"}
    actions = frozenset({"github.rerun", "github.approve", "github.merge"})

    @staticmethod
    def _rest_headers(token: str) -> dict:
        return {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28"}

    def _graphql(self, http, token: str, query: str) -> dict:
        root = call_json(http, "POST", GRAPHQL, json={"query": query}, timeout=15,
                         headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        if not isinstance(root, dict) or not isinstance(root.get("data"), dict):
            errors = root.get("errors") if isinstance(root, dict) else None
            first = errors[0].get("message") if isinstance(errors, list) and errors and isinstance(errors[0], dict) else ""
            raise ServiceError(f"GitHub answered without data. {first}".strip())
        return root

    def fetch(self, http, cfg, prev=None, now=None) -> Snapshot:
        now = now or time.time()
        token = cfg.secret(ENV)
        pulse = parse_pulse(self._graphql(http, token, PULSE_QUERY), now)
        if pulse is None:
            raise ServiceError("GitHub's answer couldn't be read.")
        old = prev.state if prev is not None and isinstance(prev.state, GitHubState) else GitHubState(pulse)
        stats, stats_at = old.stats, old.stats_at
        if now - stats_at >= STATS_EVERY:
            try:
                stats, stats_at = self._stats(http, token), now
            except (HttpError, ServiceError):
                pass
        activity, activity_at = old.activity, old.activity_at
        if now - activity_at >= ACTIVITY_EVERY:
            try:
                activity = parse_activity(self._graphql(http, token, ACTIVITY_QUERY)) or activity
                activity_at = now
            except (HttpError, ServiceError):
                pass
        return self._snapshot(GitHubState(pulse, stats, stats_at, activity, activity_at), now)

    def _stats(self, http, token: str) -> dict:
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
        user = call_json(http, "GET", f"{API}/user", headers=headers, timeout=10)
        private = user.get("owned_private_repos")
        if not isinstance(private, int):
            private = user.get("total_private_repos") if isinstance(user.get("total_private_repos"), int) else 0
        repos = call_json(http, "GET", f"{API}/user/repos?per_page=100&affiliation=owner&sort=pushed",
                          headers=headers, timeout=15)
        stars = sum(r.get("stargazers_count") or 0 for r in repos if isinstance(r, dict)) if isinstance(repos, list) else 0
        return {"repos": (user.get("public_repos") or 0) + private, "stars": stars}

    def _snapshot(self, state: GitHubState, now: float) -> Snapshot:
        p = state.pulse
        failing_pr = next((x for x in p.my_prs if x.ci == "failure"), None)
        failing_main = next((r for r in p.main_ci if r.ci == "failure"), None)
        any_green = any(x.ci == "success" for x in p.my_prs) or any(r.ci == "success" for r in p.main_ci)
        if failing_main:
            tone, reason = ERROR, f"CI failing on {failing_main.repo} · {failing_main.branch}"
        elif failing_pr:
            tone, reason = ERROR, f"Checks failing on {failing_pr.repo} #{failing_pr.number}: {failing_pr.title}"
        elif p.has_pending:
            tone, reason = WARNING, "Checks are running"
        elif p.to_review:
            n = len(p.to_review)
            tone = WARNING
            reason = ("1 pull request waits for your review" if n == 1
                      else f"{n} pull requests wait for your review")
        elif any_green:
            tone, reason = OK, "All checks passed"
        else:
            tone, reason = IDLE, "Nothing going on"
        sections = []
        if p.my_prs:
            sections.append(Section("Your pull requests", [
                Item(f"#{x.number} {x.title}",
                     f"{x.repo} · {_CI_LABEL[x.ci]}{_REVIEW_LABEL[x.review]}{' · draft' if x.is_draft else ''}",
                     url=x.url, tone=_CI_TONE[x.ci]) for x in p.my_prs[:8]]))
        if p.to_review:
            sections.append(Section("Waiting for your review", [
                Item(f"#{x.number} {x.title}", x.repo, url=x.url, tone=WARNING) for x in p.to_review[:8]]))
        if p.main_ci:
            sections.append(Section("Default branches", [
                Item(r.repo, f"{r.branch} · {_CI_LABEL[r.ci]}", url=r.url, tone=_CI_TONE[r.ci])
                for r in p.main_ci[:8]]))
        headline = plural(len(p.my_prs), "open pull request")
        if state.activity:
            headline += f" · {state.activity['total']} contributions this year"
        extra = {"login": p.login, "stats": state.stats, "activity": state.activity}
        return Snapshot(self.id, self.display_name, tone, headline, reason, sections, now,
                        extra=extra, state=state)

    def next_interval(self, snapshot: Snapshot) -> float:
        state = snapshot.state
        return 60 if isinstance(state, GitHubState) and state.pulse.has_pending else 300

    def events(self, old_state, new_state) -> list:
        if not isinstance(old_state, GitHubState) or not isinstance(new_state, GitHubState):
            return []
        raw = pulse_events(old_state.pulse, new_state.pulse)
        if not raw:
            return []
        kind, ref = max(raw, key=lambda e: _PRIORITY[e[0]])   # first of the highest priority
        new = new_state.pulse
        if kind == "main_failed":
            r = next(x for x in new.main_ci if x.repo == ref)
            body, url = f"{r.repo} · {r.branch}", r.url
        else:
            x = next(x for x in (new.to_review if kind == "review_requested" else new.my_prs) if x.id == ref)
            body, url = f"{x.repo} #{x.number}: {x.title}", x.url
        if len(raw) > 1:
            body += f" (+{len(raw) - 1} more)"
        return [Event(kind, _ACTIVE[kind], body, {"url": url, "events": [list(e) for e in raw]})]

    # ── detail ──

    def detail(self, http, cfg, now=None) -> Detail:
        now = now or time.time()
        headers = self._rest_headers(cfg.secret(ENV))
        user = call_json(http, "GET", f"{API}/user", headers=headers)
        login = user.get("login") or ""

        def search(query: str) -> list:
            try:
                body = call_json(http, "GET", f"{API}/search/issues", headers=headers,
                                 params={"q": query, "per_page": 10, "sort": "updated"})
            except HttpError:
                return []
            return [i for i in body.get("items") or [] if isinstance(i, dict)]

        def pull_ref(item: dict) -> Optional[str]:
            url, number = item.get("repository_url"), item.get("number")
            if not isinstance(url, str) or not isinstance(number, int):
                return None
            return "/".join(url.rstrip("/").split("/")[-2:]) + f"#{number}"

        mine = []
        for item in search(f"is:pr is:open author:{login} archived:false"):
            ref = pull_ref(item)
            if not ref:
                continue
            draft = bool(item.get("draft"))
            mine.append(Item(item.get("title") or "Pull request", ref, tone=IDLE if draft else INFO,
                             date=parse_date(item.get("updated_at")), url=item.get("html_url"),
                             badge="Draft" if draft else None,
                             actions=[] if draft else [Action("github.merge", "Squash and merge", ref,
                                                              "arrow.triangle.merge",
                                                              confirm=f"Merge {ref} into its base branch?")]))
        asked = []
        for item in search(f"is:pr is:open review-requested:{login} archived:false"):
            ref = pull_ref(item)
            if not ref:
                continue
            author = (item.get("user") or {}).get("login") or ""
            asked.append(Item(item.get("title") or "Pull request", f"{ref} · {author}" if author else ref,
                              tone=WARNING, date=parse_date(item.get("updated_at")), url=item.get("html_url"),
                              actions=[Action("github.approve", "Approve", ref, "checkmark.seal")]))
        runs, failing = self._runs(http, headers)
        sections = []
        if asked:
            sections.append(Section("Reviews asked of you", asked))
        sections.append(Section("Your pull requests", mine, None if mine else "No open pull request."))
        if runs:
            sections.append(Section("CI on your latest repos", runs))
        return Detail(self.id, self.display_name,
                      [Stat("Your PRs", str(len(mine)), INFO),
                       Stat("Reviews", str(len(asked)), WARNING if asked else IDLE),
                       Stat("CI failing", str(failing), ERROR if failing else OK)],
                      sections, now)

    @staticmethod
    def _runs(http, headers: dict) -> tuple[list, int]:
        """CI runs on the repos you pushed to last; re-run only on failed ones."""
        try:
            repos = call_json(http, "GET", f"{API}/user/repos", headers=headers,
                              params={"sort": "pushed", "per_page": 5, "affiliation": "owner,collaborator"})
        except HttpError:
            return [], 0
        items, failing = [], 0
        for name in [r.get("full_name") for r in repos if isinstance(r, dict)] if isinstance(repos, list) else []:
            if not isinstance(name, str):
                continue
            try:
                body = call_json(http, "GET", f"{API}/repos/{name}/actions/runs", headers=headers,
                                 params={"per_page": 3})
            except HttpError:
                continue
            for run in body.get("workflow_runs") or []:
                if not isinstance(run, dict) or not isinstance(run.get("id"), int):
                    continue
                status, conclusion = run.get("status") or "", run.get("conclusion") or ""
                actions = []
                if status != "completed":
                    tone = WARNING
                elif conclusion == "success":
                    tone = OK
                elif conclusion in ("failure", "timed_out"):
                    tone = ERROR
                    failing += 1
                    actions.append(Action("github.rerun", "Re-run failed jobs", f"{name}/{run['id']}",
                                          "arrow.clockwise"))
                else:
                    tone = IDLE
                label = (conclusion if status == "completed" else status).replace("_", " ").title()
                items.append(Item(run.get("name") or "Workflow", f"{name} · {run.get('head_branch') or ''}",
                                  tone=tone, date=parse_date(run.get("created_at")), url=run.get("html_url"),
                                  badge=label or None, actions=actions))
        return items, failing

    def perform(self, http, cfg, kind: str, target: str) -> str:
        headers = self._rest_headers(cfg.secret(ENV))
        if kind == "github.rerun":
            m = _RUN_RE.match(target)
            if not m:
                raise ServiceError("Unknown run.")
            call_json(http, "POST", f"{API}/repos/{m.group(1)}/actions/runs/{m.group(2)}/rerun-failed-jobs",
                      headers=headers)
            return "Failed jobs started again"
        if kind in ("github.approve", "github.merge"):
            m = _PULL_RE.match(target)
            if not m:
                raise ServiceError("Unknown pull request.")
            repo, number = m.group(1), m.group(2)
            if kind == "github.approve":
                call_json(http, "POST", f"{API}/repos/{repo}/pulls/{number}/reviews", headers=headers,
                          json={"event": "APPROVE"})
                return "Approved"
            call_json(http, "PUT", f"{API}/repos/{repo}/pulls/{number}/merge", headers=headers,
                      json={"merge_method": "squash"})
            return "Merged"
        raise ServiceError("This action isn't available.")
