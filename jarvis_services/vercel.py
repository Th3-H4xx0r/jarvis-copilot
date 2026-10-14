"""Vercel: the last terminal deployments every 30 s (optionally only some projects);
up close, deployments with redeploy / promote / cancel, and projects.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import re
import time

from jarvis_services.base import (
    ERROR, IDLE, OK, WARNING, Action, Detail, Event, Item, Section, Service, ServiceError, Snapshot,
    Stat, call_json, first_line, parse_date,
)

API = "https://api.vercel.com"
ENV = "SERVICES_VERCEL_TOKEN"
_TERMINAL = ("READY", "ERROR", "CANCELED")
_UID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_NAME = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
_TARGET = re.compile(r"^[A-Za-z0-9_-]{0,64}$")


def _parse(d: dict):
    if not isinstance(d, dict):
        return None
    uid, name, state = d.get("uid"), d.get("name"), d.get("state")
    if not (isinstance(uid, str) and isinstance(name, str) and isinstance(state, str)):
        return None
    meta = d.get("meta") if isinstance(d.get("meta"), dict) else {}
    return {"id": uid, "project": name, "url": d.get("url") or "", "state": state,
            "created": parse_date(d.get("createdAt")) or 0.0,
            "message": (meta.get("githubCommitMessage") or meta.get("gitlabCommitMessage")
                        or meta.get("bitbucketCommitMessage")),
            "branch": meta.get("githubCommitRef") or meta.get("gitlabCommitRef") or meta.get("bitbucketBranch")}


def _label(state: str) -> str:
    return "Ready" if state == "READY" else "Canceled" if state == "CANCELED" else "Error"


def _tone(state: str) -> str:
    return OK if state == "READY" else WARNING if state == "CANCELED" else ERROR


class VercelService(Service):
    id = "vercel"
    display_name = "Vercel"
    interval = 30
    first_delay = 5
    secrets = {"token": ENV}
    secret_labels = {"token": "Access token"}
    settings = {"projects": []}
    actions = frozenset({"vercel.redeploy", "vercel.promote", "vercel.cancel"})

    @staticmethod
    def _headers(cfg) -> dict:
        return {"Authorization": f"Bearer {cfg.secret(ENV)}", "Accept": "application/json"}

    def fetch(self, http, cfg, prev=None, now=None) -> Snapshot:
        now = now or time.time()
        body = call_json(http, "GET", f"{API}/v6/deployments?limit=5", headers=self._headers(cfg), timeout=10)
        deployments = [d for d in map(_parse, body.get("deployments") or []) if d and d["state"] in _TERMINAL]
        projects = [p for p in cfg.setting(self.id, "projects", []) if isinstance(p, str)]
        if projects:
            deployments = [d for d in deployments if d["project"] in projects]
        latest = deployments[0] if deployments else None
        state = {"latest": latest}
        if latest is None:
            return Snapshot(self.id, self.display_name, IDLE, "No deployment yet", "Nothing deployed lately",
                            [], now, state=state)
        branch = f" · {latest['branch']}" if latest["branch"] else ""
        reason = {"READY": f"Last deploy is live: {latest['project']}{branch}",
                  "CANCELED": f"Last deploy was canceled: {latest['project']}{branch}"}.get(
            latest["state"], f"Last deploy failed: {latest['project']}{branch}")
        items = [Item(d["project"], " · ".join(x for x in (_label(d["state"]), d["branch"], d["message"]) if x),
                      url=f"https://{d['url']}" if d["url"] else None, tone=_tone(d["state"]), date=d["created"])
                 for d in deployments[:10]]
        return Snapshot(self.id, self.display_name, _tone(latest["state"]),
                        f"{latest['project']} · {_label(latest['state'])}", reason,
                        [Section("Deployments", items)], now, state=state)

    def events(self, old_state, new_state) -> list:
        if not old_state or not new_state:
            return []
        new, old = new_state.get("latest"), old_state.get("latest")
        if not new or (old and old["id"] == new["id"]) or new["state"] == "CANCELED":
            return []
        body = " · ".join(x for x in (new["project"], new["branch"]) if x)
        data = {"deployment": new["id"], "url": f"https://{new['url']}" if new["url"] else None}
        if new["state"] == "READY":
            return [Event("deploy_ready", "Deploy ready", body, data)]
        return [Event("deploy_failed", "Deploy failed", body, data)]

    # ── detail ──

    def detail(self, http, cfg, now=None) -> Detail:
        now = now or time.time()
        headers = self._headers(cfg)
        deployments = call_json(http, "GET", f"{API}/v6/deployments?limit=20", headers=headers).get("deployments") or []
        try:
            projects = call_json(http, "GET", f"{API}/v9/projects?limit=20", headers=headers).get("projects") or []
        except ServiceError:
            projects = []
        items, ready, failed, building = [], 0, 0, 0
        for d in deployments:
            if not isinstance(d, dict) or not isinstance(d.get("uid"), str):
                continue
            uid, name = d["uid"], d.get("name") or "Deployment"
            state = str(d.get("state") or d.get("readyState") or "").upper()
            target = d.get("target")
            meta = d.get("meta") if isinstance(d.get("meta"), dict) else {}
            creator = (d.get("creator") or {}).get("username") or "" if isinstance(d.get("creator"), dict) else ""
            tone, actions = IDLE, []
            redeploy = Action("vercel.redeploy", "Redeploy", f"{uid}|{name}|{target or ''}", "arrow.clockwise")
            if state == "READY":
                ready += 1
                tone = OK
                actions.append(redeploy)
                if target != "production":
                    actions.append(Action("vercel.promote", "Promote to production", f"{uid}|{name}",
                                          "arrow.up.circle",
                                          confirm="A new production build starts from this deployment, "
                                                  "using your production environment variables."))
            elif state == "ERROR":
                failed += 1
                tone = ERROR
                actions.append(redeploy)
            elif state in ("BUILDING", "QUEUED", "INITIALIZING"):
                building += 1
                tone = WARNING
                actions.append(Action("vercel.cancel", "Cancel build", uid, "xmark.circle",
                                      destructive=True, confirm="Stop this build?"))
            subtitle = " · ".join(x for x in (meta.get("githubCommitRef") or "",
                                              first_line(meta.get("githubCommitMessage") or ""), creator) if x)
            badge = "Production" if target == "production" else "Preview" if state == "READY" else state.capitalize()
            items.append(Item(name, subtitle or state.capitalize(), tone=tone,
                              date=parse_date(d.get("created") or d.get("createdAt")),
                              url=f"https://{d['url']}" if isinstance(d.get("url"), str) else None,
                              badge=badge or None, actions=actions))
        project_items = [Item(p.get("name") or "Project", str(p.get("framework") or "").capitalize(),
                              date=parse_date(p.get("updatedAt")))
                         for p in projects[:20] if isinstance(p, dict)]
        sections = [Section("Deployments", items)]
        if project_items:
            sections.append(Section(f"Projects · {len(project_items)}", project_items))
        return Detail(self.id, self.display_name,
                      [Stat("Ready", str(ready), OK),
                       Stat("Building", str(building), WARNING if building else IDLE),
                       Stat("Failed", str(failed), ERROR if failed else IDLE),
                       Stat("Projects", str(len(projects)))],
                      sections, now)

    def perform(self, http, cfg, kind: str, target: str) -> str:
        headers = self._headers(cfg)
        parts = target.split("|")
        if kind == "vercel.redeploy":
            if len(parts) != 3 or not (_UID.match(parts[0]) and _NAME.match(parts[1]) and _TARGET.match(parts[2])):
                raise ServiceError("Unknown deployment.")
            body = {"name": parts[1], "deploymentId": parts[0]}
            if parts[2]:
                body["target"] = parts[2]
            url = call_json(http, "POST", f"{API}/v13/deployments", headers=headers, json=body).get("url")
            return f"Building {url}" if url else "New deployment started"
        if kind == "vercel.promote":
            # Vercel only promotes production builds in place: a preview is rebuilt for
            # production, as `vercel promote` does.
            if len(parts) != 2 or not (_UID.match(parts[0]) and _NAME.match(parts[1])):
                raise ServiceError("Unknown deployment.")
            body = {"deploymentId": parts[0], "name": parts[1], "target": "production",
                    "meta": {"action": "promote"}}
            url = call_json(http, "POST", f"{API}/v13/deployments", headers=headers, json=body).get("url")
            return f"Building {url} for production" if url else "Production build started"
        if kind == "vercel.cancel":
            if not _UID.match(target):
                raise ServiceError("Unknown deployment.")
            call_json(http, "PATCH", f"{API}/v12/deployments/{target}/cancel", headers=headers)
            return "Build canceled"
        raise ServiceError("This action isn't available.")
