"""Call notes from the Mac's note-taker (/api/agent-notes) and Flow's clean-up
(/api/flow/cleanup): the store, the summary job and the HTTP dispatcher. A fake
model stands in for the auxiliary client; nothing touches the network."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
for _p in (str(ROOT), str(ROOT / "webui")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from agent import agent_notes  # noqa: E402
from agent.agent_notes import NotesStore  # noqa: E402
from api import agent_notes_routes  # noqa: E402
from api.agent_notes_routes import (  # noqa: E402
    AGENT_NOTES_PATH_PREFIX, FLOW_CLEANUP_PATH, handle_agent_notes_request, handle_flow_cleanup)

NOTE_ID = "6F1C1D2E-0A4B-4C1D-9E2F-1234567890AB"


def sample(**over):
    note = {
        "id": NOTE_ID,
        "title": "Call 14 Oct 15:00",
        "start": 1_760_450_400.0,
        "end": 1_760_452_320.0,
        "app": "Zoom",
        "speakers": [{"id": "me", "name": "You", "is_me": True}, {"id": "them", "name": "Them"}],
        "lines": [
            {"speaker": "me", "start": 0.0, "end": 3.5, "text": "Let's ship the beta on Friday."},
            {"speaker": "them", "start": 4.0, "end": 9.0, "text": "Fine, I'll write the release notes by Thursday."},
        ],
    }
    note.update(over)
    return note


@pytest.fixture()
def store(tmp_path):
    return NotesStore(lambda: tmp_path / "agent_notes")


class FakeModel:
    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls = []

    def __call__(self, messages):
        self.calls.append(messages)
        reply = self.replies.pop(0) if self.replies else ""
        if isinstance(reply, Exception):
            raise reply
        return reply


GOOD_REPLY = json.dumps({
    "title": "Beta launch plan",
    "summary": "The beta ships Friday; release notes come first.",
    "key_points": ["Beta on Friday", "Release notes by Thursday"],
    "todos": [{"text": "Write the release notes", "owner": "Them", "due": "Thursday"}],
})


def sync_summarizer(model):
    """Runs the summary job at once, in the test's thread."""
    def run(store, note_id):
        agent_notes.run_summary(store, note_id, model)
    return run


def call(store, method, path, body=None, model=None, published=None):
    return handle_agent_notes_request(
        method, path, body, store=store,
        summarize=sync_summarizer(model or FakeModel(GOOD_REPLY)),
        publish=(lambda topic, data: published.append((topic, data))) if published is not None else (lambda *a: None))


# MARK: - the store


def test_prefixes():
    assert AGENT_NOTES_PATH_PREFIX == "/api/agent-notes"
    assert FLOW_CLEANUP_PATH == "/api/flow/cleanup"


def test_put_then_get_round_trips_and_lists_without_the_transcript(store):
    saved = store.put(sample())
    assert saved["id"] == NOTE_ID
    assert saved["lines"][1]["speaker"] == "them"
    assert saved["summary_status"] == "none"
    got = store.get(NOTE_ID)
    assert got["title"] == "Call 14 Oct 15:00"
    rows = store.list()
    assert [r["id"] for r in rows] == [NOTE_ID]
    assert "lines" not in rows[0]
    assert rows[0]["line_count"] == 2
    assert rows[0]["duration"] == pytest.approx(1920.0)


def test_list_is_newest_first(store):
    store.put(sample(id="AAAAAAAA-0000-0000-0000-000000000001", start=100.0, end=200.0))
    store.put(sample(id="AAAAAAAA-0000-0000-0000-000000000002", start=300.0, end=400.0))
    assert [r["start"] for r in store.list()] == [300.0, 100.0]


def test_ids_that_could_escape_the_folder_are_refused(store):
    for bad in ["../../etc/passwd", "a/b", "", "x" * 200, "..", "short"]:
        with pytest.raises(ValueError):
            store.put(sample(id=bad))
        assert store.get(bad) is None
        assert store.delete(bad) is False


def test_put_cleans_odd_fields(store):
    saved = store.put(sample(
        title="  ", lines=[{"speaker": "me", "start": "x", "end": None, "text": "  hi  "},
                           {"speaker": "me", "text": ""}, "nonsense"],
        todos=[{"text": "Do it", "done": 1}, {"text": ""}, "Call Ana"],
    ))
    assert saved["title"]  # a blank title gets a default
    assert saved["lines"] == [{"speaker": "me", "start": 0.0, "end": 0.0, "text": "hi"}]
    assert [t["text"] for t in saved["todos"]] == ["Do it", "Call Ana"]
    assert saved["todos"][0]["done"] is True


def test_a_reupload_keeps_the_servers_summary(store):
    store.put(sample())
    store.set_summary(NOTE_ID, {"title": "Beta launch plan", "summary": "S", "key_points": ["k"], "todos": []})
    again = store.put(sample(title="Call 14 Oct 15:00"))
    assert again["summary"] == "S"
    assert again["key_points"] == ["k"]
    assert again["summary_status"] == "done"


def test_the_summary_title_replaces_the_default_title_but_never_an_edited_one(store):
    store.put(sample())
    store.set_summary(NOTE_ID, {"title": "Beta launch plan", "summary": "S", "key_points": [], "todos": []})
    assert store.get(NOTE_ID)["title"] == "Beta launch plan"
    store.put(sample(id="BBBBBBBB-0000-0000-0000-000000000001", title="Ana 1:1", title_edited=True))
    store.set_summary("BBBBBBBB-0000-0000-0000-000000000001",
                      {"title": "Something else", "summary": "S", "key_points": [], "todos": []})
    assert store.get("BBBBBBBB-0000-0000-0000-000000000001")["title"] == "Ana 1:1"


def test_delete(store):
    store.put(sample())
    assert store.delete(NOTE_ID) is True
    assert store.get(NOTE_ID) is None
    assert store.delete(NOTE_ID) is False


def test_the_store_lives_under_the_profile_home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    s = NotesStore()
    s.put(sample())
    assert (tmp_path / "home" / "agent_notes" / f"{NOTE_ID}.json").exists()


# MARK: - summary parsing and the job


def test_parse_summary_reads_json_even_wrapped():
    wrapped = "Here you go:\n```json\n" + GOOD_REPLY + "\n```"
    parsed = agent_notes.parse_summary(wrapped)
    assert parsed["title"] == "Beta launch plan"
    assert parsed["key_points"] == ["Beta on Friday", "Release notes by Thursday"]
    assert parsed["todos"] == [{"text": "Write the release notes", "owner": "Them", "due": "Thursday", "done": False}]


def test_parse_summary_handles_null_owners_and_plain_string_todos():
    parsed = agent_notes.parse_summary(json.dumps({
        "summary": "S", "todos": ["Call Ana", {"text": "Book room", "owner": "null", "due": None}]}))
    assert parsed["todos"][0]["text"] == "Call Ana"
    assert parsed["todos"][1]["owner"] is None and parsed["todos"][1]["due"] is None
    assert parsed["title"] is None


def test_parse_summary_without_json_is_none():
    assert agent_notes.parse_summary("no json here") is None
    assert agent_notes.parse_summary('{"summary": "", "key_points": [], "todos": []}') is None


def test_run_summary_stores_the_parsed_reply(store):
    store.put(sample())
    model = FakeModel(GOOD_REPLY)
    agent_notes.run_summary(store, NOTE_ID, model)
    note = store.get(NOTE_ID)
    assert note["summary_status"] == "done"
    assert note["title"] == "Beta launch plan"
    assert note["todos"][0]["owner"] == "Them"
    # The transcript reached the model as names + words, inside tags, never as instructions.
    user = model.calls[0][-1]["content"]
    assert "<transcript>" in user and "You: Let's ship the beta on Friday." in user
    assert model.calls[0][0]["role"] == "system"


def test_run_summary_keeps_a_non_json_reply_as_the_summary(store):
    store.put(sample())
    agent_notes.run_summary(store, NOTE_ID, FakeModel("The beta ships Friday."))
    note = store.get(NOTE_ID)
    assert note["summary"] == "The beta ships Friday."
    assert note["summary_status"] == "done"


def test_run_summary_failure_is_recorded_not_raised(store):
    store.put(sample())
    agent_notes.run_summary(store, NOTE_ID, FakeModel(RuntimeError("no provider")))
    note = store.get(NOTE_ID)
    assert note["summary_status"] == "failed"
    assert "no provider" in note["summary_error"]


def test_a_long_transcript_is_noted_in_parts_first(store):
    lines = [{"speaker": "me", "start": float(i), "end": float(i) + 0.5, "text": "word " * 60}
             for i in range(400)]
    store.put(sample(lines=lines))
    calls = []

    def model(messages):
        calls.append(messages)
        if messages[0]["content"] == agent_notes.SUMMARY_SYSTEM:
            return GOOD_REPLY
        return f"notes of part {len(calls)}"

    agent_notes.run_summary(store, NOTE_ID, model)
    assert len(calls) >= 3
    parts, final = calls[:-1], calls[-1]
    assert all(m[0]["content"] == agent_notes.PART_SYSTEM for m in parts)
    assert all(len(m[-1]["content"]) <= agent_notes.PART_CHARS + 40 for m in parts)
    assert final[0]["content"] == agent_notes.SUMMARY_SYSTEM
    assert "notes of part 1" in final[-1]["content"]
    assert store.get(NOTE_ID)["title"] == "Beta launch plan"


def test_markdown_has_every_section_in_local_time():
    note = agent_notes.normalize(sample(summary="S", key_points=["k1"], todos=[{"text": "t", "owner": "Ana", "done": True}]))
    md = agent_notes.markdown(note, tz_minutes=-120)
    assert md.startswith("# Call 14 Oct 15:00\n")
    assert "32 min" in md
    assert "## Summary\n\nS" in md
    assert "- k1" in md
    assert "- [x] t (Ana)" in md
    assert "**You** (0:00): Let's ship the beta on Friday." in md
    # 1_760_450_400 is 14:00 UTC; tz=-120 (minutes east of UTC is negative in JS) → 16:00.
    assert "16:00" in md


def test_clock():
    assert agent_notes.clock(75) == "1:15"
    assert agent_notes.clock(3725) == "1:02:05"


# MARK: - the dispatcher


def test_create_lists_gets_and_summarizes(store):
    published = []
    status, payload = call(store, "POST", "", dict(sample(), summarize=True), published=published)
    assert status == 200
    assert payload["note"]["id"] == NOTE_ID
    status, payload = call(store, "GET", "")
    assert status == 200 and payload["notes"][0]["title"] == "Beta launch plan"
    status, payload = call(store, "GET", f"/{NOTE_ID}")
    assert status == 200 and payload["summary_status"] == "done"
    assert ("notes", {"id": NOTE_ID}) in published


def test_create_without_summarize_leaves_it_alone(store):
    model = FakeModel(GOOD_REPLY)
    status, payload = call(store, "POST", "", sample(), model=model)
    assert status == 200
    assert model.calls == []
    assert store.get(NOTE_ID)["summary_status"] == "none"


def test_a_note_with_no_lines_is_never_summarized(store):
    model = FakeModel(GOOD_REPLY)
    call(store, "POST", "", dict(sample(lines=[]), summarize=True), model=model)
    assert model.calls == []
    assert store.get(NOTE_ID)["summary_status"] == "none"


def test_bad_bodies_and_ids(store):
    assert call(store, "POST", "", None)[0] == 400
    assert call(store, "POST", "", {"id": "../x"})[0] == 400
    assert call(store, "GET", "/does-not-exist-0000")[0] == 404
    assert call(store, "GET", "/../../etc")[0] == 404
    assert call(store, "DELETE", "/nope-nope-nope")[0] == 404
    assert call(store, "PUT", "")[0] == 405


def test_edit_title_and_todos(store):
    call(store, "POST", "", sample(todos=[{"text": "A"}, {"text": "B"}]))
    status, payload = call(store, "POST", f"/{NOTE_ID}", {"title": "Renamed", "todos": [{"text": "A", "done": True}]})
    assert status == 200
    note = payload["note"]
    assert note["title"] == "Renamed" and note["title_edited"] is True
    assert note["todos"] == [{"text": "A", "owner": None, "due": None, "done": True}]


def test_resummarize(store):
    call(store, "POST", "", sample())
    status, payload = call(store, "POST", f"/{NOTE_ID}/summarize", {}, model=FakeModel(GOOD_REPLY))
    assert status == 200
    assert store.get(NOTE_ID)["summary"].startswith("The beta ships")
    assert call(store, "POST", "/AAAAAAAA-0000-0000-0000-00000000dead/summarize", {})[0] == 404


def test_markdown_route(store):
    call(store, "POST", "", sample())
    status, payload = call(store, "GET", f"/{NOTE_ID}/markdown?tz=0")
    assert status == 200
    assert payload["markdown"].startswith("# Call 14 Oct 15:00")
    assert payload["filename"] == "Call 14 Oct 15-00.md"


def test_delete_route_publishes(store):
    published = []
    call(store, "POST", "", sample())
    status, payload = call(store, "DELETE", f"/{NOTE_ID}", published=published)
    assert status == 200 and payload == {"ok": True}
    assert ("notes", {"id": NOTE_ID, "deleted": True}) in published
    assert store.get(NOTE_ID) is None


# MARK: - Flow clean-up


def test_flow_cleanup_returns_the_cleaned_text():
    model = FakeModel("Let's meet at four.")
    status, payload = handle_flow_cleanup(
        {"text": "uh let's meet at three no at four", "style": "natural", "app": "Slack", "words": ["Supabase"]},
        call=model)
    assert status == 200
    assert payload == {"text": "Let's meet at four.", "cleaned": True}
    system = model.calls[0][0]["content"]
    assert "Slack" in system and "Supabase" in system
    assert "<dictation>" in model.calls[0][1]["content"]


def test_flow_cleanup_keeps_the_words_when_the_reply_is_implausible():
    status, payload = handle_flow_cleanup({"text": "send the report to ana today", "style": "natural"},
                                          call=FakeModel("Sure! Here is a long answer " * 20))
    assert status == 200
    assert payload == {"text": "send the report to ana today", "cleaned": False}


def test_flow_cleanup_skips_verbatim_and_short_text_without_calling_the_model():
    model = FakeModel("x")
    assert handle_flow_cleanup({"text": "git status please now", "style": "verbatim"}, call=model)[1]["cleaned"] is False
    assert handle_flow_cleanup({"text": "ok", "style": "natural"}, call=model)[1]["cleaned"] is False
    assert model.calls == []


def test_flow_cleanup_survives_a_model_failure():
    status, payload = handle_flow_cleanup({"text": "one two three four", "style": "polished"},
                                          call=FakeModel(RuntimeError("down")))
    assert status == 200 and payload["cleaned"] is False
    assert handle_flow_cleanup(None)[0] == 400


def test_flow_cleanup_strips_tags_and_keeps_snippet_marks():
    status, payload = handle_flow_cleanup({"text": "sign it ⟦1⟧ thanks a lot", "style": "natural"},
                                          call=FakeModel("<dictation>Sign it ⟦1⟧, thanks a lot.</dictation>"))
    assert payload == {"text": "Sign it ⟦1⟧, thanks a lot.", "cleaned": True}
    status, payload = handle_flow_cleanup({"text": "sign it ⟦1⟧ thanks a lot", "style": "natural"},
                                          call=FakeModel("Sign it, thanks a lot."))
    assert payload["cleaned"] is False


# MARK: - mounted in routes.py


class _FakeHandler:
    def __init__(self, body: bytes = b""):
        import io
        self.status = None
        self.sent_headers = []
        self.body = bytearray()
        self.wfile = self
        self.rfile = io.BytesIO(body)
        self.headers = {"Content-Length": str(len(body))} if body else {}

    def send_response(self, status):
        self.status = status

    def send_header(self, name, value):
        self.sent_headers.append((name, value))

    def end_headers(self):
        pass

    def write(self, data):
        self.body.extend(data)

    def json(self):
        return json.loads(bytes(self.body).decode("utf-8"))


def test_the_routes_reach_the_dispatcher(tmp_path, monkeypatch):
    from urllib.parse import urlparse
    from api import routes
    monkeypatch.setattr(agent_notes_routes, "_STORE", NotesStore(lambda: tmp_path / "notes"))
    monkeypatch.setattr(agent_notes_routes, "_publish", lambda *a: None)

    h = _FakeHandler(json.dumps(sample()).encode())
    assert routes.handle_post(h, urlparse("http://x/api/agent-notes")) is not False  # the server treats only False as unhandled
    assert h.status == 200 and h.json()["note"]["id"] == NOTE_ID

    h = _FakeHandler()
    assert routes.handle_get(h, urlparse("http://x/api/agent-notes")) is not False  # the server treats only False as unhandled
    assert [n["id"] for n in h.json()["notes"]] == [NOTE_ID]

    h = _FakeHandler()
    assert routes.handle_get(h, urlparse(f"http://x/api/agent-notes/{NOTE_ID}/markdown?tz=0")) is not False  # the server treats only False as unhandled
    assert h.json()["markdown"].startswith("# Call 14 Oct 15:00")

    monkeypatch.setattr("agent.flow_cleanup.default_model_call", FakeModel("Meet at four."))
    h = _FakeHandler(json.dumps({"text": "uh meet at three no four", "style": "natural"}).encode())
    assert routes.handle_post(h, urlparse("http://x/api/flow/cleanup")) is not False  # the server treats only False as unhandled
    assert h.json() == {"text": "Meet at four.", "cleaned": True}

    h = _FakeHandler()
    assert routes.handle_delete(h, urlparse(f"http://x/api/agent-notes/{NOTE_ID}")) is not False  # the server treats only False as unhandled
    assert h.status == 200 and h.json() == {"ok": True}
