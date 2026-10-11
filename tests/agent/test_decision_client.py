"""Decision client: OpenAI Decisions API request shape, parsing and errors (no network)."""
import json

import httpx
import pytest


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    import model_tools  # noqa: F401
    monkeypatch.setenv("CELERIS_API_KEY", "ck_test")
    monkeypatch.delenv("CELERIS_BASE_URL", raising=False)


def _client(handler):
    return httpx.Client(transport=httpx.MockTransport(handler))


def _ok(choice="deep", conf=0.82):
    return {"model": "celeris-1-decision",
            "answers": [{"type": "choice", "name": "route", "choice": choice, "confidence": conf,
                         "probabilities": [{"value": "deep", "probability": 0.9},
                                           {"value": "none", "probability": 0.1}]}],
            "usage": {"input_tokens": 57, "output_tokens": 0}}


def test_request_shape_and_parse():
    from agent.decision_client import choose
    seen = {}

    def handler(req):
        seen["url"], seen["auth"], seen["body"] = str(req.url), req.headers["authorization"], json.loads(req.content)
        return httpx.Response(200, json=_ok())

    d = choose("celeris", "celeris-1-decision", instructions="Which route?",
               choices=[("deep", "needs research"), ("none", None)], text="debug my code",
               client=_client(handler))
    assert seen["url"] == "https://inference.celeris.ai/celeris-1-decision/v1/decisions"
    assert seen["auth"] == "Bearer ck_test"
    q = seen["body"]["questions"][0]
    assert seen["body"]["model"] == "celeris-1-decision" and seen["body"]["input"] == "debug my code"
    assert q == {"type": "choice", "name": "route", "instructions": "Which route?",
                 "choices": [{"value": "deep", "description": "needs research"}, {"value": "none"}]}
    assert (d.choice, d.confidence, d.input_tokens) == ("deep", 0.82, 57)
    assert d.probabilities == {"deep": 0.9, "none": 0.1}


def test_missing_key(monkeypatch):
    monkeypatch.delenv("CELERIS_API_KEY", raising=False)
    from agent.decision_client import DecisionError, choose
    with pytest.raises(DecisionError, match="CELERIS_API_KEY"):
        choose("celeris", "celeris-1-decision", instructions="q", choices=[("a", None), ("b", None)],
               text="x", client=_client(lambda r: httpx.Response(200, json=_ok())))


@pytest.mark.parametrize("status", [401, 402, 429, 502])
def test_http_error_carries_status(status):
    from agent.decision_client import DecisionError, choose
    body = {"error": {"message": "nope", "type": "x"}}
    with pytest.raises(DecisionError, match=f"HTTP {status}"):
        choose("celeris", "celeris-1-decision", instructions="q", choices=[("a", None), ("b", None)],
               text="x", client=_client(lambda r: httpx.Response(status, json=body)))


def test_choice_outside_the_options_is_a_bad_reply():
    from agent.decision_client import DecisionError, choose
    with pytest.raises(DecisionError, match="bad reply"):
        choose("celeris", "celeris-1-decision", instructions="q", choices=[("a", None), ("b", None)],
               text="x", client=_client(lambda r: httpx.Response(200, json=_ok(choice="zzz"))))


def test_timeout():
    from agent.decision_client import DecisionError, choose

    def handler(req):
        raise httpx.ReadTimeout("slow", request=req)

    with pytest.raises(DecisionError, match="timed out"):
        choose("celeris", "celeris-1-decision", instructions="q", choices=[("a", None), ("b", None)],
               text="x", client=_client(handler))
