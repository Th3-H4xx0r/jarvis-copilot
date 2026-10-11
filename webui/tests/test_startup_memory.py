"""Server startup stays light: no whole-session parsing, no unused STT model."""
import json

import api.session_recovery as recovery
import api.voice as voice


def _write_session(path, n_messages):
    path.write_text(json.dumps({
        "session_id": path.stem, "title": "t", "created_at": 1, "updated_at": 1,
        "messages": [{"role": "user", "content": str(i)} for i in range(n_messages)],
    }), encoding="utf-8")


def test_startup_recovery_parses_only_sessions_that_have_a_backup(tmp_path, monkeypatch):
    for sid in ("aaa", "bbb", "ccc"):
        _write_session(tmp_path / f"{sid}.json", 3)
    _write_session(tmp_path / "bbb.json.bak", 5)  # the shrunken-live shape (#1558)
    parsed = []
    real_count = recovery._msg_count
    monkeypatch.setattr(recovery, "_msg_count", lambda p: parsed.append(p.name) or real_count(p))

    result = recovery.recover_all_sessions_on_startup(tmp_path)

    assert sorted(parsed) == ["bbb.json", "bbb.json.bak"]
    assert result["scanned"] == 3
    assert result["restored"] == 1
    assert len(json.loads((tmp_path / "bbb.json").read_text())["messages"]) == 5


def test_recovery_status_without_backup_does_not_read_the_session(tmp_path, monkeypatch):
    live = tmp_path / "abc.json"
    _write_session(live, 2)
    monkeypatch.setattr(recovery, "_msg_count", lambda p: (_ for _ in ()).throw(AssertionError(p)))

    status = recovery.inspect_session_recovery_status(live)

    assert status["recommend"] == "no_backup"
    assert status["live_messages"] == -1


class _Threads:
    def __init__(self):
        self.started = []

    def __call__(self, target=None, daemon=None, name=None):
        threads = self

        class _T:
            def start(self):
                threads.started.append(name)

        return _T()


def _warm(monkeypatch, *, engines, env=None):
    """Run _spawn_stt_warm outside pytest's guard with fake engines per surface."""
    threads = _Threads()
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.delenv("JC_STT_WARM", raising=False)
    if env is not None:
        monkeypatch.setenv("JC_STT_WARM", env)
    monkeypatch.setattr(voice, "_stt_warm_started", False)
    monkeypatch.setattr(voice, "_voice_engine", lambda surface="voice": engines.get(surface))
    monkeypatch.setattr(voice.threading, "Thread", threads)
    voice._spawn_stt_warm()
    return threads.started


def test_stt_model_is_not_warmed_when_voice_and_pod_stream_through_an_engine(monkeypatch):
    soniox = object()
    assert _warm(monkeypatch, engines={"voice": soniox, "pod": soniox}) == []
    # Not remembered as started: a later connection re-checks the settings.
    assert voice._stt_warm_started is False


def test_stt_model_is_warmed_when_a_surface_uses_the_local_model(monkeypatch):
    assert _warm(monkeypatch, engines={"voice": object(), "pod": None}) == ["jc-stt-warm"]
    assert voice._stt_warm_started is True


def test_stt_warm_env_forces_or_disables_the_warm_up(monkeypatch):
    soniox = object()
    assert _warm(monkeypatch, engines={"voice": soniox, "pod": soniox}, env="1") == ["jc-stt-warm"]
    assert _warm(monkeypatch, engines={}, env="0") == []


def test_stt_warm_keeps_warming_when_the_engine_lookup_fails(monkeypatch):
    def broken(surface="voice"):
        raise RuntimeError("config unreadable")

    threads = _Threads()
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.delenv("JC_STT_WARM", raising=False)
    monkeypatch.setattr(voice, "_stt_warm_started", False)
    monkeypatch.setattr(voice, "_voice_engine", broken)
    monkeypatch.setattr(voice.threading, "Thread", threads)

    voice._spawn_stt_warm()

    assert threads.started == ["jc-stt-warm"]
