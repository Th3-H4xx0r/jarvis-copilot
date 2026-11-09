"""Plain-words names for security event kinds, shown on the Security pages and to Jarvis.

``title_for(kind, actor, detail)`` never raises; an unknown kind comes back as itself.
"""
from __future__ import annotations

TITLES = {
    "auth.failed": "Failed sign-in",
    "login.failed": "Failed sign-in",
    "login.ok": "Signed in",
    "pair.failed": "Pairing code rejected",
    "pair.claimed": "New device paired",
    "session.seen": "Session in use",
    "session.revoked": "Signed out",
    "device.revoked": "Device removed",
    "relay.opened": "Relay opened",
    "tui.opened": "Terminal opened",
    "request.blocked": "Blocked address refused",
    "config.secret_changed": "Settings key changed",
    "config.password_changed": "Webui password changed",
    "config.edge_changed": "Edge settings changed",
    "car.command": "Car command",
    "door.command": "Door command",
    "approval.requested": "Approval requested",
    "approval.answered": "Approval answered",
    "approval.result": "Approval answered",
    "inject.detected": "Prompt injection detected",
    "tool.risky": "Risky tool used",
    "agent.blocked": "Tool blocked (injection)",
    "gateway.message": "Message from a chat app",
    "ssh.accepted": "SSH login",
    "ssh.login": "SSH login",
    "ssh.failed": "SSH login failed",
    "sudo.command": "sudo command",
    "file.changed": "File changed",
    "repo.changed": "Code changed on the server",
    "repo.head_moved": "Server code updated",
    "advisor.code_changed": "Advisor code changed",
    "advisor.changed": "Advisor settings changed",
    "log.chain_broken": "Security log edited",
    "host.source_unavailable": "Watch unavailable",
    "security.dropped": "Events dropped",
}


def title_for(kind, actor=None, detail=None) -> str:
    kind = str(kind or "")
    try:
        actor, detail = actor or {}, detail or {}
        if kind in ("login.failed", "pair.failed") and detail.get("reason") == "rate_limited":
            return "Sign-in refused (too many tries)"
        if kind in ("ssh.accepted", "ssh.login") and actor.get("ip") in ("127.0.0.1", "::1"):
            return "SSH login via relay"
    except AttributeError:
        pass
    return TITLES.get(kind, kind)
