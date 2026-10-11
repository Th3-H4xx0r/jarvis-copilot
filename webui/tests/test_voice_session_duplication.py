"""A voice chat must not re-append earlier replies each turn.

Voice replies that were only the Pod's "[end]" tag are saved with empty content and a
`reasoning` field. Once compaction made the model context shorter than the visible
transcript, the post-turn writeback re-inserted every such reply after the current turn,
so the copies doubled per turn (one session reached 504k messages / 536 MB and the webui
was OOM-killed whenever it loaded).
"""

import copy
import json
import logging
import pathlib

from api import models
from api.streaming import (
    _carry_late_harness_results,
    _find_current_user_turn,
    _merge_display_messages_after_agent_result,
    _restore_reasoning_metadata,
)

API = pathlib.Path(__file__).parent.parent / "api"


def _voice_turns(n_turns, restore_against_display):
    """Run voice turns through the post-turn writeback (api/streaming.py) after a compaction."""
    display, context = [], []
    clock = [1_791_000_000]

    def turn(text, reply):
        clock[0] += 30
        prev_display, prev_context = copy.deepcopy(display), copy.deepcopy(context)
        result = copy.deepcopy(prev_context) + [
            {"role": "user", "content": text, "timestamp": clock[0]},
            {"role": "assistant", "content": reply, "timestamp": clock[0] + 1},
        ]
        next_context = _restore_reasoning_metadata(prev_context, result)
        restored = _restore_reasoning_metadata(prev_display, result) if restore_against_display else next_context
        new_display = _carry_late_harness_results(
            display, len(prev_display),
            _merge_display_messages_after_agent_result(prev_display, prev_context, restored, text))
        for m in reversed(new_display):  # the turn's reasoning lands on its last reply
            if m.get("role") == "assistant":
                m["reasoning"] = "[end]"
                break
        return next_context, new_display

    for i in range(4):
        context, display = turn(f"warm-up {i}", "")  # a bare "[end]" reply, stripped to ""
    context = [{"role": "user", "content": "[context compaction summary]"}] + context[-2:]
    sizes = []
    for i in range(n_turns):
        context, display = turn(f"question {i}", "" if i % 2 else "Done, sir.")
        sizes.append(len(display))
    return sizes, display


def test_voice_turns_after_compaction_grow_by_one_exchange_each():
    sizes, display = _voice_turns(12, restore_against_display=False)
    assert [b - a for a, b in zip(sizes, sizes[1:])] == [2] * 11
    assert len(display) == 8 + 2 * 12


def test_merge_never_reappends_a_reply_already_in_the_transcript():
    # Even a writeback that aligns against the transcript (the old call sites) stays linear.
    sizes, _ = _voice_turns(12, restore_against_display=True)
    assert sizes[-1] - sizes[0] == 2 * 11


def test_replayed_stamped_reply_is_not_appended_again():
    answer = {"role": "assistant", "content": "", "reasoning": "[end]", "timestamp": 100}
    previous_display = [{"role": "user", "content": "open chrome", "timestamp": 99}, answer]
    previous_context = [{"role": "user", "content": "open chrome"}, {"role": "assistant", "content": ""}]
    result = copy.deepcopy(previous_context) + [
        {"role": "user", "content": "thanks", "timestamp": 130},
        copy.deepcopy(answer),  # a copy of the earlier reply, replayed after the new turn
        {"role": "assistant", "content": "You're welcome, sir.", "timestamp": 131},
    ]

    merged = _merge_display_messages_after_agent_result(previous_display, previous_context, result, "thanks")

    assert [m.get("content") for m in merged] == ["open chrome", "", "thanks", "You're welcome, sir."]


def test_identical_replies_in_separate_turns_both_stay():
    previous_display = [
        {"role": "user", "content": "ping", "timestamp": 10},
        {"role": "assistant", "content": "pong", "timestamp": 11},
    ]
    previous_context = copy.deepcopy(previous_display)
    result = previous_context + [
        {"role": "user", "content": "ping", "timestamp": 20},
        {"role": "assistant", "content": "pong", "timestamp": 21},
    ]

    merged = _merge_display_messages_after_agent_result(previous_display, previous_context, result, "ping")

    assert [m["timestamp"] for m in merged] == [10, 11, 20, 21]


def test_current_turn_is_the_latest_matching_user_message():
    # Matching from the start re-appended the whole history after an earlier
    # "Hello, are you there?" (or after "question 1" for "question 10").
    history = [
        {"role": "user", "content": "Hello, are you there?"},
        {"role": "assistant", "content": "Here, sir."},
        {"role": "user", "content": "question 1"},
        {"role": "assistant", "content": "Done."},
    ]
    assert _find_current_user_turn(history + [{"role": "user", "content": "Hello, are you there?"}],
                                   "Hello, are you there?") == 4
    assert _find_current_user_turn(history + [{"role": "user", "content": "question 10"}], "question 10") == 4
    assert _find_current_user_turn(history + [{"role": "assistant", "content": "ok"}], "unrelated") == 2


def test_writeback_restores_metadata_against_the_model_context_not_the_transcript():
    # The agent's result is built from the model context; aligning it with the (longer)
    # transcript by position is what re-inserted old replies.
    for name in ("streaming.py", "routes.py"):
        src = (API / name).read_text(encoding="utf-8")
        assert "_restore_reasoning_metadata(_previous_messages" not in src, name


def test_loading_an_oversized_session_logs_a_warning(tmp_path, monkeypatch, caplog):
    # A chat this big takes GBs to parse; say so in the log long before it OOMs the box.
    monkeypatch.setattr(models, "SESSION_DIR", tmp_path)
    monkeypatch.setattr(models, "_OVERSIZED_SESSION_BYTES", 200)
    payload = {"session_id": "big_voice", "title": "Voice",
               "messages": [{"role": "assistant", "content": "", "reasoning": "[end]"}] * 20}
    (tmp_path / "big_voice.json").write_text(json.dumps(payload), encoding="utf-8")
    (tmp_path / "small.json").write_text(json.dumps({**payload, "session_id": "small", "messages": []}),
                                         encoding="utf-8")

    with caplog.at_level(logging.WARNING, logger=models.logger.name):
        assert len(models.Session.load("big_voice").messages) == 20
        assert models.Session.load("small").messages == []

    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert len(warnings) == 1 and "big_voice" in warnings[0]

