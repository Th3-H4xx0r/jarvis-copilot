"""Todo due alerts run as a no-model cron script (cron/scripts/todo_due_alerts.py)."""
import importlib.util
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from jarvis_registry.store import Registry

_PATH = Path(__file__).resolve().parents[2] / "cron" / "scripts" / "todo_due_alerts.py"
CT = ZoneInfo("America/Chicago")
NOW = datetime(2026, 11, 24, 8, 5, tzinfo=CT)


def _mod():
    spec = importlib.util.spec_from_file_location("todo_due_alerts", _PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def reg(tmp_path):
    r = Registry(tmp_path / "registry.db")
    yield r
    r.close()


class FakeNotify:
    def __init__(self, ok=True, err=""):
        self.calls = []
        self.ok, self.err = ok, err

    def __call__(self, title, body):
        self.calls.append((title, body))
        return self.ok, self.err


def _item(**kw):
    base = {"id": 1, "title": "Pay rent", "notes": "", "due": "2026-11-24T08:00:00-06:00",
            "priority": "normal", "done": False, "notified": False, "source": "user",
            "created": "2026-11-20T09:00:00-06:00", "completed": None}
    base.update(kw)
    return base


def _put(reg, doc):
    reg.space("todo-list").put("list", doc)


def _doc(reg):
    return reg.open("todo-list").get("list")


def _updated_at(reg):
    row = reg._one("SELECT updated_at FROM documents WHERE space_id='todo-list' AND key='list'")
    return row["updated_at"] if row else None


def test_due_item_notified_and_marked(reg):
    _put(reg, {"items": [_item(notes="Landlord portal")], "next_id": 2})
    notify = FakeNotify()
    out = _mod().run(NOW, registry=reg, notify=notify)
    assert out == []
    assert notify.calls == [("Todo due", "Pay rent — Landlord portal")]
    assert _doc(reg)["items"][0]["notified"] is True


def test_body_is_title_when_no_notes(reg):
    _put(reg, {"items": [_item()], "next_id": 2})
    notify = FakeNotify()
    _mod().run(NOW, registry=reg, notify=notify)
    assert notify.calls == [("Todo due", "Pay rent")]


def test_future_done_or_notified_items_untouched(reg):
    items = [
        _item(id=1, due="2026-11-24T09:00:00-06:00"),
        _item(id=2, done=True),
        _item(id=3, notified=True),
        _item(id=4, due=None),
    ]
    _put(reg, {"items": items, "next_id": 5})
    before = _updated_at(reg)
    notify = FakeNotify()
    assert _mod().run(NOW, registry=reg, notify=notify) == []
    assert notify.calls == []
    assert _updated_at(reg) == before
    assert _doc(reg)["items"] == items


def test_push_failure_keeps_item_and_reports(reg):
    _put(reg, {"items": [_item()], "next_id": 2})
    notify = FakeNotify(ok=False, err="no phone with push registered")
    out = _mod().run(NOW, registry=reg, notify=notify)
    assert out == ["Todo due alert failed for: Pay rent (no phone with push registered)"]
    assert _doc(reg)["items"][0]["notified"] is False


def test_naive_due_is_central(reg):
    # 08:00 Central, naive → due at NOW (08:05 CT); 08:10 naive → not yet due.
    _put(reg, {"items": [_item(id=1, due="2026-11-24T08:00:00"),
                         _item(id=2, title="Later", due="2026-11-24T08:10:00")], "next_id": 3})
    notify = FakeNotify()
    _mod().run(NOW, registry=reg, notify=notify)
    assert notify.calls == [("Todo due", "Pay rent")]


@pytest.mark.parametrize("doc", [None, {"items": "x"}, {"items": [None, 3, {"title": "no due"}]}])
def test_missing_or_malformed_doc_is_silent(reg, doc):
    if doc is not None:
        _put(reg, doc)
    notify = FakeNotify()
    assert _mod().run(NOW, registry=reg, notify=notify) == []
    assert notify.calls == []


def test_missing_space_is_silent(reg):
    assert _mod().run(NOW, registry=reg, notify=FakeNotify()) == []


def test_other_items_preserved(reg):
    other = _item(id=7, title="Someday", due=None, notes="keep me")
    _put(reg, {"items": [_item(), other], "next_id": 8, "extra": {"k": 1}})
    _mod().run(NOW, registry=reg, notify=FakeNotify())
    doc = _doc(reg)
    assert doc["next_id"] == 8 and doc["extra"] == {"k": 1}
    assert doc["items"][1] == other
