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
])
def test_research_and_plain_browsing_stay_headless(text):
    assert not gate.explicit_mac_request(text)


def test_mac_browser_tools_are_recognised():
    for name in ("chrome_navigate", "chrome_snapshot", "chrome_click",
                 "mcp_playwright_desktop_browser_navigate",
                 "mcp_playwright_desktop_remote_browser_click"):
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
