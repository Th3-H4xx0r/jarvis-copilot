"""Tests for the supervised ``jc-client restart`` launchctl-race fix.

``launchctl load``/``unload`` are NOT synchronous: the job keeps settling after
the command returns. The old restart fired ``unload`` then ``load`` 0.5s later,
so the load often hit a still-tearing-down slot and silently no-op'd — leaving
the service DOWN with nothing to respawn it (the reported "Restart just stops
it" bug). The fix waits for the old job to actually clear before loading, then
verifies the reload took (with one retry).

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_restart.py -q
"""

import types

import pytest

from jc_client import cli


@pytest.fixture(autouse=True)
def _fast_clock(monkeypatch):
    """Drive cli's poll loops on a fake clock so the timeout waits are instant."""
    clock = {"now": 1000.0}
    monkeypatch.setattr(
        cli, "time",
        types.SimpleNamespace(
            time=lambda: clock["now"],
            sleep=lambda s: clock.__setitem__("now", clock["now"] + max(float(s), 0.05)),
        ),
    )


class _Supervisor:
    """Fake launchctl whose ``is_loaded`` reflects ``load``/``unload`` — with an
    optional settle delay (in is_loaded polls) before the new state shows, and an
    optional number of leading ``load`` calls that silently no-op (slot busy)."""

    def __init__(self, *, loaded=True, unload_delay=0, load_delay=0, load_noops=0):
        self.loaded = loaded
        self.unload_delay = unload_delay
        self.load_delay = load_delay
        self.load_noops = load_noops
        self.calls = []
        self._pending = None  # (target_state, polls_until_visible)

    def is_loaded(self):
        if self._pending is not None:
            target, n = self._pending
            if n <= 0:
                self.loaded = target
                self._pending = None
            else:
                self._pending = (target, n - 1)
        return self.loaded

    def unload(self):
        self.calls.append("unload")
        self._pending = (False, self.unload_delay)

    def load(self):
        self.calls.append("load")
        if self.load_noops > 0:
            self.load_noops -= 1
            return  # simulate a no-op load (the slot was still busy)
        self._pending = (True, self.load_delay)


def _wire(monkeypatch, sup, load=None):
    monkeypatch.setattr(cli, "_supervisor_kind", lambda: "launchctl")
    monkeypatch.setattr(cli, "_supervisor_is_loaded", sup.is_loaded)
    monkeypatch.setattr(cli, "_supervisor_unload", sup.unload)
    monkeypatch.setattr(cli, "_supervisor_load", load or sup.load)


def test_restart_unloads_then_loads_and_succeeds(monkeypatch):
    sup = _Supervisor(loaded=True)
    _wire(monkeypatch, sup)
    rc = cli.cmd_restart(object())
    assert rc == 0
    assert sup.calls[0] == "unload"
    assert "load" in sup.calls
    assert sup.loaded is True


def test_restart_waits_for_unload_before_loading(monkeypatch):
    # The unload takes a couple polls to settle; load must NOT run while the old
    # job is still loaded (that's the silent no-op that drops the service).
    sup = _Supervisor(loaded=True, unload_delay=2)
    seen = []

    def _load():
        seen.append(sup.loaded)  # snapshot the loaded state at load() time
        sup.load()

    _wire(monkeypatch, sup, load=_load)
    rc = cli.cmd_restart(object())
    assert rc == 0
    assert seen and all(state is False for state in seen), (
        "load() ran while the old job was still loaded — the launchctl race"
    )


def test_restart_retries_when_first_load_noops(monkeypatch):
    sup = _Supervisor(loaded=True, load_noops=1)
    _wire(monkeypatch, sup)
    rc = cli.cmd_restart(object())
    assert rc == 0
    assert sup.calls.count("load") >= 2  # retried after the no-op
    assert sup.loaded is True


def test_restart_reports_failure_when_load_never_takes(monkeypatch):
    sup = _Supervisor(loaded=True, load_noops=99)  # every load no-ops
    _wire(monkeypatch, sup)
    rc = cli.cmd_restart(object())
    assert rc == 1
    assert sup.loaded is False
