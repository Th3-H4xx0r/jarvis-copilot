"""The reconnect backoff, which is what keeps a bad day from becoming a storm.

A connection that dies the instant it opens is not a healthy one: the server
evicted us because another client claimed the same device identity. Treating
that as success — resetting the backoff — is what turned one duplicate into
forty-five reconnects a minute.
"""
from __future__ import annotations

from jc_client import service


def test_a_connection_has_to_last_to_count_as_healthy():
    assert service._STABLE_SECONDS >= 10, "a second or two is not a healthy connection"


def test_the_backoff_climbs_and_is_bounded():
    assert service._BACKOFF_SECONDS[0] <= 2, "reconnect promptly the first time"
    assert service._BACKOFF_SECONDS == sorted(service._BACKOFF_SECONDS)
    assert service._BACKOFF_SECONDS[-1] >= 30, "and give up hammering eventually"


def test_the_reset_is_gated_on_how_long_the_connection_lived():
    """Read the loop itself: the reset must sit behind the duration check."""
    import inspect

    body = inspect.getsource(service.Service.run)
    assert "_STABLE_SECONDS" in body, "the run loop must consult the stability floor"
    gated = body.index("if lived >= _STABLE_SECONDS")
    reset = body.index("backoff_idx = 0", gated)
    assert reset > gated, "backoff_idx must only be cleared inside that branch"
