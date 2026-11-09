"""Rules: every event kind gets ignore / digest / alert / block, deterministically."""
from datetime import datetime

from plugins.security_advisor import rules
from security.events import Event

NOW = datetime(2026, 11, 8, 12, 0, 0)


def ev(kind, actor=None, source="device", eid=1, **detail):
    return Event(id=eid, ts="2026-11-08T12:00:00Z", source=source, kind=kind,
                 actor=actor or {}, detail=detail)


def ctx(recent=None, valid=False, **kw):
    store = recent or []
    defaults = dict(
        recent=lambda kind, window_s: [e for e in store if e.kind == kind],
        ip_has_valid_session=lambda ip: valid,
        known_ssh_ips=set(), usual_hours=(6, 23), disabled_rules=set(), now=NOW)
    defaults.update(kw)
    return rules.RuleContext(**defaults)


def burst(ip="203.0.113.5", n=10):
    kinds = ["auth.failed", "pair.failed", "login.failed"]
    return [ev(kinds[i % 3], {"ip": ip}, eid=i + 1) for i in range(n)]


def test_failed_auth_burst_blocks_ip():
    events = burst()
    d = rules.evaluate(events[-1], ctx(events))
    assert d.outcome == "block"
    assert d.action == {"type": "block_ip", "ip": "203.0.113.5"}
    assert d.dedup_key == f"{d.rule}:203.0.113.5"


def test_few_failures_are_digest():
    events = burst(n=3)
    assert rules.evaluate(events[-1], ctx(events)).outcome == "digest"


def test_burst_from_other_ips_does_not_count():
    events = burst(ip="198.51.100.9", n=9) + [ev("auth.failed", {"ip": "203.0.113.5"}, eid=50)]
    assert rules.evaluate(events[-1], ctx(events)).outcome == "digest"


def test_rate_limited_refusals_do_not_count_toward_a_block():
    # The webui refuses retries past its own login limit and logs them as rate_limited;
    # those refusals must not push an IP over the burst threshold.
    events = burst(n=6) + [ev("login.failed", {"ip": "203.0.113.5"}, eid=100 + i,
                              reason="rate_limited") for i in range(8)]
    assert rules.evaluate(events[-1], ctx(events)).outcome == "digest"
    assert rules.evaluate(events[5], ctx(events)).outcome == "digest"


def test_auth_json_rewrites_are_digest_but_other_secrets_alert():
    # The credential pool rewrites auth.json on its own; .env and SSH files stay alerts.
    auth = ev("file.changed", source="host", path="/srv/home/auth.json", change="modified")
    assert rules.evaluate(auth, ctx()).outcome == "digest"
    for path in ("/srv/home/.env", "/root/.ssh/authorized_keys", "/etc/ssh/sshd_config"):
        e = ev("file.changed", source="host", path=path, change="modified")
        assert rules.evaluate(e, ctx()).outcome == "alert", path
    gone = ev("file.changed", source="host", path="/srv/home/auth.json", change="removed")
    assert rules.evaluate(gone, ctx()).outcome == "alert"


def test_burst_from_ip_with_valid_session_alerts_not_blocks():
    events = burst()
    d = rules.evaluate(events[-1], ctx(events, valid=True))
    assert d.outcome == "alert" and d.action is None


def test_burst_from_known_device_or_home_network_alerts_not_blocks():
    events = burst()
    events[-1].actor["device_id"] = "dev-1"
    assert rules.evaluate(events[-1], ctx(events)).outcome == "alert"
    lan = burst(ip="192.168.1.20")
    d = rules.evaluate(lan[-1], ctx(lan))
    assert d.outcome == "alert" and d.action is None


def test_new_device_paired_alerts():
    d = rules.evaluate(ev("pair.claimed", {"ip": "203.0.113.5", "device_id": "dev-2"}), ctx())
    assert d.outcome == "alert" and d.title


def test_ssh_login_new_ip_alerts_relay_digests():
    d = rules.evaluate(ev("ssh.accepted", {"ip": "198.51.100.4", "user": "root"}, source="host"), ctx())
    assert d.outcome == "alert"
    d = rules.evaluate(ev("ssh.accepted", {"ip": "127.0.0.1", "user": "root"}, source="host"), ctx())
    assert d.outcome == "digest" and "via relay" in d.title
    d = rules.evaluate(ev("ssh.accepted", {"ip": "198.51.100.4"}, source="host"),
                       ctx(known_ssh_ips={"198.51.100.4"}))
    assert d.outcome == "digest"


def test_ssh_login_over_tailscale_digests():
    # Tailscale already authenticates his account; a new tailnet device isn't an intrusion.
    for ip in ("100.100.1.2", "fd7a:115c:a1e0::1234"):
        d = rules.evaluate(ev("ssh.accepted", {"ip": ip, "user": "root"}, source="host"), ctx())
        assert d.outcome == "digest" and "via Tailscale" in d.title


def test_ssh_failed_burst_is_digest():
    events = [ev("ssh.failed", {"ip": "203.0.113.9"}, source="host", eid=i) for i in range(20)]
    assert rules.evaluate(events[-1], ctx(events)).outcome == "digest"


def test_sensitive_file_change_alerts_repo_change_digests():
    assert rules.evaluate(ev("file.changed", source="host", path="/etc/ssh/sshd_config",
                             change="modified"), ctx()).outcome == "alert"
    assert rules.evaluate(ev("repo.changed", source="host", files=["a.py"]), ctx()).outcome == "digest"
    assert rules.evaluate(ev("advisor.code_changed", source="host", files=["security/x.py"]),
                          ctx()).outcome == "alert"


def test_secret_changed_from_unpaired_session_alerts():
    unpaired = ev("config.secret_changed", {"ip": "203.0.113.5", "session_kind": "unpaired"},
                  name="PARALLEL_API_KEY")
    paired = ev("config.secret_changed", {"ip": "203.0.113.5", "session_kind": "paired",
                                          "device_id": "dev-1"}, name="PARALLEL_API_KEY")
    assert rules.evaluate(unpaired, ctx()).outcome == "alert"
    assert rules.evaluate(paired, ctx()).outcome == "digest"


def test_password_or_edge_change_alerts():
    assert rules.evaluate(ev("config.password_changed", action="set"), ctx()).outcome == "alert"
    assert rules.evaluate(ev("config.edge_changed", action="disable"), ctx()).outcome == "alert"


def test_car_command_outside_usual_hours_alerts():
    car = ev("car.command", {"ip": "203.0.113.5"}, command="unlock", result=200)
    assert rules.evaluate(car, ctx(now=NOW.replace(hour=3))).outcome == "alert"
    assert rules.evaluate(car, ctx(now=NOW.replace(hour=12))).outcome == "digest"
    door = ev("door.command", path="/disarm", result=200)
    assert rules.evaluate(door, ctx(now=NOW.replace(hour=3))).outcome == "alert"


def test_agent_blocked_alerts():
    d = rules.evaluate(ev("agent.blocked", source="agent", tool="terminal"), ctx())
    assert d.outcome == "alert"


def test_chain_broken_alerts():
    assert rules.evaluate(ev("log.chain_broken", source="host", first_bad_id=7), ctx()).outcome == "alert"


def test_disabled_rule_falls_back_to_digest():
    d = rules.evaluate(ev("pair.claimed"), ctx())
    assert rules.evaluate(ev("pair.claimed"), ctx(disabled_rules={d.rule})).outcome == "digest"
    events = burst()
    d = rules.evaluate(events[-1], ctx(events))
    assert rules.evaluate(events[-1], ctx(events, disabled_rules={d.rule})).outcome == "digest"


def test_unknown_kind_is_ignore():
    assert rules.evaluate(ev("something.new"), ctx()).outcome == "ignore"
    assert rules.evaluate(ev("session.seen"), ctx()).outcome == "ignore"


def test_known_low_level_kinds_are_digest():
    for kind in ("tool.risky", "approval.answered", "relay.opened", "inject.detected"):
        assert rules.evaluate(ev(kind), ctx()).outcome == "digest", kind


def test_rule_table_names_every_rule_once():
    names = [r["name"] for r in rules.RULES]
    assert len(names) == len(set(names)) and all(r["description"] for r in rules.RULES)
