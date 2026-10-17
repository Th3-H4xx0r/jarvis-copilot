"""Sync turns on by itself for folders Claude/Codex sessions run in — with limits."""
from agent.agent_sync_policy import should_auto_sync

HOME = "/Users/p"


def test_ok():
    assert should_auto_sync({"id": "p1", "sync_enabled": 0}, "/Users/p/code/app",
                            home=HOME, switched_off=set()) == (True, "")


def test_auto_sync_skips_home_and_switched_off():
    assert should_auto_sync({"id": "p1"}, HOME, home=HOME, switched_off=set()) == (False, "home")
    assert should_auto_sync({"id": "p1"}, "/Users/p/code/app", home=HOME,
                            switched_off={"p1"}) == (False, "switched_off")


def test_already_on():
    assert should_auto_sync({"id": "p1", "sync_enabled": 1}, "/Users/p/code/app", home=HOME,
                            switched_off=set()) == (False, "already_on")


def test_unsafe_path_refused():
    assert should_auto_sync({"id": "p1"}, "/", home=HOME, switched_off=set()) == (False, "unsafe")
    assert should_auto_sync({"id": "p1"}, "", home=HOME, switched_off=set()) == (False, "unsafe")
