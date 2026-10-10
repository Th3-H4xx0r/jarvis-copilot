"""Inbound ``event`` frames on the device bridge: a board streams data to a server-side handler."""

import os
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from api import device_bridge as db  # noqa: E402


class _FakeSock:
    def shutdown(self, *_a):
        pass

    def close(self):
        pass


def _conn(device_id):
    conn = db._DeviceConn(device_id=device_id, sock=_FakeSock(), conn=None, name="board")
    db._register(conn)
    return conn


def _collector(expected):
    got, done = [], threading.Event()

    def handler(device_id, data):
        got.append((device_id, data))
        if len(got) >= expected:
            done.set()

    return got, done, handler


def test_event_reaches_its_handler_in_order():
    got, done, handler = _collector(2)
    db.on_device_event("test_report", handler)
    conn = _conn("board-1")
    try:
        db._handle_message(conn, {"type": "event", "name": "test_report", "data": {"seq": 1}})
        db._handle_message(conn, {"type": "event", "name": "test_report", "data": {"seq": 2}})
        assert done.wait(2)
        assert got == [("board-1", {"seq": 1}), ("board-1", {"seq": 2})]
    finally:
        db._unregister("board-1")
        db.on_device_event("test_report", None)


def test_unknown_names_and_bad_data_are_ignored():
    got, done, handler = _collector(1)
    db.on_device_event("test_known", handler)
    conn = _conn("board-2")
    try:
        db._handle_message(conn, {"type": "event", "name": "nobody_listens", "data": {}})
        db._handle_message(conn, {"type": "event", "name": "test_known", "data": "not a dict"})
        db._handle_message(conn, {"type": "event", "name": "test_known", "data": {"ok": True}})
        assert done.wait(2)
        assert got == [("board-2", {"ok": True})]
    finally:
        db._unregister("board-2")
        db.on_device_event("test_known", None)


def test_a_raising_handler_does_not_stop_later_events():
    got, done, handler = _collector(1)
    calls = {"n": 0}

    def flaky(device_id, data):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("boom")
        handler(device_id, data)

    db.on_device_event("test_flaky", flaky)
    conn = _conn("board-3")
    try:
        db._handle_message(conn, {"type": "event", "name": "test_flaky", "data": {"n": 1}})
        db._handle_message(conn, {"type": "event", "name": "test_flaky", "data": {"n": 2}})
        assert done.wait(2)
        assert got == [("board-3", {"n": 2})]
    finally:
        db._unregister("board-3")
        db.on_device_event("test_flaky", None)
