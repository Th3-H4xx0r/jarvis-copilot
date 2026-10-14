"""Notion: recently edited pages every 300 s; read-only detail."""
from __future__ import annotations

from jarvis_services.config import ConfigView
from jarvis_services.notion import NotionService
from jarvis_services.testing import FakeHttp

NOW = 1_791_936_000.0  # 2026-10-14 00:00 UTC
KEY = "secret_notion_123"
CFG = ConfigView({"SERVICES_NOTION_API_KEY": KEY}, {}, environ={})
SEARCH = "https://api.notion.com/v1/search"


def page(pid, title, edited="2026-10-13T23:30:00.000Z", emoji=None):
    p = {"object": "page", "id": pid, "last_edited_time": edited, "url": f"https://www.notion.so/{pid}",
         "properties": {"Name": {"id": "title", "type": "title", "title": [{"plain_text": title}]}}}
    if emoji:
        p["icon"] = {"type": "emoji", "emoji": emoji}
    return p


DATABASE = {"object": "database", "id": "db1", "last_edited_time": "2026-10-10T10:00:00Z",
            "title": [{"plain_text": "Road"}, {"plain_text": "map"}], "url": "https://www.notion.so/db1"}


def test_poll_request_and_snapshot():
    s = NotionService()
    assert s.interval == 300
    http = FakeHttp().add("POST", SEARCH, {"object": "list", "results": [
        page("p1", "Plan", emoji="📝"), page("p2", "Notes", edited="2026-10-01T10:00:00Z")]})
    snap = s.fetch(http, CFG, None, NOW)
    call = http.calls[0]
    assert call.headers == {"Authorization": f"Bearer {KEY}", "Notion-Version": "2022-06-28",
                            "Content-Type": "application/json"}
    assert call.json == {"sort": {"direction": "descending", "timestamp": "last_edited_time"}, "page_size": 3}
    assert snap.headline == "2 recent pages"
    assert snap.reason == "Last edited: Plan"
    assert snap.tone == "info"                                    # edited 10 min before NOW
    assert [i.title for i in snap.sections[0].items] == ["📝 Plan", "Notes"]


def test_old_edits_are_idle_and_empty_is_idle():
    http = FakeHttp().add("POST", SEARCH, {"results": [page("p", "Old", edited="2026-01-01T00:00:00Z")]})
    assert NotionService().fetch(http, CFG, None, NOW).tone == "idle"
    empty = NotionService().fetch(FakeHttp().add("POST", SEARCH, {"results": []}), CFG, None, NOW)
    assert empty.reason == "No recent page" and empty.sections == []


def test_detail_splits_pages_and_databases():
    http = FakeHttp().add("POST", SEARCH, {"results": [page("p1", "Plan"), DATABASE]})
    d = NotionService().detail(http, CFG, NOW)
    assert http.calls[0].json["page_size"] == 25
    assert [s.title for s in d.sections] == ["Edited lately", "Databases"]
    assert d.sections[1].items[0].title == "Roadmap"
    assert {s.label: s.value for s in d.stats}["Pages"] == "1"
    assert NotionService().actions == frozenset()
