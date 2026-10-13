"""One default (a model via Single, or a harness) + Voice/Chat overrides.

Pranav (2026-10-12): "can you add support for a harness to be used as the default instead of it being
a single model only. Add this across all platforms"."""
import json

import pytest

from agent.harness import store as hstore
from agent.harness.planner import resolve_harness


@pytest.fixture
def store(tmp_path):
    s = hstore.HarnessStore(tmp_path, "default")
    (s.base / "designs").mkdir(parents=True)
    for hid in ("mine", "router"):
        (s.base / "designs" / f"{hid}.json").write_text(json.dumps({
            "id": hid, "name": hid.title(), "version": 1,
            "nodes": [{"id": "in", "type": "message", "x": 0, "y": 0},
                      {"id": "a", "type": "answer", "model": "@session", "x": 200, "y": 0}],
            "edges": [{"from": "in", "to": "a", "when": "always"}]}))
    return s


def _write(store, data):
    store._assign_path.write_text(json.dumps(data))


def test_fresh_install_keeps_todays_behaviour(store):
    assert store.get_assignments() == {"default": "single", "voice": "fast-claude", "chat": "single"}
    assert store.overrides() == {"voice": "fast-claude", "chat": ""}


def test_an_old_file_migrates_without_changing_behaviour(store):
    _write(store, {"voice": "router", "chat": "single"})
    assert store.get_assignments() == {"default": "single", "voice": "router", "chat": "single"}
    assert store.overrides() == {"voice": "router", "chat": ""}
    _write(store, {"voice": "router", "chat": "mine"})
    assert store.effective("chat") == "mine" and store.effective("messaging") == "mine"


def test_overrides_fall_back_to_the_default(store):
    _write(store, {"default": "mine", "voice": "", "chat": ""})
    for surface in ("voice", "chat", "messaging", "schedule", "anything"):
        assert store.effective(surface) == "mine"
    _write(store, {"default": "mine", "voice": "router", "chat": ""})
    assert store.effective("voice") == "router" and store.effective("chat") == "mine"


def test_a_missing_harness_in_an_override_falls_through(store):
    _write(store, {"default": "mine", "voice": "gone", "chat": ""})
    assert store.effective("voice") == "mine"
    _write(store, {"default": "gone", "voice": "", "chat": ""})
    assert store.effective("chat") == "single"


@pytest.mark.parametrize("raw", ["not json", '{"voice": 3, "chat": null}', '{"default": ""}', "[]"])
def test_a_broken_file_reads_as_defaults(store, raw):
    store._assign_path.write_text(raw)
    assert store.effective("chat") == "single"
    assert store.get_assignments()["default"] == "single"


def test_snapshot_keeps_effective_assignments_for_old_clients(store):
    _write(store, {"default": "mine", "voice": "", "chat": ""})
    snap = store.snapshot()
    assert snap["assignments"] == {"default": "mine", "voice": "mine", "chat": "mine"}
    assert snap["overrides"] == {"voice": "", "chat": ""}


class _Sess:
    harness_id = None


def test_resolve_order(store):
    _write(store, {"default": "mine", "voice": "router", "chat": ""})
    doc, _ = resolve_harness(store, session=_Sess(), surface="chat", requested_id=None, explicit_model=None)
    assert doc["id"] == "mine"
    doc, _ = resolve_harness(store, session=_Sess(), surface="voice", requested_id=None, explicit_model=None)
    assert doc["id"] == "router"
    doc, _ = resolve_harness(store, session=_Sess(), surface="chat", requested_id=None,
                             explicit_model=("claude-haiku-5-5", "anthropic-api"))
    assert doc["id"] == "single"
    pinned = _Sess()
    pinned.harness_id = "router"
    doc, _ = resolve_harness(store, session=pinned, surface="chat", requested_id=None, explicit_model=None)
    assert doc["id"] == "router"
