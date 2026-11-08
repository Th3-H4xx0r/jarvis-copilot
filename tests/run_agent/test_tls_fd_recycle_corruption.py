"""Regressions for issue #29507 — cross-thread close of the per-request OpenAI
client could release a TLS socket FD whose integer was still cached in the
owning httpx worker's SSL BIO. The kernel then recycled the FD into the next
``open()`` (e.g. the kanban dispatcher's ``kanban.db``), and the worker's
delayed TLS flush wrote a 24-byte TLS application-data record on top of the
SQLite header.

The fix has two prongs:

1. ``force_close_tcp_sockets`` no longer calls ``sock.close()`` — only
   ``shutdown(SHUT_RDWR)``. Shutdown unblocks the worker's pending
   ``recv``/``send`` without releasing the FD.

2. ``_RequestClientSlot.close_once`` is thread-aware: a stranger thread (the
   interrupt-check / stale-call loop) only aborts the sockets and leaves
   the client in the slot; the worker's own ``finally`` performs the
   actual ``client.close()`` from its own thread context.

Both prongs together close the FD-recycling window. The tests below pin
each prong individually and one end-to-end test simulates the reporter's
timeline at object granularity (no network, no real sockets).
"""
from __future__ import annotations

import logging
import socket as _socket
import threading
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Prong 1: force_close_tcp_sockets must NOT release file descriptors.
# ---------------------------------------------------------------------------


class _FakeSocket:
    """Records shutdown/close calls without touching real FDs."""

    def __init__(self):
        self.shutdown_calls = 0
        self.close_calls = 0

    def shutdown(self, _how):
        self.shutdown_calls += 1

    def close(self):
        self.close_calls += 1


def _build_fake_client(sock):
    """Mimic the httpcore-1 layout that ``_iter_pool_sockets`` walks."""
    stream = SimpleNamespace(_sock=sock)
    http11 = SimpleNamespace(_network_stream=stream)
    pool_entry = SimpleNamespace(_connection=http11)
    pool = SimpleNamespace(_connections=[pool_entry])
    transport = SimpleNamespace(_pool=pool)
    http_client = SimpleNamespace(_transport=transport)
    return SimpleNamespace(_client=http_client)


def test_force_close_tcp_sockets_shutdown_only_no_close():
    """The smoking-gun guarantee: shutdown is called, close is NOT.

    If a future refactor reintroduces ``sock.close()`` here, the
    FD-recycling race that corrupted ``kanban.db`` (issue #29507) will
    re-open. Pin the contract explicitly.
    """
    from agent.agent_runtime_helpers import force_close_tcp_sockets

    sock = _FakeSocket()
    client = _build_fake_client(sock)

    n = force_close_tcp_sockets(client)

    assert n == 1
    assert sock.shutdown_calls == 1, "shutdown() must run — it's how we unblock the worker"
    assert sock.close_calls == 0, (
        "close() must NOT run from this helper — releasing the FD here is the "
        "race that wrote TLS bytes into kanban.db (#29507)"
    )


def test_force_close_tcp_sockets_uses_shut_rdwr():
    """Both directions must be shut down so the SSL state machine fully unwinds.

    Half-close (e.g. SHUT_WR only) wouldn't unblock a worker blocked in
    ``recv``, defeating the whole point of the helper.
    """
    from agent.agent_runtime_helpers import force_close_tcp_sockets

    captured = []

    class _ProbingSocket:
        def shutdown(self, how):
            captured.append(how)

        def close(self):  # pragma: no cover — must not run, asserted below
            captured.append("CLOSE_CALLED")

    sock = _ProbingSocket()
    client = _build_fake_client(sock)

    force_close_tcp_sockets(client)

    assert captured == [_socket.SHUT_RDWR]


def test_force_close_tcp_sockets_swallows_oserror_on_shutdown():
    """A socket already shut down / not connected raises ``OSError`` — benign."""
    from agent.agent_runtime_helpers import force_close_tcp_sockets

    class _AlreadyShut:
        def shutdown(self, _how):
            raise OSError("not connected")

        def close(self):  # pragma: no cover — must not run
            raise AssertionError("close() must not be called")

    client = _build_fake_client(_AlreadyShut())

    # No exception escapes; the helper still counts the socket as handled.
    assert force_close_tcp_sockets(client) == 1


def test_force_close_tcp_sockets_handles_multiple_pool_entries():
    """Walk every pool connection — the bug equally applies to all of them."""
    from agent.agent_runtime_helpers import force_close_tcp_sockets

    socks = [_FakeSocket(), _FakeSocket(), _FakeSocket()]
    entries = [
        SimpleNamespace(_connection=SimpleNamespace(_network_stream=SimpleNamespace(_sock=s)))
        for s in socks
    ]
    pool = SimpleNamespace(_connections=entries)
    transport = SimpleNamespace(_pool=pool)
    http_client = SimpleNamespace(_transport=transport)
    client = SimpleNamespace(_client=http_client)

    assert force_close_tcp_sockets(client) == 3
    for s in socks:
        assert s.shutdown_calls == 1
        assert s.close_calls == 0


# ---------------------------------------------------------------------------
# Prong 2: _RequestClientSlot.close_once is thread-aware.
# ---------------------------------------------------------------------------


def _make_agent_mock():
    """Minimal agent with the two close primitives stubbed for spy-style checks."""
    agent = MagicMock()
    agent._interrupt_requested = False
    agent._close_request_openai_client = MagicMock()
    agent._abort_request_openai_client = MagicMock()
    return agent


def _call_inside_owner_thread(callable_):
    """Run callable_ on a separate thread so its ``threading.get_ident()``
    differs from the test thread."""
    result = {"value": None, "exc": None}

    def runner():
        try:
            result["value"] = callable_()
        except BaseException as e:  # noqa: BLE001 — propagate test failures faithfully
            result["exc"] = e

    t = threading.Thread(target=runner)
    t.start()
    t.join(timeout=5.0)
    if result["exc"] is not None:
        raise result["exc"]
    return result["value"]


def test_close_from_stranger_thread_aborts_only_no_close():
    """Stranger-thread close → ``_abort_request_openai_client``, slot kept.

    Reproduces the asyncio_0 → Thread-1616 interrupt path. After this call
    the worker's eventual ``finally`` must still see the client in the
    slot so IT can be the one releasing the FD.
    """
    from agent.chat_completion_helpers import _RequestClientSlot

    agent = _make_agent_mock()
    slot = _RequestClientSlot(agent)
    sentinel = object()
    owner_tid = _call_inside_owner_thread(
        lambda: (slot.set(sentinel), threading.get_ident())[1]
    )

    slot.close_once("interrupt_abort")

    agent._abort_request_openai_client.assert_called_once_with(sentinel, reason="interrupt_abort")
    agent._close_request_openai_client.assert_not_called()
    assert slot.client is sentinel
    assert slot.owner_tid == owner_tid


def test_close_from_owner_thread_pops_and_full_close():
    """Worker-thread close → ``_close_request_openai_client``, slot emptied."""
    from agent.chat_completion_helpers import _RequestClientSlot

    agent = _make_agent_mock()
    slot = _RequestClientSlot(agent)
    sentinel = object()

    def workload():
        slot.set(sentinel)
        slot.close_once("request_complete")

    _call_inside_owner_thread(workload)

    agent._close_request_openai_client.assert_called_once_with(sentinel, reason="request_complete")
    agent._abort_request_openai_client.assert_not_called()
    assert slot.client is None
    assert slot.owner_tid is None


def test_stranger_then_owner_close_sequence_runs_full_close_exactly_once():
    """Stranger abort followed by owner close → full close runs once.

    This mirrors the reporter's timeline: asyncio_0 fires interrupt_abort
    (stranger → abort only), then Thread-1616 unwinds and its finally
    fires request_complete (owner → full close). Net result must be one
    abort + one full close, with the slot ending empty.
    """
    from agent.chat_completion_helpers import _RequestClientSlot

    agent = _make_agent_mock()
    slot = _RequestClientSlot(agent)
    sentinel = object()
    client_set = threading.Event()
    stranger_done = threading.Event()

    def owner_workload():
        slot.set(sentinel)
        client_set.set()
        stranger_done.wait(timeout=2.0)
        # Worker unwinds — its finally calls close once.
        slot.close_once("request_complete")

    owner = threading.Thread(target=owner_workload)
    owner.start()
    assert client_set.wait(timeout=2.0)
    # Test thread plays the stranger.
    slot.close_once("interrupt_abort")
    stranger_done.set()
    owner.join(timeout=5.0)

    assert not owner.is_alive(), "owner thread hung past join timeout"
    assert agent._abort_request_openai_client.call_count == 1
    assert agent._close_request_openai_client.call_count == 1
    assert slot.client is None
    assert slot.owner_tid is None
    # A late close after the slot is empty is a no-op.
    slot.close_once("request_complete")
    assert agent._close_request_openai_client.call_count == 1


# ---------------------------------------------------------------------------
# End-to-end: the agent's ``_abort_request_openai_client`` shuts sockets and
# logs deferred_close=stranger_thread without ever calling client.close().
# ---------------------------------------------------------------------------


def test_agent_abort_request_openai_client_does_not_call_client_close(caplog):
    """``_abort_request_openai_client`` must shutdown sockets but NEVER close().

    This is the actual entry point used by the stranger-thread path. If a
    future refactor accidentally wires it back to ``_close_openai_client``
    the FD race is back. Pin both the shutdown side-effect AND the absence
    of any ``client.close()`` call.
    """
    from run_agent import AIAgent

    sock = _FakeSocket()
    client = _build_fake_client(sock)

    # ``client.close()`` would mutate the holder if invoked — give it a
    # MagicMock spy so we can assert no call.
    client.close = MagicMock()

    agent = AIAgent.__new__(AIAgent)
    agent._client_log_context = lambda: "provider=test"

    with caplog.at_level(logging.INFO, logger="run_agent"):
        agent._abort_request_openai_client(client, reason="interrupt_abort")

    # Sockets shut down (one in our fake pool).
    assert sock.shutdown_calls == 1
    assert sock.close_calls == 0
    # And critically: client.close() never ran here.
    client.close.assert_not_called()

    # The log line is parseable: same ``tcp_force_closed=N`` field shape as
    # the existing ``close`` log so dashboards keep working, plus a
    # ``deferred_close=stranger_thread`` marker to make the new path
    # observable in production triage.
    msgs = [r.getMessage() for r in caplog.records]
    assert any(
        "OpenAI client aborted (interrupt_abort" in m
        and "tcp_force_closed=1" in m
        and "deferred_close=stranger_thread" in m
        for m in msgs
    ), f"missing abort log line; got: {msgs!r}"


def test_agent_abort_request_openai_client_null_client_is_noop():
    """A ``None`` client must short-circuit cleanly (defensive)."""
    from run_agent import AIAgent

    agent = AIAgent.__new__(AIAgent)
    agent._client_log_context = lambda: "provider=test"

    # No exception, no side effect.
    agent._abort_request_openai_client(None, reason="interrupt_abort")


# ---------------------------------------------------------------------------
# FD-recycling proof: when shutdown-only is honored, a stranger-thread abort
# CANNOT release an FD that the owning thread still references.
# ---------------------------------------------------------------------------


def test_fd_recycle_window_closed_by_shutdown_only():
    """Construct the exact race the reporter saw — abort from a stranger
    thread, then have the (simulated) kernel recycle the FD into a new file.
    With the fix, the worker's surviving socket reference cannot be
    confused with the recycled file descriptor.
    """
    from agent.agent_runtime_helpers import force_close_tcp_sockets

    # Tracks "was the FD released by the abort path?" — that is the only
    # signal the kernel needs to recycle the integer to a new ``open()``.
    fd_released = {"yes": False}

    class _OwnedSocket:
        """Simulates a socket whose FD is shared with the owner's SSL BIO.

        ``close`` flips ``fd_released`` so the test can assert that with
        the fix the abort path NEVER releases the FD (and therefore the
        kernel never recycles it under the owner's still-active reference).
        """

        def __init__(self):
            self.shutdowns = 0

        def shutdown(self, _how):
            self.shutdowns += 1

        def close(self):
            fd_released["yes"] = True

    sock = _OwnedSocket()
    client = _build_fake_client(sock)

    # Stranger thread runs the abort sweep (== what asyncio_0 did in the
    # reporter's session).
    _call_inside_owner_thread(lambda: force_close_tcp_sockets(client))

    assert sock.shutdowns == 1, "shutdown must wake the worker"
    assert fd_released["yes"] is False, (
        "force_close_tcp_sockets released the FD from a stranger thread — "
        "this is exactly the #29507 race. The owner thread must own close()."
    )
