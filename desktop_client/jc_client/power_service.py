"""jc-client's glue for keep-awake, Wake Mac and password autofill.

Owns the MacPower policy (mac_power.py) and the PasswordBroker
(password_broker.py), and connects them to the Mac app (ui.sock requests and
broadcasts), the server (frames down, events up, the check-in over HTTPS) and the
root helper (power_install.py sets it up).
"""
from __future__ import annotations

import json
import logging
import threading
import urllib.request
from typing import Callable, Optional

from jc_client.mac_power import MacPower, helper_call
from jc_client.password_broker import PasswordBroker

log = logging.getLogger(__name__)

UI_REQUESTS = frozenset({"password_request", "password_seen", "password_local_answer",
                         "password_fill_result", "password_pending", "mac_power_token",
                         "mac_power_wake", "mac_power_state", "mac_power_set", "power_install",
                         "approval_key"})
FRAMES = frozenset({"mac_power_set", "mac_password_answer", "mac_password_unlock"})
_KINDS = ("sudo", "admin", "keychain", "unlock")
# Requests only the Jarvis Mac app may make (checked by the connecting process,
# which ui_server reads from the kernel): a stranger on ui.sock can't start the
# root setup, answer for Touch ID, hand in a fill result, or pose as a dialog.
_APP_ONLY = frozenset({"password_seen", "password_local_answer", "password_fill_result",
                       "password_pending", "mac_power_token", "mac_power_wake", "mac_power_set",
                       "power_install", "approval_key"})
_APP_SUFFIX = "/Jarvis.app/Contents/MacOS/Jarvis"
_MAX_CONTEXT = 2000


class Procs:
    """What a process is: its executable, parent and command line (macOS)."""

    def exe(self, pid: int) -> str:
        try:
            import ctypes
            lib = ctypes.CDLL("/usr/lib/libproc.dylib")
            buf = ctypes.create_string_buffer(4096)
            return buf.value.decode("utf-8", "replace") if lib.proc_pidpath(int(pid), buf, 4096) > 0 else ""
        except Exception:  # noqa: BLE001
            return ""

    def _ps(self, pid: int, field: str) -> str:
        try:
            import subprocess
            return subprocess.run(["/bin/ps", "-ww", "-o", f"{field}=", "-p", str(int(pid))],
                                  capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:  # noqa: BLE001
            return ""

    def ppid(self, pid: int) -> int:
        out = self._ps(pid, "ppid")
        return int(out) if out.isdigit() else 0

    def command(self, pid: int) -> str:
        return self._ps(pid, "command")


def sudo_context(command: str, started_by: str) -> str:
    """What the phone shows (and his signature covers): the whole sudo command."""
    text = command if len(command) <= _MAX_CONTEXT else (
        command[:_MAX_CONTEXT] + f" … [{len(command) - _MAX_CONTEXT} more characters not shown]")
    return f"{text} (started by {started_by})" if started_by else text


class PowerService:
    def __init__(self, up: Callable[[dict], None], ui_broadcast: Callable[[dict], None],
                 sessions: Callable[[], list], api_origin: Callable[[], Optional[str]],
                 procs: Optional[Procs] = None) -> None:
        self._procs = procs or Procs()
        self._up = up
        self._ui = ui_broadcast
        self._origin = api_origin
        self._lock = threading.Lock()
        self._fills: dict = {}    # request id -> (Event, reply holder)
        self.passwords = PasswordBroker(up, ui_broadcast, self._ask_app)
        self.power = MacPower(helper_call, up, self._checkin, sessions,
                              pending_password=lambda: bool(self.passwords.pending()))

    def start(self) -> None:
        self.power.start()

    def close(self) -> None:
        self.power.close()

    def wait_while_quiet(self, stop: threading.Event, limit: float = 20.0) -> None:
        """Before reconnecting: a timer check-in that's putting the Mac back to sleep
        must not reconnect (the server would take it for the Mac coming back)."""
        waited = 0.0
        # also while a wake isn't classified yet (asleep until on_did_wake runs)
        while (self.power.quiet() or self.power.asleep()) and waited < limit and not stop.is_set():
            stop.wait(0.5)
            waited += 0.5

    # ── server ───────────────────────────────────────────────────────────
    def _get(self, path: str, timeout: float = 8.0) -> dict:
        origin = self._origin()
        if not origin:
            raise OSError("not paired")
        # Cloudflare refuses Python's default User-Agent (error 1010).
        req = urllib.request.Request(origin + path, headers={"User-Agent": "jc-client/0.1"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8") or "{}")

    def _checkin(self) -> dict:
        return self._get("/api/coding/agents/mac/checkin")

    def handle_frame(self, frame: dict) -> None:
        t = frame.get("type")
        if t == "mac_power_set":
            self.power.on_frame(frame)
        elif t == "mac_password_answer":
            self.passwords.on_answer(str(frame.get("id") or ""), str(frame.get("decision") or ""),
                                     frame.get("ts"), frame.get("signature"))
        elif t == "mac_password_unlock":
            self._ask_async("unlock", "Unlock Mac")

    # ── the Mac app ──────────────────────────────────────────────────────
    def _ask_app(self, msg: dict, timeout: float) -> dict:
        """password_fill to the app (broadcast); it answers with password_fill_result."""
        rid = str(msg.get("id") or "")
        event, holder = threading.Event(), {}
        with self._lock:
            self._fills[rid] = (event, holder)
        try:
            self._ui(msg)
            if not event.wait(timeout):
                return {"ok": False, "error": "The Jarvis Mac app didn't answer"}
            return holder
        finally:
            with self._lock:
                self._fills.pop(rid, None)

    def _ask_async(self, kind: str, context: str) -> None:
        if any(p["kind"] == kind for p in self.passwords.pending()):
            return
        threading.Thread(target=self.passwords.request, args=(kind, context), daemon=True,
                         name=f"jc-password-{kind}").start()

    def _is_app(self, req: dict) -> bool:
        return self._procs.exe(int(req.get("_peer_pid") or 0)).endswith(_APP_SUFFIX)

    def _sudo_request(self, req: dict) -> dict:
        """jarvis-askpass, for sudo. Only a process whose parent really is sudo; the
        command shown (and signed) is read from that sudo, never the client's word.
        Blocks this client's reader until he answers."""
        peer = int(req.get("_peer_pid") or 0)
        sudo = self._procs.ppid(peer) if peer else 0
        if not sudo or self._procs.exe(sudo) != "/usr/bin/sudo":
            return {"ok": False, "error": "not sudo's askpass"}
        starter = self._procs.command(self._procs.ppid(sudo)).split(" ")[0].rsplit("/", 1)[-1]
        context = sudo_context(self._procs.command(sudo) or "sudo", starter)
        return self.passwords.request("sudo", context, ppid=sudo)

    def ui_request(self, req: dict) -> dict:
        kind = req.get("type")
        if kind in _APP_ONLY and not self._is_app(req):
            return {"ok": False, "error": "only the Jarvis Mac app may ask that"}
        if kind == "password_request":
            return self._sudo_request(req)
        if kind == "password_seen":
            what = str(req.get("kind") or "admin")
            self._ask_async(what if what in _KINDS else "admin", str(req.get("context") or ""))
            return {"ok": True}
        if kind == "password_local_answer":
            return {"ok": self.passwords.on_local_answer(str(req.get("id") or ""),
                                                         str(req.get("decision") or ""))}
        if kind == "password_fill_result":
            with self._lock:
                waiter = self._fills.get(str(req.get("id") or ""))
            if waiter is None:
                return {"ok": False}
            event, holder = waiter
            holder.update({k: req[k] for k in ("ok", "password", "error") if k in req})
            event.set()
            return {"ok": True}
        if kind == "password_pending":
            return {"ok": True, "pending": self.passwords.pending()}
        if kind == "mac_power_token":
            self._up({"type": "event", "name": "mac_power_token",
                      "data": {"token": str(req.get("token") or ""), "env": str(req.get("env") or "")}})
            return {"ok": True}
        if kind == "mac_power_wake":
            self.power.request_wake()
            return {"ok": True}
        if kind == "mac_power_state":
            from jc_client import power_install
            return {"ok": True, **self.power.status(), "helper": power_install.status()}
        if kind == "mac_power_set":
            change = {k: bool(req[k]) for k in ("keep_awake", "timer_on", "let_sleep") if k in req}
            self.power.on_frame(change)
            self._up({"type": "event", "name": "mac_power_set", "data": change})
            return {"ok": True, **self.power.status()}
        if kind == "power_install":
            # In the background: the admin dialog can wait minutes, and this
            # client's other requests queue behind a reply. Done → broadcast.
            password = req.get("password") or None

            def run() -> None:
                from jc_client import power_install
                try:
                    result = power_install.install(password)
                except Exception as exc:  # noqa: BLE001
                    result = {"ok": False, "error": str(exc)}
                self._ui({"type": "power_install_done", **result})
            threading.Thread(target=run, daemon=True, name="jc-power-install").start()
            return {"ok": True, "started": True}
        if kind == "approval_key":
            try:
                return {"ok": True, **self._get("/api/coding/agents/mac/approval-key")}
            except Exception as exc:  # noqa: BLE001
                return {"ok": False, "error": str(exc)}
        return {"ok": False, "error": f"unknown request {kind!r}"}
