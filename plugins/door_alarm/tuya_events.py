"""Tuya's message service — the live cloud feed the door alarm falls back on when the ESP32 is down.

A Pulsar consumer over a websocket (Tuya's documented "Message Service"): username = access ID,
password = md5(access_id + md5(secret))[8:24]; each frame is ``{messageId, payload}`` where payload
is base64 JSON ``{data, protocol, pv, t}`` and ``data`` is AES-128 (key = secret[8:24]) — ECB with
PKCS7 on older projects, GCM (12-byte nonce first, tag last) on newer ones. Every frame is acked.
Protocol 4 = data-point report, protocol 20 = device events (online/offline/rename…).
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import threading
import time
from typing import Any, Callable, Optional

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

log = logging.getLogger(__name__)

_HOSTS = {
    "us": "wss://mqe.tuyaus.com:8285/", "us-e": "wss://mqe.tuyaus.com:8285/",
    "eu": "wss://mqe.tuyaeu.com:8285/", "eu-w": "wss://mqe.tuyaeu.com:8285/",
    "in": "wss://mqe.tuyain.com:8285/", "cn": "wss://mqe.tuyacn.com:8285/",
    "sg": "wss://mqe.tuyaus.com:8285/",
}


def _md5(text: str) -> str:
    return hashlib.md5(text.encode()).hexdigest()


def password(access_id: str, secret: str) -> str:
    return _md5(access_id + _md5(secret))[8:24]


def ws_url(region: str, access_id: str, env: str = "event") -> str:
    host = _HOSTS.get((region or "").lower(), _HOSTS["us"])
    return (f"{host}ws/v2/consumer/persistent/{access_id}/out/{env}/{access_id}-sub"
            "?ackTimeoutMillis=3000&subscriptionType=Failover")


def _decrypt(data_b64: str, secret: str) -> Optional[dict]:
    key = secret[8:24].encode()
    try:
        raw = base64.b64decode(data_b64)
    except (ValueError, TypeError):
        return None
    if raw and len(raw) % 16 == 0:
        try:
            dec = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
            unpadder = padding.PKCS7(128).unpadder()
            plain = unpadder.update(dec.update(raw) + dec.finalize()) + unpadder.finalize()
            return json.loads(plain.decode())
        except (ValueError, UnicodeDecodeError):
            pass
    if len(raw) > 28:
        try:
            return json.loads(AESGCM(key).decrypt(raw[:12], raw[12:], None).decode())
        except Exception:
            return None
    return None


def _dp_id(entry: dict) -> Optional[int]:
    for key in entry:
        if isinstance(key, str) and key.isdigit():
            return int(key)
    return None


def decode(text: Any, secret: str) -> tuple[Optional[str], Optional[dict]]:
    """``(messageId, event)``; event is ``{kind: report, dev_id, reports:[{code, value, t, dp_id}]}``,
    ``{kind: online, dev_id, online}`` or None (other events, undecryptable)."""
    try:
        frame = json.loads(text) if isinstance(text, (str, bytes)) else dict(text)
    except ValueError:
        return None, None
    message_id = frame.get("messageId")
    try:
        payload = json.loads(base64.b64decode(frame.get("payload") or ""))
    except (ValueError, TypeError):
        return message_id, None
    data = _decrypt(payload.get("data") or "", secret) if isinstance(payload, dict) else None
    if not isinstance(data, dict):
        return message_id, None
    dev_id = data.get("devId")
    protocol = payload.get("protocol")
    if protocol == 4 and isinstance(data.get("status"), list):
        reports = []
        for entry in data["status"]:
            if not isinstance(entry, dict) or "code" not in entry:
                continue
            t = entry.get("t")
            reports.append({"code": entry["code"], "value": entry.get("value"),
                            "t": t / 1000.0 if isinstance(t, (int, float)) else None,  # Tuya sends ms
                            "dp_id": _dp_id(entry)})
        return message_id, {"kind": "report", "dev_id": dev_id, "reports": reports}
    if protocol == 20 and data.get("bizCode") in ("online", "offline"):
        return message_id, {"kind": "online", "dev_id": dev_id, "online": data["bizCode"] == "online"}
    return message_id, None


def _default_connect(url: str, headers: dict):
    from websockets.sync.client import connect
    return connect(url, additional_headers=headers, open_timeout=15, ping_interval=30, ping_timeout=15,
                   max_size=2 ** 20)


class TuyaEventFeed:
    """One consumer thread for one device. ``on_report(list)``, ``on_online(bool)``,
    ``on_state(state, error)`` with state ``connected`` | ``down`` | ``auth``."""

    def __init__(self, access_id: str, secret: str, region: str, dev_id: str, *,
                 on_report: Callable[[list], None], on_online: Callable[[bool], None] | None = None,
                 on_state: Callable[[str, str], None] | None = None,
                 connect: Callable | None = None, sleep: Callable[[float], Any] | None = None) -> None:
        self.access_id = access_id
        self._secret = secret
        self.region = region
        self.dev_id = dev_id
        self.on_report = on_report
        self.on_online = on_online or (lambda _o: None)
        self.on_state = on_state or (lambda _s, _e: None)
        self._connect = connect or _default_connect
        self._stop = threading.Event()
        self._sleep = sleep or self._stop.wait
        self._thread: Optional[threading.Thread] = None
        self._conn = None

    def consume(self, conn) -> None:
        """Read frames until the connection closes: ack each one, deliver ours."""
        while not self._stop.is_set():
            try:
                text = conn.recv(timeout=60)
            except TimeoutError:
                continue
            except Exception:
                return  # closed (websockets' ConnectionClosed, EOF, reset) — the caller reconnects
            message_id, event = decode(text, self._secret)
            if message_id:
                conn.send(json.dumps({"messageId": message_id}))
            if not event or event.get("dev_id") != self.dev_id:
                continue
            try:
                if event["kind"] == "report" and event["reports"]:
                    self.on_report(event["reports"])
                elif event["kind"] == "online":
                    self.on_online(event["online"])
            except Exception:
                log.warning("door alarm cloud event handler failed", exc_info=True)

    def run_until(self, stop: threading.Event) -> None:
        backoff = 5.0
        while not (stop.is_set() or self._stop.is_set()):
            try:
                conn = self._connect(ws_url(self.region, self.access_id),
                                     {"username": self.access_id, "password": password(self.access_id, self._secret)})
            except Exception as exc:
                status = getattr(exc, "status_code", None) or getattr(getattr(exc, "response", None), "status_code", None)
                if status in (401, 403):
                    self.on_state("auth", "Tuya refused the message-service login (is Message Service enabled?)")
                    self._sleep(1800)
                else:
                    self.on_state("down", str(exc)[:200])
                    self._sleep(backoff)
                    backoff = min(backoff * 2, 300.0)
                continue
            self._conn = conn
            backoff = 5.0
            self.on_state("connected", "")
            try:
                self.consume(conn)
                if not (stop.is_set() or self._stop.is_set()):
                    self.on_state("down", "the message service closed the connection")
            except Exception as exc:
                self.on_state("down", str(exc)[:200])
            finally:
                try:
                    conn.close()
                except Exception:
                    pass
                self._conn = None
            self._sleep(2)

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self.run_until, args=(self._stop,), name="door-cloud-feed", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        conn = self._conn
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
