"""IT runs as Background jobs: the "IT agent" card shows the phase and step live, the report lands in the
chat, the PC is held awake for the run, and a restarted server shows the card as lost at its phase."""
from types import SimpleNamespace

import pytest

import api.config  # noqa: F401  (puts the agent checkout on sys.path)
import api.harness_runner as hr
import api.it_jobs as it_jobs
from agent import escalation
from agent.it_agent.model import Check, Phase, Run, Step

REF = "@anthropic-api:claude-sonnet-5-5"


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    escalation.reset_for_tests()
    it_jobs._last_key.clear()
    monkeypatch.setattr(hr, "_publish_job", lambda sid, card: None)
    yield
    escalation.reset_for_tests()


class FakeSession(SimpleNamespace):
    def save(self, **kw):
        pass


class Power:
    def __init__(self, keep=False):
        self.keep, self.calls = keep, []

    def device(self, did):
        return {"keep_awake": self.keep}

    def keep_awake(self, did, on):
        self.calls.append((did, on))
        return {"ok": True}


def _job(job_id="j1", session_id="s1", **extra):
    job = {"job_id": job_id, "session_id": session_id, "reason": "it_task", "summary": "install docker",
           "model": REF, "status": "running", "started_at": 100.0, "completed_at": None, "text": None,
           "parent": dict(it_jobs.IT_PARENT)}
    job.update(extra)
    with escalation._lock:
        escalation._jobs[job_id] = job
    return job


def _setup_start(monkeypatch, ref=(REF, ""), pc=("pc", "Pranav-Desktop", "")):
    from agent import mac_browser_gate
    monkeypatch.setattr(it_jobs, "supervisor_ref", lambda: ref)
    monkeypatch.setattr(it_jobs.pc, "find_pc", lambda text="": pc)
    monkeypatch.setattr(mac_browser_gate, "turn_text", lambda tid: "install docker desktop on my pc")
    monkeypatch.setattr(mac_browser_gate, "allowed", lambda tid: False)
    monkeypatch.setattr(it_jobs, "make_runner", lambda *a, **k: (lambda job: ""))


def _phase(name="Install"):
    return Phase(name, [Step("shell", "winget install x")], Check("shell", "docker --version"))


def test_start_creates_background_job_with_it_label(monkeypatch):
    _setup_start(monkeypatch)
    out = it_jobs.start_it_job("s1", "install Docker Desktop")
    job = escalation.get_job(out["job_id"])
    assert out["ok"] and job["parent"]["kind"] == "background" and job["model"] == REF
    assert hr.job_card(job)["label"] == "IT agent" and job["parent"]["question"] == "install docker desktop on my pc"


def test_start_refuses_without_supervisor_model(monkeypatch):
    _setup_start(monkeypatch, ref=(None, "No supervisor model for IT tasks: set it_agent.supervisor_model in "
                                         "config.yaml (your Default harness has no Background node)."))
    out = it_jobs.start_it_job("s1", "install Docker Desktop")
    assert out["ok"] is False and "it_agent.supervisor_model" in out["error"] and not escalation.get_jobs("s1")


def test_start_refuses_without_a_pc(monkeypatch):
    _setup_start(monkeypatch, pc=(None, "", "No PC with Jarvis (jc-client) is paired for IT tasks."))
    out = it_jobs.start_it_job("s1", "install Docker Desktop")
    assert out == {"ok": False, "error": "No PC with Jarvis (jc-client) is paired for IT tasks."}


def test_progress_updates_card_and_persists_on_phase_change(monkeypatch):
    _job()
    persisted = []
    monkeypatch.setattr(hr, "_persist_card", lambda sid, card: persisted.append(dict(card)) or True)
    run = Run(goal="install docker", request_text="", device_id="pc", device_name="PC",
              phases=[_phase("Enable WSL2"), _phase("Install")], state="working", step_label="wsl --status")
    run.add_log("step", "shell: wsl --status → ran (exit 0)")
    it_jobs.publish_progress("s1", "j1", run)
    it_jobs.publish_progress("s1", "j1", run)
    job = escalation.get_job("j1")
    assert job["activity"] == "Phase 1/2 · Enable WSL2 — wsl --status" and job["it"]["phase"] == "Enable WSL2"
    assert job["trail"][-1]["detail"].startswith("shell: wsl --status") and len(persisted) == 1
    run.state = "checking"
    it_jobs.publish_progress("s1", "j1", run)
    assert len(persisted) == 2 and persisted[-1]["it"]["state"] == "checking"


def _runner_rig(monkeypatch, run_task, keep=False):
    power = Power(keep)
    seen = {}
    monkeypatch.setattr(it_jobs, "_power", lambda: power)
    monkeypatch.setattr(it_jobs, "build_deps", lambda *a, **k: SimpleNamespace())
    monkeypatch.setattr(it_jobs, "run_task", run_task)
    monkeypatch.setattr(it_jobs, "limits", lambda: None)
    monkeypatch.setattr(hr, "deliver_result", lambda sid, **kw: seen.setdefault("deliver", (sid, kw)))
    monkeypatch.setattr(hr, "_save_transcript", lambda *a: seen.setdefault("transcript", a))
    monkeypatch.setattr(hr, "_finish_job", lambda sid, jid, status, **kw: seen.setdefault("finish", (status, kw)))
    runner = it_jobs.make_runner("s1", "install docker", "install docker on my pc", False, REF, "pc", "PC")
    return runner, power, seen


def test_runner_delivers_report_and_finishes_with_status(monkeypatch):
    def fake_run(run, deps, limits):
        run.status, run.end_reason, run.report = "failed", "check_failed", "**Couldn't finish: install docker**"
        return run
    runner, _, seen = _runner_rig(monkeypatch, fake_run)
    assert runner({"job_id": "j1"}) == ""
    sid, kw = seen["deliver"]
    assert kw["text"] == "**Couldn't finish: install docker**" and kw["error"] == "check_failed"
    assert kw["node"]["label"] == "IT agent" and kw["kind"] == "background"
    assert seen["finish"] == ("failed", {"result": "**Couldn't finish: install docker**"})
    assert seen["transcript"][3][0]["content"].startswith("# IT task: install docker")


def test_runner_crash_still_reports(monkeypatch):
    def boom(run, deps, limits):
        raise RuntimeError("bridge gone")
    runner, power, seen = _runner_rig(monkeypatch, boom)
    runner({"job_id": "j1"})
    assert "Something went wrong" in seen["deliver"][1]["text"] and seen["finish"][0] == "failed"
    assert power.calls == [("pc", True), ("pc", False)]


def test_run_holds_pc_awake_and_restores_previous_setting(monkeypatch):
    def done(run, deps, limits):
        run.status, run.end_reason, run.report = "done", "checks_passed", "ok"
        return run
    runner, power, _ = _runner_rig(monkeypatch, done)
    runner({"job_id": "j1"})
    assert power.calls == [("pc", True), ("pc", False)]
    runner2, power2, _ = _runner_rig(monkeypatch, done, keep=True)
    runner2({"job_id": "j1"})
    assert power2.calls == []


def test_start_from_worker_attaches_card_to_parent_reply(monkeypatch):
    _setup_start(monkeypatch)
    reply = {"role": "assistant", "content": "On it."}
    session = FakeSession(session_id="s1", messages=[{"role": "user", "content": "x"}, reply])
    attached = []
    monkeypatch.setattr(hr, "_load_session", lambda sid: session)
    monkeypatch.setattr(hr, "attach_job_cards", lambda s, m, cards: attached.append((s, m, cards)))
    out = it_jobs.start_it_job("s1~claude", "install Docker Desktop")
    s, m, cards = attached[0]
    assert s is session and m is reply and cards[0]["id"] == out["job_id"] and cards[0]["label"] == "IT agent"


def test_job_card_carries_it_only_when_present():
    assert "it" not in hr.job_card(_job())
    assert hr.job_card(_job("j2", it={"state": "working", "phase": "Install"}))["it"]["phase"] == "Install"


def test_lost_card_keeps_phase(monkeypatch):
    stored = {"id": "j9", "status": "running", "started_at": 1.0, "it": {"state": "working", "phase": "Install"}}
    session = FakeSession(session_id="s1", messages=[{"role": "assistant", "_meta": {"jobs": [stored]}}])
    monkeypatch.setattr(hr, "_load_session", lambda sid: session)
    card = next(c for c in hr.session_job_cards("s1") if c["id"] == "j9")
    assert card["status"] == "lost" and card["it"]["phase"] == "Install"


def test_build_deps_routes_models_and_parses_research(monkeypatch):
    asked = []
    monkeypatch.setattr(it_jobs, "fast_ref", lambda: "@celeris:celeris-1")
    monkeypatch.setattr(it_jobs, "_one_shot", lambda ref, prompt, max_tokens: asked.append((ref, max_tokens)) or "{}")
    monkeypatch.setattr(it_jobs, "_dispatch", lambda name, args: {
        "web_search": '{"data": {"web": [{"url": "https://a", "title": "A", "description": "d"}]}}',
        "web_extract": '{"results": [{"url": "https://a", "title": "A", "content": "body"}]}'}[name])
    run = Run(goal="g", request_text="", device_id="pc", device_name="PC")
    deps = it_jobs.build_deps("j1", "s1", run, REF)
    deps.ask("fast", "p", 400)
    deps.ask("plan", "p", 4000)
    assert asked == [("@celeris:celeris-1", 400), (REF, 4000)]
    assert deps.search("q") == [{"url": "https://a", "title": "A", "description": "d"}]
    assert deps.extract(["https://a"]) == [{"url": "https://a", "title": "A", "content": "body"}]
    _job()
    assert deps.should_stop() is False
    escalation.update_job("j1", stop_requested=True)
    assert deps.should_stop() is True


def test_pc_changes_need_his_own_words():
    assert it_jobs.asked_for_pc("install docker desktop on my pc", False)
    assert it_jobs.asked_for_pc("fix my wifi", False)
    assert not it_jobs.asked_for_pc("summarize my email", False)
    assert it_jobs.asked_for_pc("", True)


def test_start_passes_whether_he_asked(monkeypatch):
    _setup_start(monkeypatch)
    seen = {}
    monkeypatch.setattr(it_jobs, "make_runner", lambda *a, **k: seen.update(kw=k) or (lambda job: ""))
    it_jobs.start_it_job("s1", "install Docker Desktop")
    assert seen["kw"]["pc_allowed"] is True


def test_one_it_run_per_pc_at_a_time(monkeypatch):
    # Live 2026-11-18: two sleep runs on one PC; the second slept it again the moment it woke.
    _setup_start(monkeypatch)
    _job("j-running", it={"state": "working"}, device_id="pc")
    out = it_jobs.start_it_job("s1", "install Docker Desktop")
    assert out["ok"] is False and "already running" in out["error"]
