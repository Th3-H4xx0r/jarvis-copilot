"""Deterministic rules: each security event becomes ignore / digest / alert / block.

Rules are small functions tried in order; the first that returns a Decision wins.
A rule switched off in settings (``disabled_rules``) falls back to ``digest`` so
the event still shows in the daily summary. No model is involved here.
"""
from __future__ import annotations

import ipaddress
from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable

from security.events import Event

AUTH_FAIL_KINDS = ("auth.failed", "pair.failed", "login.failed")
AUTH_BURST_COUNT = 10
AUTH_BURST_WINDOW_S = 300

# Never auto-blocked: loopback, his LAN, link-local and the Tailscale range.
_PROTECTED_NETS = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    "100.64.0.0/10", "::1/128", "fc00::/7", "fe80::/10")]

# Tailscale's address ranges (CGNAT IPv4 and its fixed IPv6 ULA prefix).
_TAILNET_NETS = [ipaddress.ip_network(n) for n in ("100.64.0.0/10", "fd7a:115c:a1e0::/48")]


def _is_tailnet(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr.version == n.version and addr in n for n in _TAILNET_NETS)


# Everything the webui, agent and host sources emit that has no rule of its own.
DIGEST_KINDS = frozenset({
    "auth.failed", "pair.failed", "login.failed", "login.ok", "session.revoked",
    "device.revoked", "relay.opened", "tui.opened", "approval.answered", "request.blocked",
    "car.command", "door.command", "config.secret_changed",
    "inject.detected", "tool.risky", "approval.requested", "approval.result", "gateway.message",
    "ssh.accepted", "ssh.failed", "sudo.command", "repo.changed", "repo.head_moved",
    "host.source_unavailable", "security.dropped", "advisor.changed",
})
IGNORE_KINDS = frozenset({"session.seen"})


@dataclass
class Decision:
    outcome: str  # "ignore" | "digest" | "alert" | "block"
    rule: str
    title: str
    summary: str
    dedup_key: str
    action: dict | None = None


@dataclass
class RuleContext:
    recent: Callable[[str, int], list]  # (kind, window_s) -> events of that kind in the window
    ip_has_valid_session: Callable[[str], bool]
    known_ssh_ips: set = field(default_factory=set)
    usual_hours: tuple = (6, 23)
    disabled_rules: set = field(default_factory=set)
    now: datetime = field(default_factory=datetime.now)
    exceptions: set = field(default_factory=set)  # IPs he allowed from an alert


def is_protected_ip(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True  # not an address we understand: never block on it
    return any(addr in net for net in _PROTECTED_NETS)


def _ip(event: Event) -> str:
    return str((event.actor or {}).get("ip") or "")


def _key(rule: str, event: Event) -> str:
    actor = event.actor or {}
    who = actor.get("ip") or actor.get("device_id") or (event.detail or {}).get("path") or event.kind
    return f"{rule}:{who}"


def _d(outcome: str, rule: str, event: Event, title: str, summary: str, action=None) -> Decision:
    return Decision(outcome, rule, title, summary, _key(rule, event), action)


# ── rules ────────────────────────────────────────────────────────────────

def _counts_as_failure(event: Event) -> bool:
    # A retry the webui refused under its own login limit is logged, not counted: it
    # was never checked, and counting it would block an IP for retrying too fast.
    return (event.detail or {}).get("reason") != "rate_limited"


def auth_burst(event: Event, ctx: RuleContext):
    if event.kind not in AUTH_FAIL_KINDS or not _counts_as_failure(event):
        return None
    ip = _ip(event)
    if not ip:
        return None
    ids = {event.id}
    for kind in AUTH_FAIL_KINDS:
        ids.update(e.id for e in ctx.recent(kind, AUTH_BURST_WINDOW_S)
                   if _ip(e) == ip and _counts_as_failure(e))
    if len(ids) < AUTH_BURST_COUNT:
        return None
    title = f"{len(ids)} failed sign-ins from {ip}"
    if (ip in ctx.exceptions or is_protected_ip(ip) or ctx.ip_has_valid_session(ip)
            or (event.actor or {}).get("device_id")):
        return _d("alert", "auth_burst", event, title,
                  f"{ip} failed to sign in or pair {len(ids)} times in "
                  f"{AUTH_BURST_WINDOW_S // 60} minutes. Not blocked: it is one of your networks "
                  "or devices.")
    return _d("block", "auth_burst", event, title,
              f"{ip} failed to sign in or pair {len(ids)} times in "
              f"{AUTH_BURST_WINDOW_S // 60} minutes, so it was blocked.",
              {"type": "block_ip", "ip": ip})


def new_device(event: Event, ctx: RuleContext):
    if event.kind != "pair.claimed":
        return None
    name = (event.actor or {}).get("device_name") or "A new device"
    return _d("alert", "new_device", event, "New device paired",
              f"{name} paired with Jarvis from {_ip(event) or 'an unknown address'}.")


def ssh_login(event: Event, ctx: RuleContext):
    if event.kind != "ssh.accepted":
        return None
    ip, user = _ip(event), (event.actor or {}).get("user") or "someone"
    if ip in ("127.0.0.1", "::1"):
        return _d("digest", "ssh_new_ip", event, f"SSH login as {user} via relay",
                  "An SSH login came through the paired-device relay.")
    if _is_tailnet(ip):
        return _d("digest", "ssh_new_ip", event, f"SSH login as {user} via Tailscale",
                  f"An SSH login came from {ip} on his tailnet (Tailscale authenticates the device).")
    if ip in ctx.known_ssh_ips or ip in ctx.exceptions:
        return _d("digest", "ssh_new_ip", event, f"SSH login as {user}",
                  f"SSH login from a known address ({ip}).")
    return _d("alert", "ssh_new_ip", event, f"SSH login from a new IP ({ip})",
              f"{user} logged into the server over SSH from {ip}, an address not seen before.")


def sensitive_file(event: Event, ctx: RuleContext):
    if event.kind == "file.changed":
        path = (event.detail or {}).get("path") or "a watched file"
        change = (event.detail or {}).get("change") or "changed"
        if change == "modified" and path.rsplit("/", 1)[-1] == "auth.json":
            # The credential pool rewrites auth.json whenever it rotates or refreshes a key.
            return _d("digest", "sensitive_file", event, f"Server file {change}: {path}",
                      f"{path} was {change} (credentials refreshed).")
        return _d("alert", "sensitive_file", event, f"Server file {change}: {path}",
                  f"{path} was {change}. These files control SSH, services, schedules or keys.")
    if event.kind == "advisor.code_changed":
        return _d("alert", "advisor_code", event, "Security Advisor code changed",
                  "The advisor's own code differs from git HEAD: "
                  + ", ".join((event.detail or {}).get("files") or [])[:300])
    if event.kind == "log.chain_broken":
        return _d("alert", "log_tamper", event, "Security log was edited",
                  f"The event log's hash chain breaks at row "
                  f"{(event.detail or {}).get('first_bad_id')}; a row was changed or removed.")
    return None


def secret_changed(event: Event, ctx: RuleContext):
    if event.kind != "config.secret_changed":
        return None
    name = (event.detail or {}).get("name") or "a key"
    if (event.actor or {}).get("session_kind") == "paired":
        return _d("digest", "secret_changed", event, f"Key changed: {name}",
                  f"{name} was changed from a paired device.")
    return _d("alert", "secret_changed", event, f"Key changed by an unpaired session: {name}",
              f"{name} was changed from {_ip(event) or 'an unknown address'}, "
              "not from one of your paired devices.")


def access_changed(event: Event, ctx: RuleContext):
    if event.kind == "config.password_changed":
        return _d("alert", "access_changed", event, "Web UI password changed",
                  f"The web UI password was {(event.detail or {}).get('action') or 'changed'} "
                  f"from {_ip(event) or 'an unknown address'}.")
    if event.kind == "config.edge_changed":
        return _d("alert", "access_changed", event, "Public access settings changed",
                  f"The edge (tunnel/nginx) was changed: {(event.detail or {}).get('action')}.")
    return None


def _in_hours(hour: int, hours) -> bool:
    start, end = int(hours[0]), int(hours[1])
    if start <= end:
        return start <= hour < end
    return hour >= start or hour < end


def odd_hours_command(event: Event, ctx: RuleContext):
    if event.kind not in ("car.command", "door.command"):
        return None
    if _in_hours(ctx.now.hour, ctx.usual_hours):
        return None
    what = "Car" if event.kind == "car.command" else "Door alarm"
    detail = event.detail or {}
    cmd = detail.get("command") or detail.get("path") or "command"
    return _d("alert", "odd_hours", event, f"{what} command at {ctx.now:%H:%M}",
              f"{what} {cmd} at {ctx.now:%H:%M}, outside your usual hours "
              f"({ctx.usual_hours[0]}:00–{ctx.usual_hours[1]}:00).")


def agent_blocked(event: Event, ctx: RuleContext):
    if event.kind != "agent.blocked":
        return None
    tool = (event.detail or {}).get("tool") or "a tool"
    return _d("alert", "agent_blocked", event, f"Blocked {tool} after a prompt injection",
              f"Jarvis read content that looked like a prompt injection "
              f"({(event.detail or {}).get('origin') or 'unknown source'}), so {tool} was stopped.")


_RULE_FUNCS = [
    ("auth_burst", "Block an IP after 10 failed sign-ins or pairing codes in 5 minutes", auth_burst),
    ("new_device", "Alert when a new device pairs", new_device),
    ("ssh_new_ip", "Alert on an SSH login from a new IP", ssh_login),
    ("sensitive_file", "Alert when SSH, systemd, cron, key or edge files change", sensitive_file),
    ("advisor_code", "Alert when the advisor's own code changes", sensitive_file),
    ("log_tamper", "Alert when the security log's hash chain breaks", sensitive_file),
    ("secret_changed", "Alert when keys change from a session that is not a paired device",
     secret_changed),
    ("access_changed", "Alert when the web password or public access changes", access_changed),
    ("odd_hours", "Alert on car or door commands outside your usual hours", odd_hours_command),
    ("agent_blocked", "Alert when Jarvis is stopped after a prompt injection", agent_blocked),
]

RULES = [{"name": n, "description": d} for n, d, _ in _RULE_FUNCS]


def evaluate(event: Event, ctx: RuleContext) -> Decision:
    seen = set()
    for _name, _desc, func in _RULE_FUNCS:
        if func in seen:
            continue
        seen.add(func)
        decision = func(event, ctx)
        if decision is None:
            continue
        if decision.rule in ctx.disabled_rules and decision.outcome != "digest":
            return Decision("digest", decision.rule, decision.title, decision.summary,
                            decision.dedup_key, None)
        return decision
    if event.kind in IGNORE_KINDS:
        return _d("ignore", "default", event, event.kind, "")
    if event.kind in DIGEST_KINDS:
        return _d("digest", "default", event, event.kind.replace(".", " "), "")
    return _d("ignore", "default", event, event.kind, "")
