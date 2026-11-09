"""Follow sshd and sudo in the systemd journal and emit security events.

``journalctl -o json -f`` gives one JSON object per line. Matches on the same
field are OR'ed, so one process follows sshd (``sshd-session`` on OpenSSH 9.8+)
and sudo together.
"""
from __future__ import annotations

import json
import logging
import re
import subprocess
import threading

logger = logging.getLogger(__name__)

DEFAULT_CMD = ["journalctl", "-o", "json", "-f", "-n", "0",
               "SYSLOG_IDENTIFIER=sshd", "SYSLOG_IDENTIFIER=sshd-session", "SYSLOG_IDENTIFIER=sudo"]
_SSHD = {"sshd", "sshd-session"}

_ACCEPTED = re.compile(
    r"^Accepted (?P<method>\S+) for (?P<user>\S+) from (?P<ip>\S+) port \d+(?: \S+)?(?:: (?P<key>.+))?$")
_FAILED = re.compile(
    r"^Failed (?P<method>\S+) for (?P<invalid>invalid user )?(?P<user>\S+) from (?P<ip>\S+) port \d+")
_INVALID = re.compile(r"^Invalid user (?P<user>\S*) from (?P<ip>\S+) port \d+")
_SUDO = re.compile(r"^\s*(?P<user>\S+) : .*?USER=(?P<as_user>\S+) ; COMMAND=(?P<command>.+)$")


def parse_journal_line(line: str):
    """``(kind, actor, detail)`` for an sshd/sudo journal line, else None."""
    try:
        rec = json.loads(line)
    except (TypeError, ValueError):
        return None
    if not isinstance(rec, dict):
        return None
    ident = str(rec.get("SYSLOG_IDENTIFIER") or rec.get("_COMM") or "")
    msg = rec.get("MESSAGE")
    if not isinstance(msg, str):
        return None
    msg = msg.strip()
    if ident in _SSHD:
        m = _ACCEPTED.match(msg)
        if m:
            return ("ssh.accepted", {"ip": m["ip"], "user": m["user"]},
                    {"method": m["method"], "key": (m["key"] or "").strip()})
        m = _FAILED.match(msg)
        if m:
            return ("ssh.failed", {"ip": m["ip"], "user": m["user"]},
                    {"method": m["method"], "invalid_user": bool(m["invalid"])})
        m = _INVALID.match(msg)
        if m:
            return ("ssh.failed", {"ip": m["ip"], "user": m["user"]},
                    {"method": "none", "invalid_user": True})
        return None
    if ident == "sudo":
        m = _SUDO.match(msg)
        if m:
            return ("sudo.command", {"user": m["user"], "as_user": m["as_user"]},
                    {"command": m["command"].strip()[:500]})
    return None


class SshFollower:
    """Runs ``journalctl -f`` on a daemon thread; restarts it with backoff (5 s → 5 min)."""

    def __init__(self, emit=None, cmd: list[str] | None = None):
        if emit is None:
            from security.events import emit
        self.emit = emit
        self.cmd = list(cmd or DEFAULT_CMD)
        self.state = "stopped"
        self._stop = threading.Event()
        self._proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="security-ssh", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        proc = self._proc
        if proc and proc.poll() is None:
            try:
                proc.terminate()
            except Exception:
                pass
        if self._thread:
            self._thread.join(timeout=5)
        if self.state == "running":
            self.state = "stopped"

    def _run(self) -> None:
        backoff = 5.0
        while not self._stop.is_set():
            try:
                self._proc = subprocess.Popen(self.cmd, stdout=subprocess.PIPE,
                                              stderr=subprocess.DEVNULL, text=True)
            except (FileNotFoundError, PermissionError) as e:
                self.state = "unavailable"
                self.emit("host", "host.source_unavailable", {}, source_name="ssh", error=str(e)[:200])
                return
            self.state = "running"
            try:
                for line in self._proc.stdout:
                    parsed = parse_journal_line(line)
                    if parsed:
                        kind, actor, detail = parsed
                        self.emit("host", kind, actor, **detail)
                    backoff = 5.0
            except Exception as e:
                logger.debug("ssh follower read failed: %s", e)
            finally:
                try:
                    self._proc.wait(timeout=5)
                except Exception:
                    pass
            if self._stop.wait(backoff):
                break
            backoff = min(backoff * 2, 300.0)
