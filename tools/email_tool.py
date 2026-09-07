"""`send_email` — one obvious way to send mail, with attachments.

There was no email TOOL: Gmail lived behind a shell script and the SMTP path
behind `send_message`'s platform config. Asked to email a photo, the model
fired five `tool_search` calls, poked at `himalaya --help`, wrote a scratch
file, and gave up with "the email systems are currently proving uncooperative"
— while a configured, working himalaya account sat there the whole time.

Delivery order: himalaya (its account owns the credentials), else SMTP from
`send_message`'s email platform config. Attachments come from `attach` and
from `MEDIA:<path>` lines in the body, which is what the model actually emits.
"""
from __future__ import annotations

import json
import mimetypes
import os
import re
import shutil
import subprocess
from email import encoders
from email.mime.base import MIMEBase
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formatdate
from pathlib import Path
from typing import Any, Optional

from tools.registry import registry, tool_error

_MEDIA_TAG_RE = re.compile(r"^[ \t]*MEDIA:[ \t]*(?P<path>\S+)[ \t]*$", re.MULTILINE)
_SEND_TIMEOUT = 120


def _himalaya_binary() -> Optional[str]:
    return shutil.which("himalaya")


def _himalaya_config_path() -> Path:
    return Path(os.path.expanduser("~/.config/himalaya/config.toml"))


def _himalaya_sender() -> Optional[str]:
    """The default account's address. himalaya refuses a message with no
    sender ("cannot send message without a sender"), and it does not add one."""
    try:
        text = _himalaya_config_path().read_text(encoding="utf-8")
    except Exception:
        return None
    blocks = re.split(r"^\[", text, flags=re.MULTILINE)
    first_email = None
    for block in blocks:
        emails = re.findall(r'^\s*email\s*=\s*"([^"]+)"', block, flags=re.MULTILINE)
        if not emails:
            continue
        if first_email is None:
            first_email = emails[0]
        if re.search(r"^\s*default\s*=\s*true", block, flags=re.MULTILINE):
            name = re.findall(r'^\s*display-name\s*=\s*"([^"]+)"', block, flags=re.MULTILINE)
            return f'"{name[0]}" <{emails[0]}>' if name else emails[0]
    return first_email


def _run_himalaya(cmd: list, raw: str) -> tuple:
    proc = subprocess.run(cmd, input=raw, capture_output=True, text=True, timeout=_SEND_TIMEOUT)
    return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()


def _smtp_settings() -> Optional[dict]:
    """SMTP credentials from send_message's email platform, when present."""
    address = os.getenv("EMAIL_ADDRESS", "").strip()
    password = os.getenv("EMAIL_PASSWORD", "").strip()
    host = os.getenv("EMAIL_SMTP_HOST", "").strip()
    if not (address and password and host):
        return None
    try:
        port = int(os.getenv("EMAIL_SMTP_PORT", "587"))
    except (TypeError, ValueError):
        port = 587
    return {"address": address, "password": password, "host": host, "port": port}


def _collect_attachments(body: str, attach) -> tuple:
    """Return (cleaned_body, [(Path, bytes)], [warnings])."""
    paths = [str(p) for p in (attach or []) if str(p).strip()]
    warnings = []
    if "MEDIA:" in (body or ""):
        for match in _MEDIA_TAG_RE.finditer(body):
            paths.append(match.group("path").strip("`\"'"))
        body = _MEDIA_TAG_RE.sub("", body)
        body = re.sub(r"\n{3,}", "\n\n", body).strip()

    files = []
    for raw in paths:
        path = Path(os.path.expanduser(raw))
        try:
            if path.is_file():
                files.append((path, path.read_bytes()))
            else:
                warnings.append(f"attachment not found: {path}")
        except OSError as exc:
            warnings.append(f"could not read {path}: {exc}")
    return body, files, warnings


def _build(sender: str, to: str, subject: str, body: str, cc: str,
           html: bool, files) -> str:
    if files:
        msg = MIMEMultipart()
        msg.attach(MIMEText(body or "", "html" if html else "plain", "utf-8"))
        for path, blob in files:
            ctype, _ = mimetypes.guess_type(path.name)
            maintype, _, subtype = (ctype or "application/octet-stream").partition("/")
            part = MIMEBase(maintype, subtype or "octet-stream")
            part.set_payload(blob)
            encoders.encode_base64(part)
            part.add_header("Content-Disposition", "attachment", filename=path.name)
            msg.attach(part)
    else:
        msg = MIMEText(body or "", "html" if html else "plain", "utf-8")
    msg["From"] = sender
    msg["To"] = to
    msg["Subject"] = subject or "(no subject)"
    if cc:
        msg["Cc"] = cc
    msg["Date"] = formatdate(localtime=True)
    return msg.as_string()


def send_email(to: str = "", subject: str = "", body: str = "",
               attach=None, cc: str = "", html: bool = False) -> str:
    to = str(to or "").strip()
    if not to:
        return tool_error("`to` is required — who should receive this?", success=False)

    body, files, warnings = _collect_attachments(str(body or ""), attach)
    if not (body.strip() or files):
        return tool_error("nothing to send: give a body or an attachment", success=False)

    binary = _himalaya_binary()
    smtp = _smtp_settings()
    if not binary and not smtp:
        return tool_error(
            "Email is not configured. Set up a himalaya account (`himalaya account configure`) "
            "or EMAIL_ADDRESS / EMAIL_PASSWORD / EMAIL_SMTP_HOST.", success=False)

    result: dict[str, Any] = {"to": to, "subject": subject,
                             "attached": [p.name for p, _ in files]}
    if warnings:
        result["warnings"] = warnings

    if binary:
        sender = _himalaya_sender()
        if not sender:
            return tool_error("himalaya has no configured account to send from", success=False)
        raw = _build(sender, to, subject, body, cc, html, files)
        try:
            code, out, err = _run_himalaya([binary, "message", "send"], raw)
        except Exception as exc:
            return json.dumps({**result, "sent": False, "error": f"himalaya failed: {exc}"})
        if code != 0:
            return json.dumps({**result, "sent": False,
                               "error": (err or out or f"himalaya exited {code}")})
        return json.dumps({**result, "sent": True, "via": "himalaya", "from": sender})

    import smtplib
    import ssl
    raw = _build(smtp["address"], to, subject, body, cc, html, files)
    try:
        server = smtplib.SMTP(smtp["host"], smtp["port"])
        server.starttls(context=ssl.create_default_context())
        server.login(smtp["address"], smtp["password"])
        server.sendmail(smtp["address"], [to] + ([cc] if cc else []), raw)
        server.quit()
    except Exception as exc:
        return json.dumps({**result, "sent": False, "error": f"SMTP send failed: {exc}"})
    return json.dumps({**result, "sent": True, "via": "smtp", "from": smtp["address"]})


SEND_EMAIL_SCHEMA = {
    "name": "send_email",
    "description": (
        "Send an email, with attachments. This is THE way to send mail — do not shell out to "
        "himalaya, gmail scripts or SMTP. Attach a file with `attach` (e.g. the `image_path` "
        "from a photo skill); a MEDIA:<path> line in the body is attached too. Returns whether "
        "it was sent and what was attached."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "to": {"type": "string", "description": "Recipient address."},
            "subject": {"type": "string"},
            "body": {"type": "string", "description": "The message text."},
            "attach": {"type": "array", "items": {"type": "string"},
                       "description": "Absolute paths of files to attach."},
            "cc": {"type": "string"},
            "html": {"type": "boolean", "description": "Send the body as HTML."},
        },
        "required": ["to", "body"],
    },
}


def check_email_requirements() -> bool:
    return True


registry.register(
    name="send_email",
    toolset="messaging",
    schema=SEND_EMAIL_SCHEMA,
    handler=lambda args, **kw: send_email(
        to=args.get("to", ""),
        subject=args.get("subject", ""),
        body=args.get("body", ""),
        attach=args.get("attach") or [],
        cc=args.get("cc", ""),
        html=bool(args.get("html")),
    ),
    check_fn=check_email_requirements,
    emoji="📧",
)
