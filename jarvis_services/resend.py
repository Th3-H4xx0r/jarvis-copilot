"""Resend: the latest emails and how they went, every minute; up close, the domains
too. Read only: nothing here sends an email.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import time

from jarvis_services.base import (
    ERROR, IDLE, INFO, OK, WARNING, Detail, Item, Section, Service, ServiceError, Snapshot, Stat, call_json,
    parse_date,
)

API = "https://api.resend.com"
ENV = "SERVICES_RESEND_API_KEY"


def _tone(event: str) -> str:
    if event in ("bounced", "complained", "failed", "suppressed"):
        return ERROR
    if event in ("delivered", "opened", "clicked"):
        return OK
    if event == "delivery_delayed":
        return WARNING
    return INFO


def _to(raw) -> list:
    if isinstance(raw, list):
        return [x for x in raw if isinstance(x, str)]
    return [raw] if isinstance(raw, str) else []


class ResendService(Service):
    id = "resend"
    display_name = "Resend"
    interval = 60
    first_delay = 6
    secrets = {"api_key": ENV}
    secret_labels = {"api_key": "API key (Full access)"}
    #: Kept for the clients' compose screens; the server never sends.
    settings = {"from": ""}

    @staticmethod
    def _headers(cfg) -> dict:
        return {"Authorization": f"Bearer {cfg.secret(ENV)}", "Accept": "application/json"}

    def fetch(self, http, cfg, prev=None, now=None) -> Snapshot:
        now = now or time.time()
        body = call_json(http, "GET", f"{API}/emails?limit=100", headers=self._headers(cfg), timeout=10)
        emails = []
        for e in body.get("data") or []:
            if not isinstance(e, dict) or not isinstance(e.get("id"), str) or not isinstance(e.get("created_at"), str):
                continue
            emails.append({"subject": e.get("subject") or "", "to": _to(e.get("to")),
                           "event": e.get("last_event") or "", "date": parse_date(e["created_at"]) or now})
        total = body.get("total") if isinstance(body.get("total"), int) else body.get("count")
        if not isinstance(total, int):
            total = len(emails) if emails else None
        if not emails:
            return Snapshot(self.id, self.display_name, IDLE, "Emails", "No email yet", [], now)
        latest = emails[0]
        tone = _tone(latest["event"])
        reason = (f"Last email is delayed: {latest['subject']}" if tone == WARNING
                  else f"Last email {latest['event']}: {latest['subject']}")
        items = [Item(e["subject"], f"to {', '.join(e['to'])} · {e['event']}", tone=_tone(e["event"]), date=e["date"])
                 for e in emails[:5]]
        return Snapshot(self.id, self.display_name, tone,
                        f"{total} emails sent" if total is not None else "Emails", reason,
                        [Section("Recent emails", items)], now)

    def detail(self, http, cfg, now=None) -> Detail:
        now = now or time.time()
        headers = self._headers(cfg)
        emails = [e for e in call_json(http, "GET", f"{API}/emails?limit=20", headers=headers).get("data") or []
                  if isinstance(e, dict)]
        delivered = bounced = 0
        email_items = []
        for e in emails:
            event = e.get("last_event") or "sent"
            tone = _tone(event)
            delivered += tone == OK
            bounced += tone == ERROR
            email_items.append(Item(e.get("subject") or "(no subject)", ", ".join(_to(e.get("to"))), tone=tone,
                                    date=parse_date(e.get("created_at")),
                                    badge=event.replace("_", " ").capitalize()))
        try:
            domains = [d for d in call_json(http, "GET", f"{API}/domains", headers=headers).get("data") or []
                       if isinstance(d, dict)]
        except (ServiceError, AttributeError):   # domains are a bonus; the emails still show
            domains = []
        domain_items = [Item(d.get("name") or "Domain", d.get("region") or "",
                             tone=OK if d.get("status") == "verified" else ERROR if d.get("status") == "failed" else WARNING,
                             badge=str(d.get("status") or "").replace("_", " ").capitalize() or None)
                        for d in domains]
        sections = [Section("Latest emails", email_items)]
        if domain_items:
            sections.append(Section("Domains", domain_items))
        return Detail(self.id, self.display_name,
                      [Stat("Delivered", str(delivered), OK), Stat("Bounced", str(bounced), ERROR if bounced else IDLE),
                       Stat("Domains", str(len(domains)))],
                      sections, now)
