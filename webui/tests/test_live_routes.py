"""/api/live/* — the phone's live-button push tokens (per device, 0600, never from Jarvis or a board)
and the pushes made from them: control refreshes and the door card's update / end / push-to-start."""
import json
import os
import stat

import pytest

from api import live_routes
from api.live_routes import LiveTokens, handle_live_request

CTRL_A = "a1" * 32
CTRL_B = "b2" * 32
CARD = "c3" * 40
START = "d4" * 40


@pytest.fixture
def tokens(tmp_path):
    clock = [1_000.0]
    store = LiveTokens(tmp_path / "live", clock=lambda: clock[0])
    store.clock_ref = clock
    return store


def call(tokens, path, body, host=False, caller=None, device="phone1"):
    return handle_live_request("POST", path, body, host_signed=host, caller=caller, device_id=device, tokens=tokens)


class Sender:
    def __init__(self, results=None):
        self.sent = []
        self.results = results or {}

    def __call__(self, token, *args, **kw):
        self.sent.append((token, args, kw))
        return self.results.get(token, {"ok": True})


# ── who may register ──

@pytest.mark.parametrize("path, body", [("/control-tokens", {"tokens": [CTRL_A]}),
                                        ("/activity-token", {"source": "door", "token": CARD})])
def test_jarvis_over_the_host_signed_loopback_cannot_register(tokens, path, body):
    status, payload = call(tokens, path, body, host=True)
    assert status == 403 and payload["ok"] is False
    assert tokens.controls() == [] and tokens.activities("door") == []


def test_a_board_cannot_register(tokens):
    status, _ = call(tokens, "/control-tokens", {"tokens": [CTRL_A]}, caller="board")
    assert status == 403
    assert tokens.controls() == []


def test_only_post(tokens):
    status, _ = handle_live_request("GET", "/control-tokens", None, tokens=tokens)
    assert status == 405


def test_unknown_path(tokens):
    status, _ = call(tokens, "/nope", {})
    assert status == 404


# ── control tokens ──

def test_control_tokens_are_stored_per_device_in_a_private_file(tokens):
    assert call(tokens, "/control-tokens", {"tokens": [CTRL_A, CTRL_A.upper()]})[0] == 200
    assert call(tokens, "/control-tokens", {"tokens": [CTRL_B]}, device="phone2")[0] == 200
    assert sorted(tokens.controls()) == [("phone1", CTRL_A), ("phone2", CTRL_B)]   # deduped, lower-cased
    path = tokens.root / "tokens.json"
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    saved = json.loads(path.read_text())
    assert saved["devices"]["phone1"]["controls"] == [CTRL_A]
    # a device's new list replaces its own, never another device's
    call(tokens, "/control-tokens", {"tokens": []})
    assert tokens.controls() == [("phone2", CTRL_B)]
    # survives a restart
    assert LiveTokens(tokens.root).controls() == [("phone2", CTRL_B)]


@pytest.mark.parametrize("body", [{}, {"tokens": "abc"}, {"tokens": ["not hex!"]}, {"tokens": ["ab"]},
                                  {"tokens": ["ab" * 400]}, {"tokens": [5]},
                                  {"tokens": [f"{i:02x}" * 32 for i in range(40)]}])   # too many
def test_bad_control_tokens_are_refused(tokens, body):
    status, _ = call(tokens, "/control-tokens", body)
    assert status == 400
    assert tokens.controls() == []


# ── activity tokens ──

def test_activity_tokens_per_device_and_source_and_forgetting(tokens):
    assert call(tokens, "/activity-token", {"source": "door", "token": CARD})[0] == 200
    assert call(tokens, "/activity-token", {"source": "door-start", "token": START})[0] == 200
    assert [(d, t) for d, t, _ in tokens.activities("door")] == [("phone1", CARD)]
    assert [(d, t) for d, t, _ in tokens.activities("door-start")] == [("phone1", START)]
    assert call(tokens, "/activity-token", {"source": "door-start", "token": ""})[0] == 200   # "" forgets
    assert tokens.activities("door-start") == []
    assert tokens.activities("door")


@pytest.mark.parametrize("body", [{"token": CARD}, {"source": "../x", "token": CARD}, {"source": "door", "token": "zz"},
                                  {"source": "door"}, {"source": "door", "token": 5}])
def test_bad_activity_tokens_are_refused(tokens, body):
    assert call(tokens, "/activity-token", body)[0] == 400


# ── pushes ──

def test_refresh_controls_pushes_each_token_once_and_drops_dead_ones(tokens):
    tokens.set_controls("phone1", [CTRL_A, CTRL_B])
    tokens.set_controls("phone2", [CTRL_B])
    send = Sender({CTRL_B: {"ok": False, "status": 410, "error": "APNs HTTP 410: Unregistered"}})
    assert live_routes.refresh_controls(tokens=tokens, sender=send) == 1
    assert sorted(t for t, _, _ in send.sent) == [CTRL_A, CTRL_B]
    assert tokens.controls() == [("phone1", CTRL_A)]


def test_a_transient_failure_keeps_the_token(tokens):
    tokens.set_controls("phone1", [CTRL_A])
    send = Sender({CTRL_A: {"ok": False, "status": 500, "error": "APNs HTTP 500"}})
    assert live_routes.refresh_controls(tokens=tokens, sender=send) == 0
    assert tokens.controls() == [("phone1", CTRL_A)]


def test_a_raising_sender_is_contained(tokens):
    tokens.set_controls("phone1", [CTRL_A])

    def boom(*a, **k):
        raise RuntimeError("no network")

    assert live_routes.refresh_controls(tokens=tokens, sender=boom) == 0


def test_card_update_and_end(tokens):
    tokens.set_activity("phone1", "door", CARD)
    send = Sender()
    cs = {"state": {"id": "door.arming", "title": "Stop arming", "symbol": "stop.circle.fill", "alert": False},
          "finished": False}
    assert live_routes.push_activity("door", cs, event="update", stale_after=90, tokens=tokens, sender=send) == 1
    token, args, kw = send.sent[0]
    assert token == CARD and args[0] == cs and kw["event"] == "update" and kw["priority"] == 10
    assert kw["stale_after"] == 90
    end = {**cs, "finished": True, "result": "Armed Away"}
    assert live_routes.push_activity("door", end, event="end", dismissal_after=5, tokens=tokens, sender=send) == 1
    assert send.sent[1][2]["event"] == "end" and send.sent[1][2]["dismissal_after"] == 5
    assert tokens.activities("door") == []        # an ended card's token is forgotten


def test_push_to_start_only_where_no_card_runs(tokens):
    tokens.set_activity("phone1", "door-start", START)
    tokens.set_activity("phone2", "door-start", START[::-1])
    tokens.set_activity("phone2", "door", CARD)
    assert live_routes.needs_start("door", tokens=tokens) is True
    send = Sender()
    cs = {"state": {"id": "door.arming", "title": "Stop arming", "symbol": "stop.circle.fill", "alert": False},
          "finished": False}
    n = live_routes.start_activity("door", cs, attributes_type="ButtonActivityAttributes",
                                   attributes={"source": "door", "buttonID": "", "name": "Door alarm",
                                               "symbol": "lock.shield"},
                                   alert={"title": "Door alarm", "body": "Arming Away"}, tokens=tokens, sender=send)
    assert n == 1 and [t for t, _, _ in send.sent] == [START]
    kw = send.sent[0][2]
    assert kw["event"] == "start"
    assert kw["extra"]["attributes-type"] == "ButtonActivityAttributes"
    assert kw["extra"]["attributes"]["source"] == "door"
    assert kw["extra"]["alert"] == {"title": "Door alarm", "body": "Arming Away"}
    assert kw["extra"]["input-push-token"] == 1
    tokens.set_activity("phone1", "door", CARD[::-1])
    assert live_routes.needs_start("door", tokens=tokens) is False


def test_forget_stale_card_tokens(tokens):
    tokens.set_activity("phone1", "door", CARD)
    tokens.clock_ref[0] += 600
    tokens.set_activity("phone2", "door", CARD[::-1])
    live_routes.forget_stale("door", before=tokens.clock_ref[0] - 60, tokens=tokens)
    assert [d for d, _, _ in tokens.activities("door")] == ["phone2"]


def test_a_corrupt_file_reads_as_empty(tokens):
    tokens.root.mkdir(parents=True, exist_ok=True)
    (tokens.root / "tokens.json").write_text("{not json")
    assert tokens.controls() == []
    tokens.set_controls("phone1", [CTRL_A])
    assert tokens.controls() == [("phone1", CTRL_A)]


def test_live_state_is_a_server_only_skill():
    from api.device_bridge import SERVER_ONLY_SKILLS
    assert "live_state" in SERVER_ONLY_SKILLS
