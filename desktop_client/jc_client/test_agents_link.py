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

    def send_text(self, shell, text, timeout=3.0, now=False):
        self.sent.append((shell, text) if not now else (shell, text, "now"))
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


def test_moved_list_reaches_the_mac_app():
    ui = []
    link = AgentsLink(lambda f: None, vscode=FakeVSCode(), queue=lambda: Queue(), inline=True,
                      power_thread=False, ui_broadcast=ui.append)
    link.handle_frame({"type": "agent_moved", "ckeys": ["claude|s1"],
                       "sessions": [{"ckey": "claude|s1", "agent": "claude", "title": "Fix it",
                                     "project": "app"}]})
    assert ui[-1] == {"type": "moved", "sessions": [{"ckey": "claude|s1", "agent": "claude",
                                                     "title": "Fix it", "project": "app"}]}
    link.handle_frame({"type": "agent_resume_local", "ckey": "claude|s1", "agent": "claude",
                       "session_id": "s1", "cwd": "/w", "terminal": {"term_program": "vscode"}})
    assert ui[-1] == {"type": "moved", "sessions": []} and link.moved_sessions() == []


def test_not_owner_ack_stops_shipping_instead_of_resending_forever(tmp_path):
    """A session that moved to the server: the server refuses the Mac's chunks
    (not_owner). The Mac must stop, not rewind to 0 and resend on every ack."""
    link, up, _ = _link()
    p = tmp_path / "s9.jsonl"
    p.write_text('{"uuid":"a"}\n')
    link.on_hook("event", "claude", {"hook_event_name": "Stop", "session_id": "s9",
                                     "cwd": "/Users/p/app", "transcript_path": str(p)})
    for _ in range(5):
        link.handle_frame({"type": "agent_transcript_ack", "ckey": "claude|s9", "ok": False,
                           "size": 0, "reason": "not_owner"})
    assert len(_events(up, "agent_transcript_chunk")) == 1


class FakeRoster:
    def __init__(self, entries):
        self.entries, self.triggers = entries, []

    def scan_now(self, send=True):
        return list(self.entries)

    def trigger(self, reason=""):
        self.triggers.append(reason)

    def note_hook(self, *a, **k):
        pass

    def close(self):
        pass


class FakeRuntime:
    def __init__(self):
        self.resumed = []

    def resume_in_terminal(self, agent, sid, cwd, terminal, stale_pid=None):
        self.resumed.append((agent, sid, cwd, stale_pid))
        return "vscode"


def test_continue_on_mac_stops_the_stale_claude_process():
    """Claude hooks carry no pid: the stale process still running the old copy
    is found by its session id, so it's stopped instead of left running
    (unblocked) next to the resumed one."""
    rt = FakeRuntime()
    link = AgentsLink(lambda f: None, vscode=FakeVSCode(), queue=lambda: Queue(), runtime=rt,
                      inline=True, power_thread=False)
    link.roster = FakeRoster([{"agent": "claude", "session_id": "s1", "pid": 4242,
                               "kind": "interactive"}])
    link.handle_frame({"type": "agent_moved", "ckeys": ["claude|s1"]})
    link.handle_frame({"type": "agent_resume_local", "ckey": "claude|s1", "agent": "claude",
                       "session_id": "s1", "cwd": "/w", "terminal": {"term_program": "vscode"}})
    assert rt.resumed == [("claude", "s1", "/w", 4242)]


def test_wake_tells_the_server_the_mac_is_back():
    """A short sleep can keep the socket: no reconnect, no hello. The wake itself
    must reach the server, or the Mac stays 'asleep' there (sends refused) and
    the gate never hears what moved."""
    link, up, _ = _link()
    link.roster = FakeRoster([])
    link.on_wake()
    assert _events(up, "agent_hello")


def test_sync_parts_out_of_order_still_merge(tmp_path, monkeypatch):
    """Frames run on a worker pool: part 1 can be handled before part 0."""
    import json
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    up = []
    link = AgentsLink(up.append, vscode=FakeVSCode(), queue=lambda: Queue(), inline=True,
                      power_thread=False)
    sh = link.shipper
    local = sh.local_path("claude", "s1", "/x")
    local.parent.mkdir(parents=True)
    a = json.dumps({"uuid": "a"})
    b = json.dumps({"uuid": "b"})
    local.write_text(a + "\n")
    data = (a + "\n" + b + "\n").encode()
    half = len(data) // 2
    base = {"type": "agent_transcript_sync", "ckey": "claude|s1", "agent": "claude",
            "session_id": "s1", "origin_cwd": "/x", "parts": 2, "then": "merge"}
    link.handle_frame(dict(base, part=1, data_b64=base64.b64encode(data[half:]).decode()))
    link.handle_frame(dict(base, part=0, data_b64=base64.b64encode(data[:half]).decode()))
    assert local.read_text() == a + "\n" + b + "\n"
    assert _events(up, "agent_merge_done")


def test_waiting_session_is_never_typed_into():
    """A pending approval/question: typing would answer its menu. Queue it for
    the end of the turn (Claude) or refuse (others)."""
    link, up, q = _link()
    link.handle_frame({"type": "agent_instruction", "delivery_id": "w1", "agent": "claude",
                       "session_id": "s1", "text": "yes", "state": "approval",
                       "terminal": {"term_program": "vscode"}, "run": {"pid": 901}})
    assert link.vscode.sent == [] and q.items == [("s1", "yes")]
    assert _events(up, "agent_delivery")[-1]["state"] == "queued"
    link.handle_frame({"type": "agent_instruction", "delivery_id": "w2", "agent": "codex",
                       "session_id": "c1", "text": "yes", "state": "question",
                       "terminal": {"term_program": "vscode"}, "run": {"pid": 901}})
    assert link.vscode.sent == [] and _events(up, "agent_delivery")[-1]["state"] == "failed"


def test_a_queued_message_is_delivered_when_the_stop_hook_hands_it_over():
    link, up, q = _link()
    link.handle_frame({"type": "agent_instruction", "delivery_id": "q1", "agent": "claude",
                       "session_id": "s1", "text": "then lint", "state": "working",
                       "terminal": {"term_program": "ghostty"}, "run": {"pid": 5}})
    assert _events(up, "agent_delivery")[-1]["state"] == "queued"
    link.on_stop_handed("s1")
    assert _events(up, "agent_delivery")[-1] == {"delivery_id": "q1", "state": "delivered", "reason": None}
    link.on_stop_handed("s1")
    assert len([e for e in _events(up, "agent_delivery") if e["state"] == "delivered"]) == 1


def test_a_working_session_in_vscode_gets_it_in_claudes_own_queue():
    """Typed with Enter while it works, Claude Code queues it itself (the
    "ctrl+enter to send now" line in the terminal)."""
    link, up, q = _link()
    link.handle_frame({"type": "agent_instruction", "delivery_id": "k1", "agent": "claude",
                       "session_id": "s1", "text": "then lint", "state": "working",
                       "terminal": {"term_program": "vscode"}, "run": {"pid": 901}})
    assert link.vscode.sent == [(900, "then lint")] and q.items == []
    assert _events(up, "agent_delivery")[-1]["state"] == "queued"


def test_send_now_types_ctrl_enter_into_a_working_session():
    link, up, _ = _link()
    link.handle_frame({"type": "agent_instruction", "delivery_id": "k2", "agent": "claude",
                       "session_id": "s1", "text": "stop and fix tests", "state": "working",
                       "now": True, "terminal": {"term_program": "vscode"}, "run": {"pid": 901}})
    assert link.vscode.sent == [(900, "stop and fix tests", "now")]
    assert _events(up, "agent_delivery")[-1]["state"] == "sent"


def test_send_now_to_codex_is_queued_not_ctrl_entered():
    """Ctrl+Enter is Claude Code's key: typed into Codex's TUI it would be junk."""
    link, up, q = _link()
    link.handle_frame({"type": "agent_instruction", "delivery_id": "k3", "agent": "codex",
                       "session_id": "s1", "text": "and lint", "state": "working", "now": True,
                       "terminal": {"term_program": "vscode"}, "run": {"pid": 901}})
    assert link.vscode.sent == [(900, "and lint")] and q.items == []
    assert _events(up, "agent_delivery")[-1]["state"] == "queued"


def test_a_menu_the_mac_already_sees_is_never_typed_into():
    """The server can still say "working" while Claude's approval menu is up on
    the Mac (the hook hasn't reached it yet): the Mac's own engine decides, or
    the Enter would pick the menu's highlighted "Yes"."""
    up, q = [], Queue()
    link = AgentsLink(up.append, vscode=FakeVSCode(), queue=lambda: q, instructions_on=lambda: True,
                      inline=True, power_thread=False,
                      local_state=lambda agent, sid: "approval" if sid == "s1" else None)
    link.handle_frame({"type": "agent_instruction", "delivery_id": "k4", "agent": "claude",
                       "session_id": "s1", "text": "then lint", "state": "working", "now": True,
                       "terminal": {"term_program": "vscode"}, "run": {"pid": 901}})
    assert link.vscode.sent == [] and q.items == [("s1", "then lint")]
    assert _events(up, "agent_delivery")[-1]["state"] == "queued"
