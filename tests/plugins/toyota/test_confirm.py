"""His yes in the conversation instead of Face ID: toyota_command asks, his next message decides."""
import json
import time

import pytest

import plugins.toyota.confirm as confirm
import plugins.toyota.tools as tools

from .fake_ha import DEVICE, signed_in_ha

CHAT = "20261017_chat"
ASKED = [{"role": "user", "content": "unlock my car"}]


@pytest.fixture(autouse=True)
def _fresh():
    confirm.reset_for_tests()
    yield
    confirm.reset_for_tests()


@pytest.fixture
def clock(monkeypatch):
    now = [1000.0]
    monkeypatch.setattr(confirm, "_clock", lambda: now[0])
    return now


@pytest.fixture
def car(monkeypatch):
    """A signed-in fake car behind both the tools and the yes path; Face ID cards are recorded."""
    ha = signed_in_ha()
    monkeypatch.setattr(tools, "HAClient", lambda: ha)
    monkeypatch.setattr(confirm, "HAClient", lambda: ha)
    ha.face_id = []
    monkeypatch.setattr(tools, "_request_approval", lambda command: ha.face_id.append(command) or {"ok": True})
    return ha


def reply(text):
    return [{"role": "user", "content": "unlock my car"}, {"role": "assistant", "content": text}]


def command(name, task_id=CHAT):
    return json.loads(tools._handle_command({"command": name}, task_id=task_id))


@pytest.mark.parametrize("words", [
    "Yes.", "yes", "Yeah, do it", "Yep", "Go ahead", "Jarvis, yes", "OK", "Yes please",
    "Um, yes.", "yes go ahead", "Do it.", "Confirm", "Absolutely",
    [{"type": "text", "text": "yes"}],
])
def test_a_plain_yes_counts(words):
    assert confirm.is_yes(words)


@pytest.mark.parametrize("words", [
    "no", "No, don't", "Not yet", "yes but wait", "wait", "maybe later", "what?", "yes?", "unlock it",
    "[Background job finished] yes", "", "go home", "yeah I was thinking about it", "yes, and set it to 70", "Hmm, yes",
    "yes if it's locked", "nah", "Cancel", "yes " + "and then some more words " * 3, "Okay what's my range",
])
def test_anything_less_than_a_plain_yes_does_not(words):
    assert not confirm.is_yes(words)


@pytest.mark.parametrize("words,asked", [
    ("Okay, lock it", ["unlock"]), ("Okay, turn it off", ["start"]), ("OK turn off the hazards", ["hazards_on"]),
    ("Sure, unlock the trunk", ["unlock"]), ("yes unlock it", ["lock"]), ("yes start it", ["unlock"]),
])
def test_a_yes_naming_another_command_does_not(words, asked):
    assert not confirm.is_yes(words, asked)


@pytest.mark.parametrize("words,asked", [
    ("Sure, unlock it", ["unlock"]), ("yes start the car", ["start"]), ("yeah pop the trunk", ["trunk_unlock"]),
    ("ok turn them on", ["hazards_on"]), ("Yes, unlock it and start it", ["unlock", "start"]),
])
def test_a_yes_naming_what_was_asked_counts(words, asked):
    assert confirm.is_yes(words, asked)


@pytest.mark.parametrize("reply,commands,asked", [
    ("Unlock the car?", ["unlock"], True),
    ("Should I unlock your Camry?", ["unlock"], True),
    ("Unlocked. Want me to start it up too?", ["start"], True),
    ("Flash the hazards?", ["hazards_on"], True),
    ("Pop the trunk?", ["trunk_unlock"], True),
    ("Unlock the car and start the car?", ["unlock", "start"], True),
    ("Want me to draft a reply?", ["unlock"], False),
    ("Lock the car?", ["unlock"], False),
    ("I'll unlock the car.", ["unlock"], False),
    ("Unlock the car?", ["unlock", "start"], False),
    ("Turn off the hazards?", ["hazards_on"], False),
    ("", ["unlock"], False),
])
def test_the_reply_he_heard_has_to_ask_it(reply, commands, asked):
    assert confirm.was_asked(reply, commands) is asked


def test_a_yes_to_some_other_question_runs_nothing(car, clock):
    # A model that queued a command behind his back, then asked about something else.
    confirm.on_turn(CHAT, "summarize my email", "webui", ASKED)
    command("unlock")
    note = confirm.on_turn(CHAT, "Yes please", "webui", reply("Here's the summary. Want me to draft a reply?"))
    assert "never put to him" in note and car.services() == []


def test_a_gateway_background_node_keeps_the_face_id_card(car, clock):
    from tools.approval import unattended_run

    with unattended_run():
        confirm.on_turn(CHAT, "unlock the car", "telegram", ASKED)
        out = command("unlock")
    assert out["pending_approval"] is True and car.face_id == ["unlock"]


def test_the_same_question_asked_twice_still_takes_his_yes(car, clock):
    # Jarvis asked in plain words first, then again once the tool told it to: two identical "Yes."
    history = [{"role": "user", "content": "unlock my car"}]
    confirm.on_turn(CHAT, "unlock my car", "webui", history)
    history += [{"role": "assistant", "content": "Unlock the car?"}, {"role": "user", "content": "Yes."}]
    assert confirm.on_turn(CHAT, "Yes.", "webui", history) is None
    command("unlock")
    history += [{"role": "assistant", "content": "Unlock the car?"}, {"role": "user", "content": "Yes."}]
    assert "Unlocked" in confirm.on_turn(CHAT, "Yes.", "webui", history)


def test_the_question_names_every_command():
    assert confirm.question(["unlock"]) == "Unlock the car?"
    assert confirm.question(["unlock", "start"]) == "Unlock the car and start the car?"
    assert confirm.question(["lights", "horn", "trunk_unlock"]) == \
        "Turn on the headlights, sound the horn and unlock the trunk?"


def test_jarvis_asks_and_nothing_reaches_the_car(car, clock):
    confirm.on_turn(CHAT, "unlock my car", "webui", ASKED)
    out = command("unlock")
    assert out["needs_confirmation"] is True and out["ask"] == "Unlock the car?"
    assert "Nothing has been sent" in out["message"]
    assert car.services() == [] and car.face_id == []


def test_his_yes_runs_it_before_the_model_answers(car, clock):
    # Keyed by the chat: a surface whose task id is new every turn (the TUI) still matches.
    assert confirm.on_pre_llm_call(task_id="turn-1", session_id=CHAT, user_message="unlock my car",
                                   platform="tui", conversation_history=ASKED) is None
    command("unlock", task_id="turn-1")
    clock[0] += 8
    note = confirm.on_pre_llm_call(task_id="turn-2", session_id=CHAT, user_message="Yes.",
                                   platform="tui", conversation_history=reply("Unlock the car?"))
    assert car.services() == [("door_unlock", {"vehicle": DEVICE})]
    assert "already ran it" in note["context"] and "Unlocked" in note["context"]
    # The same command asked for again in that turn reports how it went instead of asking again.
    again = command("unlock", task_id="turn-2")
    assert again["result"] == "Unlocked" and "needs_confirmation" not in again
    assert len(car.services()) == 1


@pytest.mark.parametrize("message,words", [
    ('[The user sent a voice message~ Here\'s what they said: "Yes, do it."]', "Yes, do it."),
    ('[Replying to: "Unlock the car?"]\n\nyes', "yes"),
    ("[Pranav] yes", "[Pranav] yes"),          # a group chat: others in it can't confirm for him
    ("yes", "yes"),
])
def test_his_words_come_out_of_the_gateway_wrappers(message, words):
    assert confirm.own_words(message) == words


def test_a_telegram_voice_note_yes_counts(car, clock):
    confirm.on_turn(CHAT, "unlock my car", "telegram", ASKED)
    command("unlock")
    note = confirm.on_turn(CHAT, '[The user sent a voice message~ Here\'s what they said: "Yep."]',
                           "telegram", reply("Unlock the car?"))
    assert "Unlocked" in note


def test_a_mic_that_caught_the_end_of_the_question_still_counts():
    assert confirm.is_yes("car? Yes", ["unlock"], echo="Unlock the car?")
    assert confirm.is_yes("the car yes please", ["unlock"], echo="Unlock the car?")
    assert not confirm.is_yes("unlock", ["unlock"], echo="Unlock the car?")
    assert not confirm.is_yes("car? No", ["unlock"], echo="Unlock the car?")


def test_a_run_nobody_answers_never_touches_his_question(car, clock):
    confirm.on_turn(CHAT, "unlock my car", "webui", ASKED)
    command("unlock")
    # A subagent of this chat, whose (model-written) goal is just "yes".
    assert confirm.on_turn("sa-0-abcd1234", "yes", "webui", reply("Unlock the car?"), session_id=CHAT) is None
    assert car.services() == []
    assert "Unlocked" in confirm.on_turn(CHAT, "yes", "webui", reply("Unlock the car?"))


def test_anything_else_cancels_it(car, clock):
    confirm.on_turn(CHAT, "unlock my car", "webui", ASKED)
    command("unlock")
    note = confirm.on_turn(CHAT, "actually no", "webui", reply("Unlock the car?"))
    assert "nothing was sent" in note
    assert confirm.on_turn(CHAT, "yes", "webui", reply("Okay, I won't.")) is None
    assert car.services() == []


def test_a_yes_after_two_minutes_runs_nothing(car, clock):
    confirm.on_turn(CHAT, "start the car", "webui", ASKED)
    command("start")
    clock[0] += confirm.ANSWER_WITHIN + 1
    note = confirm.on_turn(CHAT, "yes", "webui", reply("Start the car?"))
    assert "unanswered for over 2 minutes" in note and car.services() == []


def test_one_yes_covers_every_command_asked_together(car, clock):
    confirm.on_turn(CHAT, "unlock it and start it", "webui", ASKED)
    command("unlock")
    out = command("start")
    assert out["ask"] == "Unlock the car and start the car?" and out["commands"] == ["unlock", "start"]
    note = confirm.on_turn(CHAT, "yep", "webui", reply("Unlock the car and start the car?"))
    assert [s for s, _ in car.services()] == ["door_unlock", "engine_start"]
    assert "Unlocked" in note and "Started" in note


@pytest.mark.parametrize("task_id,platform", [
    ("sa-0-1234abcd", "webui"),          # a subagent
    ("subagent-0-1234abcd", "webui"),
    (f"{CHAT}~node2", "webui"),          # a harness background job
    ("live-recap-abc", "webui"),         # a Live pass
    ("cron_job_1", "cron"),              # a scheduled job
    ("bg_123456_abcd", "telegram"),      # a /background task
])
def test_runs_he_cannot_answer_keep_the_face_id_card(car, clock, task_id, platform):
    confirm.on_turn(task_id, "unlock the car", platform, ASKED)
    out = command("unlock", task_id=task_id)
    assert out["pending_approval"] is True and car.face_id == ["unlock"] and car.services() == []


def test_a_turn_the_hook_never_saw_keeps_the_face_id_card(car):
    out = command("unlock", task_id="never-seen")
    assert out["pending_approval"] is True and car.face_id == ["unlock"]
    assert command("unlock", task_id=None)["pending_approval"] is True


def test_stop_still_runs_at_once(car, clock):
    confirm.on_turn(CHAT, "turn the car off", "webui", ASKED)
    assert command("stop")["result"] == "Stopped"
    assert car.services() == [("engine_stop", {"vehicle": DEVICE})]


def test_a_retried_turn_is_not_a_second_answer(car, clock):
    confirm.on_turn(CHAT, "unlock my car", "webui", ASKED)
    command("unlock")
    first = confirm.on_turn(CHAT, "yes", "webui", reply("Unlock the car?"))
    # A failed turn re-runs with the same message and the same history: same note, no second unlock.
    assert confirm.on_turn(CHAT, "yes", "webui", reply("Unlock the car?")) == first
    assert len(car.services()) == 1
    # A retry of the asking turn keeps the question open.
    confirm.reset_for_tests()
    confirm.on_turn(CHAT, "start it", "webui", ASKED)
    command("start")
    assert confirm.on_turn(CHAT, "start it", "webui", ASKED) is None
    assert "Started" in confirm.on_turn(CHAT, "yes", "webui", reply("Start the car?"))


def test_the_same_yes_to_a_new_question_is_a_new_answer(car, clock):
    confirm.on_turn(CHAT, "unlock it and then start it", "webui", ASKED)
    command("unlock")
    confirm.on_turn(CHAT, "yes", "webui", reply("Unlock the car?"))
    command("start")                     # Jarvis asks about the start in that turn's reply
    note = confirm.on_turn(CHAT, "yes", "webui", reply("Unlocked. Start the car?"))
    assert "Started" in note
    assert [s for s, _ in car.services()] == ["door_unlock", "engine_start"]


def test_chats_do_not_answer_each_other(car, clock):
    confirm.on_turn(CHAT, "unlock my car", "webui", ASKED)
    command("unlock")
    confirm.on_turn("another_chat", "hi", "webui", [])
    assert confirm.on_turn("another_chat", "yes", "webui", reply("Hello!")) is None
    assert car.services() == []


def test_a_slow_car_is_reported_as_on_its_way(monkeypatch):
    class SlowCar:
        def __init__(self, ha):
            self.ha = ha

        async def command(self, name, approved=False):
            import asyncio
            await asyncio.sleep(0.5)
            return {"result": "Unlocked"}

    async def signed_in(ha):
        return None

    monkeypatch.setattr(confirm, "ToyotaCar", SlowCar)
    monkeypatch.setattr(confirm, "HAClient", lambda: object())
    monkeypatch.setattr(confirm.service, "require_signed_in", signed_in)
    started = time.monotonic()
    results = confirm.run_commands(["unlock"], wait=0.05)
    assert time.monotonic() - started < 0.4
    assert "hasn't confirmed" in results["unlock"]


def test_signed_out_says_so_and_sends_nothing(monkeypatch):
    from .fake_ha import FakeHA

    ha = FakeHA()
    monkeypatch.setattr(confirm, "HAClient", lambda: ha)
    results = confirm.run_commands(["unlock"])
    assert results["unlock"].startswith("not sent") and ha.services() == []


def test_the_plugin_registers_the_hook():
    import plugins.toyota as plugin

    hooks = []

    class Ctx:
        def register_tool(self, **kw):
            pass

        def register_hook(self, name, callback):
            hooks.append((name, callback))

    plugin.register(Ctx())
    assert ("pre_llm_call", confirm.on_pre_llm_call) in hooks
