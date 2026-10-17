"""Messages sent from the phone show in the chat; the newest text survives the cap."""
import json

from agent.coding_transcript_read import MAX_TEXT, parse_transcript_text


def A(uid, text):
    return json.dumps({"type": "assistant", "uuid": uid,
                       "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})


def U(uid, text):
    return json.dumps({"type": "user", "uuid": uid, "message": {"role": "user", "content": text}})


def STOP(uid, reason):
    return json.dumps({"type": "user", "uuid": uid, "isMeta": True,
                       "message": {"role": "user", "content": "Stop hook feedback:\n" + reason}})


PHONE = "Pranav sent this from his phone (Jarvis, Agents tab). Do it now:\n\n"


def test_a_phone_message_handed_at_stop_is_a_user_bubble():
    msgs = parse_transcript_text("\n".join([
        U("u1", "deploy it"), A("a1", "Deployed."), STOP("s1", PHONE + "Hi"), A("a2", "Hi! It came through.")]))
    assert [(m["role"], m["text"]) for m in msgs] == [
        ("user", "deploy it"), ("assistant", "Deployed."), ("user", "Hi"),
        ("assistant", "Hi! It came through.")]
    assert msgs[2].get("from_phone") is True


def test_other_stop_hook_feedback_stays_hidden():
    msgs = parse_transcript_text("\n".join([
        U("u1", "x"), A("a1", "one"), STOP("s1", "lint failed, fix it"), A("a2", "two")]))
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[1]["text"].endswith("two")


def test_a_long_turn_keeps_its_newest_text():
    first = "x" * (MAX_TEXT + 500)
    msgs = parse_transcript_text("\n".join([U("u1", "go"), A("a1", first), A("a2", "THE END")]))
    assert msgs[-1]["text"].endswith("THE END")
