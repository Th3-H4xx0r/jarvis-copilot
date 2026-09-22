"""The `live_transcript` tool: coarse before fine, and never a whole transcript.

The tool exists so a chat can answer "what did she say about the vendor?" over a
year of ambient recording without any of that recording entering the prompt. That
only works if searching digests locates the stretch of talk and a second, narrow
call fetches the words — so the workflow test below is the one that matters.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT / "webui") not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT / "webui"))

from api import config as api_config  # noqa: E402
from api import live_store  # noqa: E402

from tools.live_transcript_tool import live_transcript  # noqa: E402
from tools.registry import registry  # noqa: E402


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(api_config, "STATE_DIR", tmp_path)
    live_store.reset_for_tests()
    yield tmp_path
    live_store.reset_for_tests()


def _call(**args) -> dict:
    raw = live_transcript(args)
    assert isinstance(raw, str), "every tool handler must return a JSON string"
    return json.loads(raw)


def _say(session_id: str, text: str, *, start: int, speaker: str = "") -> dict:
    return live_store.append_segment(
        session_id, ts_start_ms=start, ts_end_ms=start + 3000, text=text,
        speaker_id=speaker)


# ── coarse, then fine ──────────────────────────────────────────────────────


def test_a_digest_search_locates_a_window_without_returning_any_speech():
    """The coarse pass answers "which stretch", cheaply — it must not smuggle a
    transcript back with it."""
    session = live_store.start_session(device_id="iphone")["id"]
    _say(session, "so about that", start=0)
    _say(session, "I think Northwind is the one", start=4000)
    live_store.add_digest(
        session, seq_from=1, seq_to=2,
        summary="They compared vendors and leaned toward Northwind.",
        topics=["vendors"], ts_start_ms=0, ts_end_ms=7000)

    out = _call(action="search_digests", query="vendors")

    assert out["ok"] is True
    assert out["count"] == 1
    assert out["digests"][0]["seq_from"] == 1
    assert out["digests"][0]["seq_to"] == 2
    assert "segments" not in out, "the coarse pass must not carry utterances"


def test_the_coarse_result_points_at_a_range_that_yields_the_actual_words():
    """The whole design in one test: search digests, then fetch only that window's
    utterances. Break this and the tool either lies or loads a transcript."""
    session = live_store.start_session(device_id="iphone")["id"]
    _say(session, "unrelated small talk about lunch", start=0)
    _say(session, "Northwind quoted forty thousand", start=600000)
    _say(session, "that is over our ceiling", start=604000)
    live_store.add_digest(
        session, seq_from=1, seq_to=1, summary="Lunch plans.",
        ts_start_ms=0, ts_end_ms=3000)
    live_store.add_digest(
        session, seq_from=2, seq_to=3,
        summary="The vendor quote came in above budget.",
        topics=["vendor", "budget"],
        ts_start_ms=600000, ts_end_ms=607000)

    coarse = _call(action="search_digests", query="vendor")
    assert coarse["count"] == 1
    window = coarse["digests"][0]

    fine = _call(action="range", live_session_id=window["live_session_id"],
                 ts_from_ms=window["ts_start_ms"], ts_to_ms=window["ts_end_ms"])

    assert fine["ok"] is True
    texts = [s["text"] for s in fine["segments"]]
    assert texts == ["Northwind quoted forty thousand", "that is over our ceiling"]
    assert "unrelated small talk about lunch" not in texts


def test_the_fine_search_finds_an_exact_phrase_somebody_said():
    session = live_store.start_session()["id"]
    _say(session, "the deadline is the fourteenth", start=0)
    _say(session, "I will bring the slides", start=4000)

    out = _call(action="search_segments", query="deadline")

    assert out["count"] == 1
    assert out["segments"][0]["text"] == "the deadline is the fourteenth"
    assert out["segments"][0]["seq"] == 1


def test_a_fine_search_can_be_scoped_to_one_recording():
    """Without this, a word said in every meeting is useless as a query."""
    first = live_store.start_session(device_id="iphone")["id"]
    second = live_store.start_session(device_id="glasses")["id"]
    _say(first, "budget talk in the first room", start=0)
    _say(second, "budget talk in the second room", start=0)

    everywhere = _call(action="search_segments", query="budget")
    scoped = _call(action="search_segments", query="budget", live_session_id=second)

    assert everywhere["count"] == 2
    assert scoped["count"] == 1
    assert scoped["segments"][0]["live_session_id"] == second


def test_a_range_is_bounded_by_its_timestamps():
    session = live_store.start_session()["id"]
    _say(session, "before", start=0)
    _say(session, "inside", start=10000)
    _say(session, "after", start=60000)

    out = _call(action="range", live_session_id=session,
                ts_from_ms=9000, ts_to_ms=14000)

    assert [s["text"] for s in out["segments"]] == ["inside"]


def test_a_long_utterance_comes_back_clipped():
    """The tool's promise is that no single call can flood the prompt."""
    session = live_store.start_session()["id"]
    _say(session, "keyword " + ("blah " * 400), start=0)

    out = _call(action="search_segments", query="keyword")

    text = out["segments"][0]["text"]
    assert len(text) < 500
    assert text.endswith("…")


# ── voices and recordings ─────────────────────────────────────────────────


def test_a_segment_carries_the_speaker_name_not_a_bare_id():
    """An answer that quotes "speaker 3f9a2b" is not an answer."""
    speaker = live_store.create_speaker(kind="other", name="Dana")["id"]
    session = live_store.start_session()["id"]
    _say(session, "I signed off on it", start=0, speaker=speaker)

    out = _call(action="search_segments", query="signed")

    assert out["segments"][0]["speaker"] == "Dana"
    assert out["segments"][0]["speaker_id"] == speaker


def test_speakers_lists_the_voices_and_can_sample_one():
    speaker = live_store.create_speaker(kind="other", name="Dana")["id"]
    session = live_store.start_session()["id"]
    _say(session, "something Dana said", start=0, speaker=speaker)

    listing = _call(action="speakers")
    assert [s["name"] for s in listing["speakers"]] == ["Dana"]

    one = _call(action="speakers", speaker_id=speaker)
    assert one["speaker"]["name"] == "Dana"
    assert [s["text"] for s in one["samples"]] == ["something Dana said"]


def test_sessions_lists_the_recordings_with_their_paired_chat():
    live_store.start_session(device_id="iphone", title="Standup",
                            chat_session_id="chat-7", source_label="AirPods Pro")

    out = _call(action="sessions")

    assert out["count"] == 1
    row = out["sessions"][0]
    assert row["title"] == "Standup"
    assert row["chat_session_id"] == "chat-7"
    assert row["source_label"] == "AirPods Pro"
    assert row["state"] == "recording"


# ── bad input is an answer, not a crash ───────────────────────────────────


def test_a_search_without_a_query_is_reported_not_raised():
    for action in ("search_digests", "search_segments"):
        out = _call(action=action)
        assert out["ok"] is False
        assert "query" in out["error"]


def test_a_range_without_a_session_or_an_end_is_reported():
    session = live_store.start_session()["id"]
    assert _call(action="range", ts_to_ms=1000)["ok"] is False
    assert _call(action="range", live_session_id=session)["ok"] is False


def test_an_unknown_action_is_reported():
    out = _call(action="delete_everything")
    assert out["ok"] is False
    assert "delete_everything" in out["error"]


def test_a_malformed_search_returns_nothing_rather_than_failing():
    """FTS5 syntax is not something the model should have to get right."""
    live_store.start_session()
    out = _call(action="search_segments", query='budget NEAR "')
    assert out["ok"] is True
    assert out["count"] == 0


def test_searching_an_archive_with_nothing_in_it_is_empty_not_an_error():
    assert _call(action="search_digests", query="anything")["count"] == 0
    assert _call(action="sessions")["count"] == 0


# ── wiring ────────────────────────────────────────────────────────────────


def test_the_tool_is_reachable_by_an_agent_and_not_merely_registered():
    """Registration alone does nothing: the toolset has to be a TOOLSETS key AND
    the tool name has to sit inside a platform composite, or `_get_platform_tools`
    drops it without a word."""
    from toolsets import TOOLSETS, resolve_toolset

    assert registry.get_tool_names_for_toolset("live") == ["live_transcript"]
    assert "live" in TOOLSETS
    assert "live_transcript" in set(resolve_toolset("hermes-cli")), \
        "not in the platform composite, so it would be silently dropped"


def test_the_schema_names_no_tool_from_another_toolset():
    """A cross-toolset name in a description invites calls to tools that are not
    loaded (AGENTS.md pitfall)."""
    from tools.live_transcript_tool import _SCHEMA

    blob = json.dumps(_SCHEMA).lower()
    for foreign in ("web_search", "session_search", "read_file", "search_files",
                    "terminal", "memory", "delegate_task"):
        assert foreign not in blob
