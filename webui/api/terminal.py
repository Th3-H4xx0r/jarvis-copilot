"""Embedded workspace terminal support for JarvisCopilot Web UI.

The terminal is intentionally independent from the agent execution path.  It
starts a shell with an explicit cwd/env per process and never mutates
process-global os.environ, which avoids expanding the session-env race tracked
in the agent execution layer.
"""

from __future__ import annotations

import errno
import codecs
import fcntl
import os
import queue
import select
import shutil
import signal
import struct
import subprocess
import termios
import threading
from dataclasses import dataclass, field
from pathlib import Path


def _set_nonblocking(fd: int) -> None:
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)


def _winsize(rows: int, cols: int) -> bytes:
    rows = max(8, min(int(rows or 24), 80))
    cols = max(20, min(int(cols or 80), 240))
    return struct.pack("HHHH", rows, cols, 0, 0)


@dataclass
class TerminalSession:
    session_id: str
    workspace: str
    proc: subprocess.Popen
    master_fd: int
    rows: int = 24
    cols: int = 80
    output: queue.Queue = field(default_factory=lambda: queue.Queue(maxsize=2000))
    closed: threading.Event = field(default_factory=threading.Event)
    reader: threading.Thread | None = None
    # For an ATTACH terminal (live coding tmux): the tmux session name, so the
    # reader can tell a clean DETACH from the tmux session being GONE (claude
    # quit / ctrl-C) and emit reason="ended" accordingly.
    tmux_name: str | None = None
    close_reason: str | None = None

    def is_alive(self) -> bool:
        return not self.closed.is_set() and self.proc.poll() is None

    def put_output(self, event: str, payload: dict) -> None:
        try:
            self.output.put_nowait((event, payload))
        except queue.Full:
            # Keep the terminal responsive by dropping the oldest queued chunk.
            try:
                self.output.get_nowait()
            except queue.Empty:
                pass
            try:
                self.output.put_nowait((event, payload))
            except queue.Full:
                pass


_TERMINALS: dict[str, TerminalSession] = {}
_LOCK = threading.RLock()


def _decode_terminal_output(decoder, data: bytes) -> str:
    """Decode PTY bytes without stripping terminal control sequences."""
    return decoder.decode(data)


def _shell_path() -> str:
    shell = os.environ.get("SHELL") or ""
    if shell and Path(shell).exists():
        return shell
    return shutil.which("zsh") or shutil.which("bash") or shutil.which("sh") or "/bin/sh"


def _shell_argv(shell: str) -> list[str]:
    name = Path(shell).name
    if name in {"zsh", "bash", "sh"}:
        return [shell, "-i"]
    return [shell]


def _reader_loop(term: TerminalSession) -> None:
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    try:
        while not term.closed.is_set():
            if term.proc.poll() is not None:
                break
            try:
                ready, _, _ = select.select([term.master_fd], [], [], 0.25)
            except (OSError, ValueError):
                break
            if not ready:
                continue
            try:
                # Read big: a single tmux full-pane repaint can be tens of KB.
                # Pulling it in one read (vs many 8KB reads) means fewer queue
                # items → fewer SSE frames → far less terminal lag.
                data = os.read(term.master_fd, 65536)
            except OSError as exc:
                if exc.errno in (errno.EIO, errno.EBADF):
                    break
                raise
            if not data:
                break
            text = _decode_terminal_output(decoder, data)
            if text:
                term.put_output("output", {"text": text})
    except Exception as exc:
        term.put_output("terminal_error", {"error": str(exc)})
    finally:
        term.closed.set()
        code = term.proc.poll()
        payload = {"exit_code": code}
        # An ATTACH terminal whose tmux session is GONE means claude actually
        # ENDED (the user quit / ctrl-C'd it), not just a detach. Tell the client
        # via reason="ended" so it shows the ended panel instead of re-attaching
        # the dead tmux — re-attaching looped forever (the infinite-reload bug).
        tn = getattr(term, "tmux_name", None)
        if tn:
            try:
                r = subprocess.run(["tmux", "has-session", "-t", tn],
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=5)
                if r.returncode != 0:
                    payload["reason"] = "ended"
                    term.close_reason = "ended"
            except Exception:
                pass
        term.put_output("terminal_closed", payload)


def _set_size(term: TerminalSession, rows: int, cols: int) -> None:
    term.rows = max(8, min(int(rows or term.rows or 24), 80))
    term.cols = max(20, min(int(cols or term.cols or 80), 240))
    try:
        fcntl.ioctl(term.master_fd, termios.TIOCSWINSZ, _winsize(term.rows, term.cols))
    except OSError:
        pass
    try:
        if term.proc.poll() is None:
            os.killpg(term.proc.pid, signal.SIGWINCH)
    except (OSError, ProcessLookupError):
        pass


def start_terminal(session_id: str, workspace: Path, rows: int = 24, cols: int = 80, restart: bool = False) -> TerminalSession:
    """Start or return the embedded terminal for a WebUI session."""
    sid = str(session_id or "").strip()
    if not sid:
        raise ValueError("session_id is required")
    cwd = str(Path(workspace).expanduser().resolve())
    if not Path(cwd).is_dir():
        raise ValueError("workspace is not a directory")

    with _LOCK:
        current = _TERMINALS.get(sid)
        if current and current.is_alive() and not restart and current.workspace == cwd:
            _set_size(current, rows, cols)
            return current
        if current:
            close_terminal(sid)

        master_fd, slave_fd = os.openpty()
        # Build a safe env: allowlist common shell vars, strip API keys and secrets.
        # The PTY shell is an interactive UI surface — do not leak server credentials.
        _SAFE_ENV_KEYS = {
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
            "LC_CTYPE", "LC_MESSAGES", "LANGUAGE", "TZ", "TMPDIR", "TEMP",
            "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        }
        env = {k: v for k, v in os.environ.items() if k in _SAFE_ENV_KEYS}
        env.update(
            {
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
                "COLUMNS": str(cols),
                "LINES": str(rows),
                "PWD": cwd,
                "HERMES_WEBUI_TERMINAL": "1",
            }
        )
        shell = _shell_path()
        proc = subprocess.Popen(
            _shell_argv(shell),
            cwd=cwd,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            start_new_session=True,
        )
        os.close(slave_fd)
        _set_nonblocking(master_fd)

        term = TerminalSession(
            session_id=sid,
            workspace=cwd,
            proc=proc,
            master_fd=master_fd,
            rows=rows,
            cols=cols,
        )
        _set_size(term, rows, cols)
        term.reader = threading.Thread(target=_reader_loop, args=(term,), daemon=True)
        term.reader.start()
        _TERMINALS[sid] = term
        return term


def _tmux_set_mouse(name: str) -> None:
    """Best-effort: enable tmux mouse mode for session ``name``.

    With mouse mode on, the browser/mobile xterm forwards the wheel to tmux as
    real mouse events (tmux enters copy-mode and scrolls its scrollback) instead
    of xterm translating the wheel into ↑/↓ arrow keys — which the ``claude``
    REPL reads as command-history cycling. Idempotent; safe to call per attach.
    A missing/locked tmux server must never block the attach, so we swallow all
    errors.
    """
    try:
        subprocess.run(["tmux", "set-option", "-t", name, "mouse", "on"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=5, check=False)
    except Exception:
        pass


def start_attach_terminal(session_id: str, tmux_name: str,
                          rows: int = 24, cols: int = 80,
                          restart: bool = False) -> TerminalSession:
    """Start (or return) a live terminal ATTACHED to a coding session's tmux.

    Unlike ``start_terminal`` (which spawns a fresh shell in a workspace), this
    runs ``tmux attach-session -t <tmux_name>`` in a PTY so the WebUI can watch
    and type into the live ``claude`` session. Closing this terminal DETACHES
    (the tmux session and its claude keep running). Registered under
    ``session_id`` so the existing /api/terminal/{output,input,resize,close}
    machinery drives it unchanged.
    """
    sid = str(session_id or "").strip()
    if not sid:
        raise ValueError("session_id is required")
    name = str(tmux_name or "").strip()
    if not name:
        raise ValueError("tmux_name is required")
    if not shutil.which("tmux"):
        raise RuntimeError("tmux is not installed on this host")

    with _LOCK:
        current = _TERMINALS.get(sid)
        # Single live viewer per coding session. The live terminal is a view of
        # ONE tmux pane, which can only be a single size at a time and whose
        # output we fan out through one queue. If two viewers (e.g. web + phone)
        # attach at once they fight over the pane size — the smaller client wins
        # and squishes the other — AND race each other draining the output
        # queue. That is exactly the doubled / condensed / garbled terminal
        # users hit. So a new attach always TAKES OVER: tear down any existing
        # attach and re-attach fresh at THIS client's size. The previous
        # viewer's SSE sees terminal_closed and shows a "reopen to resume" note.
        if current:
            close_terminal(sid)

        # Mouse mode so the wheel scrolls tmux scrollback instead of cycling
        # the claude REPL's command history (see _tmux_set_mouse).
        _tmux_set_mouse(name)

        master_fd, slave_fd = os.openpty()
        _SAFE_ENV_KEYS = {
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
            "LC_CTYPE", "LC_MESSAGES", "LANGUAGE", "TZ", "TMPDIR", "TEMP",
            "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        }
        env = {k: v for k, v in os.environ.items() if k in _SAFE_ENV_KEYS}
        env.update({"TERM": "xterm-256color", "COLORTERM": "truecolor",
                    "COLUMNS": str(cols), "LINES": str(rows)})
        home = env.get("HOME") or os.path.expanduser("~") or "/"
        proc = subprocess.Popen(
            # -d detaches any other client first, guaranteeing this PTY is the
            # ONLY client so tmux sizes the pane to us (no smallest-client
            # squish from a leftover/stray attach).
            ["tmux", "attach-session", "-d", "-t", name],
            cwd=home, env=env,
            stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
            close_fds=True, start_new_session=True,
        )
        os.close(slave_fd)
        _set_nonblocking(master_fd)

        term = TerminalSession(session_id=sid, workspace=home, proc=proc,
                               master_fd=master_fd, rows=rows, cols=cols,
                               tmux_name=name)
        _set_size(term, rows, cols)
        term.reader = threading.Thread(target=_reader_loop, args=(term,), daemon=True)
        term.reader.start()
        _TERMINALS[sid] = term
        return term


def get_terminal(session_id: str) -> TerminalSession | None:
    with _LOCK:
        term = _TERMINALS.get(str(session_id or ""))
        if term and term.is_alive():
            return term
        return term


def register_terminal(session_id: str, term) -> None:
    """Register a TerminalSession-compatible object under ``session_id``.

    Used by non-PTY feeds (e.g. a desktop-host coding session whose output is
    fed by ``coding_term_output`` bridge frames). The object must expose the
    read surface the SSE route uses (``output`` queue, ``closed`` Event,
    ``proc.poll()``, ``is_alive()``); it MAY expose ``feed_write(data)`` /
    ``feed_resize(rows, cols)`` / ``feed_close()`` to override the PTY write
    path (see ``write_terminal`` / ``resize_terminal`` / ``close_terminal``).
    Replaces (closing) any terminal already registered under this id.
    """
    sid = str(session_id or "").strip()
    if not sid:
        raise ValueError("session_id is required")
    with _LOCK:
        current = _TERMINALS.get(sid)
    if current is not None and current is not term:
        close_terminal(sid)
    with _LOCK:
        _TERMINALS[sid] = term


def write_terminal(session_id: str, data: str) -> None:
    term = get_terminal(session_id)
    if not term or not term.is_alive():
        raise KeyError("terminal not running")
    feed_write = getattr(term, "feed_write", None)
    if callable(feed_write):
        feed_write(str(data or ""))
        return
    os.write(term.master_fd, str(data or "").encode("utf-8", errors="replace"))


def resize_terminal(session_id: str, rows: int, cols: int) -> None:
    term = get_terminal(session_id)
    if not term:
        raise KeyError("terminal not running")
    feed_resize = getattr(term, "feed_resize", None)
    if callable(feed_resize):
        feed_resize(rows, cols)
        return
    _set_size(term, rows, cols)


def close_terminal(session_id: str) -> bool:
    sid = str(session_id or "")
    with _LOCK:
        term = _TERMINALS.pop(sid, None)
    if not term:
        return False
    feed_close = getattr(term, "feed_close", None)
    if callable(feed_close):
        term.closed.set()
        try:
            feed_close()
        except Exception:
            pass
        return True
    term.closed.set()
    try:
        if term.proc.poll() is None:
            try:
                os.killpg(term.proc.pid, signal.SIGHUP)
            except ProcessLookupError:
                pass
            try:
                term.proc.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(term.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    finally:
        try:
            os.close(term.master_fd)
        except OSError:
            pass
    return True
