"""Tests for the direct chrome_* agent tools (A2 speed path)."""

import json

from tools.registry import discover_builtin_tools, registry

discover_builtin_tools()  # ensure chrome_device_tool is auto-imported + registered

import tools.chrome_device_tool as cdt  # noqa: E402


def test_chrome_tools_registered():
    for n in ("chrome_navigate", "chrome_snapshot", "chrome_click",
              "chrome_type", "chrome_press_key"):
        assert registry.get_entry(n) is not None, f"{n} not registered"


def test_module_is_auto_discovered():
    assert "tools.chrome_device_tool" in discover_builtin_tools()


# ── result unwrapping ────────────────────────────────────────────────────────

def test_extract_snapshot_unwraps_nested_result():
    res = {"ok": True, "result": {"ok": True, "result": "- link x [ref=e1]"}}
    text, err = cdt._extract_snapshot(res)
    assert err is None and text == "- link x [ref=e1]"


def test_extract_snapshot_device_offline():
    text, err = cdt._extract_snapshot({"ok": False, "error": "device did not respond"})
    assert text == "" and "did not respond" in err


def test_extract_snapshot_inner_error():
    text, err = cdt._extract_snapshot({"ok": True, "result": {"ok": False, "error": "boom"}})
    assert text == "" and err == "boom"


def test_truncate_caps_large():
    big = "\n".join(f"- link {i} [ref=e{i}]" for i in range(5000))
    out = cdt._truncate(big)
    assert len(out) <= 8200


# ── call path (device resolution + invoke mocked) ────────────────────────────

def test_chrome_call_no_device(monkeypatch):
    monkeypatch.setattr(cdt, "_resolve_chrome_device", lambda: None)
    out = json.loads(cdt._chrome_call("chrome_navigate", {"url": "x"}))
    assert "error" in out and "paired" in out["error"].lower()


def test_chrome_call_success(monkeypatch):
    monkeypatch.setattr(cdt, "_resolve_chrome_device", lambda: "dev1")
    captured = {}

    def fake_invoke(dev, skill, args):
        captured.update(dev=dev, skill=skill, args=args)
        return {"ok": True, "result": {"ok": True, "result": "- heading 'Houston' [ref=e1]"}}

    monkeypatch.setattr(cdt, "invoke_skill_safe", fake_invoke)
    out = cdt._chrome_call("chrome_navigate", {"url": "https://en.wikipedia.org/wiki/Houston"})
    assert "Houston" in out
    assert captured == {"dev": "dev1", "skill": "chrome_navigate",
                        "args": {"url": "https://en.wikipedia.org/wiki/Houston"}}


def test_handlers_forward_args(monkeypatch):
    calls = []
    monkeypatch.setattr(cdt, "_chrome_call", lambda skill, args: calls.append((skill, args)) or "ok")
    cdt._h_navigate({"url": "u"})
    cdt._h_click({"element": "first", "ref": "e9"})
    cdt._h_type({"element": "box", "ref": "e3", "text": "hi", "submit": True})
    cdt._h_press_key({"key": "Enter"})
    cdt._h_snapshot({})
    assert calls == [
        ("chrome_navigate", {"url": "u"}),
        ("chrome_click", {"element": "first", "ref": "e9"}),
        ("chrome_type", {"element": "box", "ref": "e3", "text": "hi", "submit": True}),
        ("chrome_press_key", {"key": "Enter"}),
        ("chrome_snapshot", {}),
    ]


# ── device resolution + check_fn over the webui REST API ─────────────────────

def test_tools_have_no_check_fn():
    # Always-present (deferred under lazy loading) — no flaky probe-gate.
    for n in ("chrome_navigate", "chrome_click", "chrome_press_key"):
        assert registry.get_entry(n).check_fn is None


def test_resolve_chrome_device_via_rest(monkeypatch):
    def fake_api(method, path, body=None, timeout=10.0):
        assert method == "GET" and path == "/api/devices/skills"
        return {"skills": [
            {"name": "chrome_navigate", "device_id": "mac1", "device_name": "Mac"},
            {"name": "send_sms", "device_id": "phone1"},
        ]}
    monkeypatch.setattr(cdt, "_api_request", fake_api)
    assert cdt._resolve_chrome_device() == "mac1"


def test_resolve_none_when_no_chrome_device(monkeypatch):
    monkeypatch.setattr(cdt, "_api_request",
                        lambda *a, **k: {"skills": [{"name": "send_sms", "device_id": "p"}]})
    assert cdt._resolve_chrome_device() is None


def test_resolve_none_on_api_error(monkeypatch):
    monkeypatch.setattr(cdt, "_api_request", lambda *a, **k: {"_error": "connection refused"})
    assert cdt._resolve_chrome_device() is None


def test_invoke_skill_safe_posts_via_rest(monkeypatch):
    captured = {}

    def fake_api(method, path, body=None, timeout=10.0):
        captured.update(method=method, path=path, body=body)
        return {"ok": True, "result": {"ok": True, "result": "snap"}}

    monkeypatch.setattr(cdt, "_api_request", fake_api)
    out = cdt.invoke_skill_safe("mac1", "chrome_navigate", {"url": "u"})
    assert out["ok"] is True
    assert captured["method"] == "POST" and captured["path"] == "/api/devices/skills/invoke"
    assert captured["body"]["device_id"] == "mac1"
    assert captured["body"]["skill"] == "chrome_navigate"
    assert captured["body"]["args"] == {"url": "u"}


def test_invoke_skill_safe_transport_error(monkeypatch):
    monkeypatch.setattr(cdt, "_api_request", lambda *a, **k: {"_error": "refused"})
    out = cdt.invoke_skill_safe("mac1", "chrome_navigate", {})
    assert out["ok"] is False and "refused" in out["error"]
