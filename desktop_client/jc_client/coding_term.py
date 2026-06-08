"""Desktop side of the coding-terminal relay.

The server opens a local coding session (``coding_term_open``); we spawn a
real PTY, exec the requested argv (typically
``["tmux","new-session","-A","-s",<name>, …claude…]``) inside it, and become a
DUMB PIPE between the bridge and that PTY:

  - PTY output bytes → ``coding_term_output`` frames back to the server
  - inbound ``coding_term_input`` → written to the PTY
  - ``coding_term_resize`` → resizes the PTY window
  - child exit → ``coding_term_exit`` with the exit code

This mirrors ``mcp_relay.McpRelayManager`` exactly: a per-id dict of children
under a lock, one reader thread per child pumping output back as bridge frames,
inbound frames written to the child, and defensive teardown of threads/fds. The
only differences are (a) it's a PTY rather than pipes (so ``tmux``/``claude``
behave as if attached to a terminal) and (b) the public API is dict-frame based
(``handle_frame(frame: dict)`` and ``send(frame: dict)``) to match the
coding-session protocol.

The PTY itself is abstracted behind a tiny ``_Pty`` interface
(``read/write/resize/close/poll``) so POSIX (stdlib ``pty``) and Windows
(``pywinpty``) share all the manager logic above it.
"""

from __future__ import annotations

import logging
import os
import sys
import threading
from typing import Callable, Optional

log = logging.getLogger(__name__)

# How much PTY output to grab per read. The reader loops, so this only bounds
# the size of a single ``coding_term_output`` frame, not throughput.
_READ_CHUNK = 65536
# Default window if the open frame omits rows/cols.
_DEFAULT_ROWS = 40
_DEFAULT_COLS = 120
# How long to wait after a graceful terminate before SIGKILL (POSIX).
_KILL_GRACE_S = 2.0


# ── PTY abstraction ─────────────────────────────────────────────────────────


class _Pty:
    """Minimal cross-platform PTY interface.

    Subclasses implement ``read()`` (bytes, b"" at EOF), ``write(data: bytes)``,
    ``resize(rows, cols)``, ``poll()`` (exit code or None while running) and
    ``close()`` (terminate child + free fds). Construction spawns the child.
    """

    def read(self) -> bytes:  # pragma: no cover - interface
        raise NotImplementedError

    def write(self, data: bytes) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def resize(self, rows: int, cols: int) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def poll(self) -> Optional[int]:  # pragma: no cover - interface
        raise NotImplementedError

    def close(self) -> None:  # pragma: no cover - interface
        raise NotImplementedError


class _PosixPty(_Pty):
    """POSIX PTY using stdlib ``pty.openpty`` + ``subprocess.Popen``.

    The child runs in its own session (``start_new_session=True``) with the
    slave end as its controlling terminal, so tmux/claude get a real tty and
    job-control/SIGWINCH behave. We read the master fd with ``os.read`` and
    write to it directly.
    """

    def __init__(self, argv: list[str], cwd: Optional[str],
                 env: Optional[dict], rows: int, cols: int):
        import pty
        import subprocess

        self._master, slave = pty.openpty()
        # Apply the initial window size before exec so the child's first paint
        # already fits (tmux reads the winsize at startup).
        try:
            self._set_winsize(rows, cols)
        except Exception as exc:  # noqa: BLE001
            log.debug("initial winsize failed: %s", exc)

        full_env = dict(os.environ)
        if env:
            # Stringify everything — execve rejects non-str env values.
            full_env.update({str(k): str(v) for k, v in env.items()})
        # A sane TERM so curses/tmux render; only set if the caller didn't.
        full_env.setdefault("TERM", "xterm-256color")

        try:
            self._proc = subprocess.Popen(
                argv,
                stdin=slave,
                stdout=slave,
                stderr=slave,
                start_new_session=True,
                cwd=cwd or None,
                env=full_env,
                close_fds=True,
            )
        finally:
            # The child owns the slave now; the parent must drop its copy or
            # the master never sees EOF when the child exits.
            try:
                os.close(slave)
            except OSError:
                pass

    def _set_winsize(self, rows: int, cols: int) -> None:
        import fcntl
        import struct
        import termios

        winsize = struct.pack("HHHH", max(1, int(rows)), max(1, int(cols)), 0, 0)
        fcntl.ioctl(self._master, termios.TIOCSWINSZ, winsize)

    def read(self) -> bytes:
        try:
            return os.read(self._master, _READ_CHUNK)
        except OSError:
            # EIO is the normal "slave closed" signal on Linux; treat as EOF.
            return b""

    def write(self, data: bytes) -> None:
        os.write(self._master, data)

    def resize(self, rows: int, cols: int) -> None:
        self._set_winsize(rows, cols)

    def poll(self) -> Optional[int]:
        return self._proc.poll()

    def close(self) -> None:
        import signal

        proc = self._proc
        try:
            if proc.poll() is None:
                # Signal the whole process group (new session leader) so tmux's
                # children die too, not just the wrapper.
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except (ProcessLookupError, PermissionError, OSError):
                    proc.terminate()
                try:
                    proc.wait(timeout=_KILL_GRACE_S)
                except Exception:  # noqa: BLE001 - still alive → hard kill
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except (ProcessLookupError, PermissionError, OSError):
                        try:
                            proc.kill()
                        except Exception:  # noqa: BLE001
                            pass
        except Exception as exc:  # noqa: BLE001
            log.debug("posix pty terminate failed: %s", exc)
        try:
            os.close(self._master)
        except OSError:
            pass


class _WindowsPty(_Pty):
    """Windows PTY via ``pywinpty``. Imported lazily so the module loads (and
    POSIX tests run) without pywinpty installed; the manager raises a clear
    error to the caller if it's actually needed and missing."""

    def __init__(self, argv: list[str], cwd: Optional[str],
                 env: Optional[dict], rows: int, cols: int):
        import winpty  # type: ignore  # raises ImportError if not installed

        full_env = dict(os.environ)
        if env:
            full_env.update({str(k): str(v) for k, v in env.items()})
        # pywinpty's spawn takes a single command list and (rows, cols).
        self._proc = winpty.PtyProcess.spawn(
            argv,
            cwd=cwd or None,
            env=full_env,
            dimensions=(max(1, int(rows)), max(1, int(cols))),
        )

    def read(self) -> bytes:
        try:
            data = self._proc.read(_READ_CHUNK)
        except EOFError:
            return b""
        if not data:
            return b""
        return data.encode("utf-8", "replace") if isinstance(data, str) else data

    def write(self, data: bytes) -> None:
        self._proc.write(data.decode("utf-8", "replace")
                         if isinstance(data, (bytes, bytearray)) else data)

    def resize(self, rows: int, cols: int) -> None:
        self._proc.setwinsize(max(1, int(rows)), max(1, int(cols)))

    def poll(self) -> Optional[int]:
        if self._proc.isalive():
            return None
        # exitstatus may be None right at the edge; default to 0.
        code = getattr(self._proc, "exitstatus", None)
        return 0 if code is None else int(code)

    def close(self) -> None:
        try:
            if self._proc.isalive():
                self._proc.terminate(force=True)
        except Exception as exc:  # noqa: BLE001
            log.debug("windows pty terminate failed: %s", exc)


def _open_pty(argv: list[str], cwd: Optional[str], env: Optional[dict],
              rows: int, cols: int) -> _Pty:
    """Factory: pick the platform PTY implementation and spawn the child.

    Raises ImportError (Windows, pywinpty missing) or OSError/ValueError (bad
    argv/cwd) — the manager catches these and reports a ``coding_term_exit``."""
    if sys.platform == "win32":
        return _WindowsPty(argv, cwd, env, rows, cols)
    return _PosixPty(argv, cwd, env, rows, cols)


# ── per-terminal session ────────────────────────────────────────────────────


class _Term:
    """One live terminal: its PTY + reader thread + bookkeeping."""

    def __init__(self, term_id: str, pty: _Pty):
        self.term_id = term_id
        self.pty = pty
        self.reader: Optional[threading.Thread] = None
        self.closing = False  # set when WE initiated teardown (suppress exit)


# ── manager ─────────────────────────────────────────────────────────────────


class CodingTermManager:
    """Owns the per-id coding-terminal PTYs for one bridge connection.

    Thread-safe. ``send`` is the connection's frame-sender, called as
    ``send(frame: dict)`` to push a JSON-able frame back over the bridge
    (mirrors how ``McpRelayManager`` is handed ``ws.send_text``; here the
    coding-session protocol speaks dict frames, so we pass dicts).
    """

    def __init__(self, send: Callable[[dict], None]):
        self._send = send
        self._terms: dict[str, _Term] = {}
        self._lock = threading.Lock()

    # ── bridge frame dispatch ───────────────────────────────────────────

    def handle_frame(self, frame: dict) -> None:
        """Single entry point: dispatch an inbound bridge frame by ``type``.

        Never raises — a bad/unexpected frame is logged and dropped so the
        receive loop stays alive."""
        try:
            if not isinstance(frame, dict):
                return
            ftype = frame.get("type")
            if ftype == "coding_term_open":
                self._handle_open(frame)
            elif ftype == "coding_term_input":
                self._handle_input(frame)
            elif ftype == "coding_term_resize":
                self._handle_resize(frame)
            elif ftype == "coding_term_close":
                self._handle_close(frame)
            else:
                log.debug("coding_term: ignoring frame type %r", ftype)
        except Exception as exc:  # noqa: BLE001 - defensive; never bubble up
            log.warning("coding_term handle_frame failed: %s", exc)

    # individual handlers (kept separate so service.py could also call them
    # directly if it dispatches frames itself, the way it calls
    # McpRelayManager.handle_open/handle_frame/handle_close).

    def _handle_open(self, frame: dict) -> None:
        term_id = str(frame.get("term_id") or "")
        if not term_id:
            log.warning("coding_term_open missing term_id")
            return
        with self._lock:
            existing = self._terms.get(term_id)
            if existing is not None:
                # A fresh open for a term_id we already hold = the server wants a
                # NEW attach (e.g. the viewer reopened the live terminal). Replace
                # the old PTY instead of silently ignoring the open — ignoring left
                # "reopen" permanently dead. Mark it closing BEFORE it leaves the
                # registry, so if the old child happens to die in this window its
                # reader still sees closing=True and does NOT emit a spurious
                # coding_term_exit (which the server would read as the session
                # ending). Both mutations under one lock so the flag can't be
                # observed-as-False after eviction.
                existing.closing = True
                self._terms.pop(term_id, None)
        if existing is not None:
            try:
                existing.pty.close()
            except Exception as exc:  # noqa: BLE001
                log.debug("coding_term_open replace: closing old %s failed: %s",
                          term_id, exc)
            log.info("coding_term_open: %s re-opened — replaced existing PTY",
                     term_id)
        argv = frame.get("argv")
        if not isinstance(argv, list) or not argv or not all(
            isinstance(a, str) for a in argv
        ):
            self._emit_exit(term_id, code=-1,
                            error="coding_term_open requires a non-empty string argv")
            return
        cwd = frame.get("cwd")
        env = frame.get("env") if isinstance(frame.get("env"), dict) else None
        rows = _as_int(frame.get("rows"), _DEFAULT_ROWS)
        cols = _as_int(frame.get("cols"), _DEFAULT_COLS)

        try:
            pty = _open_pty(argv, cwd if isinstance(cwd, str) else None,
                            env, rows, cols)
        except ImportError as exc:
            # Windows without pywinpty — clear, actionable, non-fatal.
            self._emit_exit(
                term_id, code=-1,
                error=("PTY unavailable: pywinpty is not installed "
                       f"(pip install pywinpty). {exc}"),
            )
            return
        except Exception as exc:  # noqa: BLE001 - bad argv/cwd/etc.
            self._emit_exit(term_id, code=-1, error=f"failed to open pty: {exc}")
            return

        term = _Term(term_id, pty)
        with self._lock:
            self._terms[term_id] = term
        reader = threading.Thread(
            target=self._pump_output, args=(term,),
            daemon=True, name=f"coding-term-{term_id[:8]}",
        )
        term.reader = reader
        reader.start()
        log.info("coding terminal %s opened (%s)", term_id, argv[0])

    def _handle_input(self, frame: dict) -> None:
        term_id = str(frame.get("term_id") or "")
        with self._lock:
            term = self._terms.get(term_id)
        if not term:
            return
        data = frame.get("data")
        if data is None:
            return
        payload = data.encode("utf-8", "replace") if isinstance(data, str) else bytes(data)
        try:
            term.pty.write(payload)
        except Exception as exc:  # noqa: BLE001 - child gone / broken pipe
            log.debug("coding_term_input write failed for %s: %s", term_id, exc)

    def _handle_resize(self, frame: dict) -> None:
        term_id = str(frame.get("term_id") or "")
        with self._lock:
            term = self._terms.get(term_id)
        if not term:
            return
        rows = _as_int(frame.get("rows"), _DEFAULT_ROWS)
        cols = _as_int(frame.get("cols"), _DEFAULT_COLS)
        try:
            term.pty.resize(rows, cols)
        except Exception as exc:  # noqa: BLE001
            log.debug("coding_term_resize failed for %s: %s", term_id, exc)

    def _handle_close(self, frame: dict) -> None:
        term_id = str(frame.get("term_id") or "")
        with self._lock:
            term = self._terms.pop(term_id, None)
        if term is None:
            return
        term.closing = True  # suppress the exit frame for a caller-initiated close
        try:
            term.pty.close()
        except Exception as exc:  # noqa: BLE001
            log.debug("coding_term_close teardown failed for %s: %s", term_id, exc)
        log.info("coding terminal %s closed", term_id)

    def shutdown_all(self) -> None:
        """Tear down every terminal — called on bridge disconnect (mirrors
        McpRelayManager.shutdown_all)."""
        with self._lock:
            terms = list(self._terms.values())
            self._terms.clear()
        for term in terms:
            term.closing = True
            try:
                term.pty.close()
            except Exception:  # noqa: BLE001
                pass

    # ── internals ───────────────────────────────────────────────────────

    def _pump_output(self, term: _Term) -> None:
        """Reader thread: stream PTY output as ``coding_term_output`` frames
        until EOF, then emit ``coding_term_exit`` (unless WE closed it)."""
        term_id = term.term_id
        try:
            while True:
                data = term.pty.read()
                if not data:
                    break  # EOF — slave closed / child exited
                self._emit_output(term_id, data)
        except Exception as exc:  # noqa: BLE001
            log.debug("coding_term output pump ended for %s: %s", term_id, exc)
        finally:
            # Drop from the registry ONLY if it's still THIS term (a re-open may
            # have replaced us under the same term_id — we must not evict the new
            # PTY). ``mine`` = the registry entry was ours (child exited on its own).
            with self._lock:
                mine = self._terms.get(term_id) is term
                if mine:
                    self._terms.pop(term_id, None)
            if not term.closing:
                code = _safe_poll(term.pty)
                # Free the master fd now that the pump is done with it.
                if mine:
                    try:
                        term.pty.close()
                    except Exception:  # noqa: BLE001
                        pass
                self._emit_exit(term_id, code=code if code is not None else 0)

    # ── frame emitters ──────────────────────────────────────────────────

    def _emit_output(self, term_id: str, data: bytes) -> None:
        # Decode to text for the JSON frame; replace undecodable bytes so a
        # mid-UTF-8 split chunk never crashes the pump. (Frames are line/JSON
        # based downstream, so text is the right wire shape here.)
        text = data.decode("utf-8", "replace")
        self._emit({"type": "coding_term_output", "term_id": term_id, "data": text})

    def _emit_exit(self, term_id: str, code: int, error: Optional[str] = None) -> None:
        frame = {"type": "coding_term_exit", "term_id": term_id, "code": int(code)}
        if error:
            frame["error"] = error
        self._emit(frame)

    def _emit(self, frame: dict) -> None:
        try:
            self._send(frame)
        except Exception as exc:  # noqa: BLE001 - connection closed
            log.debug("coding_term emit %s failed: %s", frame.get("type"), exc)


# ── helpers ─────────────────────────────────────────────────────────────────


def _as_int(value: object, default: int) -> int:
    try:
        n = int(value)  # type: ignore[arg-type]
        return n if n > 0 else default
    except (TypeError, ValueError):
        return default


def _safe_poll(pty: _Pty) -> Optional[int]:
    try:
        return pty.poll()
    except Exception:  # noqa: BLE001
        return None
