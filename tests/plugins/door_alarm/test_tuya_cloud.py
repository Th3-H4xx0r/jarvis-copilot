"""Tuya OpenAPI client: request signing, token handling, error classes, paging, parsing."""
import hashlib
import hmac
import json

import pytest

from plugins.door_alarm.tuya_cloud import TuyaCloud, TuyaError, base_url


class FakeTransport:
    """Records requests; answers from a queue of (status, json) or a callable(method, url, headers, body)."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = []

    def __call__(self, method, url, headers, body, timeout):
        self.calls.append({"method": method, "url": url, "headers": headers, "body": body})
        answer = self.answers.pop(0)
        if callable(answer):
            return answer(method, url, headers, body)
        if isinstance(answer, Exception):
            raise answer
        return answer


TOKEN = (200, {"success": True, "t": 1_800_000_000_000,
               "result": {"access_token": "tok1", "refresh_token": "ref1", "expire_time": 7200, "uid": "u1"}})


def cloud(answers, clock=None):
    t = FakeTransport(answers)
    c = TuyaCloud("id123", "secretsecretsecretsecretsecret12", base_url("us"), transport=t,
                  clock=clock or (lambda: 1_800_000_000.0), nonce=lambda: "")
    return c, t


def expected_sign(secret, client_id, token, t, method, body, path_query):
    string_to_sign = f"{method}\n{hashlib.sha256((body or '').encode()).hexdigest()}\n\n{path_query}"
    msg = client_id + (token or "") + t + string_to_sign
    return hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest().upper()


def test_regions():
    assert base_url("us") == "https://openapi.tuyaus.com"
    assert base_url("us-e") == "https://openapi-ueaz.tuyaus.com"
    assert base_url("eu") == "https://openapi.tuyaeu.com"
    with pytest.raises(ValueError):
        base_url("mars")


def test_token_request_and_business_request_are_signed_per_tuya():
    c, t = cloud([TOKEN, (200, {"success": True, "result": {"id": "dev1", "name": "Wireless Doorbell"}})])
    info = c.device("dev1")
    assert info["name"] == "Wireless Doorbell"
    tok_call, dev_call = t.calls
    assert tok_call["url"] == "https://openapi.tuyaus.com/v1.0/token?grant_type=1"
    ts = tok_call["headers"]["t"]
    assert tok_call["headers"]["sign"] == expected_sign(
        "secretsecretsecretsecretsecret12", "id123", None, ts, "GET", "", "/v1.0/token?grant_type=1")
    assert "access_token" not in tok_call["headers"]
    assert dev_call["headers"]["access_token"] == "tok1"
    assert dev_call["headers"]["sign"] == expected_sign(
        "secretsecretsecretsecretsecret12", "id123", "tok1", dev_call["headers"]["t"], "GET", "", "/v1.0/devices/dev1")
    assert dev_call["headers"]["sign_method"] == "HMAC-SHA256"


def test_query_keys_are_signed_sorted_and_post_bodies_hashed():
    c, t = cloud([TOKEN, (200, {"success": True, "result": True})])
    c.issue("dev1", {"alarm_volume": "high"})
    call = t.calls[1]
    assert call["method"] == "POST"
    assert call["url"] == "https://openapi.tuyaus.com/v2.0/cloud/thing/dev1/shadow/properties/issue"
    body = call["body"]
    assert json.loads(json.loads(body)["properties"]) == {"alarm_volume": "high"}
    assert call["headers"]["sign"] == expected_sign(
        "secretsecretsecretsecretsecret12", "id123", "tok1", call["headers"]["t"], "POST", body,
        "/v2.0/cloud/thing/dev1/shadow/properties/issue")
    assert TuyaCloud._sign_path("/v1.0/x", {"b": "2", "a": "1"}) == "/v1.0/x?a=1&b=2"


def test_token_is_reused_until_near_expiry_then_refetched():
    now = [1_800_000_000.0]
    ok = (200, {"success": True, "result": {}})
    c, t = cloud([TOKEN, ok, ok, TOKEN, ok], clock=lambda: now[0])
    c.device("d")
    c.device("d")
    now[0] += 7200 - 30  # inside the last minute
    c.device("d")
    urls = [x["url"].split("?")[0] for x in t.calls]
    assert urls.count("https://openapi.tuyaus.com/v1.0/token") == 2


def test_token_invalid_is_retried_once_with_a_new_token():
    c, t = cloud([TOKEN, (200, {"success": False, "code": 1010, "msg": "token invalid"}), TOKEN,
                  (200, {"success": True, "result": {"id": "d"}})])
    assert c.device("d") == {"id": "d"}


@pytest.mark.parametrize("code,msg,kind", [
    (1004, "sign invalid", "auth"),
    (1106, "permission deny", "auth"),
    (28841002, "No permissions. Your subscription to cloud development plan has expired.", "auth"),
    (2008, "command or value not support", "refused"),
    (1109, "param is illegal", "refused"),
])
def test_errors_are_classified(code, msg, kind):
    c, _ = cloud([TOKEN, (200, {"success": False, "code": code, "msg": msg})])
    with pytest.raises(TuyaError) as err:
        c.device("d")
    assert err.value.kind == kind
    assert err.value.code == code


def test_network_failures_are_transient():
    c, _ = cloud([OSError("timed out")])
    with pytest.raises(TuyaError) as err:
        c.devices()
    assert err.value.kind == "transient"
    c2, _ = cloud([(502, None)])
    with pytest.raises(TuyaError) as err2:
        c2.devices()
    assert err2.value.kind == "transient"


def test_devices_follow_paging():
    page1 = (200, {"success": True, "result": {"devices": [{"id": "a"}], "has_more": True, "last_row_key": "k1"}})
    page2 = (200, {"success": True, "result": {"devices": [{"id": "b"}], "has_more": False}})
    c, t = cloud([TOKEN, page1, page2])
    assert [d["id"] for d in c.devices()] == ["a", "b"]
    assert "last_row_key=k1" in t.calls[2]["url"]


def test_model_is_parsed_from_its_json_string():
    model = {"services": [{"properties": [{"abilityId": 1, "code": "doorcontact_state"}]}]}
    c, _ = cloud([TOKEN, (200, {"success": True, "result": {"model": json.dumps(model)}})])
    assert c.model("d") == model


def test_secret_is_not_in_repr():
    c, _ = cloud([])
    assert "secretsecret" not in repr(c)
