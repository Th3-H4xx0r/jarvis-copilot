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
_PING_INTERVAL = 20.0  # keepalive cadence; a text ping every 20s stays well
                       # under the ~50-60s edge idle timeout that was dropping us
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
        # Coding Sessions desktop execution + file sync + discovery (created
        # per connection).
        self._coding_term = None
        self._coding_sync = None
        self._coding_discover = None

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

    def _write_connection_state(self, state: str) -> None:
        """Persist the live connection state (+ our pid) so a SEPARATE
        launchd/systemd-supervised tray process can show the REAL green/red
        status. Without this the tray guessed from the log tail, which returned
        'unknown' (grey 'Supervised') whenever the recent log was full of other
        chatter — exactly when a long-lived connection is healthy."""
        try:
            from jc_client.logger import state_dir
            import tempfile
            d = state_dir()
            payload = {"state": state, "at": time.time(), "pid": os.getpid()}
            fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".conn-state-")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(payload, fh)
            os.replace(tmp, str(d / "connection_state.json"))
        except Exception as exc:  # noqa: BLE001 — status I/O must never break the service
            log.debug("connection_state write failed: %s", exc)

    def coding_sync_active_count(self) -> int:
        """Number of currently-open Coding-Session file syncs.

        Read by the tray to surface a "Sync: N active" status line. The
        CodingSyncAgent is created per-connection (and torn down to None
        between connections / during a reconnect), so this returns 0 when
        there is no live agent. Never raises."""
        agent = self._coding_sync
        if agent is None:
            return 0
        try:
            return int(agent.active_count())
        except Exception:
            return 0

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
            self._write_connection_state("reconnecting")
            if self._stop.wait(delay):
                break

        log.info("jc-client service stopped")
        self._write_connection_state("stopped")
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
        self._write_connection_state("connected")

        # Spin up the MCP relay for this connection (Phase 2). Lazily imported
        # so a desktop without the relay still runs every other skill.
        # MCP-over-bridge relay (A1) is OFF by default — superseded by the
        # chrome_* device skills (A2), which couldn't complete tool discovery
        # over the real bridge. Only wire it up (manager + announce) if explicitly
        # re-enabled with browser_relay_mcp: true; otherwise mcp_open is ignored
        # so it can't spawn a Playwright child that conflicts with A2's.
        self._relay = None
        if _relay_mcp_enabled():
            try:
                from jc_client.mcp_relay import McpRelayManager, find_npx
                self._relay = McpRelayManager(
                    send=ws.send_text,
                    extension=_playwright_extension_enabled(),
                    extension_token=_playwright_extension_token(),
                )
                if find_npx():
                    ws.send_text(json.dumps(
                        {"type": "mcp_relay_available", "meta": {"browser": "chrome"}}
                    ))
                    log.info("announced mcp relay capability")
                else:
                    log.info("npx not found — not announcing mcp relay")
            except Exception as exc:
                log.warning("mcp relay unavailable: %s", exc)
                self._relay = None

        # Coding Sessions: desktop execution (PTY relay) + bidirectional file
        # sync. Always on (core feature). Frames flow over this same bridge.
        try:
            from jc_client.coding_sync_mutagen import CodingMutagenAgent
            from jc_client.coding_term import CodingTermManager
            from jc_client.coding_discover import CodingDiscoverAgent

            def _coding_send(f):
                ws.send_text(json.dumps(f))

            self._coding_term = CodingTermManager(send=_coding_send)
            self._coding_sync = CodingMutagenAgent(send=_coding_send)
            # Discovery: periodically scan for live `claude` tmux sessions and
            # push them upstream so the server can surface them as coding
            # sessions. device_id may be "" here — the server fills it from the
            # bridge in that case.
            self._coding_discover = CodingDiscoverAgent(
                send=_coding_send, device_id=(creds.device_id or None))
            self._coding_discover.start()
            # Authorize this client's sync key on the server so Mutagen's SSH
            # (through the WS<->TCP relay) can connect. Idempotent on both ends.
            try:
                pub = self._coding_sync.pubkey()
                if pub:
                    _coding_send({"type": "coding_sync_authorize_key", "pubkey": pub})
            except Exception as exc:  # noqa: BLE001
                log.debug("sync key authorize push failed: %s", exc)
        except Exception as exc:
            log.warning("coding sessions desktop support unavailable: %s", exc)
            self._coding_term = None
            self._coding_sync = None
            self._coding_discover = None

        # Warm up the browser MCP (chrome_* skills) so the first browser action
        # isn't a cold `npx @playwright/mcp` start + extension attach. Best-effort,
        # off the connect path.
        try:
            from jc_client.mcp_relay import find_npx
            if find_npx():
                from jc_client.browser_mcp import browser_mcp
                threading.Thread(target=browser_mcp().start, daemon=True,
                                 name="browser-warmup").start()
        except Exception:
            pass

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
                    # A TEXT data frame (not just a WS control PING): edges like
                    # cloudflared/nginx often only reset their idle timeout on
                    # DATA frames, so a control ping alone let the connection
                    # drop every ~50s. Send both.
                    ws.send_text(json.dumps({"type": "ping"}))
                    ws.send_ping(b"jc")
                except WsConnectionClosed:
                    return
                except Exception:
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
            for _mgr_attr, _stop in (("_coding_term", "shutdown_all"),
                                     ("_coding_sync", "close"),
                                     ("_coding_discover", "close")):
                _m = getattr(self, _mgr_attr, None)
                if _m is not None:
                    try:
                        getattr(_m, _stop)()
                    except Exception:
                        pass
                    setattr(self, _mgr_attr, None)
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

        if msg_type and msg_type.startswith("coding_term_"):
            if self._coding_term:
                self._coding_term.handle_frame(frame)
            return

        if msg_type and msg_type.startswith("coding_sync_"):
            if self._coding_sync:
                self._coding_sync.handle_frame(frame)
            return

        if msg_type and (msg_type.startswith("coding_discover")
                         or msg_type in ("coding_transcript_get",
                                         "coding_transcript_put",
                                         "coding_file_put")):
            if self._coding_discover:
                self._coding_discover.handle_frame(frame)
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


def _playwright_extension_enabled() -> bool:
    """Whether to drive the user's existing Chrome via the Playwright Extension
    (visible, logged-in) instead of a dedicated profile.

    Explicit ``playwright_extension`` in ~/.jarviscopilot-client/config.yaml wins;
    otherwise auto-enable when the extension is actually installed (its token is
    readable from Chrome) — so the user just installs the extension and the rest
    is automatic, no flag or token to set."""
    try:
        import yaml
        from jc_client.logger import state_dir
        raw = yaml.safe_load((state_dir() / "config.yaml").read_text()) or {}
        if "playwright_extension" in raw:
            return bool(raw.get("playwright_extension"))
    except Exception:
        pass
    try:
        from jc_client.mcp_relay import read_extension_token_from_chrome
        return read_extension_token_from_chrome() is not None
    except Exception:
        return False


def _relay_mcp_enabled() -> bool:
    """Whether to announce the MCP-over-bridge relay (A1). Default False — A2
    (chrome_* device skills) is the supported path. Opt back in with
    ``browser_relay_mcp: true`` in ~/.jarviscopilot-client/config.yaml."""
    try:
        import yaml
        from jc_client.logger import state_dir
        raw = yaml.safe_load((state_dir() / "config.yaml").read_text()) or {}
        return bool(raw.get("browser_relay_mcp"))
    except Exception:
        return False


def _playwright_extension_token() -> Optional[str]:
    """The Playwright Extension's connection token (from its status page), used
    to auto-connect the --extension server without the interactive dialog. Read
    from ~/.jarviscopilot-client/config.yaml `playwright_extension_token`."""
    try:
        import yaml
        from jc_client.logger import state_dir
        raw = yaml.safe_load((state_dir() / "config.yaml").read_text()) or {}
        tok = raw.get("playwright_extension_token")
        return str(tok) if tok else None
    except Exception:
        return None


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
