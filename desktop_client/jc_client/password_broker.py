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
"""
from __future__ import annotations

import secrets
import threading
import time
from typing import Callable, Optional

TIMEOUT = 120.0
MAX_CONTEXT = 2400   # the whole request text: his signature covers it
_FILL_TIMEOUT = 15.0
_SUDO_REMEMBER = 300.0


class _Request:
    def __init__(self, rid: str, kind: str, context: str, nonce: str, now: float) -> None:
        self.public = {"id": rid, "kind": kind, "context": context, "nonce": nonce,
                       "created": now, "expires": now + TIMEOUT}
        self.event = threading.Event()
        self.answer: Optional[dict] = None


class PasswordBroker:
    def __init__(self, up: Callable[[dict], None], ui_broadcast: Callable[[dict], None],
                 ask_app: Callable[[dict, float], dict], *, clock: Callable[[], float] = time.time,
                 wait: Callable[[threading.Event, float], bool] = lambda e, t: e.wait(t)) -> None:
        self._up = up
        self._ui = ui_broadcast
        self._ask_app = ask_app
        self._clock = clock
        self._wait = wait
        self._lock = threading.Lock()
        self._reqs: dict = {}
        self._sudo_given: dict = {}   # sudo pid -> when it got a password

    def pending(self) -> list:
        now = self._clock()
        with self._lock:
            return [dict(r.public) for r in self._reqs.values()
                    if r.answer is None and r.public["expires"] > now]

    def request(self, kind: str, context: str, *, ppid: Optional[int] = None) -> dict:
        """Ask, wait up to TIMEOUT for his answer, then fill. Blocks the caller."""
        now = self._clock()
        if kind == "sudo" and ppid:
            with self._lock:
                self._sudo_given = {p: t for p, t in self._sudo_given.items() if now - t < _SUDO_REMEMBER}
                again = ppid in self._sudo_given
            if again:
                return {"ok": False, "error": "The Mac password didn't work (sudo asked again)"}
        req = _Request(secrets.token_hex(8), kind, (context or "")[:MAX_CONTEXT], secrets.token_hex(16), now)
        rid = req.public["id"]
        with self._lock:
            self._reqs[rid] = req
        self._send("mac_password_request", "password_request", dict(req.public))
        answered = self._wait(req.event, TIMEOUT)
        with self._lock:
            if not answered:
                req.answer = {"decision": "timeout"}
            answer = req.answer
        if answer.get("decision") == "timeout":
            return self._finish(rid, False, "No answer in 2 minutes")
        if answer.get("decision") != "allow":
            return self._finish(rid, False, "Not allowed")
        try:
            # context too: the app checks his signature covers exactly this text
            result = self._ask_app({"type": "password_fill", "id": rid, "kind": kind,
                                    "nonce": req.public["nonce"], "context": req.public["context"],
                                    "proof": answer["proof"]},
                                   _FILL_TIMEOUT) or {}
        except Exception as exc:  # noqa: BLE001
            result = {"ok": False, "error": f"The Mac app didn't answer ({exc})"}
        ok = bool(result.get("ok"))
        error = None if ok else str(result.get("error") or "The password wasn't filled")
        self._finish(rid, ok, error)
        if not ok:
            return {"ok": False, "error": error}
        if kind == "sudo":
            if ppid:
                with self._lock:
                    self._sudo_given[ppid] = self._clock()
            return {"ok": True, "password": result.get("password") or ""}
        return {"ok": True}

    def on_answer(self, rid: str, decision: str, ts, signature) -> bool:
        """His iPhone answer (relayed by the server). The first answer wins."""
        return self._answer(rid, {"decision": decision, "proof": {"ts": ts, "signature": signature}})

    def on_local_answer(self, rid: str, decision: str) -> bool:
        """His answer in the Mac menu bar (the app checked Touch ID itself)."""
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
            self._reqs.pop(rid, None)
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
