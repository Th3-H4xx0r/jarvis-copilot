from agent.voice_hallucination import is_hallucinated_output as h


def test_empty_and_punctuation_only():
    assert h("") is True
    assert h("   ") is True
    assert h("...") is True
    assert h("?!") is True
    assert h(None) is True


def test_always_hallucination_phrases():
    assert h("Thank you for watching") is True
    assert h("thanks for watching.") is True
    assert h("[BLANK_AUDIO]") is True
    assert h("Please subscribe") is True
    assert h("see you next time") is True


def test_repetition_loops():
    assert h("you you you you") is True
    assert h("Thank you. Thank you. Thank you.") is True
    assert h("the the the the the the") is True


def test_dominant_word_ratio():
    assert h("yeah yeah yeah yeah yeah yeah") is True  # >60% and >=5


def test_real_speech_not_flagged():
    assert h("how do I deploy the watch app to the device") is False
    assert h("no no no don't do that") is False          # emphatic, 50% -> allowed
    assert h("schedule a meeting with Alice on Friday") is False


def test_conversation_mode_keeps_short_replies():
    assert h("yes", mode="conversation") is False
    assert h("okay", mode="conversation") is False


def test_dictation_mode_drops_lone_filler():
    assert h("yes", mode="dictation") is True
    assert h("okay", mode="dictation") is True
    assert h("thank you", mode="dictation") is True
    # but a substantive dictation still passes
    assert h("open the deploy script and run it", mode="dictation") is False
