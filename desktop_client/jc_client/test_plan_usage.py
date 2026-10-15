"""Codex plan usage: `codex app-server` speaks JSON-RPC on stdio; the limits
come back from `account/rateLimits/read` (what Codex's own /status shows).
After coucou's CodexPlanGauge (github.com/Louis-CFM/coucou, MIT)."""
import os
import stat
import textwrap

from jc_client import plan_usage as pu

RESULT = {"rateLimits": {
    "planType": "plus",
    "primary": {"usedPercent": 42.5, "resetsAt": 2_000_000_000, "windowDurationMins": 300},
    "secondary": {"usedPercent": 130, "resetsAt": 2_000_500_000, "windowDurationMins": 10080},
}}


def test_parse_sorts_windows_by_length_and_clamps():
    u = pu.parse_codex(RESULT)
    assert u["five_hour"] == {"used_percentage": 42.5, "resets_at": 2_000_000_000}
    assert u["seven_day"] == {"used_percentage": 100, "resets_at": 2_000_500_000}
    assert u["plan"] == "plus"


def test_parse_handles_swapped_and_missing_windows():
    swapped = {"rateLimits": {"primary": {"usedPercent": 5, "resetsAt": 9, "windowDurationMins": 10080},
                              "secondary": {"usedPercent": 7, "resetsAt": 8, "windowDurationMins": 300}}}
    u = pu.parse_codex(swapped)
    assert u["five_hour"]["used_percentage"] == 7 and u["seven_day"]["used_percentage"] == 5
    assert pu.parse_codex({"rateLimits": {}}) is None
    assert pu.parse_codex({}) is None
    assert pu.parse_codex({"rateLimits": {"primary": {"usedPercent": "x"}}}) is None


def _fake_codex(tmp_path, body):
    path = tmp_path / "codex"
    path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(body))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return str(path)


def test_read_talks_json_rpc_to_the_app_server(tmp_path):
    codex = _fake_codex(tmp_path, f'''
        import json, sys
        assert sys.argv[1:] == ["app-server"]
        for line in sys.stdin:
            msg = json.loads(line)
            if msg.get("method") == "initialize":
                print(json.dumps({{"id": msg["id"], "result": {{}}}}), flush=True)
            elif msg.get("method") == "account/rateLimits/read":
                print(json.dumps({{"method": "noise"}}), flush=True)
                print(json.dumps({{"id": msg["id"], "result": {RESULT!r}}}), flush=True)
                break
    ''')
    u = pu.read_codex(codex, timeout=5)
    assert u["five_hour"]["used_percentage"] == 42.5


def test_read_gives_up_on_a_hung_or_missing_codex(tmp_path):
    hung = _fake_codex(tmp_path, '''
        import time
        time.sleep(30)
    ''')
    assert pu.read_codex(hung, timeout=0.5) is None
    assert pu.read_codex(str(tmp_path / "nope"), timeout=0.5) is None


def test_find_codex_looks_in_the_usual_places(tmp_path):
    bin_dir = tmp_path / ".local" / "bin"
    bin_dir.mkdir(parents=True)
    exe = bin_dir / "codex"
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    assert pu.find_codex(home=str(tmp_path), path_env="") == str(exe)
    assert pu.find_codex(home=str(tmp_path / "empty"), path_env="") is None


def test_poller_reports_only_real_readings():
    got = []
    readings = iter([None, {"seven_day": {"used_percentage": 1, "resets_at": 5}}])
    p = pu.CodexPoller(got.append, find=lambda: "/x/codex", read=lambda c: next(readings))
    assert p.poll_once() is False and got == []
    assert p.poll_once() is True and got[0]["seven_day"]["used_percentage"] == 1
    none = pu.CodexPoller(got.append, find=lambda: None, read=lambda c: 1 / 0)
    assert none.poll_once() is False


def test_service_sends_codex_usage_up_and_to_the_app():
    from jc_client import service
    svc = service.Service()
    sent, ui = [], []
    svc._forward_up = sent.append

    class Ui:
        def broadcast(self, m):
            ui.append(m)

    svc._ui = Ui()
    svc._codex_usage({"seven_day": {"used_percentage": 9, "resets_at": 5}, "plan": "plus"})
    data = sent[0]["data"]
    assert sent[0]["name"] == "agent_hook"
    assert (data["kind"], data["agent"]) == ("statusline", "codex")
    assert data["payload"]["rate_limits"]["seven_day"]["used_percentage"] == 9
    assert data["payload"]["plan"] == "plus"
    assert ui[0]["type"] == "usage" and ui[0]["agent"] == "codex"
