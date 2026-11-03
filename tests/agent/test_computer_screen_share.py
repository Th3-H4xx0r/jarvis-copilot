"""Every computer task is shown on a Mac screen share: started with the task, ended
with it (the Mac then uploads the replay), and named in the tool result as a
``mac_screen`` card."""
import json

import pytest

from agent.computer import loop as L
from agent.computer import screen, turns


@pytest.fixture(autouse=True)
def _clean():
    turns.reset_for_tests()
    yield
    turns.reset_for_tests()


def _wire(monkeypatch, *, run=None, share="scr_abc123"):
    calls = []
    monkeypatch.setattr("agent.computer.mac.find_mac", lambda task_id=None: ("dev1", "Mac", None))
    monkeypatch.setattr("agent.computer.decide.pick_decision_ref", lambda pref: pref)
    monkeypatch.setattr(screen, "start", lambda goal, task_id=None: calls.append(("start", goal, task_id)) or share)
    monkeypatch.setattr(screen, "end", lambda sid: calls.append(("end", sid)))
    monkeypatch.setattr(L, "run", run or (lambda *a, **k: L.Result("done", look={"app": "Calc"})))
    return calls


def test_a_task_starts_a_share_and_ends_it_when_done(monkeypatch):
    calls = _wire(monkeypatch)
    result, err = turns.run_task("open Calculator", None, "sess1")
    assert err is None and result.share == "scr_abc123"
    assert calls == [("start", "open Calculator", "sess1"), ("end", "scr_abc123")]


def test_the_share_ends_even_when_the_loop_fails(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("bridge died")
    calls = _wire(monkeypatch, run=boom)
    with pytest.raises(RuntimeError):
        turns.run_task("open Calculator", None, "sess1")
    assert calls[-1] == ("end", "scr_abc123")


def test_no_share_still_runs_the_task(monkeypatch):
    _wire(monkeypatch, share=None)
    result, err = turns.run_task("open Calculator", None, "sess1")
    assert err is None and result.share == ""
    payload = json.loads(turns.tool_result(result))
    assert "card" not in payload


def test_the_tool_result_carries_the_mac_screen_card(monkeypatch):
    monkeypatch.setattr("agent.computer.decide.data_url", lambda look: "")
    r = L.Result("done", look={"app": "Calc"}, share="scr_abc123")
    payload = json.loads(turns.tool_result(r))
    assert payload["card"] == {"kind": "mac_screen", "share": "scr_abc123"}


def test_an_image_result_carries_the_card_too_and_keeps_it_in_its_text(monkeypatch):
    monkeypatch.setattr("agent.computer.decide.data_url", lambda look: "data:image/png;base64,AAAA")
    r = L.Result("done", look={"app": "Calc"}, share="scr_abc123")
    out = turns.tool_result(r)
    assert out["_multimodal"] is True and out["card"] == {"kind": "mac_screen", "share": "scr_abc123"}
    assert list(out)[0] == "card"  # the live result snippet (a repr cut at 800 chars) starts with it
    assert '"share": "scr_abc123"' in out["content"][0]["text"]


def test_screen_start_uses_the_web_api_outside_the_web_ui(monkeypatch):
    sent = []
    monkeypatch.setattr(screen, "_in_process", lambda: None)
    monkeypatch.setattr("tools.chrome_device_tool._api_request",
                        lambda method, path, body=None, timeout=10.0: sent.append((method, path, body)) or {"id": "scr_x1y2z3"})
    assert screen.start("open Calculator", "sess1") == "scr_x1y2z3"
    screen.end("scr_x1y2z3")
    assert sent[0][:2] == ("POST", "/api/screen/shares") and sent[0][2]["reason"] == "task"
    assert sent[1][:2] == ("POST", "/api/screen/shares/scr_x1y2z3/stop")


def test_screen_start_never_raises(monkeypatch):
    monkeypatch.setattr(screen, "_in_process", lambda: None)

    def down(*a, **k):
        raise OSError("refused")
    monkeypatch.setattr("tools.chrome_device_tool._api_request", down)
    assert screen.start("x", "s") is None
    screen.end("scr_x1y2z3")
