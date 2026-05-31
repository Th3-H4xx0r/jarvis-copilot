import base64

import tools.screen_capture as sc


def test_schema_shape():
    assert sc.LOOK_AT_SCREEN_SCHEMA["name"] == "look_at_screen"
    assert "region" in sc.LOOK_AT_SCREEN_SCHEMA["parameters"]["properties"]


def test_handle_returns_multimodal_envelope(monkeypatch):
    png = b"\x89PNG\r\n\x1a\nFAKEPNGDATA"
    monkeypatch.setattr(sc, "capture_png", lambda region=None: png)
    out = sc.handle_look_at_screen({})
    assert isinstance(out, dict) and out["_multimodal"] is True
    parts = out["content"]
    assert parts[0]["type"] == "text"
    assert parts[1]["type"] == "image_url"
    url = parts[1]["image_url"]["url"]
    assert url.startswith("data:image/png;base64,")
    assert base64.b64decode(url.split(",", 1)[1]) == png
    assert "png" in out["text_summary"]


def test_handle_error_when_capture_unavailable(monkeypatch):
    monkeypatch.setattr(sc, "capture_png", lambda region=None: None)
    out = sc.handle_look_at_screen({})
    assert isinstance(out, str) and "unavailable" in out.lower()


def test_region_passed_through(monkeypatch):
    seen = {}

    def fake_capture(region=None):
        seen["region"] = region
        return b"\x89PNGx"

    monkeypatch.setattr(sc, "capture_png", fake_capture)
    sc.handle_look_at_screen({"region": {"x": 0, "y": 0, "width": 100, "height": 50}})
    assert seen["region"] == {"x": 0, "y": 0, "width": 100, "height": 50}


def test_check_returns_bool_tuple():
    ok, reason = sc.check_look_at_screen()
    assert isinstance(ok, bool) and isinstance(reason, str)
