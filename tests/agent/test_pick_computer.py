"""Which computer Jarvis drives (contract C7, Pranav's call: the Mac unless he names the PC)."""
from agent import mac_browser_gate
from agent.computer import mac

MAC = {"device_id": "mac-1", "device_name": "Pranav's MacBook Pro", "device_os": "macos", "name": "ui_look"}
PC = {"device_id": "pc-1", "device_name": "Pranav-Desktop", "device_os": "windows", "name": "ui_look"}


def test_turn_device_wins_when_no_computer_is_named():
    row, err = mac.pick_computer([MAC, PC], "pc-1", "open spotify")
    assert row is PC and err == ""


def test_named_computer_beats_the_turn_device():
    # His call 2026-11-19 ("words win"): "install docker desktop on my pc" typed on the Mac drove the Mac.
    assert mac.pick_computer([MAC, PC], "mac-1", "Can you install docker desktop on my pc")[0] is PC
    assert mac.pick_computer([MAC, PC], "pc-1", "open spotify on my mac")[0] is MAC
    assert mac.pick_computer([MAC, PC], "mac-1", "check pranav-desktop for the download")[0] is PC


def test_named_pc_picked():
    row, _ = mac.pick_computer([MAC, PC], None, "open notepad on my PC")
    assert row is PC


def test_named_windows_and_gaming_pc_picked():
    assert mac.pick_computer([MAC, PC], None, "use my gaming pc")[0] is PC
    assert mac.pick_computer([MAC, PC], None, "on windows, open settings")[0] is PC


def test_named_device_name_picked():
    row, _ = mac.pick_computer([MAC, PC], None, "check pranav-desktop for the download")
    assert row is PC


def test_unnamed_defaults_to_mac():
    row, _ = mac.pick_computer([PC, MAC], None, "open spotify on my computer")
    assert row is MAC


def test_default_mac_offline_uses_pc():
    row, err = mac.pick_computer([PC], None, "open spotify on my computer")
    assert row is PC and err == ""


def test_mac_ask_never_opens_pc():
    row, err = mac.pick_computer([PC], None, "open spotify on my mac")
    assert row is None and err == "Your Mac isn't online with computer control."


def test_pc_ask_never_opens_mac():
    row, err = mac.pick_computer([MAC], None, "do it on my PC")
    assert row is None and err == "Your PC isn't online with computer control."


def test_old_rows_without_os_count_as_mac():
    old = {"device_id": "m", "device_name": "Mac", "name": "ui_look"}
    assert mac.pick_computer([PC, old], None, "on my computer")[0] is old


def test_no_offers():
    row, err = mac.pick_computer([], None, "anything")
    assert row is None and err


def test_word_pc_inside_other_words_is_not_a_name():
    # "pcs", "upc", "npc" are not the PC
    assert mac.pick_computer([PC, MAC], None, "find npc dialogue in the upc list")[0] is MAC


def test_gate_accepts_pc_as_explicit_target():
    assert mac_browser_gate.explicit_mac_request("use my pc to open spotify")
    assert mac_browser_gate.explicit_mac_request("open notepad on my PC")
    assert mac_browser_gate.explicit_mac_request("on my gaming pc, open steam")


def test_plural_windows_is_not_the_pc():
    # Review 2026-11-15: "windows" (Chrome windows) on the Mac must stay the Mac.
    row, err = mac.pick_computer([MAC], None, "close the extra Chrome windows on my Mac")
    assert row is MAC and err == ""
    assert mac.pick_computer([MAC, PC], None, "close all the windows")[0] is MAC


def test_mac_mention_wins_over_pc_words():
    assert mac.pick_computer([MAC, PC], None, "on my mac, open the photo of my PC build")[0] is MAC


def test_gate_does_not_take_plural_windows_as_a_computer():
    assert not mac_browser_gate.explicit_mac_request("there is dirt in my windows")   # old pattern took this as a computer
