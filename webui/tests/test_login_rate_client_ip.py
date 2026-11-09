"""Login/pair rate limits key on the real client IP and check+record atomically."""
import io
import json
from urllib.parse import urlparse

from api import auth


class _Handler:
    def __init__(self, body: dict, peer="127.0.0.1", cf_ip=None):
        raw = json.dumps(body).encode()
        self.headers = {"Content-Length": str(len(raw))}
        if cf_ip:
            self.headers["CF-Connecting-IP"] = cf_ip
        self.rfile = io.BytesIO(raw)
        self.wfile = io.BytesIO()
        self.client_address = (peer, 50000)
        self.request = None
        self.status = None

    def send_response(self, status):
        self.status = status

    def send_header(self, *_):
        pass

    def end_headers(self):
        pass


def _isolate(tmp_path, monkeypatch):
    monkeypatch.setattr(auth, "_LOGIN_ATTEMPTS_FILE", tmp_path / ".login_attempts.json")
    monkeypatch.setattr(auth, "_login_attempts", {})


def test_check_and_record_is_one_step(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    allowed = [auth._check_and_record_login("203.0.113.20") for _ in range(auth._LOGIN_MAX_ATTEMPTS + 2)]
    assert allowed == [True] * auth._LOGIN_MAX_ATTEMPTS + [False, False]
    assert auth._check_and_record_login("203.0.113.21") is True


def test_pair_claim_limit_is_per_cloudflare_ip(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    import api.pairing as pairing
    monkeypatch.setattr(pairing, "claim_pairing_code", lambda *a, **k: None)
    from api.routes import handle_post
    statuses = []
    for _ in range(auth._LOGIN_MAX_ATTEMPTS + 1):
        h = _Handler({"code": "ZZZZZZ"}, cf_ip="203.0.113.30")
        handle_post(h, urlparse("http://example.test/api/auth/pair/claim"))
        statuses.append(h.status)
    assert statuses[-1] == 429 and statuses[0] == 401
    # A different real client behind the same tunnel is not locked out.
    h = _Handler({"code": "ZZZZZZ"}, cf_ip="198.51.100.30")
    handle_post(h, urlparse("http://example.test/api/auth/pair/claim"))
    assert h.status == 401
