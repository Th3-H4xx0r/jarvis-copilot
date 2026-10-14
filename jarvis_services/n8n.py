"""n8n: the latest workflow execution every 15 s (``/api/v1/executions``, falling
back to ``/rest/executions``); each new finished one is read in full and kept (the
last 10). Up close: workflows (turn on / off) and executions (retry a failed one).

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import re
import time
from typing import Any, Optional
from urllib.parse import quote

from jarvis_services.base import (
    ERROR, IDLE, OK, WARNING, Action, Detail, Event, HttpError, Item, Section, Service, ServiceError,
    Snapshot, Stat, as_id, call_json, parse_date, plural,
)

ENV = "SERVICES_N8N_API_KEY"
_TERMINAL = ("success", "error", "crashed", "canceled", "failed")
_FAILED = ("error", "crashed", "failed")
_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MAX_RUNS = 10


def _fmt(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return value[:50]
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return f"[{len(value)}]"
    if isinstance(value, dict):
        return "{…}"
    return str(value)


def _workflow_name(body: dict) -> str:
    wd = body.get("workflowData")
    if isinstance(wd, dict) and isinstance(wd.get("name"), str):
        return wd["name"]
    return body["name"] if isinstance(body.get("name"), str) else "Workflow"


def _run_detail(body: dict, success: bool) -> Optional[str]:
    """The last node's output (success) or the failing node and its message."""
    data = body.get("data")
    result = data.get("resultData") if isinstance(data, dict) else None
    if not isinstance(result, dict):
        return None
    run_data = result.get("runData") if isinstance(result.get("runData"), dict) else {}
    if not success:
        err = result.get("error")
        if isinstance(err, dict):
            msg = str(err.get("message") or "")
            node = (err.get("node") or {}).get("name") if isinstance(err.get("node"), dict) else None
            return f"{node}\n{msg}" if node else msg
        for node, runs in run_data.items():
            if isinstance(runs, list) and runs and isinstance(runs[0], dict):
                e = runs[0].get("error")
                if isinstance(e, dict) and isinstance(e.get("message"), str):
                    return f"{node}\n{e['message']}"
        return None
    last = result.get("lastNodeExecuted")
    try:
        items = run_data[last][0]["data"]["main"][0]
    except (KeyError, IndexError, TypeError):
        return None
    if not isinstance(items, list):
        return None
    header = f"→ {last} · {plural(len(items), 'item')}"
    first = items[0].get("json") if items and isinstance(items[0], dict) else None
    if isinstance(first, dict) and first:
        lines = [f"{k}: {_fmt(v)}" for k, v in list(first.items())[:4]]
        return header + "\n" + "\n".join(lines)
    return header


class N8nService(Service):
    id = "n8n"
    display_name = "n8n"
    interval = 15
    first_delay = 3
    secrets = {"api_key": ENV}
    secret_labels = {"api_key": "API key"}
    settings = {"url": "", "workflows": []}
    required_settings = ("url",)
    actions = frozenset({"n8n.activate", "n8n.deactivate", "n8n.retry"})

    @staticmethod
    def _base(cfg) -> str:
        return str(cfg.setting("n8n", "url", "") or "").strip().rstrip("/")

    @staticmethod
    def _headers(cfg) -> dict:
        return {"X-N8N-API-KEY": cfg.secret(ENV), "Accept": "application/json"}

    def fetch(self, http, cfg, prev=None, now=None) -> Snapshot:
        now = now or time.time()
        base, headers = self._base(cfg), self._headers(cfg)
        old = prev.state if prev is not None and isinstance(prev.state, dict) else {}
        runs, last_id = list(old.get("runs", ())), old.get("last_id")
        listing, error = None, None
        for url in (f"{base}/api/v1/executions?limit=1&includeData=false",
                    f"{base}/rest/executions?limit=1&includeData=false"):
            try:
                listing = call_json(http, "GET", url, headers=headers, timeout=10)
                break
            except HttpError as e:
                error = e
        if listing is None:
            raise error or ServiceError("n8n didn't answer.")
        items = listing.get("data") if isinstance(listing, dict) else listing
        first = items[0] if isinstance(items, list) and items and isinstance(items[0], dict) else None
        eid = as_id(first.get("id")) if first else None
        status = str(first.get("status") or "") if first else ""
        if eid and eid != last_id and status in _TERMINAL:
            last_id = eid
            success = status == "success"
            name, detail = self._execution(http, base, headers, eid, success)
            wanted = [w for w in cfg.setting(self.id, "workflows", []) if isinstance(w, str)]
            if not wanted or name in wanted:
                runs = [{"id": eid, "workflow": name, "detail": detail, "success": success,
                         "date": now}] + runs[:MAX_RUNS - 1]
        return self._snapshot(runs, now, {"last_id": last_id, "runs": tuple(runs)})

    @staticmethod
    def _execution(http, base: str, headers: dict, eid: str, success: bool) -> tuple[str, Optional[str]]:
        """The workflow's name and what the run did (``includeData=true`` needed on some versions)."""
        for url in (f"{base}/api/v1/executions/{eid}?includeData=true", f"{base}/api/v1/executions/{eid}",
                    f"{base}/rest/executions/{eid}?includeData=true", f"{base}/rest/executions/{eid}"):
            try:
                body = call_json(http, "GET", url, headers=headers, timeout=10)
            except HttpError:
                continue
            if isinstance(body, dict):
                return _workflow_name(body), _run_detail(body, success)
        return "Workflow", None

    def _snapshot(self, runs: list, now: float, state: dict) -> Snapshot:
        if not runs:
            return Snapshot(self.id, self.display_name, IDLE, "No run yet", "Watching your workflows",
                            [], now, state=state)
        latest = runs[0]
        reason = (f"Last run succeeded: {latest['workflow']}" if latest["success"]
                  else f"Last run failed: {latest['workflow']}"
                       + (f" · {latest['detail']}" if latest["detail"] else ""))
        failed = sum(1 for r in runs if not r["success"])
        items = [Item(r["workflow"], r["detail"] or ("succeeded" if r["success"] else "failed"),
                      tone=OK if r["success"] else ERROR, date=r["date"]) for r in runs]
        return Snapshot(self.id, self.display_name, OK if latest["success"] else ERROR,
                        "All recent runs succeeded" if failed == 0 else plural(failed, "failed run"),
                        reason, [Section("Recent runs", items)], now, state=state)

    def events(self, old_state, new_state) -> list:
        if not old_state or not new_state:
            return []
        seen = {r["id"] for r in old_state.get("runs", ())}
        out = []
        for run in new_state.get("runs", ()):
            if run["id"] in seen or run["success"]:
                continue
            detail = (run["detail"] or "").replace("\n", ": ", 1)
            out.append(Event("workflow_failed", "Workflow failed",
                             f"{run['workflow']} · {detail}" if detail else run["workflow"],
                             {"execution": run["id"]}))
        return out

    # ── detail ──

    def detail(self, http, cfg, now=None) -> Detail:
        now = now or time.time()
        base, headers = self._base(cfg), self._headers(cfg)
        # Pages of at most 250 (then `cursor` = the previous `nextCursor`): read them all
        # so the counts are right.
        workflows: list = []
        cursor = None
        while True:
            url = f"{base}/api/v1/workflows?limit=250" + (f"&cursor={quote(cursor, safe='')}" if cursor else "")
            page = call_json(http, "GET", url, headers=headers)
            workflows += [w for w in (page.get("data") or []) if isinstance(w, dict)] if isinstance(page, dict) else []
            cursor = page.get("nextCursor") if isinstance(page, dict) else None
            if not cursor or len(workflows) >= 5000:
                break
        names, active, workflow_items = {}, 0, []
        for w in workflows:
            wid = as_id(w.get("id"))
            if not wid:
                continue
            name = w.get("name") or "Workflow"
            names[wid] = name
            if w.get("isArchived"):      # listed, but n8n answers 400 to turning them on
                continue
            on = bool(w.get("active"))
            active += on
            action = (Action("n8n.deactivate", "Turn off", wid, "pause.circle", destructive=True,
                             confirm=f"Stop {name} from running?") if on
                      else Action("n8n.activate", "Turn on", wid, "play.circle"))
            workflow_items.append(Item(name, tone=OK if on else IDLE, date=parse_date(w.get("updatedAt")),
                                       url=f"{base}/workflow/{wid}", badge="Active" if on else "Off",
                                       actions=[action]))
        try:
            executions = call_json(http, "GET", f"{base}/api/v1/executions?limit=15", headers=headers).get("data") or []
        except (HttpError, AttributeError):
            executions = []
        failed, run_items = 0, []
        for e in executions:
            eid = as_id(e.get("id")) if isinstance(e, dict) else None
            if not eid:
                continue
            wf = as_id(e.get("workflowId")) or ""
            status = e.get("status") or ("success" if e.get("finished") else "error")
            bad = status in _FAILED
            failed += bad
            run_items.append(Item(names.get(wf, f"Workflow {wf}"), f"Execution {eid}",
                                  tone=ERROR if bad else OK if status == "success" else WARNING,
                                  date=parse_date(e.get("startedAt")),
                                  url=f"{base}/workflow/{wf}/executions/{eid}", badge=str(status).capitalize(),
                                  actions=[Action("n8n.retry", "Retry", eid, "arrow.clockwise")] if bad else []))
        workflow_items.sort(key=lambda i: i.date or 0, reverse=True)
        return Detail(self.id, self.display_name,
                      [Stat("Workflows", str(len(workflow_items))), Stat("Active", str(active), OK),
                       Stat("Failed runs", str(failed), ERROR if failed else IDLE)],
                      [Section("Latest runs", run_items), Section("Workflows", workflow_items[:50])], now)

    def perform(self, http, cfg, kind: str, target: str) -> str:
        if not _ID.match(target or ""):
            raise ServiceError("Unknown workflow or run.")
        base, headers = self._base(cfg), self._headers(cfg)
        if kind == "n8n.activate":
            call_json(http, "POST", f"{base}/api/v1/workflows/{target}/activate", headers=headers)
            return "Turned on"
        if kind == "n8n.deactivate":
            call_json(http, "POST", f"{base}/api/v1/workflows/{target}/deactivate", headers=headers)
            return "Turned off"
        if kind == "n8n.retry":
            try:
                call_json(http, "POST", f"{base}/api/v1/executions/{target}/retry", headers=headers)
            except HttpError as e:
                if e.status in (404, 405):   # POST …/retry only exists from n8n 1.112.0
                    raise ServiceError("Couldn't retry this run. It may have been deleted, or your n8n is "
                                       "older than 1.112, which is needed to retry from here.") from None
                raise
            return "Running again"
        raise ServiceError("This action isn't available.")
