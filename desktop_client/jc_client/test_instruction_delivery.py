"""The phone's next instruction reaches the LIVE session on this Mac: handed
to Claude when it finishes its current step (the Stop hook), or typed into an
idle tmux pane / iTerm session. Never a background `claude --resume` (that
forks the conversation into a second copy that acts on its own)."""
from jc_client import instruction_delivery as idl


def test_queue_hands_over_once_and_joins_several():
    q = idl.InstructionQueue(clock=lambda: 100.0)
    assert q.take("s1") is None
    q.add("s1", "also run lint")
    q.add("s1", "then commit")
    q.add("s2", "other")
    assert q.take("s1") == "also run lint\n\nthen commit"
    assert q.take("s1") is None
    assert q.pending("s2") == 1


def test_old_messages_expire():
    now = [0.0]
    q = idl.InstructionQueue(clock=lambda: now[0])
    q.add("s1", "stale")
    now[0] = idl.QUEUE_TTL + 1
    assert q.take("s1") is None


def test_stop_reply_makes_claude_continue_with_it():
    out = idl.stop_reply("run the tests")
    assert out["decision"] == "block"
    assert "run the tests" in out["reason"] and "phone" in out["reason"]


def test_typing_into_tmux_sends_literal_text_then_enter():
    calls = []
    ok, why = idl.type_into({"tmux_pane": "%3"}, "rm -rf x; echo $HOME", run=lambda argv: calls.append(argv) or 0,
                            which=lambda name: "/opt/homebrew/bin/tmux")
    assert ok
    assert calls == [["/opt/homebrew/bin/tmux", "send-keys", "-t", "%3", "-l", "--", "rm -rf x; echo $HOME"],
                     ["/opt/homebrew/bin/tmux", "send-keys", "-t", "%3", "Enter"]]


def test_typing_into_iterm_passes_the_text_as_an_argument_not_script():
    calls = []
    ok, _ = idl.type_into({"iterm": "w0t1p0:ABC-123"}, 'say "hi" & quit', run=lambda argv: calls.append(argv) or 0,
                          which=lambda name: None)
    assert ok
    argv = calls[0]
    assert argv[0] == "/usr/bin/osascript"
    assert argv[-2:] == ["ABC-123", 'say "hi" & quit']          # data, never spliced into the script
    assert 'say "hi"' not in " ".join(argv[:-2])


def test_nothing_to_type_into_is_a_clear_no():
    ok, why = idl.type_into({"term_program": "vscode"}, "x", run=lambda argv: 0, which=lambda n: None)
    assert not ok and "can't type" in why
