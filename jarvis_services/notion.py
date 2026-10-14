"""Notion: the pages edited last, every 5 minutes; up close, pages and databases.
Read only.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import time
from datetime import datetime

from jarvis_services.base import (
    IDLE, INFO, Detail, Item, Section, Service, Snapshot, Stat, call_json, parse_date, plural,
)

SEARCH = "https://api.notion.com/v1/search"
ENV = "SERVICES_NOTION_API_KEY"
_SORT = {"direction": "descending", "timestamp": "last_edited_time"}


def _title(obj: dict, joined: bool) -> str:
    """Database: its title; page: its title property. ``joined`` keeps every fragment
    (the detail), else only the first (as the notch shows it)."""
    def text(fragments) -> str:
        parts = [f.get("plain_text") for f in fragments or [] if isinstance(f, dict)]
        parts = [p for p in parts if isinstance(p, str)]
        return "".join(parts) if joined else (parts[0] if parts else "")

    if obj.get("object") == "database":
        return text(obj.get("title"))
    for prop in (obj.get("properties") or {}).values():
        if isinstance(prop, dict) and prop.get("type") == "title":
            found = text(prop.get("title"))
            if found:
                return found
    return ""


def _emoji(obj: dict):
    icon = obj.get("icon")
    return icon.get("emoji") if isinstance(icon, dict) and icon.get("type") == "emoji" else None


class NotionService(Service):
    id = "notion"
    display_name = "Notion"
    interval = 300
    first_delay = 9
    secrets = {"api_key": ENV}
    secret_labels = {"api_key": "Internal integration secret"}

    @staticmethod
    def _headers(cfg) -> dict:
        return {"Authorization": f"Bearer {cfg.secret(ENV)}", "Notion-Version": "2022-06-28",
                "Content-Type": "application/json"}

    def fetch(self, http, cfg, prev=None, now=None) -> Snapshot:
        now = now or time.time()
        body = call_json(http, "POST", SEARCH, headers=self._headers(cfg), timeout=10,
                         json={"sort": _SORT, "page_size": 3})
        pages = []
        for obj in body.get("results") or []:
            if not isinstance(obj, dict) or not isinstance(obj.get("id"), str):
                continue
            edited = parse_date(obj.get("last_edited_time"))
            if edited is None:
                continue
            pages.append({"title": _title(obj, joined=False) or "Untitled", "emoji": _emoji(obj),
                          "edited": edited, "url": obj.get("url") or "https://notion.so"})
        pages.sort(key=lambda p: p["edited"], reverse=True)
        items = [Item(" ".join(x for x in (p["emoji"], p["title"]) if x), tone=INFO, date=p["edited"],
                      url=p["url"]) for p in pages[:10]]
        recent = bool(pages) and pages[0]["edited"] > now - 3600
        return Snapshot(self.id, self.display_name, INFO if recent else IDLE, plural(len(pages), "recent page"),
                        f"Last edited: {pages[0]['title']}" if pages else "No recent page",
                        [Section("Recently edited", items)] if items else [], now)

    def detail(self, http, cfg, now=None) -> Detail:
        now = now or time.time()
        body = call_json(http, "POST", SEARCH, headers=self._headers(cfg), json={"sort": _SORT, "page_size": 25})
        results = [o for o in body.get("results") or [] if isinstance(o, dict)]
        pages, databases = [], []
        for obj in results:
            emoji = _emoji(obj)
            item = Item(f"{emoji + ' ' if emoji else ''}{_title(obj, joined=True) or 'Untitled'}",
                        date=parse_date(obj.get("last_edited_time")), url=obj.get("url"),
                        badge="Archived" if obj.get("archived") else None)
            (databases if obj.get("object") == "database" else pages).append(item)
        today = datetime.fromtimestamp(now).date()
        edited_today = sum(1 for o in results
                           if (t := parse_date(o.get("last_edited_time"))) and datetime.fromtimestamp(t).date() == today)
        sections = [Section("Edited lately", pages)]
        if databases:
            sections.append(Section("Databases", databases))
        return Detail(self.id, self.display_name,
                      [Stat("Edited today", str(edited_today), INFO if edited_today else IDLE),
                       Stat("Pages", str(len(pages))), Stat("Databases", str(len(databases)))],
                      sections, now)
