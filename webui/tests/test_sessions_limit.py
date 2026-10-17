"""GET /api/sessions?limit=N returns only the N most recent sessions.

The phone's chat widget only needs the latest chat; the whole list is ~1.1 KB a
chat (660 KB at 578 chats), and it was fetched for every widget refresh.
"""

import json
import time
import urllib.error
import urllib.request

from tests._pytest_port import BASE


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=10) as r:
        return json.loads(r.read())


def post(path, body=None):
    req = urllib.request.Request(BASE + path, data=json.dumps(body or {}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read()), r.status
    except urllib.error.HTTPError as e:
        return json.loads(e.read()), e.code


def _titled_sessions(n):
    ids = []
    for i in range(n):
        made, _ = post("/api/session/new", {})
        sid = made["session"]["session_id"]
        # Untitled empty sessions are hidden from the list.
        post("/api/session/rename", {"session_id": sid, "title": f"test-limit-{i}"})
        ids.append(sid)
        time.sleep(0.05)
    return ids


def test_limit_returns_the_most_recent_sessions_only():
    ids = _titled_sessions(3)
    try:
        full = [s["session_id"] for s in get("/api/sessions")["sessions"]]
        limited = [s["session_id"] for s in get("/api/sessions?limit=2")["sessions"]]
        assert limited == full[:2]
        assert limited[0] == ids[-1]
    finally:
        for sid in ids:
            post("/api/session/delete", {"session_id": sid})


def test_a_missing_or_bad_limit_returns_every_session():
    ids = _titled_sessions(2)
    try:
        full = [s["session_id"] for s in get("/api/sessions")["sessions"]]
        for query in ("?limit=0", "?limit=-1", "?limit=abc", "?limit="):
            assert [s["session_id"] for s in get("/api/sessions" + query)["sessions"]] == full
    finally:
        for sid in ids:
            post("/api/session/delete", {"session_id": sid})
