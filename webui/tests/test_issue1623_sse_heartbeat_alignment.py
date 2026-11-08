"""Tests for #1623: SSE app heartbeat must fire well under the kernel keepalive timeout.

Bug shape: server.py's per-connection TCP keepalive (added v0.50.289 / #1581)
declares a peer dead at KEEPIDLE=10s + KEEPINTVL=5s * KEEPCNT=3 = 25s. The
SSE handlers in api/routes.py used a 30s app-level heartbeat. When the LLM
is thinking and the queue is idle, the kernel could tear down the socket
before the app sent its first heartbeat byte — flaky-network drops at ~10s
that the user perceived as "the stream died around 10 seconds in."

Fix: lower the heartbeat to 5s at every SSE handler and pin the inequality
with a regression test so future tuning of either timer can't re-introduce
the misalignment.
"""

from pathlib import Path


REPO = Path(__file__).parent.parent


def test_sse_heartbeat_constant_below_kernel_keepalive_window():
    """The SSE heartbeat is at most half the kernel keepalive timeout
    (10 + 5*3 = 25s). 5s gives the kernel ~5x headroom."""
    import re
    from api import sse
    heartbeat = sse.HEARTBEAT_SECONDS

    # Reproduce the kernel-keepalive window from server.py setsockopt block.
    server_src = (REPO / "server.py").read_text(encoding="utf-8")
    assert "TCP_KEEPIDLE" in server_src, "TCP_KEEPIDLE must be set on accepted connections"
    keepidle = int(re.search(r"TCP_KEEPIDLE.*?(\d+)\)", server_src, re.S).group(1))
    keepintvl = int(re.search(r"TCP_KEEPINTVL.*?(\d+)\)", server_src, re.S).group(1))
    keepcnt = int(re.search(r"TCP_KEEPCNT.*?(\d+)\)", server_src, re.S).group(1))
    kernel_window = keepidle + keepintvl * keepcnt

    assert heartbeat * 2 <= kernel_window, (
        f"App SSE heartbeat ({heartbeat}s) must be at most half of the kernel "
        f"keepalive window ({kernel_window}s = {keepidle} + {keepintvl}*{keepcnt}). "
        f"Otherwise flaky-network probes can tear down the socket before the "
        f"app sends a heartbeat byte. (#1623)"
    )


def test_no_sse_handler_uses_30s_or_higher_timeout():
    """No SSE/long-poll handler should poll its queue with the old 25/30s timeout."""
    import re
    for path in (REPO / "api").glob("*.py"):
        bad = re.findall(r"\.get\(timeout=3[05]\)", path.read_text(encoding="utf-8"))
        assert not bad, f"{path.name}: {len(bad)} queue poll(s) still use a 25/30s timeout (#1623)"
