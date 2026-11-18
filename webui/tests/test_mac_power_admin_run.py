"""admin-run / pc-run approvals (IT agent, W3): relayed like Mac passwords, but the push shows why — never
the command — and a helper failure doesn't push "password not filled"."""
from __future__ import annotations

import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from api.mac_power import MacPowerStore  # noqa: E402

PC = "dev-pc"
CMD = "wsl --install --no-distribution"


def _store(tmp_path, alerts):
    return MacPowerStore(tmp_path / "mac_power.json", alert=lambda t, b, d: alerts.append((t, b, d)),
                         send_frame=lambda d, f: True, connected=lambda: {PC}, clock=lambda: 1000.0,
                         os_of=lambda d: "windows")


def _request(store, kind="admin-run", why="Enable WSL2", rid="r1"):
    store.on_password_request(PC, {"id": rid, "kind": kind, "context": CMD, "why": why, "nonce": "a" * 32,
                                   "created": 1000.0, "expires": 1120.0})


def test_admin_run_request_push_body_is_why_not_command(tmp_path):
    alerts = []
    store = _store(tmp_path, alerts)
    _request(store)
    title, body, data = alerts[0]
    assert title == "Run as admin on your PC" and body == "Enable WSL2"
    assert CMD not in title and CMD not in body and "--install" not in body and data["kind"] == "mac_password"
    _request(store, why="", rid="r2")
    assert alerts[1][1] == "Approve with Face ID"
    _request(store, why="x" * 500, rid="r3")
    assert len(alerts[2][1]) == 120


def test_admin_run_request_carries_why_in_list(tmp_path):
    store = _store(tmp_path, [])
    _request(store, why="y" * 400)
    row = store.list_payload(lambda d: "")["password_requests"][0]
    assert row["kind"] == "admin-run" and row["context"] == CMD and row["why"] == "y" * 300


def test_admin_run_done_sends_no_failure_push(tmp_path):
    alerts = []
    store = _store(tmp_path, alerts)
    _request(store)
    store.on_password_done(PC, {"id": "r1", "ok": False, "error": "The Jarvis helper isn't running"})
    assert len(alerts) == 1


def test_pc_run_kind_is_titled_and_relayed_the_same_way(tmp_path):
    alerts = []
    store = _store(tmp_path, alerts)
    _request(store, kind="pc-run", why="Remove the old Docker (uninstalls software)")
    title, body, _ = alerts[0]
    assert title == "Approve a command on your PC" and body.startswith("Remove the old Docker")
    store.on_password_done(PC, {"id": "r1", "ok": False, "error": "boom"})
    assert len(alerts) == 1
