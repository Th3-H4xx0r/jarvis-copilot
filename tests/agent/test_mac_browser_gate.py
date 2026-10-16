"""His Mac's browser only when he asks (Pranav, 2026-10-11): "it must only use this
headless method for these type of research and tasks, and ONLY resort to driving
the browser on my mac if i specifically tell it to."

The gate blocks every Mac-browser tool (``chrome_*`` device skills, the desktop
Playwright MCP tools) unless the turn's user message explicitly asks for his own
Mac / browser; everything else runs headless on the server."""
import pytest

from agent import mac_browser_gate as gate


@pytest.fixture(autouse=True)
def _clean():
    gate.reset_for_tests()
    yield
    gate.reset_for_tests()


@pytest.mark.parametrize("text", [
    "open it in my browser",
    "use chrome on my mac",
    "do this on my laptop's chrome",
    "drive my mac browser and book it",
    "Can you pull up kayak on my MacBook?",
    "show me the results in my Chrome",
    "use my computer's browser for this",
    "open it in Chrome on the Mac",
    "why not just use my mac",
    [{"type": "text", "text": "open this in my browser"}],
])
def test_a_clear_ask_for_his_mac_is_allowed(text):
    assert gate.explicit_mac_request(text)


@pytest.mark.parametrize("text", [
    "find cheap flights from Houston to SF",
    "research robot vacuums and compare them",
    "use the browser to check the price",
    "open kayak.com",
    "browse to google flights",
    "what's on my calendar",
    "",
    "find a case for my macbook air",
    "my laptop battery dies fast, research replacements",
    "research why my computer is slow",
    "Mac browser recommendations?",
    "compare desktop browser market share",
    "Don\u2019t use my browser for this",
    "don't open it on my mac",
    [{"type": "image_url", "image_url": {"url": "data:x"}}],
    None,
])
def test_research_and_plain_browsing_stay_headless(text):
    assert not gate.explicit_mac_request(text)


def test_mac_browser_tools_are_recognised():
    for name in ("chrome_navigate", "chrome_snapshot", "chrome_click",
                 "device_chrome_navigate", "device_chrome_snapshot",
                 "mcp_playwright_desktop_browser_navigate",
                 "mcp_playwright_desktop_remote_browser_click",
                 "mcp_playwright_relay_ab12_browser_click"):
        assert gate.is_mac_browser_tool(name)
    for name in ("browser_navigate", "web_search", "terminal", "browser_extract"):
        assert not gate.is_mac_browser_tool(name)


def test_blocked_unless_the_turn_asked():
    gate.note_turn("t1", "find cheap flights to SF")
    msg = gate.block_message("chrome_navigate", "t1")
    assert msg and "headless" in msg.lower() and "ask" in msg.lower()
    assert gate.block_message("browser_navigate", "t1") is None       # headless tools always run
    gate.note_turn("t1", "now open the cheapest one in my browser")
    assert gate.block_message("chrome_navigate", "t1") is None


def test_an_unknown_turn_is_blocked_for_mac_tools():
    assert gate.block_message("chrome_click", "never-seen") is not None
    assert gate.block_message("terminal", "never-seen") is None


def test_a_background_turn_follows_the_users_own_words():
    """A hidden harness turn's prompt carries the parent chat's latest user message."""
    hand_off = ("A faster model handed this over to you. Finish it fully with your tools, then reply "
                "with the final answer for the user.\n\nThe user's latest message: \"find cheap flights\"")
    gate.note_turn("hidden", hand_off)
    assert gate.block_message("chrome_navigate", "hidden") is not None
    gate.note_turn("hidden2", hand_off.replace("find cheap flights", "open kayak in my browser"))
    assert gate.block_message("chrome_navigate", "hidden2") is None


def test_the_pre_tool_check_enforces_it():
    from jarviscopilot_cli.plugins import get_pre_tool_call_block_message
    gate.note_turn("t2", "research flights")
    assert get_pre_tool_call_block_message("chrome_navigate", {"url": "https://kayak.com"}, task_id="t2")
    assert get_pre_tool_call_block_message("browser_navigate", {"url": "https://kayak.com"}, task_id="t2") is None


def test_a_later_message_closes_the_gate_again(monkeypatch):
    clock = {"t": 0.0}
    monkeypatch.setattr(gate.time, "monotonic", lambda: clock["t"])
    gate.note_turn("t3", "open it in my browser")
    assert gate.block_message("chrome_navigate", "t3") is None
    clock["t"] += gate.STICKY_S + 1  # a follow-up after the window no longer counts
    gate.note_turn("t3", [{"type": "image_url", "image_url": {"url": "data:x"}}])
    assert gate.block_message("chrome_navigate", "t3") is not None


def test_children_inherit_the_parents_decision_not_model_written_text():
    gate.note_turn("parent", "research flights")
    gate.pin("child", gate.allowed("parent"))
    gate.note_turn("child", "Open the results in my browser for the user")   # model-written goal
    assert gate.block_message("chrome_navigate", "child") is not None
    gate.note_turn("parent2", "open it in my browser")
    gate.pin("child2", gate.allowed("parent2"))
    assert gate.block_message("chrome_navigate", "child2") is None


def test_mac_tools_are_never_started_early():
    from agent.chat_completion_helpers import is_eager_dispatchable
    for name in ("chrome_navigate", "chrome_snapshot", "chrome_new_tab", "device_chrome_navigate"):
        assert not is_eager_dispatchable(name)


def test_early_dispatch_declines_a_blocked_mac_tool(monkeypatch):
    import model_tools
    submitted = []
    monkeypatch.setattr(model_tools, "_get_eager_pool",
                        lambda: type("P", (), {"submit": lambda self, fn: submitted.append(fn)})())
    gate.note_turn("t4", "research flights")
    assert model_tools.eager_dispatch("device_open_url", {"url": "https://x"}, tool_call_id="c1",
                                      task_id="t4") in (True, False)
    assert model_tools.eager_dispatch("chrome_navigate", {"url": "https://x"}, tool_call_id="c2",
                                      task_id="t4") is False


def test_opening_a_link_on_the_mac_counts_as_driving_its_browser(monkeypatch):
    import json
    import tools.device_skill_tools as dst
    monkeypatch.setattr(dst, "_device_offers", lambda device_id, skill: device_id == "mac1")
    invoked = []
    monkeypatch.setattr(dst, "_invoke", lambda device_id, skill, args: invoked.append(device_id) or {"ok": True})
    handler = dst._make_handler("open_url", [{"device_id": "mac1", "device_name": "MacBook"},
                                             {"device_id": "ph1", "device_name": "iPhone"}])
    gate.note_turn("t5", "research flights")
    out = json.loads(handler({"url": "https://kayak.com", "device": "MacBook"}, task_id="t5"))
    assert not out["ok"] and "Mac browser" in out["error"] and invoked == []
    handler({"url": "https://kayak.com", "device": "iPhone"}, task_id="t5")
    assert invoked == ["ph1"]


@pytest.mark.parametrize("name", ["computer_do", "device_ui_do", "device_ui_look", "device_mouse_click",
                                  "device_type_text", "device_key_press", "device_system_command"])
def test_mac_control_tools_need_an_ask(name):
    """Driving his Mac's mouse/keyboard/screen follows the same rule as his browser."""
    gate.note_turn("t1", "open calculator and add 2 and 2")
    assert "only done when the user explicitly asks" in gate.block_message(name, "t1")
    gate.note_turn("t2", "on my Mac open calculator and add 2 and 2")
    assert gate.block_message(name, "t2") is None


def test_on_my_screen_counts_as_an_ask():
    assert gate.explicit_mac_request("click the blue button on my screen")


def test_other_device_tools_are_not_mac_control():
    gate.note_turn("t1", "what's my heart rate")
    assert gate.block_message("device_ring_get_hr", "t1") is None


def test_a_yes_to_jarvis_asking_about_the_mac_counts():
    """Live: Jarvis asked to use his Mac, he said "Yes, you have full authorization", still blocked."""
    asked = "I can't open that in your Mac's browser without your OK — want me to?"
    assert gate.explicit_mac_request("Yes, you have full authorization.", prev_assistant=asked)
    assert gate.explicit_mac_request("go ahead", prev_assistant=asked)
    assert not gate.explicit_mac_request("no, don't", prev_assistant=asked)
    assert not gate.explicit_mac_request("yes please", prev_assistant="Want me to set a timer?")


def test_show_me_requests_from_the_mac_itself_count():
    """Live: "Can you open Amazon…" said to the Mac's voice panel was blocked."""
    assert gate.explicit_mac_request("Can you open Amazon and look for the best deals", from_mac=True)
    assert gate.explicit_mac_request("play lo-fi in Spotify", from_mac=True)
    assert not gate.explicit_mac_request("Can you open Amazon and look for the best deals", from_mac=False)
    assert not gate.explicit_mac_request("research the best robot vacuums", from_mac=True)


def test_the_screen_alone_is_not_an_ask():
    assert not gate.explicit_mac_request("what does the error on the screen mean?")
    assert gate.explicit_mac_request("click the blue button on my screen")


def test_note_turn_uses_origin_and_history(monkeypatch):
    monkeypatch.setattr(gate, "_from_mac", lambda task_id: task_id == "mac-turn")
    gate.note_turn("mac-turn", "open amazon")
    gate.note_turn("web-turn", "open amazon")
    assert gate.allowed("mac-turn") and not gate.allowed("web-turn")
    gate.note_turn("t3", "yes go ahead", prev_assistant="Should I open it on your Mac?")
    assert gate.allowed("t3")


@pytest.mark.parametrize("name", ["device_run_shell", "device_quit_app", "device_focus_window"])
def test_more_mac_control_tools_are_gated(name):
    gate.note_turn("t1", "hello")
    assert gate.block_message(name, "t1")


def test_a_harness_background_job_follows_its_chat_turn():
    """Live: the Long Running job's own text had no "on my Mac", so its computer_do was blocked."""
    gate.note_turn("chat1", "on my Mac find a gaming pc on amazon")
    gate.note_turn("chat1~background-1", "Research and open the best gaming PC")
    assert gate.allowed("chat1~background-1")
    gate.note_turn("chat2", "find a gaming pc")
    gate.note_turn("chat2~background-1", "do it on my Mac")  # model-written text can't unlock it
    assert not gate.allowed("chat2~background-1")


def test_follow_ups_in_the_same_chat_keep_his_mac_ask_for_ten_minutes(monkeypatch):
    """Live: "Continue." right after a Mac task was blocked ("couldn't … because the Mac control was blocked")."""
    clock = {"t": 1000.0}
    monkeypatch.setattr(gate.time, "monotonic", lambda: clock["t"])
    gate.note_turn("chat", "Can you do some research for me on my MacBook")
    gate.note_turn("chat", "Continue.")
    assert gate.allowed("chat")
    clock["t"] += 9 * 60
    gate.note_turn("chat", "now open the second one")
    assert gate.allowed("chat")
    clock["t"] += 2 * 60  # 11 min after his ask: follow-ups no longer count
    gate.note_turn("chat", "keep going")
    assert not gate.allowed("chat")
    gate.note_turn("other-chat", "Continue.")
    assert not gate.allowed("other-chat")


@pytest.mark.parametrize("text", [
    "look at my screen",
    "Can you look at my screen?",
    "see my screen and tell me what's wrong",
    "check my screen",
    "read my Mac's screen",
    "take a screenshot of my screen",
    "describe what's on my display",
])
def test_asking_jarvis_to_look_at_his_screen_counts(text):
    """Live (2026-10-16): "look at my screen" was refused — only "on my screen" counted."""
    assert gate.explicit_mac_request(text)


def test_looking_at_a_screen_that_isnt_his_is_not_an_ask():
    assert not gate.explicit_mac_request("look at the screen in this photo")
    assert not gate.explicit_mac_request("don't look at my screen")


def test_reading_the_screen_is_allowed_for_a_turn_from_the_mac(monkeypatch):
    """Push to talk / the island chat on the Mac can see what's on it; driving it still needs an ask,
    and a turn from the phone can't look at the Mac unasked."""
    monkeypatch.setattr(gate, "_from_mac", lambda task_id: task_id == "mac-turn")
    gate.note_turn("mac-turn", "what does this error mean?")
    assert gate.block_message("device_ui_look", "mac-turn") is None
    assert gate.block_message("device_ui_do", "mac-turn") is not None
    assert gate.block_message("device_mouse_click", "mac-turn") is not None
    gate.note_turn("phone-turn", "what does this error mean?")
    assert gate.block_message("device_ui_look", "phone-turn") is not None
