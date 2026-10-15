"""Send one email through Resend, with the server's key and the configured
From address. Only the Mac app's Send button calls this (POST
/api/services/mail/send); the Resend poller stays read-only.
"""
from __future__ import annotations

import re

from jarvis_services.base import ServiceError, call_json

API = "https://api.resend.com"
ENV = "SERVICES_RESEND_API_KEY"
MAX_TO = 10
MAX_SUBJECT = 300
MAX_TEXT = 100_000
_ADDRESS = re.compile(r"^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$")


def _recipients(raw) -> list:
    parts = raw if isinstance(raw, list) else re.split(r"[,;\s]+", str(raw or ""))
    to = [p.strip() for p in parts if str(p).strip()]
    if not to:
        raise ValueError("Who to? Add at least one address.")
    if len(to) > MAX_TO:
        raise ValueError(f"At most {MAX_TO} recipients.")
    for a in to:
        if not _ADDRESS.match(a):
            raise ValueError(f"{a} is not an email address.")
    return to


def send(http, cfg, *, to, subject: str, text: str) -> dict:
    key = cfg.secret(ENV)
    if not key:
        raise ValueError("No Resend key yet: add one under Services → Resend.")
    sender = str(cfg.setting("resend", "from", "") or "").strip()
    if not sender:
        raise ValueError("Set the From address under Services → Resend first.")
    recipients = _recipients(to)
    subject = str(subject or "").strip()
    if not subject or len(subject) > MAX_SUBJECT:
        raise ValueError(f"The subject must be 1–{MAX_SUBJECT} characters.")
    text = str(text or "")
    if not text.strip():
        raise ValueError("The message is empty.")
    if len(text) > MAX_TEXT:
        raise ValueError("The message is too long.")
    try:
        body = call_json(http, "POST", f"{API}/emails",
                         headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                         json={"from": sender, "to": recipients, "subject": subject, "text": text}, timeout=20)
    except ServiceError as e:
        return {"ok": False, "error": str(e) or "Resend refused the email."}
    return {"ok": True, "id": (body or {}).get("id") or ""}
