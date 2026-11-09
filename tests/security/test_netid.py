"""client_ip(): trust Cloudflare's header only when the peer is the local edge."""


def _h(peer, hdr):
    return type("H", (), {"client_address": (peer, 1), "headers": hdr})()


def test_client_ip_trusts_cf_header_only_from_loopback():
    from security.netid import client_ip
    assert client_ip(_h("127.0.0.1", {"CF-Connecting-IP": "203.0.113.9"})) == "203.0.113.9"
    assert client_ip(_h("192.168.1.20", {"CF-Connecting-IP": "203.0.113.9"})) == "192.168.1.20"
    assert client_ip(_h("127.0.0.1", {"CF-Connecting-IP": "not-an-ip"})) == "127.0.0.1"
    assert client_ip(_h("::1", {})) == "::1"


def test_client_ip_ipv6_header_and_missing_peer():
    from security.netid import client_ip
    assert client_ip(_h("::1", {"CF-Connecting-IP": " 2001:db8::5 "})) == "2001:db8::5"
    broken = type("H", (), {"client_address": None, "headers": {}})()
    assert client_ip(broken) == ""
