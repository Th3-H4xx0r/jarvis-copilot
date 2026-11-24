"""The bridge must never stay up but silent (live 2026-11-23: after the PC slept, jc-client kept running
but the PC was off Jarvis until someone restarted it by hand). A failed keepalive drops the link so it
reconnects, and as a last resort a link silent for ten minutes exits the process so its supervisor (the
Windows scheduled task, launchd, systemd) starts a fresh one."""
from __future__ import annotations

import os
import threading
import time

import pytest

from jc_client import credentials, service
from jc_client.protocol import WsConnectionClosed


def _wait_for(pred, timeout=3.0):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.01)
    return False


class _DeadWs:
    def __init__(self, exc):
        self.exc, self.closed = exc, False

    def send_text(self, text):
        raise self.exc

    def send_ping(self, payload=b""):
        pass

    def close(self):
        self.closed = True


@pytest.mark.parametrize("exc", [WsConnectionClosed("broken pipe"), RuntimeError("boom")])
def test_a_failed_keepalive_drops_the_link_so_it_reconnects(exc):
    ws, stop = _DeadWs(exc), threading.Event()
    t = threading.Thread(target=service._keepalive, args=(ws, stop, 0.01), daemon=True)
    t.start()
    t.join(2)
    assert not t.is_alive()
    assert ws.closed, "the pinger quit quietly and left the reader blocked on a dead link"


def test_a_stopped_keepalive_closes_nothing():
    ws, stop = _DeadWs(RuntimeError("boom")), threading.Event()
    stop.set()
    service._keepalive(ws, stop, 0.01)
    assert not ws.closed


# ── the last resort: no frame for ten minutes ──

def test_silence_counts_up_to_the_limit_and_a_frame_resets_it():
    t = [1000.0]
    wd = service._SilenceWatchdog(limit=600, tick=30, clock=lambda: t[0])
    for _ in range(19):
        t[0] += 30
        assert wd.tick(True) is False          # 570 s without a frame
    wd.heard()                                 # a frame: a fresh budget
    for _ in range(19):
        t[0] += 30
        assert wd.tick(True) is False
    t[0] += 30
    assert wd.tick(True) is True               # 600 s with nothing at all


def test_a_sleep_or_no_link_expected_starts_a_fresh_budget():
    # The PC's 15-minute timer check-ins wake it for a minute without a link: they mustn't add up.
    t = [1000.0]
    wd = service._SilenceWatchdog(limit=600, tick=30, clock=lambda: t[0])
    for _ in range(15):
        t[0] += 30
        wd.tick(True)                          # 450 s
    t[0] += 3600
    assert wd.tick(True) is False              # the PC slept an hour: not silence, and the budget restarts
    for _ in range(19):
        t[0] += 30
        assert wd.tick(True) is False
    t[0] += 30
    assert wd.tick(False) is False             # not paired / stopping: nothing to hear
    t[0] += 30
    assert wd.tick(True) is False


def test_the_service_exits_when_its_link_stays_silent(monkeypatch, tmp_path):
    pid_file = tmp_path / "jc-client.pid"
    pid_file.write_text(str(os.getpid()))
    monkeypatch.setattr(service.skills, "load_all", lambda **k: None)
    monkeypatch.setattr(service.credentials, "load", lambda: credentials.Credentials(
        server_url="https://jarvis.example.dev", cookie="hermes_session=x", cert_fingerprint="ab"))
    svc = service.Service()
    svc.start_agent_hooks = lambda: None
    svc.stop_agent_hooks = lambda: None
    svc._write_connection_state = lambda state: None
    release = threading.Event()
    svc._connect_and_pump = lambda creds: release.wait(10)     # wedged: connected, but no frame ever comes
    svc._watchdog = service._SilenceWatchdog(limit=0.2, tick=0.02, sleep_gap=5.0)
    exits = []

    def fake_exit(code):
        exits.append((code, pid_file.exists()))
        svc.stop()
        release.set()
    monkeypatch.setattr(service.os, "_exit", fake_exit)
    t = threading.Thread(target=svc.run, kwargs={"pid_file": pid_file}, daemon=True)
    t.start()
    assert _wait_for(lambda: exits), "a silent link must end the process"
    code, pid_file_left = exits[0]
    assert code != 0                           # non-zero: the supervisor restarts it
    assert not pid_file_left                   # or the fresh start says "already running"
    t.join(5)


def test_the_service_keeps_running_while_frames_arrive(monkeypatch, tmp_path):
    monkeypatch.setattr(service.skills, "load_all", lambda **k: None)
    monkeypatch.setattr(service.credentials, "load", lambda: credentials.Credentials(
        server_url="https://jarvis.example.dev", cookie="hermes_session=x", cert_fingerprint="ab"))
    svc = service.Service()
    svc.start_agent_hooks = lambda: None
    svc.stop_agent_hooks = lambda: None
    svc._write_connection_state = lambda state: None

    def pump(creds):
        while not svc._stop.is_set():          # the server's pings keep coming
            svc._watchdog.heard()
            time.sleep(0.01)
    svc._connect_and_pump = pump
    svc._watchdog = service._SilenceWatchdog(limit=0.2, tick=0.02, sleep_gap=5.0)
    exits = []
    monkeypatch.setattr(service.os, "_exit", lambda code: exits.append(code))
    t = threading.Thread(target=svc.run, kwargs={"pid_file": tmp_path / "jc.pid"}, daemon=True)
    t.start()
    time.sleep(0.6)
    svc.stop()
    t.join(5)
    assert exits == []
