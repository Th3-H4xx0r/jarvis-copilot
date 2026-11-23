"""QR pairing (docs/superpowers/specs/2026-11-23-qr-pairing-design.md): the computer's one-time LAN listener takes one
AES-256-GCM-sealed hand-off from his iPhone and pairs like `jc-client pair --code`."""
import base64
import json
import os
import time
import urllib.error
import urllib.request

import pytest
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from jc_client import pair_listener as P

AAD = b"jarvis-pair-computer-v1"


def seal(key: bytes, plain: dict, nonce: bytes = None) -> dict:
    nonce = nonce or os.urandom(12)
    ct = AESGCM(key).encrypt(nonce, json.dumps(plain).encode(), AAD)
    return {"v": 1, "nonce": base64.b64encode(nonce).decode(), "ct": base64.b64encode(ct).decode()}


def hand_off(ts=None):
    return {"server": "https://jarvis.example", "code": "ABC-123", "cf_id": "id.access", "cf_secret": "s3",
            "ts": int(ts if ts is not None else time.time())}


def test_payload_format():
    key = bytes(range(32))
    p = P.build_payload("192.168.1.72", 47913, key, "pranav computer", "windows")
    assert p.startswith("jarvis://pair-computer?v=1&host=192.168.1.72&port=47913&key=")
    assert "name=pranav%20computer" in p and p.endswith("&os=windows")
    assert P.key_from_payload(p) == key


def test_decrypt_round_trip():
    key = os.urandom(32)
    assert P.open_hand_off(key, seal(key, hand_off()))["code"] == "ABC-123"


def test_wrong_key_refused():
    with pytest.raises(P.PairError) as e:
        P.open_hand_off(os.urandom(32), seal(os.urandom(32), hand_off()))
    assert e.value.status == 401


def test_stale_hand_off_refused():
    key = os.urandom(32)
    with pytest.raises(P.PairError) as e:
        P.open_hand_off(key, seal(key, hand_off(ts=time.time() - 300)))
    assert e.value.status == 409


def _post(port, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/pair", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_listener_pairs_once_then_closes():
    claimed, states = [], []

    def claim(server, code, name, cf_id, cf_secret):
        claimed.append((server, code, name, cf_id, cf_secret))
        return {"ok": True, "device_name": name}
    lst = P.PairListener(claim, name="pranav-computer", os_name="windows", host="127.0.0.1",
                         on_state=lambda s, **kw: states.append(s), port=0)
    info = lst.start()
    key = P.key_from_payload(info["payload"])
    status, body = _post(info["port"], seal(key, hand_off()))
    assert status == 200 and body == {"ok": True, "device_name": "pranav-computer"}
    assert claimed == [("https://jarvis.example", "ABC-123", "pranav-computer", "id.access", "s3")]
    assert "paired" in states
    time.sleep(0.3)
    with pytest.raises(Exception):
        _post(info["port"], seal(key, hand_off()))      # closed after one success


def test_listener_refuses_a_reused_nonce():
    def claim(*a):
        return {"ok": False, "error": "code expired"}
    lst = P.PairListener(claim, name="pc", os_name="windows", host="127.0.0.1", port=0)
    info = lst.start()
    key = P.key_from_payload(info["payload"])
    body = seal(key, hand_off(), nonce=b"n" * 12)
    assert _post(info["port"], body)[0] == 502          # claim failed: he can try again with a new one
    assert _post(info["port"], body)[0] == 409          # the same sealed request never runs twice
    lst.stop()


def test_controller_status_and_manual(monkeypatch):
    from jc_client import credentials as C
    sent = []
    ctl = P.PairController(lambda m: sent.append(m), claim=lambda *a: {"ok": True, "device_name": "pc"},
                           load=lambda: C.Credentials(server_url="https://jarvis.example", device_name="pc"))
    st = ctl.handle({"type": "pair_status"})
    assert st == {"ok": True, "paired": False, "server": "https://jarvis.example", "device_name": "pc"}
    assert ctl.handle({"type": "pair_manual", "server": "https://jarvis.example", "code": "ABC-123"})["ok"] is True
    assert sent and sent[-1]["type"] == "pair_state" and sent[-1]["state"] == "paired"
