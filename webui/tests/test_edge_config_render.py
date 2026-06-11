"""Tests for the edge nginx config renderer (webui/edge/config_render.py).

Regression coverage for the voice "Request failed (500)" bug: nginx started as
root drops its worker processes to a built-in unprivileged user that cannot
traverse the root-owned edge dir (~/.jarviscopilot/edge, mode 700), so it fails
to write request-body temp files (client_body_temp) with EACCES and 500s any
POST big enough to spill to disk — e.g. the voice audio upload — before the
request ever reaches the app. The renderer must pin nginx workers to the user
that owns the edge dir when running as root.
"""
import pathlib
import sys
from unittest import mock

# Defensive: make `edge` importable when run outside the webui pytest rootdir.
_WEBUI_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(_WEBUI_DIR) not in sys.path:
    sys.path.insert(0, str(_WEBUI_DIR))

from edge import config_render  # noqa: E402

_SETTINGS = {
    "domain": "jarvis.pkrishna.dev",
    "routes": {"@": "https://127.0.0.1:8787"},
}


def _render(extra=None):
    s = dict(_SETTINGS)
    if extra:
        s.update(extra)
    return config_render.render_nginx(s)


def test_explicit_worker_user_is_emitted_in_main_context():
    conf = _render({"nginx_worker_user": "root"})
    assert "user root;" in conf
    # Must be in the main context — before the events/http blocks and before
    # worker_processes (nginx rejects `user` anywhere else).
    assert conf.index("user root;") < conf.index("worker_processes")
    assert conf.index("user root;") < conf.index("events {")
    assert conf.index("user root;") < conf.index("http {")


def test_worker_user_pinned_when_running_as_root():
    # Simulate running as root with no explicit override.
    with mock.patch.object(config_render.os, "geteuid", return_value=0, create=True), \
         mock.patch("pwd.getpwuid") as gp:
        gp.return_value = mock.Mock(pw_name="root")
        conf = _render()
    assert "user root;" in conf


def test_no_worker_user_when_non_root():
    # Non-root master: nginx ignores `user` (workers already run as the
    # launching/owning user), so we must NOT emit it (avoids a startup warning).
    with mock.patch.object(config_render.os, "geteuid", return_value=1000, create=True):
        conf = _render()
    # No bare `user <name>;` main-context directive.
    assert "\nuser " not in conf
    assert not conf.startswith("user ")


def test_renderer_still_emits_core_proxy_block():
    # Guard against the fix accidentally breaking the rest of the config.
    conf = _render({"nginx_worker_user": "root"})
    assert "proxy_pass https://127.0.0.1:8787;" in conf
    assert "client_max_body_size 64m;" in conf
    assert "server_name jarvis.pkrishna.dev;" in conf


def test_renderer_emits_low_latency_streaming_directives():
    # The voice WS + ndjson/SSE streams need an unbuffered, keep-alive,
    # no-idle-stall proxy path, or voice reads as "slow / never responds"
    # (request buffering delays the upload; a held final WS frame stalls the
    # stream). Regression guard for the 2026-06-11 voice latency work.
    conf = _render()
    for directive in (
        "proxy_buffering off;",
        "proxy_request_buffering off;",
        "proxy_send_timeout 3600s;",
        "proxy_socket_keepalive on;",
        "tcp_nodelay on;",
    ):
        assert directive in conf, f"missing edge directive: {directive!r}"
