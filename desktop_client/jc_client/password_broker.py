"""Mac password prompts, filled only after Pranav's yes (spec 2026-11-02).

A request (sudo through jarvis-askpass, an admin or Keychain dialog the Mac app
saw, or "Unlock Mac" from the phone) goes up to the server, which shows it on
the iPhone, and to the Mac app's menu bar. His answer comes back as a signed
iPhone approval (Face ID key) or a Mac Touch ID yes; the broker hands that
proof to the Mac app, which checks it, then types the password or (sudo) hands
it back for askpass. The password only ever passes between the app and askpass
on this Mac; the server and the phone never see it.

Never retried: one fill per request, and a sudo that asks again (its sign that
the password was wrong) is refused without asking him again.

Remote Desktop on the PC (kind "rdp"): the same Face ID path, but his yes asks the Jarvis app to
release the saved Windows password for the one session in the signed context (encrypted to the
iPhone's key, or for the web gateway); the result comes back as ``{"ok", "credential"}``.
"""
from __future__ import annotations

import logging
import secrets
import threading
import time
from typing import Callable, Optional

log = logging.getLogger(__name__)

TIMEOUT = 120.0
MAX_CONTEXT = 2400   # the whole request text: his signature covers it
# How long the app gets to answer a fill. The PC's lock-screen fill (JarvisUnlock)
# takes up to 8 s to reach the sign-in screen, ~3 s to lift the picture, clear the
# box and type, watches up to 8 s for Windows to unlock, then asks Windows for up
# to 4 s whose session is on the console: ~23 s at worst. It answers ok only when
# Windows really unlocked; anything else (ok:false, no answer, a reply without a
# real true "ok") is a failure, so the server's "password not filled" alert fires.
_FILL_TIMEOUT = 40.0
_SUDO_REMEMBER = 300.0
# The IT agent's commands (W3): his signed yes runs the exact command — elevated through the PC helper
# (admin-run) or unelevated by jc-client (pc-run). The context is the whole command, never cut.
COMMAND_KINDS = frozenset({"admin-run", "pc-run"})


def _not_run(status: str, error: str) -> dict:
    return {"ok": False, "status": status, "exit_code": None, "output": "", "truncated": False, "timed_out": False,
            "duration_ms": 0, "error": error}


class _Request:
    def __init__(self, rid: str, kind: str, context: str, nonce: str, now: float, why: str = "") -> None:
        self.public = {"id": rid, "kind": kind, "context": context, "nonce": nonce,
                       "created": now, "expires": now + TIMEOUT}
        if kind in COMMAND_KINDS:
            self.public["why"] = (why or "")[:300]
        self.event = threading.Event()
        self.answer: Optional[dict] = None


class PasswordBroker:
    def __init__(self, up: Callable[[dict], None], ui_broadcast: Callable[[dict], None],
                 ask_app: Callable[[dict, float], dict], *, clock: Callable[[], float] = time.time,
                 unlock_grant: Callable[[], Optional[dict]] = lambda: None, device_id: str = "",
                 wait: Callable[[threading.Event, float], bool] = lambda e, t: e.wait(t)) -> None:
        self._up = up
        self._ui = ui_broadcast
        self._ask_app = ask_app
        self._clock = clock
        self._wait = wait
        # His standing unlock permission (jc_client/unlock_grant.py): an unlock tries it before asking the phone.
        self._unlock_grant = unlock_grant
        self._device_id = device_id
        self._lock = threading.Lock()
        self._reqs: dict = {}
        self._sudo_given: dict = {}   # sudo pid -> when it got a password

    def pending(self) -> list:
        now = self._clock()
        with self._lock:
            return [dict(r.public) for r in self._reqs.values()
                    if r.answer is None and r.public["expires"] > now]

    def request(self, kind: str, context: str, *, ppid: Optional[int] = None, why: str = "",
                run_timeout: Optional[int] = None) -> dict:
        """Ask, wait up to TIMEOUT for his answer, then fill (or, for an IT command, run it). Blocks."""
        now = self._clock()
        if kind == "sudo" and ppid:
            with self._lock:
                self._sudo_given = {p: t for p, t in self._sudo_given.items() if now - t < _SUDO_REMEMBER}
                again = ppid in self._sudo_given
            if again:
                return {"ok": False, "error": "The Mac password didn't work (sudo asked again)"}
        text = (context or "") if kind in COMMAND_KINDS else (context or "")[:MAX_CONTEXT]
        req = _Request(secrets.token_hex(8), kind, text, secrets.token_hex(16), now, why=why)
        rid = req.public["id"]
        if kind == "unlock":
            done = self._unlock_with_permission(rid, req)
            if done is not None:
                return done
        with self._lock:
            self._reqs[rid] = req
        self._send("mac_password_request", "password_request", dict(req.public))
        answered = self._wait(req.event, TIMEOUT)
        with self._lock:
            if not answered:
                req.answer = {"decision": "timeout"}
            answer = req.answer
        if kind in COMMAND_KINDS:
            return self._run_command(rid, req, answer, int(run_timeout or 600))
        if answer.get("decision") == "timeout":
            return self._finish(rid, False, "No answer in 2 minutes")
        if answer.get("decision") != "allow":
            return self._finish(rid, False, "Not allowed")
        try:
            # context too: the app checks his signature covers exactly this text. Remote Desktop
            # (kind "rdp") asks the app to *release* the saved password for the one session named in
            # the signed context instead of typing it (plan 2026-11-15-remote-desktop, Task 2).
            msg_type = "password_release" if kind == "rdp" else "password_fill"
            result = self._ask_app({"type": msg_type, "id": rid, "kind": kind,
                                    "nonce": req.public["nonce"], "context": req.public["context"],
                                    "proof": answer["proof"]},
                                   _FILL_TIMEOUT) or {}
        except Exception as exc:  # noqa: BLE001
            result = {"ok": False, "error": f"The Mac app didn't answer ({exc})"}
        ok = result.get("ok") is True   # a JSON true, never a truthy string or number
        error = None if ok else str(result.get("error") or "The password wasn't filled")
        self._finish(rid, ok, error)
        if not ok:
            return {"ok": False, "error": error}
        if kind == "rdp":
            return {"ok": True, "credential": result.get("credential")}
        if kind == "sudo":
            if ppid:
                with self._lock:
                    self._sudo_given[ppid] = self._clock()
            return {"ok": True, "password": result.get("password") or ""}
        return {"ok": True}

    def _own_id(self) -> str:
        """This computer's id as the server knows it (the hello's device_id), read when needed."""
        try:
            return str((self._device_id() if callable(self._device_id) else self._device_id) or "")
        except Exception:  # noqa: BLE001
            return ""

    def _unlock_with_permission(self, rid: str, req: _Request) -> Optional[dict]:
        """With his unlock permission: the app checks it and types; no phone. None → ask him as usual (no
        permission, or the app refused it)."""
        try:
            grant = self._unlock_grant()
        except Exception:  # noqa: BLE001
            grant = None
        if not grant:
            return None
        try:
            result = self._ask_app({"type": "password_fill", "id": rid, "kind": "unlock",
                                    "nonce": req.public["nonce"], "context": req.public["context"],
                                    "grant": grant, "device": self._own_id()}, _FILL_TIMEOUT) or {}
        except Exception as exc:  # noqa: BLE001
            result = {"ok": False, "error": str(exc)}
        if result.get("ok") is True:
            log.info("unlocked with his unlock permission (no Face ID)")
            return {"ok": True}
        log.info("unlock permission not used (%s); asking for Face ID", result.get("error") or "refused")
        return None

    def _run_command(self, rid: str, req: _Request, answer: dict, run_timeout: int) -> dict:
        if answer.get("decision") == "timeout":
            self._finish(rid, False, "No answer in 2 minutes")
            return _not_run("approval_timeout", "No answer in 2 minutes")
        if answer.get("decision") != "allow":
            self._finish(rid, False, "Not allowed")
            return _not_run("denied", "Not allowed")
        msg = {"type": "admin_run" if req.public["kind"] == "admin-run" else "pc_run", "id": rid,
               "command": req.public["context"], "nonce": req.public["nonce"], "proof": answer["proof"],
               "timeout_s": run_timeout}
        try:
            result = self._ask_app(msg, run_timeout + 15) or {}
        except Exception as exc:  # noqa: BLE001
            result = {"ok": False, "error": f"The command didn't run ({exc})"}
        if result.get("ok") is not True:   # a JSON true, never a truthy string or number
            out = _not_run("failed", str(result.get("error") or "The command didn't run"))
            self._finish(rid, False, out["error"])
            return out
        output = result.get("output")
        if output is None:   # pc-run: jc-client's own runner answers with stdout/stderr
            output = "\n".join(p for p in (str(result.get("stdout") or ""), str(result.get("stderr") or "")) if p)
        self._finish(rid, True, None)
        return {"ok": True, "status": "ran", "exit_code": result.get("exit_code"), "output": str(output)[-16000:],
                "truncated": bool(result.get("truncated")), "timed_out": bool(result.get("timed_out")),
                "duration_ms": int(result.get("duration_ms") or 0), "error": ""}

    def on_answer(self, rid: str, decision: str, ts, signature) -> bool:
        """His iPhone answer (relayed by the server). The first answer wins."""
        return self._answer(rid, {"decision": decision, "proof": {"ts": ts, "signature": signature}})

    def on_local_answer(self, rid: str, decision: str) -> bool:
        """His answer in the Mac menu bar (the app checked Touch ID itself). Never for an IT command: only
        his signed iPhone approval of the exact command counts."""
        with self._lock:
            req = self._reqs.get(str(rid or ""))
            if req is not None and req.public["kind"] in COMMAND_KINDS:
                return False
        return self._answer(rid, {"decision": decision, "proof": {"local": True}})

    def _answer(self, rid: str, answer: dict) -> bool:
        with self._lock:
            req = self._reqs.get(str(rid or ""))
            if req is None or req.answer is not None:
                return False
            req.answer = answer
        req.event.set()
        return True

    def _finish(self, rid: str, ok: bool, error: Optional[str]) -> dict:
        with self._lock:
            req = self._reqs.pop(rid, None)
        log.info("mac password request %s (%s): %s", rid, req.public["kind"] if req else "?",
                 "filled" if ok else f"not filled: {error}")
        data = {"id": rid, "ok": ok}
        if error:
            data["error"] = error
        self._send("mac_password_done", "password_done", data)
        return {"ok": True} if ok else {"ok": False, "error": error}

    def _send(self, event: str, ui_type: str, data: dict) -> None:
        for fn, msg in ((self._up, {"type": "event", "name": event, "data": data}),
                        (self._ui, {"type": ui_type, **data})):
            try:
                fn(msg)
            except Exception:  # noqa: BLE001 — offline: the other side still gets it
                pass
