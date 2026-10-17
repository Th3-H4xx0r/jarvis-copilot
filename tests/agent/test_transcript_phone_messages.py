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


def Q(uid, prompt, mode="prompt", origin="human", meta=None):
    a = {"type": "queued_command", "prompt": prompt, "commandMode": mode, "origin": {"kind": origin}}
    if meta:
        a["isMeta"] = True
    return json.dumps({"type": "attachment", "uuid": uid, "timestamp": "2026-10-17T22:29:21.000Z",
                       "attachment": a})


def test_a_message_queued_while_it_works_is_a_user_bubble():
    """Typed mid-turn (from the phone or the keyboard), Claude Code records the
    message only as a queued_command attachment, never as a user line."""
    msgs = parse_transcript_text("\n".join([
        U("u1", "run the tests"), A("a1", "Running."), Q("q1", "then lint"),
        Q("q2", [{"type": "text", "text": "and push"}]), A("a2", "Linted and pushed.")]))
    assert [(m["role"], m["text"]) for m in msgs] == [
        ("user", "run the tests"), ("assistant", "Running."), ("user", "then lint"),
        ("user", "and push"), ("assistant", "Linted and pushed.")]


def test_task_notifications_and_peer_messages_in_the_queue_stay_hidden():
    msgs = parse_transcript_text("\n".join([
        U("u1", "x"), A("a1", "one"),
        Q("q1", "<task-notification>\n<task-id>t1</task-id>", mode="task-notification"),
        Q("q2", "<cross-session-message from=\"uds:/x\">hi</cross-session-message>", origin="peer", meta=True),
        A("a2", "two")]))
    assert [m["role"] for m in msgs] == ["user", "assistant"]


def test_a_queued_message_also_written_as_a_user_line_shows_once():
    msgs = parse_transcript_text("\n".join([
        U("u1", "go"), A("a1", "Working."), Q("q1", "stop and fix it"), U("u2", "stop and fix it"),
        A("a2", "Fixed.")]))
    assert [m["text"] for m in msgs if m["role"] == "user"] == ["go", "stop and fix it"]
