"""Continue one of the owner's Codex CLI sessions on the server.

When his Mac sleeps, a Codex session he was running there can carry on here,
driven from his phone as a chat: the server resumes the same thread from its
copy of the rollout file and Jarvis feeds it turns and answers its approvals.

CodexRuntime — spike findings (2026-10-17, Codex CLI 0.163.0 on the Mac)
------------------------------------------------------------------------
Chosen path: ``codex app-server`` over stdio. Resume, a turn and an approval
round trip were all exercised live against a throwaway thread.

* Protocol: newline-delimited JSON-RPC on stdin/stdout. No ``"jsonrpc"``
  field is needed. ``codex app-server generate-json-schema --out DIR`` (or
  ``generate-ts``) dumps the full schema. Config warnings go to stderr.
* Handshake: request ``initialize {clientInfo:{name,version}}`` (the result
  carries ``userAgent`` and ``codexHome``), then the notification
  ``initialized`` (no id).
* ``thread/start {cwd, model?, approvalPolicy?, sandbox?}`` returns
  ``{thread:{id,...}}``.
* ``thread/resume {threadId, cwd?, model?, approvalPolicy?, sandbox?,
  excludeTurns?}`` loads the rollout from disk. For a top-level session the
  thread id IS the session id: the id in ``rollout-…-<id>.jsonl`` and the
  ``thread_id`` that ``codex exec --json`` prints. A thread that ``codex exec``
  started resumed fine. Resume found the thread from nothing but the rollout
  file copied to ``$CODEX_HOME/sessions/YYYY/MM/DD/`` in an otherwise empty
  CODEX_HOME. No ``session_index.jsonl`` or sqlite was needed; Codex creates
  its DBs on first use. The ``cwd`` passed to resume overrides the Mac path
  recorded in the rollout.
* ``turn/start {threadId, input:[{type:"text", text, text_elements:[]}]}``
  answers at once with ``{turn:{id,status:"inProgress"}}``. Progress then
  arrives as notifications: ``turn/started``, ``item/started``,
  ``item/completed``, ``item/agentMessage/delta``, ``thread/status/changed``
  (``activeFlags:["waitingOnApproval"]``), and finally ``turn/completed
  {threadId, turn:{status: completed|interrupted|failed, items}}``.
  ``turn/start`` on a busy thread adds the input to the active turn.
  ``turn/steer`` and ``turn/interrupt`` also exist.
* Approvals are server→client requests. They carry an ``id``, and those ids
  count up from **0** within each process.
  - ``item/commandExecution/requestApproval {threadId, turnId, itemId,
    command (one shell string), cwd, reason?}``. Answer
    ``{decision: "accept"|"acceptForSession"|"decline"|"cancel"}``.
  - ``item/fileChange/requestApproval {threadId, turnId, itemId, reason?,
    grantRoot?}``. Same decisions. The file list is only on the preceding
    ``item/started`` fileChange item (``changes:[{path, kind, diff}]``).
  - ``mcpServer/elicitation/request`` with
    ``_meta.codex_approval_kind == "mcp_tool_call"`` asks before an MCP tool
    runs. Answer ``{action: "accept"|"decline"|"cancel", content?}``. If it
    goes unanswered, the turn hangs (seen live).
  - ``item/permissions/requestApproval``. Answer ``{permissions, scope}``.
  - ``execCommandApproval`` / ``applyPatchApproval`` are the legacy v1 forms.
    Their decision is ``"approved"`` or ``{"denied":{"rejection"}}``.
  - Every answer is followed by ``serverRequest/resolved {threadId,
    requestId}``.
* ``codex login status`` exits 0 with "Logged in using ChatGPT". With no auth
  it exits 1 with "Not logged in". Auth lives in ``$CODEX_HOME/auth.json``
  (default ``~/.codex``), so the subprocess needs HOME and no API keys.
* The fallback, ``codex exec resume <SESSION_ID> --json "<prompt>"``, also
  works non-interactively: stdin must be closed, and it takes ``-m`` and
  ``--skip-git-repo-check``. It prints JSONL: ``thread.started{thread_id}``,
  ``turn.started``, ``item.completed{item:{type:"agent_message", text}}``
  and ``turn.completed{usage}``. Config warnings arrive as
  ``item.completed{type:"error"}``. It appends to the same rollout. It has
  no approval channel: exec runs with approvals "never". That is why the
  app-server path was chosen.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger(__name__)


# ── CodexRuntime: continue a Codex session on the server ─────────────────────
# One `codex app-server` child per running thread. The handle is the thread
# id, which is the Codex session id. Approvals wait in `pending_approvals()`
# until the phone answers them. See the spike notes in the module docstring.

try:  # one DeliveryError for both runtimes, so a handoff catches one type
    from agent.server_runtime import DeliveryError
except Exception:  # noqa: BLE001 — never break the AIAgent codex path above
    class DeliveryError(Exception):
        """A message could not be put into the session; ``str()`` says why."""

NOT_INSTALLED = "Codex isn't installed on the server"
NOT_LOGGED_IN = "Codex isn't logged in on the server — run `codex login` there"
_CLIENT_INFO = {"name": "jarvis", "title": "Jarvis", "version": "1.0"}
_SECRET_SUFFIXES = ("_API_KEY", "_TOKEN", "_SECRET", "_PASSWORD", "_ACCESS_KEY")
_APPROVAL_KINDS = {
    "item/commandExecution/requestApproval": "command",
    "execCommandApproval": "command",
    "item/fileChange/requestApproval": "file_change",
    "applyPatchApproval": "file_change",
    "item/permissions/requestApproval": "permissions",
    "mcpServer/elicitation/request": "mcp_tool",
}


def _codex_env(home: str) -> dict:
    """The parent env minus every credential-looking variable (Codex logs in
    from ``$CODEX_HOME/auth.json``; an ambient API key would bill the API)."""
    env = {k: v for k, v in os.environ.items()
           if not k.upper().endswith(_SECRET_SUFFIXES)}
    for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
        env.pop(k, None)
    env["HOME"] = home
    return env


def _approval_result(method: str, params: dict, allow: bool) -> dict:
    if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
        return {"decision": "accept" if allow else "decline"}
    if method in ("execCommandApproval", "applyPatchApproval"):
        return {"decision": "approved" if allow
                else {"denied": {"rejection": "Denied from Jarvis"}}}
    if method == "item/permissions/requestApproval":
        return {"permissions": (params.get("permissions") or {}) if allow else {},
                "scope": "turn"}
    return {"action": "accept", "content": {}} if allow else {"action": "decline"}


class _AppServer:
    """One ``codex app-server`` child: request/response over stdio, every
    other message (notifications, server requests) handed to ``on_message``."""

    def __init__(self, proc, on_message: Callable) -> None:
        self.proc = proc
        self._on_message = on_message
        self._wlock = threading.Lock()
        self._ids = 0
        self._waiting: dict = {}
        self.stderr_tail: deque = deque(maxlen=20)
        threading.Thread(target=self._read, daemon=True, name="codex-app-server").start()
        if getattr(proc, "stderr", None) is not None:
            threading.Thread(target=self._drain_stderr, daemon=True).start()

    def alive(self) -> bool:
        return self.proc.poll() is None

    def write(self, obj: dict) -> None:
        with self._wlock:
            self.proc.stdin.write(json.dumps(obj) + "\n")
            self.proc.stdin.flush()

    def request(self, method: str, params: dict, timeout: float) -> dict:
        with self._wlock:
            self._ids += 1
            rid = self._ids
        slot = [threading.Event(), None]
        self._waiting[rid] = slot
        try:
            self.write({"id": rid, "method": method, "params": params})
        except (OSError, ValueError) as exc:
            self._waiting.pop(rid, None)
            raise DeliveryError("Codex isn't running on the server") from exc
        if not slot[0].wait(timeout):
            self._waiting.pop(rid, None)
            raise DeliveryError(f"Codex didn't respond within {timeout:g}s")
        reply = slot[1] or {}
        if "error" in reply:
            err = reply["error"]
            why = err.get("message") if isinstance(err, dict) else str(err)
            raise DeliveryError(f"Codex refused it: {why}")
        return reply.get("result") or {}

    def close(self) -> None:
        try:
            self.proc.stdin.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=3)
        except Exception:  # noqa: BLE001
            try:
                self.proc.kill()
            except Exception:  # noqa: BLE001
                pass

    def _read(self) -> None:
        try:
            for line in self.proc.stdout:
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue
                if "method" not in msg and "id" in msg:
                    slot = self._waiting.pop(msg["id"], None)
                    if slot is not None:
                        slot[1] = msg
                        slot[0].set()
                    continue
                try:
                    self._on_message(self, msg)
                except Exception:  # noqa: BLE001
                    logger.debug("codex app-server: message handler failed", exc_info=True)
        except (OSError, ValueError):
            pass
        finally:
            for slot in list(self._waiting.values()):
                slot[1] = {"error": {"message": "Codex stopped on the server"}}
                slot[0].set()
            self._waiting.clear()

    def _drain_stderr(self) -> None:
        try:
            for line in self.proc.stderr:
                self.stderr_tail.append(str(line).rstrip())
        except (OSError, ValueError):
            pass


class CodexRuntime:
    """Continue Codex sessions on the server through ``codex app-server``.

    ``start`` returns a handle (the Codex thread id, which is the session id),
    ``send`` delivers a user turn, ``stop`` ends the child. Approval requests
    wait in ``pending_approvals()`` until ``answer_approval(id, "allow"|"deny")``.
    ``on_event(kind, data)`` (optional) hears ``approval``,
    ``approval_resolved``, ``turn/started``, ``turn/completed`` and ``error``.
    """

    APPROVAL_POLICY = "on-request"     # the model asks before leaving the sandbox
    SANDBOX = "workspace-write"
    START_TIMEOUT = 30.0

    def __init__(self, *, run: Callable = subprocess.run, popen: Callable = subprocess.Popen,
                 which: Callable = shutil.which, home: Optional[Path] = None,
                 on_event: Optional[Callable[[str, dict], None]] = None) -> None:
        self._run, self._popen, self._which = run, popen, which
        self._home = str(home) if home else None
        self._on_event = on_event
        self._lock = threading.RLock()
        self._threads: Dict[str, dict] = {}
        self._approvals: Dict[str, dict] = {}
        self._files: Dict[str, list] = {}

    # ── setup ──
    def _home_dir(self) -> str:
        if self._home:
            return self._home
        try:
            from jarviscopilot_constants import get_subprocess_home
            h = get_subprocess_home()
            if h:
                return h
        except Exception:  # noqa: BLE001
            pass
        return os.environ.get("HOME") or os.path.expanduser("~")

    def _binary(self) -> Optional[str]:
        found = self._which("codex")
        if found:
            return found
        local = Path(self._home_dir()) / ".local" / "bin" / "codex"
        return str(local) if local.is_file() and os.access(local, os.X_OK) else None

    def available(self) -> tuple:
        binary = self._binary()
        if not binary:
            return False, NOT_INSTALLED
        try:
            r = self._run([binary, "login", "status"], capture_output=True, text=True,
                          timeout=15, env=_codex_env(self._home_dir()))
        except (OSError, subprocess.SubprocessError) as exc:
            return False, f"Couldn't check Codex on the server: {exc}"
        said = f"{r.stdout or ''}\n{r.stderr or ''}".lower()
        if r.returncode != 0 or "not logged in" in said:
            return False, NOT_LOGGED_IN
        return True, ""

    def _spawn(self, cwd: str) -> _AppServer:
        binary = self._binary()
        if not binary:
            raise DeliveryError(NOT_INSTALLED)
        try:
            proc = self._popen([binary, "app-server"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd,
                               env=_codex_env(self._home_dir()), text=True,
                               encoding="utf-8", errors="replace", bufsize=1)
        except OSError as exc:
            raise DeliveryError(f"Codex couldn't start in {cwd}: {exc}") from exc
        srv = _AppServer(proc, self._on_message)
        try:
            srv.request("initialize", {"clientInfo": _CLIENT_INFO}, self.START_TIMEOUT)
            srv.write({"method": "initialized"})
        except (DeliveryError, OSError, ValueError) as exc:
            srv.close()
            raise DeliveryError(f"Codex didn't start: {exc}") from exc
        return srv

    def _open(self, srv: _AppServer, t: dict) -> str:
        """thread/resume (or thread/start) on ``srv``; returns the thread id."""
        params = {"cwd": t["cwd"], "approvalPolicy": t["approval_policy"],
                  "sandbox": t["sandbox"]}
        if t.get("model"):
            params["model"] = t["model"]
        try:
            if t.get("thread_id"):
                params.update(threadId=t["thread_id"], excludeTurns=True)
                res = srv.request("thread/resume", params, self.START_TIMEOUT)
            else:
                res = srv.request("thread/start", params, self.START_TIMEOUT)
        except DeliveryError:
            srv.close()
            raise
        tid = str(((res.get("thread") or {}).get("id")) or t.get("thread_id") or "")
        if not tid:
            srv.close()
            raise DeliveryError("Codex didn't open the session")
        return tid

    # ── lifecycle ──
    def start(self, cwd: str, *, resume_session_id: Optional[str] = None,
              prompt: Optional[str] = None, model: Optional[str] = None,
              approval_policy: Optional[str] = None, sandbox: Optional[str] = None) -> str:
        if resume_session_id and resume_session_id in self._threads:
            self.stop(resume_session_id)      # never two app-servers on one rollout
        t = {"cwd": cwd, "model": model, "thread_id": resume_session_id,
             "approval_policy": approval_policy or self.APPROVAL_POLICY,
             "sandbox": sandbox or self.SANDBOX, "lock": threading.Lock()}
        srv = self._spawn(cwd)
        handle = self._open(srv, t)
        t.update(thread_id=handle, srv=srv)
        with self._lock:
            self._threads[handle] = t
        if prompt:
            self.send(handle, prompt)
        return handle

    def send(self, handle: str, text: str, timeout: float = 30.0) -> None:
        if not (text or "").strip():
            raise DeliveryError("There's nothing to send")
        with self._lock:
            t = self._threads.get(handle)
        if t is None:
            raise DeliveryError("That Codex session isn't running on the server")
        with t["lock"]:
            if not t["srv"].alive():          # died since — bring it back first
                self._forget_approvals(t["srv"])
                srv = self._spawn(t["cwd"])
                self._open(srv, t)
                t["srv"] = srv
            t["srv"].request("turn/start", {
                "threadId": handle,
                "input": [{"type": "text", "text": text, "text_elements": []}],
            }, timeout)

    def stop(self, handle: str) -> None:
        with self._lock:
            t = self._threads.pop(handle, None)
        if t is not None:
            self._forget_approvals(t["srv"])
            t["srv"].close()

    def close(self) -> None:
        for handle in list(self._threads):
            self.stop(handle)

    # ── approvals ──
    def pending_approvals(self) -> List[dict]:
        with self._lock:
            entries = [dict(e["public"]) for e in self._approvals.values()]
        return sorted(entries, key=lambda a: a["created_at"])

    def answer_approval(self, approval_id: str, decision: str) -> bool:
        if decision not in ("allow", "deny"):
            return False
        with self._lock:
            e = self._approvals.pop(approval_id, None)
        if e is None:
            return False
        try:
            e["srv"].write({"id": e["rpc_id"],
                            "result": _approval_result(e["method"], e["params"],
                                                       decision == "allow")})
        except (OSError, ValueError):
            return False
        self._emit("approval_resolved", {"id": approval_id, "handle": e["public"]["handle"],
                                         "decision": decision})
        return True

    def _forget_approvals(self, srv: _AppServer) -> None:
        with self._lock:
            for aid in [a for a, e in self._approvals.items() if e["srv"] is srv]:
                self._approvals.pop(aid, None)

    def _handle_for(self, srv: _AppServer, params: dict) -> str:
        tid = params.get("threadId")
        if tid:
            return str(tid)
        with self._lock:
            return next((h for h, t in self._threads.items() if t.get("srv") is srv), "")

    def _approval(self, srv: _AppServer, method: str, kind: str, params: dict) -> dict:
        from agent.codex_transcript_read import _command_text
        cmd = params.get("command")
        command = _command_text(cmd) if cmd else None
        files = list((params.get("fileChanges") or {}).keys()) or self._files.pop(
            str(params.get("itemId") or ""), [])
        reason = params.get("reason") or None
        if kind == "command":
            title = f"Run {command}" if command else "Run a command"
        elif kind == "file_change":
            names = ", ".join(os.path.basename(f) for f in files[:3])
            title = f"Edit {names}" if names else "Apply file changes"
        elif kind == "permissions":
            title = "Grant extra permissions"
        else:
            title = str(params.get("message") or f"Use a {params.get('serverName')} tool")
        return {"id": uuid.uuid4().hex[:12], "handle": self._handle_for(srv, params),
                "kind": kind, "title": title, "command": command,
                "cwd": params.get("cwd"), "reason": reason, "files": files,
                "turn_id": params.get("turnId"), "created_at": time.time()}

    def _on_message(self, srv: _AppServer, msg: dict) -> None:
        method = str(msg.get("method") or "")
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
        if "id" in msg:                       # a server→client request
            kind = _APPROVAL_KINDS.get(method)
            if kind == "mcp_tool" and (params.get("_meta") or {}).get(
                    "codex_approval_kind") != "mcp_tool_call":
                srv.write({"id": msg["id"], "result": {"action": "decline"}})
                return
            if kind is None:                  # never leave a turn hanging
                srv.write({"id": msg["id"], "error": {
                    "code": -32601, "message": f"Jarvis can't answer {method}"}})
                return
            public = self._approval(srv, method, kind, params)
            with self._lock:
                self._approvals[public["id"]] = {"srv": srv, "rpc_id": msg["id"],
                                                 "method": method, "params": params,
                                                 "public": public}
            self._emit("approval", dict(public))
            return
        if method == "serverRequest/resolved":
            rid = params.get("requestId")
            with self._lock:
                gone = [a for a, e in self._approvals.items()
                        if e["srv"] is srv and e["rpc_id"] == rid]
                for aid in gone:
                    self._approvals.pop(aid, None)
            for aid in gone:
                self._emit("approval_resolved", {"id": aid, "handle": params.get("threadId")})
        elif method == "item/started":
            item = params.get("item") or {}
            if item.get("type") == "fileChange" and item.get("id"):
                if len(self._files) > 200:
                    self._files.clear()
                self._files[str(item["id"])] = [str(c.get("path")) for c in item.get("changes") or []
                                                if isinstance(c, dict) and c.get("path")]
        elif method in ("turn/started", "turn/completed", "error"):
            self._emit(method, params)

    def _emit(self, kind: str, data: dict) -> None:
        if self._on_event is None:
            return
        try:
            self._on_event(kind, data)
        except Exception:  # noqa: BLE001
            logger.debug("codex runtime: on_event failed", exc_info=True)


__all__ = [
    "run_codex_app_server_turn",
    "run_codex_stream",
    "run_codex_create_stream_fallback",
    "CodexRuntime",
    "DeliveryError",
]
