"""jc-client's end of the coding-agent hooks.

``jc-hook`` (run by Claude Code and other agents for every hook event)
connects to a UNIX socket here and sends one JSON frame. This module feeds the
frame to the shared engine (local state for the Mac island), forwards it to
the server over the device bridge, and hands blocking kinds (a permission
request, an AskUserQuestion) to the approval arbiter, which answers on the
same connection. Every path is best-effort: a broken bridge or a bad frame
never stops a hook.
"""
from __future__ import annotations

import json
import logging
import os
import socket
import threading
import time
import uuid
from typing import Callable, Optional

try:
    from jc_client import agent_engine
except ImportError:  # loaded by file path on the server (agent/agent_engine_shim.py)
    from agent import agent_engine_shim as agent_engine

log = logging.getLogger(__name__)

_READ_TIMEOUT = 5.0
_MAX_LINE = 1024 * 1024
_BLOCKING_KINDS = ("permission", "ask")


class HookServer:
    def __init__(self, path: str, engine,
                 forward: Callable[[dict], None], arbiter=None,
                 on_effects: Optional[Callable[[list], None]] = None,
                 on_usage: Optional[Callable[[dict], None]] = None,
                 host: str = "local", sweep_every: float = 1.0,
                 ingest: Optional[Callable[[str, str, dict], list]] = None,
                 on_stop: Optional[Callable[[str, dict], Optional[dict]]] = None,
                 on_gate: Optional[Callable[[str, dict], Optional[dict]]] = None,
                 on_hook: Optional[Callable[[str, str, dict], None]] = None) -> None:
        """``ingest(kind, agent, payload) -> effects`` replaces the local engine
        (the server feeds its own tracker); with it, ``engine`` may be None."""
        self.path = path
        self.host = host
        self._engine = engine
        self._ingest = ingest
        self._forward = forward
        self._arbiter = arbiter
        self._on_effects = on_effects
        # A Stop (kind "stop") is answered with what waits for the session — a
        # message from the phone — so the hook can make Claude carry on with it.
        self._on_stop = on_stop
        # A prompt or tool call (kind "gate") is answered with whether this
        # session may go on here: a session that moved to the server may not.
        self._on_gate = on_gate
        # Every event, after the engine: the roster and transcript shipper.
        self._on_hook = on_hook
        self._on_usage = on_usage
        self._limits: Optional[dict] = None   # merged plan usage (agent_engine.merge_rate_limits)
        self._sweep_every = sweep_every
        self._lock = threading.RLock()
        self._sock: Optional[socket.socket] = None
        self._stop = threading.Event()

    # ── lifecycle ──────────────────────────────────────────────────────
    def start(self) -> None:
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            sock.bind(self.path)
        finally:
            os.umask(old)
        os.chmod(self.path, 0o600)
        sock.listen(32)
        self._sock = sock
        threading.Thread(target=self._accept_loop, daemon=True, name="hook-accept").start()
        if self._sweep_every and self._engine is not None:
            threading.Thread(target=self._sweep_loop, daemon=True, name="hook-sweep").start()
        log.info("hook server listening on %s", self.path)

    def close(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        try:
            os.unlink(self.path)
        except OSError:
            pass

    # ── engine access (thread-safe) ────────────────────────────────────
    def usage(self) -> Optional[dict]:
        """The merged plan usage so far (for the Mac app's hello)."""
        with self._lock:
            return dict(self._limits) if self._limits else None

    def engine_sessions(self) -> list:
        with self._lock:
            return self._engine.sessions()

    def with_engine(self, fn):
        """Run ``fn(engine)`` under the engine lock; its effects are emitted."""
        with self._lock:
            effects = fn(self._engine)
        self._emit(effects if isinstance(effects, list) else [])
        return effects

    # ── loops ──────────────────────────────────────────────────────────
    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            sock = self._sock
            if sock is None:
                return
            try:
                conn, _ = sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True,
                             name="hook-conn").start()

    def _sweep_loop(self) -> None:
        while not self._stop.wait(self._sweep_every):
            try:
                with self._lock:
                    effects = self._engine.sweep()
                self._emit(effects)
            except Exception:
                log.debug("engine sweep failed", exc_info=True)

    # ── one connection ─────────────────────────────────────────────────
    def _read_line(self, conn: socket.socket) -> bytes:
        conn.settimeout(_READ_TIMEOUT)
        buf = b""
        while b"\n" not in buf and len(buf) < _MAX_LINE:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
        return buf.split(b"\n", 1)[0]

    def _handle(self, conn: socket.socket) -> None:
        keep_open = False
        try:
            line = self._read_line(conn)
            try:
                frame = json.loads(line)
            except Exception:
                return
            if not isinstance(frame, dict) or not isinstance(frame.get("payload"), dict):
                return
            kind = str(frame.get("kind") or "event")
            agent = str(frame.get("agent") or "claude")
            payload = frame["payload"]
            if kind in _BLOCKING_KINDS and not payload.get("tool_use_id"):
                # Claude's PermissionRequest carries no tool_use_id, so two
                # identical asks (parallel subagents, the same command twice)
                # would share a fingerprint and one answer would settle both.
                # A stamp made here travels up with the payload, so the Mac,
                # the server and the phone all agree on it.
                payload["tool_use_id"] = "jc-" + uuid.uuid4().hex[:20]
            if kind == "statusline":
                # Sent several times a second per session, each with its own
                # stale snapshot: only a real step forward goes anywhere.
                with self._lock:
                    merged = agent_engine.merge_rate_limits(self._limits, payload.get("rate_limits"))
                    if merged is not None:
                        self._limits = merged
                if merged is None:
                    return
                payload = dict(payload, rate_limits=merged)
                self._send_up(kind, agent, payload)
                if self._on_usage is not None:
                    try:
                        self._on_usage(payload)
                    except Exception:
                        log.debug("usage callback failed", exc_info=True)
                return
            self._send_up(kind, agent, payload)
            key = agent_engine.session_key(self.host, agent, str(payload.get("session_id") or ""),
                                           str(payload.get("cwd") or ""))
            engine_kind = kind if kind in _BLOCKING_KINDS else "event"
            if kind == "gate":
                answer = None
                if self._on_gate is not None:
                    try:
                        answer = self._on_gate(agent, payload)
                    except Exception:
                        log.debug("on_gate failed", exc_info=True)
                self._reply(conn, answer or {})
            if self._ingest is not None:
                effects = self._ingest(engine_kind, agent, payload) or []
            else:
                with self._lock:
                    effects = self._engine.ingest(self.host, agent, payload, kind=engine_kind)
            self._emit(effects)
            if self._on_hook is not None:
                try:
                    self._on_hook(kind, agent, payload)
                except Exception:
                    log.debug("on_hook failed", exc_info=True)
            if kind not in _BLOCKING_KINDS:
                if self._arbiter is not None:
                    try:
                        self._arbiter.observe(payload, key)
                    except Exception:
                        log.debug("arbiter observe failed", exc_info=True)
                if kind == "stop":
                    answer = None
                    if self._on_stop is not None:
                        try:
                            answer = self._on_stop(agent, payload)
                        except Exception:
                            log.debug("on_stop failed", exc_info=True)
                    self._reply(conn, answer or {})
                return
            if self._arbiter is None:
                self._reply(conn, {"decision": "ask"})
                return
            keep_open = True
            self._hand_to_arbiter(conn, kind, agent, payload, key)
        except Exception:
            log.debug("hook connection failed", exc_info=True)
        finally:
            if not keep_open:
                try:
                    conn.close()
                except OSError:
                    pass

    def _hand_to_arbiter(self, conn, kind, agent, payload, key) -> None:
        done = threading.Event()
        lock = threading.Lock()

        def reply(answer: dict) -> None:
            with lock:
                if done.is_set():
                    return
                done.set()
                self._reply(conn, answer if isinstance(answer, dict) else {"decision": "ask"})
                try:
                    conn.close()
                except OSError:
                    pass

        token = self._arbiter.submit(kind, agent, payload, key, reply)
        # Watch the hook's end: if Claude gives up on it (answered in the
        # terminal, killed), the request is settled elsewhere.
        try:
            conn.settimeout(None)
            while not done.is_set():
                chunk = conn.recv(1)
                if not chunk:
                    break
        except OSError:
            pass
        if not done.is_set():
            gone = getattr(self._arbiter, "peer_gone", None)
            if gone is not None:
                try:
                    gone(token)
                except Exception:
                    log.debug("arbiter peer_gone failed", exc_info=True)
            reply({"decision": "ask"})

    # ── helpers ────────────────────────────────────────────────────────
    def _reply(self, conn: socket.socket, answer: dict) -> None:
        try:
            conn.settimeout(2.0)
            conn.sendall((json.dumps(answer) + "\n").encode())
        except OSError:
            pass

    def _send_up(self, kind: str, agent: str, payload: dict) -> None:
        try:
            self._forward({"type": "event", "name": "agent_hook",
                           "data": {"kind": kind, "agent": agent, "payload": payload,
                                    "ts": time.time()}})
        except Exception:
            log.debug("agent_hook forward failed", exc_info=True)

    def _emit(self, effects: list) -> None:
        if effects and self._on_effects is not None:
            try:
                self._on_effects(effects)
            except Exception:
                log.debug("effects callback failed", exc_info=True)
