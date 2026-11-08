"""Tests for the approval SSE (Server-Sent Events) long-connection implementation.

Verifies:
  - SSE subscribe/unsubscribe/notify lifecycle
  - Initial snapshot delivery on connect
  - Instant push when submit_pending() fires
  - Client disconnect triggers unsubscribe cleanup
  - Multiple concurrent subscribers per session
  - Queue overflow (slow subscriber) drops silently
  - Cross-session isolation (notify only reaches matching subscribers)
  - Frontend EventSource / fallback polling patterns
"""

import json
import pathlib
import queue
import re
import sys
import threading
import time
import uuid

REPO_ROOT = pathlib.Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(REPO_ROOT))

MESSAGES_JS = (REPO_ROOT / "static" / "messages.js").read_text(encoding="utf-8")


# ═══════════════════════════════════════════════════════════════════════════════
# 1. The stream itself
# ═══════════════════════════════════════════════════════════════════════════════

class TestApprovalStream:
    """GET /api/approval/stream: the snapshot on connect, each approval as it lands, and
    the subscriber gone once the client is."""

    def setup_method(self):
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()

    def test_snapshot_then_live_approval_then_cleanup_on_disconnect(self):
        from urllib.parse import urlparse
        from api import routes as r

        sid = f"sse-stream-{uuid.uuid4().hex[:8]}"

        class Wire:
            def __init__(self):
                self.chunks = []

            def write(self, data):
                self.chunks.append(data)

            def flush(self):
                # The client goes away right after it gets the approval.
                if any(b"event: approval" in c for c in self.chunks):
                    raise BrokenPipeError()

        class Handler:
            def __init__(self):
                self.wfile = Wire()
                self.headers_sent = {}

            def send_response(self, status):
                self.status = status

            def send_header(self, key, value):
                self.headers_sent[key] = value

            def end_headers(self):
                pass

        handler = Handler()
        worker = threading.Thread(
            target=r._handle_approval_sse_stream,
            args=(handler, urlparse(f"/api/approval/stream?session_id={sid}")), daemon=True)
        worker.start()
        for _ in range(100):
            with r._lock:
                if r._approval_sse_subscribers.get(sid):
                    break
            time.sleep(0.02)
        with r._lock:
            r._approval_sse_notify_locked(sid, {"command": "rm -rf build"}, 1)
        worker.join(5)

        body = b"".join(handler.wfile.chunks).decode()
        assert handler.status == 200
        assert handler.headers_sent["Content-Type"].startswith("text/event-stream")
        assert body.index("event: initial") < body.index("event: approval")
        assert "rm -rf build" in body
        assert not worker.is_alive()
        with r._lock:
            assert sid not in r._approval_sse_subscribers



class TestFrontendSSEImplementation:
    """Verify the frontend JavaScript SSE implementation."""

    def test_eventsource_used(self):
        """Frontend must use EventSource for SSE connection."""
        assert "new EventSource(" in MESSAGES_JS, \
            "startApprovalPolling must create an EventSource for SSE"

    def test_sse_url_matches_backend(self):
        """Frontend SSE URL must match backend approval stream route."""
        assert "api/approval/stream" in MESSAGES_JS, \
            "EventSource must connect to the approval stream endpoint"
        assert "EventSource('/api/approval/stream" not in MESSAGES_JS, \
            "EventSource URL must stay relative for subpath mounts"

    def test_initial_event_listener(self):
        """Frontend must listen for 'initial' SSE events."""
        assert "'initial'" in MESSAGES_JS or '"initial"' in MESSAGES_JS, \
            "Frontend must addEventListener for 'initial' SSE events"

    def test_approval_event_listener(self):
        """Frontend must listen for 'approval' SSE events."""
        assert "'approval'" in MESSAGES_JS or '"approval"' in MESSAGES_JS, \
            "Frontend must addEventListener for 'approval' SSE events"

    def test_onerror_fallback_to_polling(self):
        """onerror must fall back to HTTP polling."""
        assert "_startApprovalFallbackPoll" in MESSAGES_JS, \
            "SSE onerror handler must call _startApprovalFallbackPoll"

    def test_fallback_poll_interval(self):
        """Fallback polling interval must match v0.50.247's 1500ms cadence."""
        assert "1500" in MESSAGES_JS, \
            "Fallback polling interval must be 1500ms to match degraded-mode parity with v0.50.247"

    def test_fallback_closes_eventsource(self):
        """onerror handler must close the EventSource before falling back."""
        # The onerror handler should call es.close()
        assert "es.close()" in MESSAGES_JS, \
            "onerror handler must close the EventSource before falling back"

    def test_stop_closes_eventsource(self):
        """stopApprovalPolling must close EventSource."""
        assert "_approvalEventSource.close()" in MESSAGES_JS, \
            "stopApprovalPolling must close _approvalEventSource"

    def test_health_timer_cleanup(self):
        """stopApprovalPolling must clear the SSE health timer."""
        assert "_approvalSSEHealthTimer" in MESSAGES_JS, \
            "SSE health timer must be tracked and cleared in stopApprovalPolling"


# ═══════════════════════════════════════════════════════════════════════════════
# 2. Unit tests (in-process, no HTTP server)
# ═══════════════════════════════════════════════════════════════════════════════

class TestSSESubscribeUnsubscribe:
    """Test the subscribe/unsubscribe lifecycle."""

    def setup_method(self):
        """Clean SSE subscriber state before each test."""
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()

    def teardown_method(self):
        """Clean up after each test."""
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()

    def test_subscribe_returns_queue(self):
        """_approval_sse_subscribe must return a Queue."""
        from api import routes as r
        sid = f"sse-test-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        assert isinstance(q, queue.Queue), "subscribe must return a queue.Queue"
        # Cleanup
        r._approval_sse_unsubscribe(sid, q)

    def test_subscribe_registers_subscriber(self):
        """After subscribe, the queue must appear in _approval_sse_subscribers."""
        from api import routes as r
        sid = f"sse-reg-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        try:
            with r._lock:
                subs = r._approval_sse_subscribers.get(sid, [])
            assert q in subs, "Subscribed queue must be in the subscribers list"
        finally:
            r._approval_sse_unsubscribe(sid, q)

    def test_unsubscribe_removes_queue(self):
        """After unsubscribe, the queue must not be in the subscribers list."""
        from api import routes as r
        sid = f"sse-unsub-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        r._approval_sse_unsubscribe(sid, q)
        with r._lock:
            subs = r._approval_sse_subscribers.get(sid, [])
        assert q not in subs, "Unsubscribed queue must not be in the list"

    def test_unsubscribe_removes_empty_session_key(self):
        """When the last subscriber is removed, the session key must be cleaned up."""
        from api import routes as r
        sid = f"sse-empty-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        r._approval_sse_unsubscribe(sid, q)
        with r._lock:
            assert sid not in r._approval_sse_subscribers, \
                "Session key must be removed when subscriber list is empty"

    def test_unsubscribe_idempotent(self):
        """Unsubscribing twice must not raise."""
        from api import routes as r
        sid = f"sse-idem-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        r._approval_sse_unsubscribe(sid, q)
        r._approval_sse_unsubscribe(sid, q)  # should not raise

    def test_unsubscribe_unknown_queue_noop(self):
        """Unsubscribing a queue that was never subscribed must not crash."""
        from api import routes as r
        sid = f"sse-noop-{uuid.uuid4().hex[:8]}"
        q = queue.Queue()
        r._approval_sse_unsubscribe(sid, q)  # should not raise


class TestSSENotify:
    """Test the notification mechanism."""

    def setup_method(self):
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()

    def teardown_method(self):
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()

    def test_notify_delivers_payload(self):
        """_approval_sse_notify must put the payload on subscriber queues."""
        from api import routes as r
        sid = f"sse-notify-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        try:
            entry = {"command": "rm -rf /tmp/test", "pattern_key": "delete"}
            r._approval_sse_notify(sid, entry, 1)
            payload = q.get(timeout=1)
            assert payload["pending"]["command"] == "rm -rf /tmp/test"
            assert payload["pending_count"] == 1
        finally:
            r._approval_sse_unsubscribe(sid, q)

    def test_notify_multiple_subscribers(self):
        """All subscribers for a session must receive the notification."""
        from api import routes as r
        sid = f"sse-multi-{uuid.uuid4().hex[:8]}"
        q1 = r._approval_sse_subscribe(sid)
        q2 = r._approval_sse_subscribe(sid)
        q3 = r._approval_sse_subscribe(sid)
        try:
            entry = {"command": "test-cmd"}
            r._approval_sse_notify(sid, entry, 2)
            for q in [q1, q2, q3]:
                payload = q.get(timeout=1)
                assert payload["pending"]["command"] == "test-cmd"
                assert payload["pending_count"] == 2
        finally:
            for q in [q1, q2, q3]:
                r._approval_sse_unsubscribe(sid, q)

    def test_notify_cross_session_isolation(self):
        """Notify for session A must NOT deliver to session B subscribers."""
        from api import routes as r
        sid_a = f"sse-iso-a-{uuid.uuid4().hex[:8]}"
        sid_b = f"sse-iso-b-{uuid.uuid4().hex[:8]}"
        qa = r._approval_sse_subscribe(sid_a)
        qb = r._approval_sse_subscribe(sid_b)
        try:
            entry = {"command": "only-for-a"}
            r._approval_sse_notify(sid_a, entry, 1)
            # qa should have the event
            payload = qa.get(timeout=1)
            assert payload["pending"]["command"] == "only-for-a"
            # qb should be empty
            assert qb.empty(), "Session B subscriber must not receive session A events"
        finally:
            r._approval_sse_unsubscribe(sid_a, qa)
            r._approval_sse_unsubscribe(sid_b, qb)

    def test_notify_no_subscribers_is_noop(self):
        """Notifying a session with no subscribers must not raise."""
        from api import routes as r
        sid = f"sse-nosub-{uuid.uuid4().hex[:8]}"
        r._approval_sse_notify(sid, {"command": "test"}, 1)  # should not raise

    def test_notify_drops_on_full_queue(self):
        """When subscriber queue is full, events must be silently dropped."""
        from api import routes as r
        sid = f"sse-full-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        try:
            # Fill the queue (maxsize=16)
            for i in range(20):
                r._approval_sse_notify(sid, {"command": f"cmd-{i}"}, i + 1)
            # Queue should have at most 16 items
            assert q.qsize() <= 16, "Queue must not exceed maxsize"
            assert q.qsize() > 0, "Queue should have some items"
        finally:
            r._approval_sse_unsubscribe(sid, q)


class TestSSENotifyFromSubmitPending:
    """Test that submit_pending triggers SSE notifications."""

    def setup_method(self):
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()
            r._pending.clear()

    def teardown_method(self):
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()
            r._pending.clear()

    def test_submit_pending_notifies_sse_subscriber(self):
        """submit_pending must push an SSE event to subscribers."""
        from api import routes as r
        sid = f"sse-submit-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        try:
            r.submit_pending(sid, {
                "command": "rm -rf /tmp/test",
                "pattern_key": "recursive delete",
                "pattern_keys": ["recursive delete"],
                "description": "recursive delete",
            })
            payload = q.get(timeout=1)
            assert payload["pending"]["command"] == "rm -rf /tmp/test"
            assert payload["pending_count"] == 1
        finally:
            r._approval_sse_unsubscribe(sid, q)

    def test_submit_pending_delivers_count(self):
        """Multiple submit_pending calls must report correct pending_count."""
        from api import routes as r
        sid = f"sse-count-{uuid.uuid4().hex[:8]}"
        q = r._approval_sse_subscribe(sid)
        try:
            for i in range(3):
                r.submit_pending(sid, {
                    "command": f"cmd-{i}",
                    "pattern_key": f"p{i}",
                    "pattern_keys": [f"p{i}"],
                    "description": f"d{i}",
                })
            for expected_count in [1, 2, 3]:
                payload = q.get(timeout=1)
                assert payload["pending_count"] == expected_count, \
                    f"Expected pending_count={expected_count}, got {payload['pending_count']}"
        finally:
            r._approval_sse_unsubscribe(sid, q)


class TestSSEConcurrency:
    """Test thread safety of SSE subscribe/unsubscribe/notify."""

    def setup_method(self):
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()
            r._pending.clear()

    def teardown_method(self):
        from api import routes as r
        with r._lock:
            r._approval_sse_subscribers.clear()
            r._pending.clear()

    def test_concurrent_subscribe_unsubscribe(self):
        """Concurrent subscribe/unsubscribe must not corrupt state."""
        from api import routes as r
        sid = f"sse-conc-{uuid.uuid4().hex[:8]}"
        errors = []
        queues = []

        def worker():
            try:
                for _ in range(50):
                    q = r._approval_sse_subscribe(sid)
                    queues.append(q)
                    r._approval_sse_unsubscribe(sid, q)
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=worker) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)

        assert not errors, f"Concurrent subscribe/unsubscribe errors: {errors}"
        # After all threads finish, no queues should remain
        with r._lock:
            subs = r._approval_sse_subscribers.get(sid, [])
        assert len(subs) == 0, "All subscribers should be cleaned up"

    def test_concurrent_notify_while_subscribing(self):
        """Notify while new subscribers are joining must not deadlock or crash."""
        from api import routes as r
        sid = f"sse-notsub-{uuid.uuid4().hex[:8]}"
        errors = []

        def notifier():
            try:
                for i in range(100):
                    r._approval_sse_notify(sid, {"command": f"cmd-{i}"}, 1)
            except Exception as e:
                errors.append(e)

        def subscriber():
            try:
                for _ in range(50):
                    q = r._approval_sse_subscribe(sid)
                    time.sleep(0.001)
                    r._approval_sse_unsubscribe(sid, q)
            except Exception as e:
                errors.append(e)

        threads = [
            threading.Thread(target=notifier),
            threading.Thread(target=subscriber),
            threading.Thread(target=subscriber),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=15)

        assert not errors, f"Concurrent notify/subscribe errors: {errors}"
        with r._lock:
            r._approval_sse_subscribers.clear()
