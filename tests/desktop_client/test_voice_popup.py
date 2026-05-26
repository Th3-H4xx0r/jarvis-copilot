"""Tests for the desktop voice-orb popup launcher."""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))


def test_build_popup_url_uses_handoff_and_mini_voice():
    from jc_client import voice_popup
    importlib.reload(voice_popup)
    url = voice_popup.build_popup_url("https://hermes:8787", "COOKIEVAL")
    assert url.startswith("https://hermes:8787/api/auth/handoff?")
    assert "session=COOKIEVAL" in url
    # next must be the percent-encoded mini-voice path
    assert "next=%2F%3Fmini%3Dvoice" in url


def test_build_popup_url_strips_trailing_slash():
    from jc_client import voice_popup
    importlib.reload(voice_popup)
    url = voice_popup.build_popup_url("https://hermes:8787/", "C")
    assert url.startswith("https://hermes:8787/api/auth/handoff?")
    assert "https://hermes:8787//" not in url


def test_build_popup_url_encodes_cookie():
    from jc_client import voice_popup
    importlib.reload(voice_popup)
    url = voice_popup.build_popup_url("https://hermes:8787", "a b/c&d")
    # Reserved chars in the cookie must be percent-encoded so they don't break
    # the query (e.g. '&' would otherwise split into a second parameter).
    assert "a b/c&d" not in url
    assert "a%20b%2Fc%26d" in url


def test_run_voice_popup_falls_back_to_browser_without_pywebview(monkeypatch):
    from jc_client import voice_popup
    importlib.reload(voice_popup)

    class Creds:
        server_url = "https://hermes:8787"
        cookie = "C"
        cert_fingerprint = "AB"

        @property
        def paired(self):
            return True

    monkeypatch.setattr(voice_popup.credentials, "load", lambda: Creds())
    monkeypatch.setattr(voice_popup, "_import_webview", lambda: None)
    opened = {}
    monkeypatch.setattr(voice_popup.webbrowser, "open", lambda u: opened.setdefault("url", u))
    voice_popup.run_voice_popup()
    assert "api/auth/handoff" in opened["url"]
    assert "session=C" in opened["url"]


def test_run_voice_popup_noop_when_unpaired(monkeypatch):
    from jc_client import voice_popup
    importlib.reload(voice_popup)

    class Creds:
        server_url = ""
        cookie = ""
        cert_fingerprint = ""

        @property
        def paired(self):
            return False

    monkeypatch.setattr(voice_popup.credentials, "load", lambda: Creds())
    calls = {"webview": 0, "browser": 0}
    monkeypatch.setattr(voice_popup, "_import_webview", lambda: calls.__setitem__("webview", 1))
    monkeypatch.setattr(voice_popup.webbrowser, "open", lambda u: calls.__setitem__("browser", 1))
    voice_popup.run_voice_popup()
    # Unpaired → nothing launched.
    assert calls == {"webview": 0, "browser": 0}
