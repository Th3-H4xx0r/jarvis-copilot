"""Tuya message service (the cloud fallback feed): auth, decrypt, parse, ack, filtering."""
import base64
import hashlib
import json
import os
import threading

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from plugins.door_alarm import tuya_events as ev

SECRET = "0123456789abcdefFEDCBA9876543210"
KEY = SECRET[8:24].encode()


def ecb(obj):
    padder = padding.PKCS7(128).padder()
    data = padder.update(json.dumps(obj).encode()) + padder.finalize()
    enc = Cipher(algorithms.AES(KEY), modes.ECB()).encryptor()
    return base64.b64encode(enc.update(data) + enc.finalize()).decode()


def gcm(obj):
    nonce = os.urandom(12)
    return base64.b64encode(nonce + AESGCM(KEY).encrypt(nonce, json.dumps(obj).encode(), None)).decode()


def frame(data_b64, protocol=4, message_id="m1", **extra):
    payload = {"data": data_b64, "protocol": protocol, "pv": "2.0", "sign": "x", "t": 1, **extra}
    return json.dumps({"messageId": message_id, "payload": base64.b64encode(json.dumps(payload).encode()).decode()})


def test_password_and_url_follow_tuya():
    md5 = lambda s: hashlib.md5(s.encode()).hexdigest()  # noqa: E731
    assert ev.password("abc", SECRET) == md5("abc" + md5(SECRET))[8:24]
    assert ev.ws_url("us", "abc") == ("wss://mqe.tuyaus.com:8285/ws/v2/consumer/persistent/abc/out/event/"
                                      "abc-sub?ackTimeoutMillis=3000&subscriptionType=Failover")


def test_status_report_decodes_with_ecb_and_gcm():
    status = {"devId": "hub1", "status": [{"code": "doorcontact_state", "value": True, "t": 1700000000123, "1": "true"}]}
    for enc in (ecb, gcm):
        msg_id, event = ev.decode(frame(enc(status)), SECRET)
        assert msg_id == "m1"
        assert event == {"kind": "report", "dev_id": "hub1",
                         "reports": [{"code": "doorcontact_state", "value": True, "t": 1700000000.123, "dp_id": 1}]}


def test_online_offline_events():
    for biz, online in (("online", True), ("offline", False)):
        _id, event = ev.decode(frame(ecb({"bizCode": biz, "devId": "hub1", "bizData": {}}), protocol=20), SECRET)
        assert event == {"kind": "online", "dev_id": "hub1", "online": online}


def test_other_business_events_and_garbage_are_none():
    _id, event = ev.decode(frame(ecb({"bizCode": "nameUpdate", "devId": "hub1", "bizData": {"name": "x"}}),
                                 protocol=20), SECRET)
    assert event is None
    _id, bad = ev.decode(frame(base64.b64encode(b"not encrypted at all!!").decode()), SECRET)
    assert bad is None


class FakeConn:
    def __init__(self, frames):
        self.frames = list(frames)
        self.sent = []

    def recv(self, timeout=None):
        if not self.frames:
            raise EOFError("closed")
        return self.frames.pop(0)

    def send(self, text):
        self.sent.append(json.loads(text))

    def close(self):
        pass


def test_feed_acks_every_message_and_delivers_only_our_device():
    reports, online = [], []
    feed = ev.TuyaEventFeed("abc", SECRET, "us", "hub1", on_report=reports.append, on_online=online.append)
    conn = FakeConn([
        frame(ecb({"devId": "hub1", "status": [{"code": "a", "value": 1, "t": 1000}]}), message_id="1"),
        frame(ecb({"devId": "other", "status": [{"code": "a", "value": 2, "t": 1000}]}), message_id="2"),
        frame(ecb({"bizCode": "offline", "devId": "hub1", "bizData": {}}), protocol=20, message_id="3"),
    ])
    feed.consume(conn)
    assert conn.sent == [{"messageId": "1"}, {"messageId": "2"}, {"messageId": "3"}]
    assert reports == [[{"code": "a", "value": 1, "t": 1.0, "dp_id": None}]]
    assert online == [False]


def test_feed_reports_auth_failures_and_backs_off():
    states = []
    stop = threading.Event()

    class Refused(Exception):
        status_code = 401

    def connect(*_a, **_k):
        stop.set()
        raise Refused("401")

    feed = ev.TuyaEventFeed("abc", SECRET, "us", "hub1", on_report=lambda r: None,
                            on_state=lambda s, e: states.append(s), connect=connect, sleep=lambda s: stop.wait(0))
    feed.run_until(stop)
    assert states and states[-1] == "auth"
