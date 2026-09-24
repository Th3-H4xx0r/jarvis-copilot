"""A new chat can be started from any page.

The + lived only in the Chat sidebar's header, so on every other page (Live,
Settings, …) and with that sidebar collapsed there was no way to start a chat
but Cmd+K. The rail (desktop) and the title bar (mobile) now carry one too.
"""
import pathlib
import re

_STATIC = pathlib.Path(__file__).resolve().parent.parent / "static"
INDEX = (_STATIC / "index.html").read_text(encoding="utf-8")
BOOT = (_STATIC / "boot.js").read_text(encoding="utf-8")


def _block(src, start, end):
    i = src.index(start)
    return src[i:src.index(end, i)]


def test_rail_has_a_new_chat_button():
    assert 'onclick="startNewChat()"' in _block(INDEX, '<nav class="rail"', "</nav>")


def test_titlebar_has_a_new_chat_button():
    assert 'onclick="startNewChat()"' in _block(INDEX, '<header class="app-titlebar"', "</header>")


def test_start_new_chat_goes_to_chat_then_uses_the_plus():
    body = _block(BOOT, "async function startNewChat", "\n}\n")
    assert re.search(r"switchPanel\('chat'", body)
    assert "$('btnNewChat').click()" in body
