"""The IT agent's PC side (wire contracts W1/W2 in docs/superpowers/plans/2026-11-18-it-agent.md).

pc_shell runs one PowerShell command as the signed-in user (unelevated), PATH refreshed so a tool installed
a step earlier is found, killed with its children at its timeout. admin_run asks Pranav's Face ID through
the password broker; on his signed yes the Jarvis helper runs the exact command elevated (kind admin-run),
or — elevated false, a destructive command he must approve — jc-client runs it unelevated (kind pc-run).
Both are server-only skills: only the IT agent's supervisor calls them, behind its classifier and gates."""
from __future__ import annotations

import base64
import html
import re
import subprocess
import threading
import time
from typing import Optional

PRELUDE = ("$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; "
           "$env:WSL_UTF8='1'\n"
           "$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'"
           "+[Environment]::GetEnvironmentVariable('Path','User')")
# After the command: exit with its own code. PowerShell -EncodedCommand otherwise ends 0/1, losing winget's
# "already installed" and an installer's 3010 "restart required" (outside what his Face ID signs).
EXIT_FOOTER = ("$jcOk = $?; if (-not $jcOk) { if ($global:LASTEXITCODE) { exit $global:LASTEXITCODE } "
               "else { exit 1 } }; exit 0")
READ_GRACE_S = 3.0   # once PowerShell exits, how long its output gets (an app it started may hold the pipe)
ARGV = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand"]
SHELL_MAX_CHARS = 8000
ADMIN_MAX_CHARS = 2400       # the server, the phone and the helper all carry the whole signed command
STDOUT_TAIL = 12000
STDERR_TAIL = 4000
_CLIXML_ERROR = re.compile(r'<S S="Error">(.*?)</S>', re.S)
_power = None


def set_power(power) -> None:
    global _power
    _power = power


def _clamp(value, default: int, low: int, high: int) -> int:
    try:
        return max(low, min(high, int(value)))
    except (TypeError, ValueError):
        return default


def encoded(command: str) -> str:
    return base64.b64encode((PRELUDE + "\n" + command + "\n" + EXIT_FOOTER).encode("utf-16-le")).decode("ascii")


def _pump(stream, buf: bytearray) -> None:
    read = getattr(stream, "read1", None) or stream.read
    try:
        while True:
            chunk = read(65536)
            if not chunk:
                return
            buf.extend(chunk)
            if len(buf) > 400_000:   # keep the tail
                del buf[:len(buf) - 200_000]
    except (OSError, ValueError):
        return


def _kill_tree(pid: int) -> None:
    import psutil
    try:
        parent = psutil.Process(pid)
        procs = parent.children(recursive=True) + [parent]
    except psutil.NoSuchProcess:
        return
    for p in procs:
        try:
            p.kill()
        except psutil.NoSuchProcess:
            pass


def _clixml(text: str) -> str:
    """PowerShell writes errors as CLIXML on stderr when it's redirected: keep only their text. A tool's own
    stderr (wsl.exe's) can come first (live), so the block is found wherever it starts."""
    at = text.find("#< CLIXML")
    if at < 0:
        return text
    head, xml = text[:at], text[at:]
    parts = _CLIXML_ERROR.findall(xml)
    if not parts:
        return text
    def plain(s: str) -> str:
        return html.unescape(re.sub(r"_x([0-9A-Fa-f]{4})_", lambda m: chr(int(m.group(1), 16)), s))
    body = "".join(plain(p) for p in parts).replace("\r\n", "\n").rstrip("\n")
    return f"{head.rstrip(chr(10))}\n{body}" if head.strip() else body


def _text(raw) -> str:
    if isinstance(raw, bytes):
        # wsl.exe (and a few other tools) write UTF-16LE whatever the console says — WSL_UTF8 is ignored
        # while WSL isn't installed: a quarter or more NUL bytes means UTF-16 text, so drop the NULs.
        if raw and raw.count(b"\x00") * 4 >= len(raw):
            raw = raw.replace(b"\x00", b"")
        raw = raw.decode("utf-8", errors="replace")
    return str(raw or "").replace("\r\r\n", "\n").replace("\r\n", "\n")


def run_powershell(command: str, timeout_s, *, popen=subprocess.Popen, kill_tree=_kill_tree,
                   clock=time.monotonic) -> dict:
    t = _clamp(timeout_s, 120, 5, 1800)
    start = clock()
    proc = popen(ARGV + [encoded(command)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                 stderr=subprocess.PIPE, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    out, err = bytearray(), bytearray()
    readers = [threading.Thread(target=_pump, args=(stream, buf), name="jc-pc-shell-out", daemon=True)
               for stream, buf in ((proc.stdout, out), (proc.stderr, err))]
    for r in readers:
        r.start()
    timed_out = False
    try:   # wait for PowerShell itself, not its pipes: an app it started keeps them open
        proc.wait(timeout=t)
    except subprocess.TimeoutExpired:
        timed_out = True
        kill_tree(proc.pid)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    deadline = time.monotonic() + READ_GRACE_S
    for r in readers:
        r.join(max(0.0, deadline - time.monotonic()))
    stdout, stderr = _text(bytes(out)), _clixml(_text(bytes(err)))
    code = None if timed_out else proc.returncode
    if isinstance(code, int) and code >= 2 ** 31:   # a Windows exit code is a DWORD: winget's are negative
        code -= 2 ** 32
    return {"ok": True, "exit_code": code, "stdout": stdout[-STDOUT_TAIL:],
            "stderr": stderr[-STDERR_TAIL:], "truncated": len(stdout) > STDOUT_TAIL or len(stderr) > STDERR_TAIL,
            "timed_out": timed_out, "duration_ms": int((clock() - start) * 1000)}


def pc_shell(command: str, timeout_s: int = 120) -> dict:
    if len(command or "") > SHELL_MAX_CHARS:
        return {"ok": False, "error": f"command too long (max {SHELL_MAX_CHARS} characters)"}
    return run_powershell(command or "", timeout_s)


def _not_run(status: str, error: str) -> dict:
    return {"ok": False, "status": status, "exit_code": None, "output": "", "truncated": False, "timed_out": False,
            "duration_ms": 0, "error": error}


def admin_run(command: str, why: str = "", timeout_s: int = 600, elevated: bool = True) -> dict:
    command = command or ""
    if len(command) > ADMIN_MAX_CHARS:
        return _not_run("refused", f"command too long to sign (max {ADMIN_MAX_CHARS} characters)")
    if not command.strip():
        return _not_run("refused", "no command")
    power: Optional[object] = _power
    if power is None:
        return _not_run("failed", "PC power isn't running in jc-client")
    kind = "admin-run" if elevated else "pc-run"
    return power.passwords.request(kind, command, why=str(why or "")[:300],
                                   run_timeout=_clamp(timeout_s, 600, 10, 1800))


def register() -> None:
    from jc_client.skills import skill
    skill("pc_shell", "Run one PowerShell command on this PC as the signed-in user (unelevated); returns its "
                      "exit code and output. Server-only (the IT agent).",
          {"type": "object", "properties": {"command": {"type": "string"}, "timeout_s": {"type": "integer"}},
           "required": ["command"]}, destructive=True,
          watchdog=lambda a: _clamp(a.get("timeout_s"), 120, 5, 1800) + 15)(pc_shell)
    skill("admin_run", "Run one command after Pranav's Face ID on his iPhone: elevated through the Jarvis helper "
                       "(or unelevated with elevated false). Server-only (the IT agent).",
          {"type": "object", "properties": {"command": {"type": "string"}, "why": {"type": "string"},
                                            "timeout_s": {"type": "integer"}, "elevated": {"type": "boolean"}},
           "required": ["command"]}, destructive=True,
          watchdog=lambda a: 120 + _clamp(a.get("timeout_s"), 600, 10, 1800) + 30)(admin_run)
