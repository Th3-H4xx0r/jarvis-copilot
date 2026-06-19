"""Unit tests for the custom-design Live Activity push (api.island_la_push).

Run from webui/:
    cd webui && python3 -m pytest tests/test_island_la_push.py
"""
from __future__ import annotations

import json

import pytest

import api.island_la_push as m
from api.island_la_push import build_custom_content_state, push_design_update


@pytest.fixture(autouse=True)
def _reset():
    m._last_sig.clear()
    m._last_push_ts.clear()
    yield


def test_content_state_has_all_keys():
    cs = build_custom_content_state("deploy", 3, {"pct": 62})
    for k in ("state", "transcript", "activity", "connected", "devices", "mode",
              "sessions", "sessionTotal", "entryTotal", "waitingCount",
              "usage5", "usageWeek", "usage5Resets", "usageWeekResets",
              "designId", "designVersion", "data"):
        assert k in cs
    assert cs["mode"] == "custom"
    assert cs["designId"] == "deploy" and cs["designVersion"] == 3
    assert json.loads(cs["data"]) == {"pct": 62}


class FakeIslandStore:
    def __init__(self, *, pinned="deploy", design=None, data=None):
        self._pinned = pinned
        self._design = design if design is not None else {"id": "deploy", "version": 2}
        self._data = data if data is not None else {"pct": 10}

    def get_selection(self):
        return {"mode": "pinned" if self._pinned else "auto",
                "pinnedId": self._pinned}

    def get_design(self, did):
        return self._design if self._design and self._design.get("id") == did else None

    def get_data(self, did):
        return dict(self._data)


class FakeTokenStore:
    def __init__(self, tokens=("abc",)):
        self.tokens = [{"token": t} for t in tokens]
        self.deleted = []

    def list_la_tokens(self):
        return list(self.tokens)

    def delete_la_token(self, t):
        self.deleted.append(t)


def _ok_sender(calls):
    def s(tok, cs, event="update"):
        calls.append((tok, cs, event))
        return {"ok": True}
    return s


def test_not_pinned_no_push():
    isl = FakeIslandStore(pinned=None)
    n = push_design_update(isl, FakeTokenStore(), "deploy", sender=lambda *a, **k: {"ok": True})
    assert n == 0


def test_pinned_pushes():
    isl = FakeIslandStore(pinned="deploy")
    calls = []
    n = push_design_update(isl, FakeTokenStore(), "deploy", sender=_ok_sender(calls))
    assert n == 1 and len(calls) == 1
    assert calls[0][1]["designId"] == "deploy"


def test_dedupe_unchanged():
    isl = FakeIslandStore(pinned="deploy")
    calls = []
    push_design_update(isl, FakeTokenStore(), "deploy", sender=_ok_sender(calls))
    n2 = push_design_update(isl, FakeTokenStore(), "deploy", sender=_ok_sender(calls))
    assert n2 == 0  # same content → no second push


def test_missing_design_no_push():
    isl = FakeIslandStore(pinned="ghost", design={"id": "deploy", "version": 1})
    n = push_design_update(isl, FakeTokenStore(), "ghost", sender=lambda *a, **k: {"ok": True})
    assert n == 0


def test_stale_token_dropped_on_410():
    isl = FakeIslandStore(pinned="deploy")
    ts = FakeTokenStore()

    def bad(tok, cs, event="update"):
        return {"ok": False, "status": 410, "error": "Unregistered"}

    n = push_design_update(isl, ts, "deploy", sender=bad)
    assert n == 0 and "abc" in ts.deleted


def test_force_bypasses_pin_gate():
    isl = FakeIslandStore(pinned=None)
    calls = []
    n = push_design_update(isl, FakeTokenStore(), "deploy",
                           sender=_ok_sender(calls), force=True)
    assert n == 1
