"""The memory model's guard: a model at its usage limit is benched until it resets; his backup covers meanwhile."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import api.memory_map as mm  # noqa: E402
import api.memory_model as M  # noqa: E402

LIMIT = ("Error code: 429 - {'error': {'type': 'usage_limit_reached', 'message': 'The usage limit has been reached', "
         "'plan_type': 'plus', 'resets_at': 1795494645, 'limit_window_minutes': 10080, 'resets_in_seconds': 600}}")


@pytest.fixture(autouse=True)
def _home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from plugins.memory.jarvis_memory import external
    external._handles.clear()
    M.reset_for_tests()
    clock = {"t": 1_000_000.0}
    monkeypatch.setattr(M, "_now", lambda: clock["t"])
    mm.set_agent({"model": "gpt-6-luna", "provider": "openai-codex"})
    yield clock
    M.reset_for_tests()


class Shot:
    """A fake _one_shot: per model ref, a list of replies (an Exception is raised)."""

    def __init__(self, **by_ref):
        self.by_ref = {k.replace("_", "-"): list(v) for k, v in by_ref.items()}
        self.calls = []

    def __call__(self, ref, prompt, max_tokens=1200, thinking=True):
        self.calls.append(ref)
        key = ref.split(":", 1)[0].lstrip("@")
        out = self.by_ref[key].pop(0) if self.by_ref.get(key) else "ok"
        if isinstance(out, Exception):
            raise out
        return out


def test_a_model_at_its_usage_limit_is_benched_until_it_resets(_home, monkeypatch):
    shot = Shot(openai_codex=[RuntimeError(LIMIT)])
    monkeypatch.setattr(M, "_one_shot", shot)
    with pytest.raises(M.ModelPaused) as e:
        M.call("p", 300)
    assert e.value.until == pytest.approx(1_000_600.0) and e.value.memory_paused
    with pytest.raises(M.ModelPaused):
        M.call("p", 300)
    assert len(shot.calls) == 1                       # benched: no second call to a limited model
    _home["t"] += 601
    assert M.call("p", 300) == "ok" and len(shot.calls) == 2


def test_his_backup_covers_while_the_memory_model_is_limited(_home, monkeypatch):
    mm.set_backup({"model": "claude-haiku-5-5", "provider": "anthropic-api"})
    shot = Shot(openai_codex=[RuntimeError(LIMIT)], anthropic_api=["from haiku", "again"])
    monkeypatch.setattr(M, "_one_shot", shot)
    assert M.call("p", 300) == "from haiku"
    assert M.call("p", 300) == "again"
    assert [c.split(":")[0] for c in shot.calls] == ["@openai-codex", "@anthropic-api", "@anthropic-api"]
    _home["t"] += 601
    M.call("p", 300)
    assert shot.calls[-1].startswith("@openai-codex")  # back on his memory model once it resets


def test_another_failure_benches_it_briefly(_home, monkeypatch):
    monkeypatch.setattr(M, "_one_shot", Shot(openai_codex=[RuntimeError("HTTP 502 Bad Gateway")]))
    with pytest.raises(M.ModelPaused) as e:
        M.call("p", 300)
    assert e.value.reason == "error" and e.value.until == pytest.approx(1_000_000.0 + M.ERROR_BENCH_S)


def test_a_limit_without_a_reset_time_benches_for_a_while(_home, monkeypatch):
    monkeypatch.setattr(M, "_one_shot", Shot(openai_codex=[RuntimeError("Error code: 429 - rate limit exceeded")]))
    with pytest.raises(M.ModelPaused) as e:
        M.call("p", 300)
    assert e.value.reason == "limit" and e.value.until == pytest.approx(1_000_000.0 + M.LIMIT_BENCH_S)


def test_paused_says_what_is_happening(_home, monkeypatch):
    assert M.paused() is None
    monkeypatch.setattr(M, "_one_shot", Shot(openai_codex=[RuntimeError(LIMIT)]))
    with pytest.raises(M.ModelPaused):
        M.call("p", 300)
    p = M.paused()
    assert p["reason"] == "limit" and p["using"] == "waiting" and p["until"] == pytest.approx(1_000_600.0)
    assert "gpt-6-luna" in p["model"] and p["backup"] == ""
    mm.set_backup({"model": "claude-haiku-5-5", "provider": "anthropic-api"})
    assert M.paused()["using"] == "backup" and "claude-haiku-5-5" in M.paused()["backup"]
    _home["t"] += 601
    assert M.paused() is None


def test_backup_setting_round_trips_and_shows_in_the_payload():
    assert mm.get_backup() is None
    assert mm.set_backup({"model": ""}) is False
    assert mm.set_backup({"model": "claude-haiku-5-5", "provider": "anthropic-api"}) is True
    payload = mm.settings_payload()
    assert payload["backup"] == {"model": "claude-haiku-5-5", "provider": "anthropic-api"}
    assert "claude-haiku-5-5" in payload["backup_label"] and payload["paused"] is None
    assert mm.set_backup(None) is True and mm.get_backup() is None
    assert mm.settings_payload()["backup_label"] == ""


def test_settings_post_takes_the_backup_alone(monkeypatch):
    import api.helpers as helpers
    out = []
    monkeypatch.setattr(helpers, "j", lambda h, payload, status=200, **k: out.append(payload))
    monkeypatch.setattr(helpers, "bad", lambda h, msg, status=400: out.append({"error": msg}))
    mm.handle_settings_post(None, {"backup": {"model": "claude-haiku-5-5", "provider": "anthropic-api"}})
    assert out[-1]["backup"]["model"] == "claude-haiku-5-5"
    assert mm.get_agent() == {"model": "gpt-6-luna", "provider": "openai-codex"}   # untouched
    mm.handle_settings_post(None, {})
    assert "error" in out[-1]


def test_the_memory_completer_goes_through_the_guard(_home, monkeypatch):
    shot = Shot(openai_codex=["mapped"])
    monkeypatch.setattr(M, "_one_shot", shot)
    assert mm.complete("hello", 300) == "mapped" and shot.calls == ["@openai-codex:gpt-6-luna"]
