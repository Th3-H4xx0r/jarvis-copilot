"""Event kinds read as plain words; unknown kinds fall back to the kind."""
from plugins.security_advisor import rules
from plugins.security_advisor.labels import TITLES, title_for


def test_known_kinds_read_as_words():
    assert title_for("auth.failed") == "Failed sign-in"
    assert title_for("pair.failed", {}, {"reason": "bad_code"}) == "Pairing code rejected"
    assert title_for("ssh.accepted", {"ip": "203.0.113.4"}) == "SSH login"
    assert title_for("ssh.accepted", {"ip": "127.0.0.1"}) == "SSH login via relay"
    assert title_for("login.failed", {}, {"reason": "rate_limited"}).startswith("Sign-in refused")


def test_unknown_or_odd_input_falls_back_to_the_kind():
    assert title_for("brand.new_kind") == "brand.new_kind"
    assert title_for(None) == ""
    assert title_for("ssh.accepted", "not-a-dict", 5) == "SSH login"


def test_every_kind_the_rules_know_has_a_title():
    for kind in rules.DIGEST_KINDS | {"pair.claimed", "file.changed", "advisor.code_changed",
                                      "log.chain_broken", "config.password_changed",
                                      "config.edge_changed", "agent.blocked"}:
        assert kind in TITLES, kind
