"""Main daemon: connect to the server, register skills, execute invokes.

Pseudo-loop::

    while not stop:
        creds = credentials.load()
        if not creds.paired: sleep + retry
        ws = WsConnection(creds.server_url, creds.cookie, creds.cert_fingerprint)
        ws.connect()
        ws.send_text({"type":"register", "skills":[...]})
        spawn periodic ping thread
        for frame in ws.read_frames():
            handle(frame)
        backoff before reconnect

Public entry point: ``run(...)``. Used by both ``jc-client start``
(foreground / systemd ExecStart) and the tray app (spawned as a
background thread when the tray boots).
"""
from __future__ import annotations

import json
import logging
import os
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

from jc_client import credentials
from jc_client.logger import setup as setup_logging
from jc_client.protocol import WsConnection, WsConnectionClosed
from jc_client import skills

log = logging.getLogger(__name__)

# Reconnection backoff schedule (seconds).
_BACKOFF_SECONDS = [1, 2, 4, 8, 16, 32, 60]
_PING_INTERVAL = 30.0
_MAX_CONCURRENT_INVOKES = 8
# Per-skill watchdog. Stay under the server's invoke_skill default of 30s
# so the bot gets our error before timing out itself.
_SKILL_TIMEOUT_S = 20.0
_SKILL_SLOW_S = 3.0


class Service:
    """Encapsulates the connect-and-dispatch loop. Stoppable via
    ``stop()`` from any thread (tray, signal handler, etc.)."""

    def __init__(self) -> None:
        self._stop = threading.Event()
        self._paused = threading.Event()
        # When paused, invokes return {"ok":false,"error":"paused"}.
        self._executor = ThreadPoolExecutor(
            max_workers=_MAX_CONCURRENT_INVOKES,
            thread_name_prefix="skill-invoke",
        )
        self._ws: Optional[WsConnection] = None
        self._registered_count = 0
        self._connected = False
        self._last_connect_attempt = 0.0
        self._last_error = ""
        # Per-connection MCP relay manager (Phase 2): tunnels a local Playwright
        # MCP to the server. Created in _connect_and_pump, torn down on drop.
        self._relay = None

    # ── public ────────────────────────────────────────────────────────

    def stop(self) -> None:
        self._stop.set()
        if self._ws:
            try:
                self._ws.close()
            except Exception:
                pass

    def pause(self) -> None:
        self._paused.set()
        log.info("service paused; invokes will be rejected")

    def resume(self) -> None:
        self._paused.clear()
        log.info("service resumed")

    @property
    def is_paused(self) -> bool:
        return self._paused.is_set()

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def status_summary(self) -> dict:
        creds = credentials.load()
        return {
            "paired": creds.paired,
            "server": creds.server_url,
            "device_name": creds.device_name,
            "connected": self._connected,
            "paused": self.is_paused,
            "skills_registered": self._registered_count,
            "last_error": self._last_error,
        }

    # ── loop ──────────────────────────────────────────────────────────

    def run(self) -> int:
        """Main loop. Returns shell exit code on stop."""
        log.info("jc-client service starting")
        # Load the skill registry exactly once, here in run(), so every
        # caller — module-level run(), run_with_handle(), the tray that
        # creates a Service() directly, embedded tests — ends up with a
        # populated _REGISTRY before the connect loop sends the
        # register frame. (Otherwise the tray path silently sent an
        # empty manifest and the server reported `skills: []`.)
        try:
            skills.load_all(allow_shell=credentials.load().allow_shell)
            log.info("skill registry has %d entries", len(skills.registered_names()))
        except Exception as exc:
            log.error("skill registry load failed: %s", exc)
        backoff_idx = 0

        while not self._stop.is_set():
            creds = credentials.load()
            if not creds.paired:
                self._last_error = "not paired — run `jc-client pair`"
                log.warning(self._last_error)
                # Wait longer when there's nothing to do — re-check every
                # 5 seconds so a fresh pair flow can start us promptly.
                if self._stop.wait(5):
                    break
                continue

            self._last_connect_attempt = time.time()
            try:
                self._connect_and_pump(creds)
                backoff_idx = 0  # successful disconnect → reset backoff
            except Exception as exc:
                self._last_error = str(exc)
                log.warning("connection ended: %s", exc)

            self._connected = False
            if self._stop.is_set():
                break

            delay = _BACKOFF_SECONDS[min(backoff_idx, len(_BACKOFF_SECONDS) - 1)]
            backoff_idx += 1
            log.info("reconnecting in %ss …", delay)
            if self._stop.wait(delay):
                break

        log.info("jc-client service stopped")
        self._executor.shutdown(wait=False, cancel_futures=True)
        return 0

    # ── inner ─────────────────────────────────────────────────────────

    def _connect_and_pump(self, creds: credentials.Credentials) -> None:
        ws = WsConnection(
            server_url=creds.server_url,
            cookie=creds.cookie,
            expected_fingerprint=creds.cert_fingerprint,
            cf_client_id=creds.cf_client_id,
            cf_client_secret=creds.cf_client_secret,
        )
        ws.connect()
        self._ws = ws
        self._connected = True
        self._last_error = ""
        log.info("connected to %s", creds.server_url)

        # Spin up the MCP relay for this connection (Phase 2). Lazily imported
        # so a desktop without the relay still runs every other skill.
        try:
            from jc_client.mcp_relay import McpRelayManager
            self._relay = McpRelayManager(send=ws.send_text)
        except Exception as exc:
            log.warning("mcp relay unavailable: %s", exc)
            self._relay = None

        # Announce relay capability so the server auto-registers a browser-relay
        # MCP server for this device (no hand-edited device_id). Only if npx is
        # available, since the relay spawns `npx @playwright/mcp`.
        if self._relay is not None:
            from jc_client.mcp_relay import find_npx
            if find_npx():
                try:
                    ws.send_text(json.dumps(
                        {"type": "mcp_relay_available", "meta": {"browser": "chrome"}}
                    ))
                    log.info("announced mcp relay capability")
                except Exception:
                    pass
            else:
                log.info("npx not found — not announcing mcp relay")

        # Register skills immediately. The deployed device bridge silently
        # drops WS messages larger than its socket recv buffer (~8 KB), so
        # we chunk the manifest. The first chunk REPLACES the registry;
        # subsequent chunks carry ``append: true`` so a server that
        # supports it accumulates. Older servers (no append support) end
        # up with only the last chunk's skills — degraded but not broken.
        manifest = skills.all_manifest(disabled=creds.skills_disabled)
        self._registered_count = len(manifest)
        chunks = _chunk_manifest(manifest, max_bytes=6 * 1024)
        for i, chunk in enumerate(chunks):
            frame = {"type": "register", "skills": chunk}
            if i == 0:
                frame["device"] = {
                    "name": creds.device_name,
                    "platform": _platform_summary(),
                }
            else:
                frame["append"] = True
            ws.send_text(json.dumps(frame))
        log.info(
            "registered %d skills in %d frame(s)", len(manifest), len(chunks)
        )

        # Periodic ping thread — keeps NATs / load balancers from
        # silently dropping the connection if the server is idle.
        ping_stop = threading.Event()

        def _pinger() -> None:
            while not ping_stop.wait(_PING_INTERVAL):
                try:
                    ws.send_ping(b"jc")
                except WsConnectionClosed:
                    return

        ping_thread = threading.Thread(target=_pinger, daemon=True, name="ws-ping")
        ping_thread.start()

        try:
            for frame in ws.read_frames():
                if self._stop.is_set():
                    break
                self._handle_frame(ws, frame)
        finally:
            ping_stop.set()
            if self._relay is not None:
                try:
                    self._relay.shutdown_all()
                except Exception:
                    pass
                self._relay = None
            try:
                ws.close()
            except Exception:
                pass
            self._ws = None

    def _handle_frame(self, ws: WsConnection, frame: dict) -> None:
        msg_type = frame.get("type")
        if msg_type == "invoke":
            call_id = frame.get("call_id") or ""
            skill_name = frame.get("skill") or ""
            args = frame.get("args") or {}
            if not call_id or not skill_name:
                log.warning("invoke missing call_id/skill: %r", frame)
                return
            if self.is_paused:
                self._send_error(ws, call_id, "client is paused")
                return
            # Dispatch on the worker pool so a 30s screenshot doesn't
            # starve the receive loop.
            self._executor.submit(self._run_invoke, ws, call_id, skill_name, args)
            return

        if msg_type == "mcp_open":
            if self._relay:
                self._relay.handle_open(frame.get("session") or "", frame.get("meta"))
            return

        if msg_type == "mcp_frame":
            if self._relay:
                self._relay.handle_frame(frame.get("session") or "", frame.get("data") or "")
            return

        if msg_type == "mcp_close":
            if self._relay:
                self._relay.handle_close(frame.get("session") or "")
            return

        if msg_type == "ping":
            try:
                ws.send_text(json.dumps({"type": "pong"}))
            except WsConnectionClosed:
                pass
            return

        if msg_type in ("hello", "registered", "pong"):
            log.debug("server: %s", msg_type)
            return

        log.warning("unknown frame type: %r", msg_type)

    def _run_invoke(
        self, ws: WsConnection, call_id: str, name: str, args: dict
    ) -> None:
        log.info("invoke %s args=%s", name, _truncate(args))

        # Watchdog: run the skill in a worker thread and wait with a
        # timeout. If the skill hangs (osascript stuck waiting on a
        # process, a system dialog blocking input, etc.), we still send
        # an error to the bot within the timeout instead of letting the
        # bot time out at 30s on its end. The hung skill thread leaks
        # but the bot stays responsive.
        holder: dict = {"result": None, "exc": None}
        done = threading.Event()

        def _runner() -> None:
            try:
                holder["result"] = skills.invoke(name, args)
            except BaseException as e:
                holder["exc"] = e
            finally:
                done.set()

        t = threading.Thread(
            target=_runner, daemon=True, name=f"skill-{name}-{call_id[:8]}"
        )
        t.start()
        t0 = time.monotonic()
        if not done.wait(timeout=_SKILL_TIMEOUT_S):
            elapsed = time.monotonic() - t0
            log.warning(
                "skill %s call_id=%s exceeded %.0fs — abandoning (thread leaks)",
                name, call_id, elapsed,
            )
            self._send_error(
                ws, call_id,
                f"skill {name!r} timed out after {int(elapsed)}s",
            )
            return

        exc = holder["exc"]
        if exc is not None:
            if isinstance(exc, KeyError):
                self._send_error(ws, call_id, f"unknown skill: {name}")
                return
            if isinstance(exc, TypeError):
                self._send_error(ws, call_id, f"bad args: {exc}")
                return
            log.error(
                "skill %s raised: %s\n%s",
                name, exc, "".join(traceback.format_exception(type(exc), exc, exc.__traceback__)),
            )
            self._send_error(ws, call_id, f"{type(exc).__name__}: {exc}")
            return

        result = holder["result"]
        wall = time.monotonic() - t0
        if wall > _SKILL_SLOW_S:
            log.warning("skill %s took %.2fs (slow)", name, wall)
        payload = json.dumps({"type": "result", "call_id": call_id, "result": result})
        t0 = time.monotonic()
        try:
            ws.send_text(payload)
        except WsConnectionClosed as exc:
            log.warning(
                "result send failed for %s call_id=%s bytes=%d: %s",
                name, call_id, len(payload), exc,
            )
            return
        except Exception as exc:
            log.error(
                "result send raised for %s call_id=%s bytes=%d: %s",
                name, call_id, len(payload), exc,
            )
            return
        log.info(
            "result sent %s call_id=%s bytes=%d in %.2fs",
            name, call_id, len(payload), time.monotonic() - t0,
        )

    def _send_error(self, ws: WsConnection, call_id: str, msg: str) -> None:
        try:
            ws.send_text(
                json.dumps({"type": "error", "call_id": call_id, "error": msg})
            )
        except WsConnectionClosed:
            pass


# ── helpers ────────────────────────────────────────────────────────────────


def _platform_summary() -> dict:
    import platform as _p

    return {
        "system": _p.system(),
        "release": _p.release(),
        "machine": _p.machine(),
    }


def _truncate(obj: object, limit: int = 200) -> str:
    """Short repr of an arg dict, suitable for logging without bloat."""
    try:
        s = json.dumps(obj, default=str)
    except Exception:
        s = repr(obj)
    if len(s) <= limit:
        return s
    return s[:limit] + "...(truncated)"


def _chunk_manifest(manifest: list[dict], max_bytes: int) -> list[list[dict]]:
    """Split a skill manifest into groups whose JSON envelope stays under
    ``max_bytes``. Always returns at least one chunk (possibly empty)."""
    # Rough envelope overhead for the register frame around the skills array
    # — type field, append flag, device field on the first frame.
    overhead = 256
    budget = max(512, max_bytes - overhead)

    chunks: list[list[dict]] = []
    current: list[dict] = []
    current_size = 2  # the "[]" framing
    for skill in manifest:
        s_size = len(json.dumps(skill)) + 1  # +1 for comma
        if current and current_size + s_size > budget:
            chunks.append(current)
            current = []
            current_size = 2
        current.append(skill)
        current_size += s_size
    if current or not chunks:
        chunks.append(current)
    return chunks


# ── module entry ───────────────────────────────────────────────────────────


def run(verbose: bool = False) -> int:
    """Foreground entry. Called from ``jc-client start`` and from the
    tray when it spawns a background thread."""
    setup_logging(level="DEBUG" if verbose else "INFO", verbose=verbose)
    creds = credentials.load()
    skills.load_all(allow_shell=creds.allow_shell)

    service = Service()
    # Catch SIGTERM / SIGINT so systemd `stop` shuts us down cleanly.
    import signal

    def _sig(_signum, _frame):
        log.info("received signal, stopping")
        service.stop()

    try:
        signal.signal(signal.SIGINT, _sig)
        signal.signal(signal.SIGTERM, _sig)
    except (ValueError, OSError):
        # Not in main thread (e.g. tray runs service in a thread).
        pass

    return service.run()


# Cross-module handle so the tray app can pause/resume/restart the
# running service without reaching into module internals.
ACTIVE: Service | None = None


def run_with_handle(verbose: bool = False) -> int:
    """Same as ``run()`` but exposes the Service via ``ACTIVE`` for the
    tray to talk to."""
    global ACTIVE
    setup_logging(level="DEBUG" if verbose else "INFO", verbose=verbose)
    creds = credentials.load()
    skills.load_all(allow_shell=creds.allow_shell)
    ACTIVE = Service()
    try:
        return ACTIVE.run()
    finally:
        ACTIVE = None
