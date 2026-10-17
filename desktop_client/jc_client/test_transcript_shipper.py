"""The live copy of this Mac's transcripts on the server: shipped, merged back."""
import base64
import json

from jc_client.transcript_shipper import TranscriptShipper


def L(uid, sid="s1"):
    return json.dumps({"uuid": uid, "sessionId": sid, "type": "user"})


def _frames(sent, name):
    return [f["data"] for f in sent if f.get("name") == name]


def test_chunks_from_acked_offset(tmp_path):
    p = tmp_path / "s1.jsonl"
    p.write_text(L("a") + "\n")
    sent = []
    sh = TranscriptShipper(sent.append, chunk=8)
    sh.watch("claude|s1", "claude", str(p), cwd="/Users/p/app")
    first = _frames(sent, "agent_transcript_chunk")
    assert first[0]["offset"] == 0 and len(base64.b64decode(first[0]["data_b64"])) == 8
    sh.on_ack("claude|s1", ok=True, size=8)
    nxt = _frames(sent, "agent_transcript_chunk")[-1]
    assert nxt["offset"] == 8


def test_need_rewinds_offset(tmp_path):
    p = tmp_path / "s1.jsonl"
    p.write_text(L("a") + "\n" + L("b") + "\n")
    sent = []
    sh = TranscriptShipper(sent.append)
    sh.watch("claude|s1", "claude", str(p), cwd="/x")
    sh.on_ack("claude|s1", ok=False, size=5)
    last = _frames(sent, "agent_transcript_chunk")[-1]
    assert last["offset"] == 5
    assert base64.b64decode(last["data_b64"]) == p.read_bytes()[5:]


def test_flush_pipelines_everything(tmp_path):
    p = tmp_path / "s1.jsonl"
    p.write_bytes(b"x" * 20)
    sent = []
    sh = TranscriptShipper(sent.append, chunk=8)
    sh.watch("claude|s1", "claude", str(p), cwd="/x")
    sh.flush_all(deadline_s=1.0)
    offs = [c["offset"] for c in _frames(sent, "agent_transcript_chunk")]
    assert offs == [0, 8, 16]


def test_offline_sends_nothing_until_online(tmp_path):
    p = tmp_path / "s1.jsonl"
    p.write_text(L("a") + "\n")
    sent = []
    sh = TranscriptShipper(sent.append)
    sh.set_online(False)
    sh.watch("claude|s1", "claude", str(p), cwd="/x")
    assert sent == []
    sh.set_online(True)
    assert _frames(sent, "agent_transcript_chunk")


def _sync(sh, ckey, data, then="merge", agent="claude", cwd="/x", parts=1):
    size = -(-len(data) // parts) if data else 0
    for i in range(parts):
        sh.apply_sync({"ckey": ckey, "agent": agent, "session_id": ckey.split("|")[1],
                       "origin_cwd": cwd, "part": i, "parts": parts, "then": then,
                       "data_b64": base64.b64encode(data[i * size:(i + 1) * size]).decode()})


def test_sync_merge_appends_server_turns(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    sent = []
    sh = TranscriptShipper(sent.append)
    local = sh.local_path("claude", "s1", "/x")
    local.parent.mkdir(parents=True)
    local.write_text(L("a") + "\n")
    server = (L("a") + "\n" + L("b") + "\n").encode()
    _sync(sh, "claude|s1", server, parts=2)
    assert local.read_text() == L("a") + "\n" + L("b") + "\n"
    done = _frames(sent, "agent_merge_done")[-1]
    assert done["ok"] is True and done["then"] == "merge" and not done.get("fork_session_id")


def test_apply_merge_fork_writes_new_file_and_keeps_all_lines(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    sent = []
    sh = TranscriptShipper(sent.append)
    local = sh.local_path("claude", "s1", "/x")
    local.parent.mkdir(parents=True)
    local.write_text(L("a") + "\n" + L("x") + "\n")
    _sync(sh, "claude|s1", (L("a") + "\n" + L("y") + "\n").encode())
    assert local.read_text() == L("a") + "\n" + L("y") + "\n"
    fork = _frames(sent, "agent_merge_done")[-1]["fork_session_id"]
    forked = (local.parent / f"{fork}.jsonl").read_text().splitlines()
    assert [json.loads(x)["uuid"] for x in forked] == ["a", "x"]
    assert all(json.loads(x)["sessionId"] == fork for x in forked)


def test_tail_appends_unseen_lines(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    sh = TranscriptShipper(lambda f: None)
    local = sh.local_path("claude", "s1", "/x")
    local.parent.mkdir(parents=True)
    local.write_text(L("a") + "\n")
    data = (L("a") + "\n" + L("b") + "\n").encode()
    sh.apply_tail({"ckey": "claude|s1", "agent": "claude", "session_id": "s1", "origin_cwd": "/x",
                   "data_b64": base64.b64encode(data).decode()})
    assert local.read_text() == L("a") + "\n" + L("b") + "\n"
