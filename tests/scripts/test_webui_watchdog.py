"""scripts/webui-watchdog.sh: restart the Jarvis web server when it stops answering (live 2026-11-23: it froze
silently 23:52-23:58 UTC until he rebooted the box; the SSH relay runs through it too)."""
import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "webui-watchdog.sh"


def _stubs(tmp_path, code="000", active="active"):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True)
    log = tmp_path / "calls.log"
    stubs = {
        "curl": f'printf "{code}"',
        "systemctl": f'echo "systemctl $*" >> {log}; case "$1" in is-active) echo {active};; show) echo 4242;; esac',
        "kill": f'echo "kill $*" >> {log}',
        "sleep": "true",
    }
    for name, body in stubs.items():
        p = bin_dir / name
        p.write_text(f"#!/bin/bash\n{body}\n")
        p.chmod(0o755)
    env = dict(os.environ, WATCHDOG_STATE=str(tmp_path / "fails"),
               WATCHDOG_CURL=str(bin_dir / "curl"), WATCHDOG_SYSTEMCTL=str(bin_dir / "systemctl"),
               WATCHDOG_KILL=str(bin_dir / "kill"), WATCHDOG_SLEEP=str(bin_dir / "sleep"))
    return env, log


def _run(env):
    return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)


def _calls(log):
    return log.read_text().splitlines() if log.exists() else []


def test_restarts_after_three_silent_checks_with_a_stack_dump_first(tmp_path):
    env, log = _stubs(tmp_path, code="000")
    for _ in range(2):
        _run(env)
    assert not [c for c in _calls(log) if "restart" in c or c.startswith("kill")]
    _run(env)
    calls = [c for c in _calls(log) if not c.startswith("systemctl is-active")]
    assert calls[-2:] == ["kill -USR1 4242", "systemctl restart jarviscopilot-webui.service"]


def test_an_answer_resets_the_count(tmp_path):
    env, log = _stubs(tmp_path, code="000")
    _run(env)
    _run(env)
    ok_env, _ = _stubs(tmp_path / "ok", code="302")
    ok_env["WATCHDOG_STATE"] = env["WATCHDOG_STATE"]
    _run(ok_env)
    _run(env)
    _run(env)
    assert not [c for c in _calls(log) if "restart" in c]


def test_leaves_a_stopped_server_alone(tmp_path):
    env, log = _stubs(tmp_path, code="000", active="inactive")
    for _ in range(4):
        _run(env)
    assert not [c for c in _calls(log) if "restart" in c or c.startswith("kill")]
