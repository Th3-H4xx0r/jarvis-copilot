"""Pod status is pushed only while the phone's Devices tab subscribes, and only when it changed."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from api import device_bridge, pod_watch  # noqa: E402


def setup_function(_fn):
    pod_watch._last.clear()


def _invoker(replies):
    calls = []

    def invoke(device_id, skill, args, timeout=0):
        calls.append((device_id, skill))
        return replies.get(device_id, {"ok": False, "error": "timeout"})

    return invoke, calls


def test_changed_statuses_are_published_once():
    published = []
    invoke, calls = _invoker({"pod-1": {"ok": True, "result": {"rssi": -50, "battery": 80}}})
    publish = lambda topic, data: published.append((topic, data))  # noqa: E731
    pod_watch.poll_once(pods=["pod-1"], invoke=invoke, publish=publish)
    pod_watch.poll_once(pods=["pod-1"], invoke=invoke, publish=publish)
    assert calls == [("pod-1", "pod_status"), ("pod-1", "pod_status")]
    assert published == [("pods", {"statuses": {"pod-1": {"rssi": -50, "battery": 80}}})]


def test_a_pod_that_does_not_answer_publishes_nothing():
    published = []
    invoke, _ = _invoker({})
    pod_watch.poll_once(pods=["pod-2"], invoke=invoke, publish=lambda t, d: published.append((t, d)))
    assert published == []


def test_no_watcher_without_subscribers(monkeypatch):
    monkeypatch.setattr(device_bridge, "subscribers", lambda topic: [])
    assert pod_watch.ensure() is False


def test_the_watcher_starts_once_for_a_subscriber(monkeypatch):
    started = []
    monkeypatch.setattr(device_bridge, "subscribers", lambda topic: ["phone"])
    monkeypatch.setattr(pod_watch.threading, "Thread", lambda **kw: type("T", (), {"start": lambda self: started.append(kw["name"])})())
    monkeypatch.setattr(pod_watch, "_running", False)
    assert pod_watch.ensure() is True
    assert pod_watch.ensure() is False
    assert started == ["pod-watch"]
    pod_watch._running = False


def test_registry_changes_tell_subscribers_the_list_moved(monkeypatch):
    published = []
    monkeypatch.setattr(device_bridge, "publish", lambda topic, data=None, exclude=None: published.append((topic, data)))
    pod_watch._on_registry_change()
    assert published == [("pods", {"what": ["list"]})]
