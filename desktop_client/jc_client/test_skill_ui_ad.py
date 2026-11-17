"""agent-desktop snapshots → today's numbered look; its dispositions → whether a move landed."""
from __future__ import annotations

from jc_client.skills import ui_ad


def _b(x, y, w=40, h=20):
    return {"x": x, "y": y, "width": w, "height": h}


WINDOW = {"ok": True, "data": {
    "app": "Code", "complete": True, "ref_count": 4, "snapshot_id": "s1",
    "window": {"id": "w-1", "title": "Welcome", "bounds": _b(100, 50, 800, 600)},
    "tree": {"role": "window", "name": "Welcome", "children": [
        {"role": "button", "name": "Run", "ref_id": "@s1:e1", "bounds": _b(110, 60)},
        {"role": "statictext", "name": "Recent projects"},
        {"role": "textfield", "name": "", "value": "search", "ref_id": "@s1:e2", "bounds": _b(200, 60, 200, 24)},
        {"role": "group", "children": [
            {"role": "tab", "name": "Explorer", "ref_id": "@s1:e3", "bounds": _b(110, 100)},
            {"role": "link", "name": "Open folder", "ref_id": "@s1:e4", "bounds": _b(300, 300)},
        ]},
    ]}}}

MENUBAR = {"ok": True, "data": {
    "app": "Finder", "complete": True, "ref_count": 4, "snapshot_id": "s2",
    "tree": {"role": "menu", "bounds": _b(0, 0, 1512, 30), "children": [
        {"role": "menuitem", "name": "File", "ref_id": "@s2:e1", "bounds": _b(60, 0, 40, 30), "children": [
            {"role": "menu", "name": "File", "bounds": _b(0, 0, 0, 0), "children": [
                {"role": "menuitem", "name": "New Folder", "ref_id": "@s2:e2", "bounds": _b(0, 0, 0, 0)},
                {"role": "menuitem", "name": None, "ref_id": "@s2:e3", "bounds": _b(0, 0, 0, 0)},
            ]}]},
        {"role": "menuitem", "name": "Edit", "ref_id": "@s2:e4", "bounds": _b(110, 0, 40, 30)},
    ]}}}


class Client:
    def __init__(self, *replies, cli=None):
        self.replies = list(replies)
        self.calls = []
        self.cli_calls = []
        self._cli = cli

    def call(self, tool, args, timeout=8.0):
        self.calls.append((tool, args))
        return self.replies.pop(0)

    def cli(self, args, timeout=8.0):
        self.cli_calls.append(args)
        return self._cli


def test_flatten_numbers_refs_and_maps_roles():
    elements, texts = ui_ad.flatten(WINDOW["data"])
    assert [e["adref"] for e in elements] == ["@s1:e1", "@s1:e2", "@s1:e3", "@s1:e4"]
    assert [e["role"] for e in elements] == ["AXButton", "AXTextField", "AXRadioButton", "AXLink"]
    assert [e["kind"] for e in elements] == ["button", "textfield", "tab", "link"]
    assert elements[0]["label"] == "Run" and elements[1]["label"] == "search"
    assert elements[0]["pt"] == (110, 60, 40, 20)
    assert "Recent projects" in texts


def test_flatten_labels_menu_items_with_path():
    elements, _ = ui_ad.flatten(MENUBAR["data"])
    assert [e["label"] for e in elements] == ["File", "File › New Folder", "Edit"]  # separator skipped


def test_flatten_caps_elements():
    many = {"tree": {"role": "window", "children": [
        {"role": "button", "name": f"b{i}", "ref_id": f"@s:e{i}", "bounds": _b(i, 0)} for i in range(500)]}}
    elements, _ = ui_ad.flatten(many)
    assert len(elements) == 400


def test_landed_mapping():
    verified = {"ok": True, "data": {"disposition": {"delivery": "delivered_verified", "retry": "unsafe"}}}
    unverified = {"ok": True, "data": {"disposition": {"delivery": "delivered_unverified", "retry": "unsafe"}}}
    refused = {"ok": False, "error": {"code": "POLICY_DENIED", "disposition": {"delivery": "not_delivered"}}}
    other = {"ok": False, "error": {"code": "TIMEOUT", "disposition": {"delivery": "delivered_unverified"}}}
    assert [ui_ad.landed(e) for e in (verified, unverified, refused, other)] == ["yes", "unknown", "no", "unknown"]


def test_read_window_look():
    client = Client(WINDOW)
    out = ui_ad.read(client, app="Code", surface=None)
    assert out["ok"] and out["title"] == "Welcome" and out["frame"] == (100, 50, 800, 600)
    assert out["snapshot_id"] == "s1" and len(out["elements"]) == 4
    tool, args = client.calls[0]
    assert tool == "desktop_snapshot"
    assert args == {"app": "Code", "interactive_only": True, "compact": True, "include_bounds": True,
                    "timeout_ms": 5000}


def test_read_surface_frame_from_elements():
    out = ui_ad.read(Client(MENUBAR), app="Finder", surface="menubar")
    # The surface's own bounds (live: menu items' boxes spread over 2000 px, so never their union).
    assert out["frame"] == (0, 0, 1512, 30)


def test_read_oversize_reports_too_big():
    client = Client({"ok": False, "error": {"code": "INTERNAL", "message": "RefMap exceeds 1MB size limit on write"}})
    out = ui_ad.read(client, app="Activity Monitor", surface=None)
    assert out["ok"] is False and out["code"] == "TOO_BIG" and len(client.calls) == 1


def test_read_notifications_is_text_only():
    listed = {"ok": True, "data": [{"app": "Messages", "title": "Mum", "body": "Call me"}]}
    client = Client(cli=listed)
    out = ui_ad.read(client, app=None, surface="notifications", headed_ok=True)
    assert out["ok"] and out["elements"] == [] and "Messages: Mum — Call me" in out["texts"]
    assert client.cli_calls == [["--headed", "list-notifications", "--limit", "10"]]


def test_read_notifications_needs_his_ok_to_open():
    client = Client({"ok": False, "error": {"code": "POLICY_DENIED", "message": "Notification Center is closed"}})
    out = ui_ad.read(client, app=None, surface="notifications", headed_ok=False)
    assert out["ok"] is False and client.cli_calls == []


def test_act_click():
    ok = {"ok": True, "data": {"disposition": {"delivery": "delivered_verified"}}}
    client = Client(ok)
    out = ui_ad.act(client, "@s1:e1", "click")
    assert out == {"ok": True, "did": "click", "via": "agent-desktop", "landed": "yes"}
    assert client.calls == [("desktop_click", {"ref_id": "@s1:e1"})]


def test_act_stale_ref_says_look_again():
    stale = {"ok": False, "error": {"code": "STALE_REF", "message": "gone", "disposition": {"delivery": "not_delivered"}}}
    out = ui_ad.act(Client(stale), "@s1:e1", "click")
    assert out["ok"] is False and out["error"] == "That screen changed; look again." and out["landed"] == "no"


def test_act_fill_never_echoes_text():
    echo = {"ok": False, "error": {"code": "ACTION_FAILED", "message": "could not set hunter2",
                                   "disposition": {"delivery": "not_delivered"}}}
    out = ui_ad.act(Client(echo), "@s1:e2", "fill", text="hunter2")
    assert all("hunter2" not in str(v) for v in out.values())


def test_act_combobox_fill_uses_select():
    client = Client({"ok": True, "data": {"disposition": {"delivery": "delivered_verified"}}})
    ui_ad.act(client, "@s1:e5", "fill", text="Large", role="AXComboBox")
    assert client.calls == [("desktop_select", {"ref_id": "@s1:e5", "value": "Large"})]


def test_act_scroll():
    client = Client({"ok": True, "data": {"disposition": {"delivery": "delivered_unverified"}}})
    out = ui_ad.act(client, "@s1:e1", "scroll", direction="down")
    assert client.calls == [("desktop_scroll", {"ref_id": "@s1:e1", "direction": "down", "amount": 3})]
    assert out["landed"] == "unknown"


def test_act_error_carries_the_code():
    out = ui_ad.act(Client({"ok": False, "error": {"code": "ACTION_NOT_SUPPORTED", "message": "no press"}}),
                    "@s1:e1", "click")
    assert out["ok"] is False and out["code"] == "ACTION_NOT_SUPPORTED"
