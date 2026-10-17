"""jc-client's side of the merged Agents tab: hooks, sleep, frames from the server."""
import base64
import time

from jc_client.agents_link import AgentsLink
from jc_client.moved_gate import REASON


class Queue:
    def __init__(self):
        self.items = []

    def add(self, sid, text):
        self.items.append((sid, text))


class FakeVSCode:
    def __init__(self):
        self.sent = []

    def terminal_pid_for(self, pid):
        return 900 if pid == 901 else None

    def send_text(self, shell, text, timeout=3.0):
        self.sent.append((shell, text))
        return True

    def run_in_terminal(self, cwd, cmd, timeout=3.0):
        self.sent.append(("run", cwd, cmd))
        return True


def _link(on=True, vscode=None):
    up, q = [], Queue()
    link = AgentsLink(up.append, vscode=vscode or FakeVSCode(), queue=lambda: q,
                      instructions_on=lambda: on, inline=True, power_thread=False)
    return link, up, q


def _events(up, name):
    return [f["data"] for f in up if f.get("type") == "event" and f.get("name") == name]


def test_instruction_typed_into_vscode_reports_sent():
    link, up, _ = _link()
    link.handle_frame({"type": "agent_instruction", "delivery_id": "d1", "agent": "claude",
                       "session_id": "s1", "text": "run tests", "state": "idle",
                       "terminal": {"term_program": "vscode"}, "run": {"pid": 901}})
    assert link.vscode.sent == [(900, "run tests")]
    assert _events(up, "agent_delivery")[-1] == {"delivery_id": "d1", "state": "sent", "reason": None}


def test_instruction_for_working_session_is_queued():
    link, up, q = _link()
    link.handle_frame({"type": "agent_instruction", "delivery_id": "d2", "agent": "claude",
                       "session_id": "s1", "text": "then lint", "state": "working",
                       "terminal": {"term_program": "ghostty"}, "run": {"pid": 5}})
    assert q.items == [("s1", "then lint")]
    assert _events(up, "agent_delivery")[-1]["state"] == "queued"


def test_idle_session_in_untypable_terminal_fails_honestly():
    link, up, q = _link()
    link.handle_frame({"type": "agent_instruction", "delivery_id": "d3", "agent": "codex",
                       "session_id": "c1", "text": "hi", "state": "idle",
                       "terminal": {"term_program": "ghostty"}, "run": {"pid": 5}})
    last = _events(up, "agent_delivery")[-1]
    assert last["state"] == "failed" and "type" in last["reason"] and q.items == []


def test_instruction_with_switch_off_fails():
    link, up, _ = _link(on=False)
    link.handle_frame({"type": "agent_instruction", "delivery_id": "d4", "agent": "claude",
                       "session_id": "s1", "text": "x", "state": "idle",
                       "terminal": {"term_program": "vscode"}, "run": {"pid": 901}})
    last = _events(up, "agent_delivery")[-1]
    assert last["state"] == "failed" and "Instructions from the phone" in last["reason"]


def test_sleep_flushes_then_sends_device_sleeping(tmp_path, monkeypatch):
    link, up, _ = _link()
    monkeypatch.setattr(link.roster, "scan_now", lambda send=True: [{"session_id": "s1"}])
    p = tmp_path / "s1.jsonl"
    p.write_text('{"uuid":"a"}\n')
    link.shipper.watch("claude|s1", "claude", str(p), cwd="/x")
    up.clear()
    with open(p, "a") as fh:
        fh.write('{"uuid":"b"}\n')   # written after the last hook: only the flush sends it
    link.on_sleep()
    names = [f.get("name") for f in up]
    assert names.index("agent_transcript_chunk") < names.index("device_sleeping")
    assert _events(up, "device_sleeping")[-1]["entries"] == [{"session_id": "s1"}]


def test_wake_holds_gate_until_moved():
    link, _, _ = _link()
    link.on_wake()
    link.handle_frame({"type": "agent_moved", "ckeys": ["claude|s1"]})
    assert link.gate_answer("claude", {"session_id": "s1"}) == {"decision": "block", "reason": REASON}
    assert link.gate_answer("claude", {"session_id": "s2"}) == {}


def test_resume_local_unblocks_and_reopens():
    link, _, _ = _link()
    link.handle_frame({"type": "agent_moved", "ckeys": ["claude|s1"]})
    link.handle_frame({"type": "agent_resume_local", "ckey": "claude|s1", "agent": "claude",
                       "session_id": "s1", "cwd": "/Users/p/app",
                       "terminal": {"term_program": "vscode"}})
    assert link.gate_answer("claude", {"session_id": "s1"}) == {}
    assert ("run", "/Users/p/app", "claude --resume s1") in link.vscode.sent


def test_hook_watches_transcript_and_notes_roster(tmp_path):
    link, up, _ = _link()
    p = tmp_path / "s9.jsonl"
    p.write_text('{"uuid":"a"}\n')
    link.on_hook("event", "claude", {"hook_event_name": "UserPromptSubmit", "session_id": "s9",
                                     "cwd": "/Users/p/app", "transcript_path": str(p),
                                     "term_program": "vscode"})
    chunk = _events(up, "agent_transcript_chunk")[-1]
    assert chunk["ckey"] == "claude|s9" and base64.b64decode(chunk["data_b64"]) == p.read_bytes()
    assert link.roster._terms[("claude", "s9")]["term_program"] == "vscode"


def test_codex_rollout_path_becomes_relative(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    link, up, _ = _link()
    p = tmp_path / ".codex" / "sessions" / "2026" / "10" / "17" / "rollout-x-c1.jsonl"
    p.parent.mkdir(parents=True)
    p.write_text("{}\n")
    link.on_hook("event", "codex", {"hook_event_name": "SessionStart", "session_id": "c1",
                                    "cwd": "/w", "transcript_path": str(p), "agent_pid": 77})
    assert _events(up, "agent_transcript_chunk")[-1]["codex_rel"] == "2026/10/17/rollout-x-c1.jsonl"
