"""The one memory-model setting (default Haiku 5.5 on the API key) and its completer."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import api.memory_map as mm  # noqa: E402


@pytest.fixture(autouse=True)
def _home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    import api.imessage_memory as im
    monkeypatch.setattr(im, "_store", None)
    from plugins.memory.jarvis_memory import external
    external._handles.clear()
    yield


def test_default_map_agent_is_haiku_on_api_key():
    assert mm.get_agent() == {"model": "claude-haiku-5-5", "provider": "anthropic-api"}
    ref, label = mm.resolve_map_model()
    assert ref == "@anthropic-api:claude-haiku-5-5" and "claude-haiku-5-5" in label


def test_set_agent_validates_and_round_trips():
    assert mm.set_agent({"model": ""}) is False
    assert mm.set_agent("nope") is False
    assert mm.set_agent({"harness_id": "h1"}) is True
    assert mm.get_agent() == {"harness_id": "h1"}
    assert mm.set_agent(None) is True          # Same as Default
    assert mm.get_agent() is None


def test_complete_goes_through_one_shot(monkeypatch):
    import api.imessage_memory_writer as w
    calls = []
    monkeypatch.setattr(w, "_one_shot", lambda ref, prompt, max_tokens=1200, thinking=True: calls.append((ref, prompt)) or "ok")
    assert mm.complete("hello", 300) == "ok"
    assert calls == [("@anthropic-api:claude-haiku-5-5", "hello")]


def test_install_registers_completer(monkeypatch):
    from plugins.memory.jarvis_memory import llm
    import api.imessage_memory_writer as w
    monkeypatch.setattr(w, "_one_shot", lambda ref, prompt, max_tokens=1200, thinking=True: "done")
    monkeypatch.setattr(mm, "_register_brief_sources", lambda: None)
    import api.memory_sources_sync as sync
    monkeypatch.setattr(sync, "start", lambda: None)
    mm.install()
    try:
        assert llm.complete("x") == "done"
    finally:
        llm.set_completer(None)


def test_imessage_writer_uses_memory_model(monkeypatch):
    import api.imessage_memory_writer as w
    mm.set_agent({"harness_id": "h9"})
    monkeypatch.setattr(w, "resolve_extraction_model", lambda agent: (f"ref:{agent}", "x"))
    assert w._memory_model()[0] == "ref:{'harness_id': 'h9'}"


def test_cleanup_start_status_restore(monkeypatch):
    import threading
    import api.helpers as helpers
    from plugins.memory.jarvis_memory import cleanup
    calls = []
    monkeypatch.setattr(helpers, "j", lambda h, payload, status=200, **k: calls.append(payload))
    gate = threading.Event()

    def fake_run(store, embedder, *, zone, complete=None, progress=None):
        progress({"step": "map", "done": 3, "total": 10, "started_at": 1.0})
        gate.wait(5)
        report = {"counts": {"merged": 2}, "examples": {}, "backup": "b", "started_at": 1, "finished_at": 2}
        cleanup.report_path(store).write_text(__import__("json").dumps(report))
        return report
    monkeypatch.setattr(cleanup, "run", fake_run)
    mm.handle_cleanup_start(None)
    assert calls[-1] == {"ok": True, "started": True}
    mm.handle_cleanup_start(None)
    assert calls[-1] == {"ok": True, "started": False}  # one run at a time
    import time
    deadline = time.time() + 3
    while (mm._cleanup["progress"] or {}).get("done") != 3 and time.time() < deadline:
        time.sleep(0.01)
    mm.handle_cleanup_status(None)
    assert calls[-1]["running"] is True and calls[-1]["progress"]["done"] == 3
    gate.set()
    mm._cleanup["thread"].join(5)
    mm.handle_cleanup_status(None)
    assert calls[-1]["running"] is False and calls[-1]["report"]["counts"]["merged"] == 2
    store = mm._store()
    cid = store.add_chunk("global", "The user has a father.", "fact:extracted", 1.0, 1.0)
    store.set_status([cid], "hidden")
    mm.handle_cleanup_restore(None, {"ids": [cid, 5]})
    assert calls[-1] == {"ok": True, "restored": 1}
    assert store.count_chunks("global") == 1


def test_complete_passes_max_tokens_to_the_provider(monkeypatch):
    import api.config as cfg
    import agent.auxiliary_client as aux
    seen = {}
    monkeypatch.setattr(cfg, "resolve_model_provider", lambda ref: ("claude-haiku-5-5", "anthropic-api", ""))
    monkeypatch.setattr(cfg, "route_anthropic_via_claude_code", lambda m, p, b: (m, p, b))
    monkeypatch.setattr(aux, "call_llm", lambda **kw: seen.update(kw) or object())
    monkeypatch.setattr(aux, "extract_content_or_reasoning", lambda r: "[]")
    assert mm.complete("x", 4000) == "[]"
    assert seen["max_tokens"] == 4000
    # Claude 5.x thinks by default: a JSON pass must not spend its budget thinking.
    assert seen["extra_body"] == {"thinking": {"type": "disabled"}}


def test_cleanup_stop_and_status_from_another_process(monkeypatch):
    import json as _json
    import time as _time
    import api.helpers as helpers
    calls = []
    monkeypatch.setattr(helpers, "j", lambda h, payload, status=200, **k: calls.append(payload))
    store = mm._store()
    store.kv_set("__cleanup__", "progress", _json.dumps({"step": "map", "done": 60, "total": 5519,
                                                          "started_at": 1.0, "at": _time.time()}))
    mm.handle_cleanup_status(None)
    assert calls[-1]["running"] is True and calls[-1]["progress"]["total"] == 5519
    mm.handle_cleanup_stop(None)
    assert calls[-1] == {"ok": True}
    assert store.kv_get("__cleanup__", "stop") == "1"
