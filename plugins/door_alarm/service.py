"""DoorService — the one object the routes, the tools' routes and the background threads share.

Lives in the webui process (it owns push, the device bridge and the Face ID approver). Hub reports
arrive from the ESP32 proxy (bridge ``event`` frames) and Tuya's cloud feed; both go through the
Hub (dedupe) into the Alarm; the Alarm's effects are carried out here.
"""
from __future__ import annotations

import logging
import os
import threading
import time
from typing import Any, Callable, Optional

from plugins.door_alarm import schema
from plugins.door_alarm.alarm import Alarm, ArmRefused, Effect  # noqa: F401  (ArmRefused re-exported)
from plugins.door_alarm.hub import Hub
from plugins.door_alarm.store import DoorStore
from plugins.door_alarm.tuya_cloud import TuyaCloud, TuyaError, base_url

log = logging.getLogger(__name__)

APPROVAL_TITLES = {"disarm": "Disarm the door alarm", "silence": "Silence the door alarm siren"}
DOMAIN = "jarvis-home"
ARMED_STATES = ("arming", "armed_away", "armed_home", "entry", "triggered")
CONTACT_KEYS = {"name": str, "instant": bool, "active_home": bool, "notify_disarmed": bool, "on_open_prompt": str}
STATE_TEXT = {"disarmed": "Disarmed", "arming": "Arming — exit delay", "armed_away": "Armed away",
              "armed_home": "Armed home", "entry": "Door opened — entry delay", "triggered": "ALARM"}
NOT_SET_UP = "The door alarm isn't set up yet. Open Devices → Door Alarm → Setup on the iPhone."


class NotSetUp(Exception):
    pass


class _Worker:
    """One background thread running jobs in order (first in, first out)."""

    def __init__(self, name: str) -> None:
        from concurrent.futures import ThreadPoolExecutor
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix=name)

    def __call__(self, fn: Callable) -> None:
        self._pool.submit(fn)


class CommandFailed(Exception):
    pass


# ── default collaborators (the webui's) ──

class _Bridge:
    def invoke(self, device: str, skill: str, args: dict, timeout: float = 10.0) -> dict:
        from api import device_bridge
        return device_bridge.invoke_skill(device, skill, args, timeout=timeout)

    def offering(self, skill: str) -> Optional[str]:
        from api import device_bridge
        return device_bridge.device_offering(skill)

    def is_connected(self, device: str) -> bool:
        from api import device_bridge
        return device in device_bridge.connected_device_ids()


def _push(title: str, body: str, data: dict | None = None, category: str | None = None, level: str | None = None) -> int:
    from api.push import alert_phones
    return alert_phones(title, body, data=data or {"type": "door_alarm"}, category=category, level=level)


def _env(key: str) -> str:
    from jarviscopilot_cli.config import get_env_value
    return (get_env_value(key) or "").strip()


class _Prompts:
    """On-open prompts run as turns in one "Door alarm" chat (host-signed loopback, like the ESP32)."""

    def __init__(self, store: DoorStore) -> None:
        self.store = store

    def __call__(self, prompt: str) -> None:
        from tools.chrome_device_tool import _api_request
        sid = self.store.config().get("events_session")
        for _ in range(2):
            if not sid:
                reply = _api_request("POST", "/api/session/new", {"title": "Door alarm"})
                sid = reply.get("session_id") or (reply.get("session") or {}).get("session_id")
                if not sid:
                    log.warning("door alarm: couldn't open its chat: %s", reply.get("_error") or reply.get("error"))
                    return
                self.store.update_config(events_session=sid)
            reply = _api_request("POST", "/api/chat/start", {"session_id": sid, "message": prompt}, timeout=20)
            if reply.get("_error") or reply.get("error"):
                sid = None
                self.store.update_config(events_session=None)
                continue
            return


def _pod_page(name: str, siren_s: float = 0) -> dict:
    """The ALARM page; while the siren runs the Pod sounds it too (silence / disarm / timeout stop it)."""
    page = {"id": "doorlarm", "title": "Door alarm",
            "root": {"type": "vstack", "style": {"gap": 6, "align": "center"}, "children": [
                {"type": "symbol", "name": "exclamationmark.triangle.fill", "style": {"size": 44, "color": "danger"}},
                {"type": "text", "value": "ALARM", "style": {"size": 34, "weight": "bold", "color": "danger"}},
                {"type": "text", "value": (name or "A door")[:28] + " opened", "style": {"size": 16, "color": "text"}},
                {"type": "text", "value": "Disarm on the iPhone", "style": {"size": 12, "color": "muted"}}]}}
    if siren_s > 0:
        page["sound"] = {"name": "alarm", "every_ms": 700, "for_s": int(siren_s + 0.5)}
    return page


def _pod_status(symbol: str, title: str, color: str, line: str, timer_to: Optional[float] = None,
                ttl: Optional[int] = None, now: float = 0.0, sound: Optional[dict] = None) -> dict:
    children = [{"type": "symbol", "name": symbol, "style": {"size": 36, "color": color}},
                {"type": "text", "value": title, "style": {"size": 28, "weight": "bold", "color": color}}]
    if timer_to:
        # "in" = seconds left: the Pod counts from when the page lands, so its own clock can be off.
        children.append({"type": "timer", "to": int(timer_to), "in": max(0, int(timer_to - now + 0.5)),
                         "format": "countdown", "style": {"size": 64, "weight": "bold", "color": color}})
    children.append({"type": "text", "value": line, "style": {"size": 14, "color": "muted"}})
    page = {"id": "doorlarm", "title": "Door alarm",
            "root": {"type": "vstack", "style": {"gap": 6, "align": "center"}, "children": children}}
    if ttl:
        page["ttl"] = ttl   # the Pod goes back home after this many seconds
    if sound:
        page["sound"] = sound   # played on the Pod while this page is up
    return page


class DoorService:
    _instance: Optional["DoorService"] = None
    _instance_lock = threading.Lock()

    @classmethod
    def instance(cls) -> "DoorService":
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = DoorService()
            return cls._instance

    def __init__(self, store: DoorStore | None = None, clock: Callable[[], float] = time.time,
                 bridge=None, push: Callable | None = None, cloud: Callable | None = None,
                 approver=None, approvals=None, run_prompt: Callable[[str], None] | None = None,
                 run: Callable[[Callable], Any] | None = None, confirm_timeout: float = 5.0) -> None:
        self.store = store or DoorStore()
        self.clock = clock
        self.bridge = bridge or _Bridge()
        self.push = push or _push
        self._cloud_factory = cloud or self._env_cloud
        if approver is None:
            from plugins.toyota.approver import approver as _shared_approver
            approver = _shared_approver()
        self.approver = approver
        if approvals is None:
            from plugins.toyota.approver import Approvals
            approvals = Approvals(clock=clock, titles=APPROVAL_TITLES, label="door alarm")
        self.approvals = approvals
        self.run_prompt = run_prompt or _Prompts(self.store)
        # Two ordered queues: alerts (pushes, phone ring, Pod) never wait behind hub writes, and hub
        # writes stay in order (a siren "on" can't land after the disarm's "off").
        self._run_alerts = run or _Worker("door-alerts")
        self._run_hub = run or _Worker("door-hub")
        self.confirm_timeout = confirm_timeout
        self.lock = threading.RLock()
        self.hub = Hub(self.store, clock)
        cfg = self.store.config()
        self.alarm = Alarm(cfg.get("alarm") or {}, contacts=self.hub.contacts, clock=clock, state=self.store.state())
        self._waiters: list[tuple[str, Any, threading.Event]] = []
        self._warned: dict[str, float] = {}
        self._saved_volume: Optional[tuple[str, Any]] = None
        self._last_refetch = 0.0
        self._cloud_cache: tuple[tuple, Optional[TuyaCloud]] = ((), None)
        self._feed = None
        self._stop = threading.Event()
        self._started = False

    # ── plumbing ──

    def _env_cloud(self) -> Optional[TuyaCloud]:
        access_id, secret = _env("TUYA_ACCESS_ID"), _env("TUYA_ACCESS_SECRET")
        if not access_id or not secret:
            return None
        region = self.store.config().get("region") or "us"
        key = (access_id, secret, region)
        if self._cloud_cache[0] != key:
            self._cloud_cache = (key, TuyaCloud(access_id, secret, base_url(region)))
        return self._cloud_cache[1]

    def cloud(self):
        try:
            return self._cloud_factory()
        except Exception:
            log.warning("door alarm: Tuya cloud client unavailable", exc_info=True)
            return None

    def _cloud_required(self):
        client = self.cloud()
        if client is None:
            raise NotSetUp("Add the Tuya cloud project's Access ID and Secret in Door Alarm → Setup first.")
        return client

    def _require(self) -> dict:
        if not self.hub.configured:
            raise NotSetUp(NOT_SET_UP)
        return self.hub.cfg

    # ── background ──

    def start(self) -> None:
        if self._started:
            return
        self._started = True
        try:
            from api import device_bridge
            device_bridge.on_device_event("door_report", lambda dev, data: self.on_board_event(dev, "door_report", data))
            device_bridge.on_device_event("door_link", lambda dev, data: self.on_board_event(dev, "door_link", data))
        except Exception:
            log.warning("door alarm: bridge events unavailable", exc_info=True)
        self._restart_feed()
        threading.Thread(target=self._timer, name="door-alarm-timer", daemon=True).start()
        self._run_alerts(self.refresh_values)   # values + known sensors right after a restart

    def refresh_values(self) -> None:
        """One status read from Tuya's cloud: every data point's value, and the sensors it names
        (a snapshot — never counted as a door opening)."""
        cloud, dev_id = self.cloud(), self.hub.cfg.get("dev_id")
        if cloud is None or not dev_id:
            return
        try:
            values = cloud.properties(dev_id)
        except TuyaError as exc:
            log.info("door alarm: status read failed: %s", exc)
            return
        self.hub.apply([{"code": v.get("code"), "dp_id": v.get("dp_id"), "value": v.get("value")} for v in values],
                       source="cloud", snapshot=True)

    def _timer(self) -> None:
        while not self._stop.wait(1.0):
            try:
                self.tick()
            except Exception:
                log.warning("door alarm tick failed", exc_info=True)

    def _restart_feed(self) -> None:
        if self._feed is not None:
            self._feed.stop()
            self._feed = None
        cfg = self.hub.cfg
        access_id, secret = _env("TUYA_ACCESS_ID"), _env("TUYA_ACCESS_SECRET")
        if not (cfg.get("dev_id") and access_id and secret and self._started):
            self.hub.cloud_link("off")
            return
        from plugins.door_alarm.tuya_events import TuyaEventFeed
        self._feed = TuyaEventFeed(access_id, secret, cfg.get("region") or "us", cfg["dev_id"],
                                   on_report=self.on_cloud_report, on_online=self.on_cloud_online,
                                   on_state=self.on_cloud_state)
        self._feed.start()

    # ── views ──

    def setup_status(self) -> dict:
        cfg = self.hub.cfg
        return {"credentials": self.cloud() is not None, "region": cfg.get("region") or "us",
                "hub": self.hub.configured, "hub_name": cfg.get("name"), "proxy": cfg.get("proxy"),
                "cloud": self.hub.link["cloud"]["state"]}

    def state(self) -> dict:
        with self.lock:
            return {"setup": self.setup_status(), "alarm": self.alarm.public(), "hub": self.hub.public(),
                    "approvals": self.approvals.pending(), "siren": self.hub.cfg.get("siren") or {}}

    def history(self, limit: int = 100, contact: Optional[str] = None) -> list[dict]:
        return self.store.events(limit=max(1, min(int(limit or 100), 500)), contact=contact)

    # ── setup ──

    def save_credentials(self, access_id: str, secret: str, region: str = "us") -> dict:
        access_id, secret, region = (access_id or "").strip(), (secret or "").strip(), (region or "us").strip().lower()
        if not access_id or not secret:
            raise ValueError("Both the Access ID and the Access Secret are needed.")
        base = base_url(region)
        probe = TuyaCloud(access_id, secret, base)
        probe.devices()  # raises TuyaError when the project/credentials don't work
        from jarviscopilot_cli.config import save_env_value
        save_env_value("TUYA_ACCESS_ID", access_id)
        save_env_value("TUYA_ACCESS_SECRET", secret)
        os.environ["TUYA_ACCESS_ID"], os.environ["TUYA_ACCESS_SECRET"] = access_id, secret
        self.store.update_config(region=region)
        self.hub.reload()
        self._restart_feed()
        return self.setup_status()

    def list_cloud_devices(self) -> list[dict]:
        keys = ("id", "name", "product_id", "product_name", "category", "online", "model")
        return [{k: d.get(k) for k in keys} for d in self._cloud_required().devices()]

    def pick(self, dev_id: str) -> dict:
        cloud = self._cloud_required()
        info = cloud.device(dev_id)
        dps = {}
        try:
            dps = schema.parse_model(cloud.model(dev_id))
        except TuyaError as exc:
            log.info("door alarm: thing model unavailable (%s), using specifications", exc)
        if not dps and hasattr(cloud, "specifications"):
            dps = schema.parse_specifications(cloud.specifications(dev_id))
        product_id = info.get("product_id")
        with self.lock:
            self.store.update_config(dev_id=dev_id, name=info.get("name"), product_id=product_id,
                                     product_name=info.get("product_name"), category=info.get("category"),
                                     dps=[d.public() for d in dps.values()], roles=schema.roles(dps, product_id),
                                     picked_at=self.clock())
            if info.get("local_key"):
                self.store.save_secret({"local_key": info["local_key"]})
            self.hub.reload()
        self.refresh_values()
        self._restart_feed()
        self._configure_board()
        return self.state()

    def set_proxy(self, board_id: Optional[str], allowed: Optional[set] = None) -> dict:
        """``allowed``: the boards that may be the proxy (connected, offering the door skills). The
        proxy is trusted with the hub's local key and its door reports, so nothing else qualifies."""
        old = self.hub.cfg.get("proxy")
        board_id = (board_id or "").strip() or None
        if board_id and allowed is not None and board_id not in allowed:
            raise ValueError("That device isn't a connected ESP32 that can be the door proxy.")
        self.store.update_config(proxy=board_id, proxy_set_at=self.clock())
        self.hub.reload()
        if old and old != board_id:
            self._safe_invoke(old, "esp32_door_forget", {})
        if board_id:
            self._configure_board()
        return self.setup_status()

    def _configure_board(self) -> Optional[dict]:
        cfg = self.hub.cfg
        board, key = cfg.get("proxy"), self.store.secret().get("local_key")
        if not (board and cfg.get("dev_id") and key):
            return None
        args = {"dev_id": cfg["dev_id"], "local_key": key, "version": cfg.get("version") or "auto"}
        if cfg.get("local_ip"):
            args["ip"] = cfg["local_ip"]
        return self._safe_invoke(board, "esp32_door_configure", args)

    def _safe_invoke(self, device: str, skill: str, args: dict, timeout: float = 10.0) -> Optional[dict]:
        try:
            return self.bridge.invoke(device, skill, args, timeout=timeout)
        except Exception as exc:
            log.info("door alarm: %s on %s failed: %s", skill, device, exc)
            return None

    def _refetch_key(self) -> None:
        now = self.clock()
        if now - self._last_refetch < 300:
            return
        self._last_refetch = now
        cloud = self.cloud()
        dev_id = self.hub.cfg.get("dev_id")
        if cloud is None or not dev_id:
            self._warn("local_key", "Door alarm proxy can't open the hub",
                       "The hub's local key changed (re-paired?). Add Tuya cloud credentials so Jarvis can fetch it.")
            return
        try:
            key = cloud.device(dev_id).get("local_key")
        except TuyaError as exc:
            self._warn("local_key", "Door alarm proxy can't open the hub", f"Couldn't fetch the hub's new key: {exc}")
            return
        if key:
            self.store.save_secret({"local_key": key})
        self._configure_board()

    # ── inputs ──

    def _resolve(self, reports: list[dict]) -> list[dict]:
        out = []
        for r in reports:
            code = r.get("code")
            if not code and r.get("dp_id") is not None:
                try:
                    dp = self.hub.dps.get(int(r["dp_id"]))
                except (TypeError, ValueError):
                    dp = None
                code = dp.code if dp else None
            if code:
                out.append({"code": code, "value": r.get("value"), "t": r.get("t")})
        return out

    def _wake_waiters(self, reports: list[dict]) -> None:
        for r in reports:
            for code, want, event in list(self._waiters):
                if code == r["code"] and r["value"] == want:
                    event.set()

    def on_board_event(self, device_id: str, name: str, data: dict) -> None:
        if not self.hub.cfg.get("proxy") or device_id != self.hub.cfg.get("proxy"):
            log.debug("door alarm: ignoring %s from %s (not the proxy)", name, device_id)
            return
        if name == "door_link":
            self.hub.local_link(data)
            if data.get("state") == "handshake_failed":
                self._refetch_key()
            return
        if name != "door_report":
            return
        dps = data.get("dps") if isinstance(data.get("dps"), dict) else {}
        when = data.get("t")   # the hub's (or the board's) time for the whole frame
        reports = self._resolve([{"dp_id": k, "value": v, "t": when} for k, v in dps.items() if str(k).isdigit()])
        self._ingest(reports, "esp32", snapshot=bool(data.get("query")))

    def on_cloud_report(self, reports: list[dict]) -> None:
        self._ingest(self._resolve(reports), "cloud", snapshot=False)

    def on_cloud_online(self, online: bool) -> None:
        self.hub.cloud_online(online)

    def on_cloud_state(self, state: str, error: str = "") -> None:
        self.hub.cloud_link(state, error)
        if state == "auth":
            self._cloud_auth_warning(error)

    def _ingest(self, reports: list[dict], source: str, snapshot: bool) -> None:
        self._wake_waiters(reports)
        if not self.hub.configured:
            return
        effects: list[Effect] = []
        with self.lock:
            changes = self.hub.apply(reports, source=source, snapshot=snapshot)
            before = self.alarm.state
            for change in changes:
                # A report queued while a link was down (or replayed by the cloud) is history: it
                # happened before now, maybe before this arming. Never alarm input.
                if change.late or (self.alarm.state != "disarmed" and change.t < self.alarm.since - 2):
                    continue
                if change.kind == "door" and change.open:
                    contact = self.hub.contact(change.contact) or {"id": change.contact, "name": change.contact}
                    effects += self.alarm.door_opened(contact)
            self._commit(before)
        self._execute(effects)

    # ── commands ──

    def arm(self, mode: str, bypass: list[str] | None = None, source: str = "app") -> dict:
        self._require()
        with self.lock:
            before = self.alarm.state
            effects = self.alarm.arm(mode, bypass or [])
            self._commit(before, source)
        self._execute(effects)
        return self.state()

    def cancel_arming(self, source: str = "app") -> dict:
        self._require()
        with self.lock:
            before = self.alarm.state
            effects = self.alarm.cancel_arming()
            self._commit(before, source)
        self._execute(effects)
        return self.state()

    def arm_now(self, source: str = "app") -> dict:
        self._require()
        with self.lock:
            before = self.alarm.state
            effects = self.alarm.arm_now()
            self._commit(before, source)
        self._execute(effects)
        return self.state()

    def _verify(self, action: str, proof: dict, nonce: Any = None) -> None:
        self.approver.verify(action, nonce if nonce is not None else proof.get("nonce"), proof.get("ts"),
                             proof.get("signature"), domain=DOMAIN)

    def disarm(self, proof: dict, source: str = "app") -> dict:
        self._require()
        self._verify("disarm", proof or {})
        return self._do("disarm", source)

    def silence(self, proof: dict, source: str = "app") -> dict:
        self._require()
        self._verify("silence", proof or {})
        return self._do("silence", source)

    def _do(self, action: str, source: str) -> dict:
        with self.lock:
            before = self.alarm.state
            effects = self.alarm.disarm() if action == "disarm" else self.alarm.silence()
            self._commit(before, source)
            if action == "silence":
                self.store.append_event({"t": self.clock(), "kind": "alarm", "state": self.alarm.state,
                                         "text": "Siren silenced", "source": source})
        self._execute(effects)
        return self.state()

    def create_approval(self, action: str, source: str = "Jarvis") -> dict:
        if action not in APPROVAL_TITLES:
            raise ValueError("Only disarm and silence need an approval.")
        self._require()
        item = self.approvals.create(action, source=source)

        def notify():
            self.push(f"{item['title']}?", "Jarvis asked. Approve it with Face ID.",
                      {"type": "door_alarm", "approval": item["id"]}, "DOOR_APPROVAL", "time-sensitive")
            device = self.bridge.offering("door_show_approvals")
            if device:   # no live link? invoke_skill wakes the phone with a push
                self._safe_invoke(device, "door_show_approvals", {}, timeout=8.0)

        self._run_alerts(notify)
        return item

    def answer_approval(self, approval_id: str, proof: dict) -> dict:
        item = self.approvals.peek(approval_id)
        self._verify(item["command"], proof or {}, nonce=approval_id)
        self.approvals.take(approval_id)
        return self._do(item["command"], "Jarvis (approved with Face ID)")

    def deny_approval(self, approval_id: str) -> None:
        self.approvals.take(approval_id)

    def set_value(self, code: str, value: Any) -> dict:
        cfg = self._require()
        dp = self.hub.by_code.get(code)
        if dp is None:
            raise ValueError(f"The hub has no setting '{code}'.")
        wanted = schema.coerce(dp, value)
        event = threading.Event()
        waiter = (code, wanted, event)
        self._waiters.append(waiter)
        try:
            via = self._send({code: wanted})
            if via is None:
                raise CommandFailed("Neither the ESP32 proxy nor Tuya's cloud could reach the hub.")
            if not event.wait(self.confirm_timeout):
                raise CommandFailed(f"The hub didn't confirm {dp.name or code} (sent via {via}).")
            return {"ok": True, "code": code, "value": wanted, "via": via}
        finally:
            self._waiters.remove(waiter)

    def _send(self, values: dict, both: bool = False) -> Optional[str]:
        """Write DPs: the ESP32 first; the cloud if that fails (or also, with ``both``)."""
        cfg = self.hub.cfg
        via = None
        board = cfg.get("proxy")
        if board and self.bridge.is_connected(board):
            dps = {str(self.hub.by_code[c].id): v for c, v in values.items() if c in self.hub.by_code}
            res = self._safe_invoke(board, "esp32_door_set", {"dps": dps}, timeout=8.0) or {}
            result = res.get("result")
            if res.get("ok") and not (isinstance(result, dict) and result.get("ok") is False):
                via = "esp32"
        if via is None or both:
            cloud = self.cloud()
            if cloud is not None and cfg.get("dev_id"):
                try:
                    cloud.issue(cfg["dev_id"], values)
                    via = via or "cloud"
                except TuyaError as exc:
                    log.info("door alarm: cloud write failed: %s", exc)
                    if via is None:
                        raise CommandFailed(str(exc)) from exc
        return via

    def settings(self) -> dict:
        return {"alarm": dict(self.alarm.settings), "contacts": self.hub.contacts(), "siren": self.hub.cfg.get("siren") or {}}

    def update_settings(self, changes: dict) -> dict:
        changes = changes or {}
        with self.lock:
            cfg = self.store.config()
            if isinstance(changes.get("alarm"), dict):
                cfg["alarm"] = self.alarm.update_settings(changes["alarm"])
            if isinstance(changes.get("contacts"), dict):
                contacts = dict(cfg.get("contacts") or {})
                for cid, values in changes["contacts"].items():
                    if not isinstance(values, dict):
                        continue
                    own = dict(contacts.get(str(cid)) or {})
                    for key, kind in CONTACT_KEYS.items():
                        if key in values:
                            val = values[key]
                            own[key] = (str(val or "").strip()[:500 if key == "on_open_prompt" else 40]
                                        if kind is str else bool(val))
                    contacts[str(cid)] = own
                cfg["contacts"] = contacts
            if isinstance(changes.get("siren"), dict):
                siren = dict(cfg.get("siren") or {})
                for key in ("ringtone", "volume"):
                    if key not in changes["siren"]:
                        continue
                    value = changes["siren"][key]
                    if value is None:
                        siren.pop(key, None)
                        continue
                    dp = next((self.hub.by_code[c] for c in self.hub.roles.get(key) or []
                               if c in self.hub.by_code and self.hub.by_code[c].writable), None)
                    if dp is None:
                        raise ValueError(f"The hub has no {key} setting.")
                    siren[key] = schema.coerce(dp, value)   # the siren must be a value the hub takes
                cfg["siren"] = siren
            self.store.save_config(cfg)
            self.hub.reload()
        return self.settings()

    def rename(self, name: str) -> dict:
        cfg = self._require()
        name = (name or "").strip()[:40]
        if not name:
            raise ValueError("Give the hub a name.")
        self._cloud_required().rename(cfg["dev_id"], name)
        self.store.update_config(name=name)
        self.hub.reload()
        return self.state()

    def network(self) -> dict:
        cfg = self._require()
        out = {"link": self.hub.public()["link"], "cloud_device": None}
        cloud = self.cloud()
        if cloud is not None:
            try:
                info = cloud.device(cfg["dev_id"])
                keep = ("online", "ip", "time_zone", "active_time", "update_time", "model", "uuid", "sub")
                out["cloud_device"] = {k: info.get(k) for k in keep}
            except TuyaError as exc:
                out["cloud_error"] = str(exc)
        return out

    def firmware(self) -> dict:
        cfg = self._require()
        try:
            return {"firmware": self._cloud_required().firmware(cfg["dev_id"])}
        except TuyaError as exc:
            return {"firmware": [], "error": str(exc)}

    def upgrade(self, firmware_id: Any) -> dict:
        cfg = self._require()
        self._cloud_required().upgrade(cfg["dev_id"], firmware_id)
        self.store.append_event({"t": self.clock(), "kind": "firmware", "text": f"Firmware update started ({firmware_id})"})
        return {"ok": True}

    # ── time ──

    def tick(self) -> None:
        with self.lock:
            before = self.alarm.state
            effects = self.alarm.tick()
            if effects or self.alarm.state != before:
                self._commit(before)
        self._execute(effects)
        self._health()

    def _commit(self, before: str, source: str = "") -> None:
        self.store.save_state(self.alarm.snapshot())
        after = self.alarm.state
        if after != before:
            text = "Arming cancelled" if (before, after) == ("arming", "disarmed") else STATE_TEXT.get(after, after)
            if after in ("entry", "triggered") and self.alarm.contact_name:
                text = f"{text}: {self.alarm.contact_name}"
            event = {"t": self.clock(), "kind": "alarm", "state": after, "from": before, "text": text}
            if source:
                event["source"] = source
            self.store.append_event(event)
            page = self._pod_state_page(after)
            if page:
                self._run_alerts(lambda: self._pod_show(page))

    # ── effects ──

    def _execute(self, effects: list[Effect]) -> None:
        hub = [e for e in effects if e.kind in ("siren_on", "siren_off")]
        alerts = [e for e in effects if e.kind not in ("siren_on", "siren_off")]
        if alerts:
            self._run_alerts(lambda: [self._effect(e) for e in alerts])
        if hub:
            self._run_hub(lambda: [self._effect(e) for e in hub])

    def _effect(self, effect: Effect) -> None:
        d, kind = effect.data, effect.kind
        try:
            if kind == "siren_on":
                self._siren(True)
            elif kind == "siren_off":
                self._siren(False)
            elif kind == "push_entry":
                self.push(f"{d.get('name')} opened", f"Disarm within {d.get('seconds')} s — then the alarm goes off.",
                          {"type": "door_alarm", "state": "entry"}, "DOOR_ALARM", "time-sensitive")
                self._show_alarm()
            elif kind == "push_triggered":
                self.push(f"Door alarm: {d.get('name')}", "The alarm is going off. Disarm it with Face ID in Jarvis.",
                          {"type": "door_alarm", "state": "triggered"}, "DOOR_ALARM", "time-sensitive")
                self._show_alarm()
            elif kind == "push_info":
                self.push(f"{d.get('name')} opened", "The door alarm is off.", {"type": "door_alarm"}, None, "active")
            elif kind in ("ring_phone", "stop_ring"):
                if kind == "stop_ring" and self.alarm.state == "triggered":   # silenced: the Pod goes quiet too
                    self._pod_show(_pod_page(self.alarm.contact_name or ""))
                device = self.bridge.offering("door_alarm_ring")
                if device:   # an asleep phone has no live link: invoke_skill wakes it with a push
                    args = {"stop": True} if kind == "stop_ring" else {"name": d.get("name") or "A door"}
                    self._safe_invoke(device, "door_alarm_ring", args, timeout=8.0)
            elif kind == "pod_alert":
                pass   # the ALARM page went to the Pod with the state change (_pod_state_page), ahead of the phone
            elif kind == "note" and not d.get("state"):   # state changes are already logged by _commit
                self.store.append_event({"t": self.clock(), "kind": "note", "text": d.get("text")})
            elif kind == "prompt":
                self.run_prompt(f"[Door alarm] {d.get('name')} just opened. {d.get('prompt')}")
        except Exception:
            log.warning("door alarm effect %s failed", kind, exc_info=True)

    def _pod_state_page(self, state: str) -> Optional[dict]:
        """The Pod's screen for an alarm state (the countdowns tick on the Pod itself)."""
        a, now = self.alarm, self.clock()
        left = int(max(0.0, (a.deadline or now) - now) + 0.5)
        if state == "arming" and a.deadline:   # Ring-style: a beep a second, faster for the last 10 s
            return _pod_status("bell.fill", "Arming", "accent", "Leave now", timer_to=a.deadline, now=now,
                               sound={"name": "beep", "every_ms": 1000, "for_s": left, "fast_last_s": 10, "fast_ms": 500})
        if state == "entry" and a.deadline:
            return _pod_status("exclamationmark.triangle.fill", "Door opened", "danger",
                               (a.contact_name or "A door")[:24], timer_to=a.deadline, now=now,
                               sound={"name": "beep", "every_ms": 500, "for_s": left})
        if state in ("armed_away", "armed_home"):
            return _pod_status("checkmark", "Armed " + ("away" if state == "armed_away" else "home"), "accent",
                               "Door alarm on", ttl=8, sound={"name": "success"})
        if state == "disarmed":
            return _pod_status("checkmark", "Disarmed", "success", "Door alarm off", ttl=8, sound={"name": "success"})
        if state == "triggered":   # here, not in the effects: those wait behind the phone and the Pod went silent
            return _pod_page(a.contact_name or "", (a.siren_until or 0) - now)
        return None

    def _pod_show(self, page: dict) -> None:
        device = self.bridge.offering("pod_show")
        if device:
            self._safe_invoke(device, "pod_show", {"page": page}, timeout=8.0)

    def _show_alarm(self) -> None:
        """Pop the alarm card up on the phone (its countdown + Face ID disarm) if the app can hear us."""
        device = self.bridge.offering("door_show_alarm")
        if device:
            self._safe_invoke(device, "door_show_alarm", {}, timeout=8.0)

    def _loudest(self, dp: schema.Dp) -> Any:
        if dp.type == "enum":
            loud = [v for v in dp.range if v.lower() not in ("mute", "off", "close", "none")]
            return loud[-1] if loud else None
        if dp.type == "value":
            return dp.max
        return None

    def _siren(self, on: bool) -> None:
        roles, by_code = self.hub.roles, self.hub.by_code
        sirens = [c for c in roles.get("siren") or [] if c in by_code and by_code[c].writable]
        if not sirens:
            self.store.append_event({"t": self.clock(), "kind": "note",
                                     "text": "The hub has no siren control mapped — phone and Pod only."})
            return
        prefs = self.hub.cfg.get("siren") or {}
        writes: list[dict] = []
        volume = next((by_code[c] for c in roles.get("volume") or [] if c in by_code and by_code[c].writable), None)
        tone = next((by_code[c] for c in roles.get("ringtone") or [] if c in by_code and by_code[c].writable), None)
        if on:
            if volume is not None:
                current = (self.hub.values.get(volume.code) or {}).get("value")
                if self._saved_volume is None and current is not None:
                    self._saved_volume = (volume.code, current)
                loud = prefs.get("volume") if prefs.get("volume") is not None else self._loudest(volume)
                if loud is not None:
                    writes.append({volume.code: loud})
            if tone is not None and prefs.get("ringtone") is not None:
                writes.append({tone.code: prefs["ringtone"]})
            writes += [{code: True} for code in sirens]
        else:
            writes += [{code: False} for code in sirens]
            if self._saved_volume is not None:
                writes.append({self._saved_volume[0]: self._saved_volume[1]})
                self._saved_volume = None
        for values in writes:
            try:
                self._send(values, both=on)
            except CommandFailed as exc:
                log.warning("door alarm siren write failed: %s", exc)

    # ── health ──

    def _warn(self, key: str, title: str, body: str, level: str = "active", every: float = 3600.0) -> None:
        now = self.clock()
        if now - self._warned.get(key, -1e18) < every:
            return
        self._warned[key] = now
        self.store.append_event({"t": now, "kind": "health", "key": key, "text": body})
        self._run_alerts(lambda: self.push(title, body, {"type": "door_alarm", "health": key}, None, level))

    def _cloud_auth_warning(self, error: str) -> None:
        self._warn("cloud_auth", "Door alarm cloud backup is off",
                   f"Tuya refused Jarvis ({error or 'credentials'}). The ESP32 still watches the doors; "
                   "renew the Tuya cloud project to keep the backup.")

    def _health(self) -> None:
        if not self.hub.configured:
            return
        now = self.clock()
        link = self.hub.link
        local_alive, cloud_alive = self.hub.local_alive(), self.hub.cloud_alive()
        if self.alarm.state in ARMED_STATES and not local_alive and not cloud_alive:
            heard = [t for t in (link["local"].get("seen"), link["cloud"].get("seen"), self.alarm.since) if t]
            if now - max(heard) >= 60:
                self._warn("blind", "Door alarm can't see the doors",
                           "Neither the ESP32 at home nor Tuya's cloud has heard from the hub. "
                           "The alarm is armed but deaf.", level="time-sensitive")
        proxy = self.hub.cfg.get("proxy")
        if proxy and not local_alive and cloud_alive:
            since = max(t for t in (link["local"].get("seen"), self.hub.cfg.get("proxy_set_at"), 0) if t is not None)
            if now - since > 90:
                self._warn("proxy_down", "Door alarm proxy offline",
                           "The ESP32 at home isn't talking to the hub; using Tuya's cloud for now.")
        if link["cloud"].get("state") == "auth":
            self._cloud_auth_warning(link["cloud"].get("error") or "")
        for code in self.hub.roles.get("battery") or []:
            value = (self.hub.values.get(code) or {}).get("value")
            low = (isinstance(value, (int, float)) and not isinstance(value, bool) and value < 20) or \
                  str(value).lower() in ("low", "lowbattery")
            if low:
                self._warn(f"battery:{code}", "Door sensor battery low",
                           f"A door contact reports a low battery ({value}).", every=86400.0)
