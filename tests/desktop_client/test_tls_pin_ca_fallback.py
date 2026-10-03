"""A pinned fingerprint that no longer matches is still accepted when the
public CA system vouches for the SAME cert on that hostname — Cloudflare
renews its edge cert every few months, which used to break every pinned
client (SSH relay, code-memory, device bridge). Self-signed / LAN / IP
servers stay strictly pinned."""
import ssl
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "desktop_client"))
from jc_client import protocol as p  # noqa: E402


class FakeSock:
    def __init__(self, host="jarvis.example.dev", port=443):
        self.server_hostname = host
        self._peer = ("203.0.113.5", port)

    def getpeername(self):
        return self._peer


def test_matching_pin_passes(monkeypatch):
    monkeypatch.setattr(p, "cert_fingerprint", lambda s: "aa")
    p._verify_fingerprint(FakeSock(), "AA")


def test_mismatch_accepted_when_public_ca_vouches_for_same_cert(monkeypatch):
    monkeypatch.setattr(p, "cert_fingerprint", lambda s: "new")
    seen = []
    monkeypatch.setattr(p, "_ca_trusts", lambda host, port, fp: seen.append((host, port, fp)) or True)
    p._CA_ACCEPTED.clear()
    p._verify_fingerprint(FakeSock(), "old")
    assert seen == [("jarvis.example.dev", 443, "new")]
    p._verify_fingerprint(FakeSock(), "old")
    assert len(seen) == 1, "accepted cert is cached; no second CA handshake"


def test_mismatch_rejected_when_ca_does_not_vouch(monkeypatch):
    monkeypatch.setattr(p, "cert_fingerprint", lambda s: "new")
    monkeypatch.setattr(p, "_ca_trusts", lambda *a: False)
    p._CA_ACCEPTED.clear()
    with pytest.raises(ssl.SSLError):
        p._verify_fingerprint(FakeSock(), "old")


def test_ip_literal_host_never_falls_back(monkeypatch):
    monkeypatch.setattr(p, "cert_fingerprint", lambda s: "new")
    called = []
    monkeypatch.setattr(p, "_ca_trusts", lambda *a: called.append(a) or True)
    p._CA_ACCEPTED.clear()
    with pytest.raises(ssl.SSLError):
        p._verify_fingerprint(FakeSock(host="192.168.1.20"), "old")
    assert called == []
