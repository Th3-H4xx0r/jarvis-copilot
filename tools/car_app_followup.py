"""Open an app on the user's device, then run the command once the app is up.

THE template for a CarPlay command that needs an app open first (music,
podcasts, a nav app): copy this shape, don't write another poller.

Why it exists: in the car the phone is locked and Jarvis talks through its
CarPlay scene. The phone's ``open_app`` there is queued: the app opens on the
car's screen only AFTER Jarvis finishes its reply, and that reply ends the voice
conversation. So a tool whose command needs the app running (Spotify Connect can
only play on a running Spotify) can't open the app and wait inside the turn. It
asks the phone to open the app, returns at once with a pending result the model
speaks ("Playing it, sir."), and finishes the job in the background as soon as
the app is up. Off CarPlay the phone's own ``open_app`` path applies (opened in
front, or a tap-to-run notification on a locked phone); the follow-up is the same.

Usage, from a tool handler (``task_id`` is the webui chat session id)::

    from tools import car_app_followup

    def _handle_podcast_play(args, **kw):
        device = car_app_followup.turn_device(kw.get("task_id"))
        out = car_app_followup.open_then(
            "podcasts", device,
            ready=lambda: podcasts.active_player(),        # truthy once the app is up
            action=lambda player: player.play(args["episode"]),
            label="Podcasts play",
        )
        return tool_result({"success": True, "pending": True, "note": out["note"]})

When a link starts the thing itself, open the link instead of the bare app:
``request_open(app, device, url=..., now=True)`` asks the phone's ``open_url`` to
open it on the car's screen right away, then ``follow_up(ready, action, ...)``
checks it took (Spotify: a ``spotify:track:`` link opens Spotify and plays it,
because iPhone Spotify opened idle on CarPlay never shows up as a Connect device
— see plugins/spotify/tools.py).

Contract:

* ``ready()`` is falsy until the app is up; what it returns is handed to
  ``action``. A ``ready()`` that raises counts as "not yet".
* ``action(value)`` runs once. Raising retries it on the next tick (the app came
  up but isn't ready for the command yet); raising :class:`Cancelled` stops
  without retrying (e.g. a newer request won, checked under the caller's lock).
* ``cancelled`` is an Event the caller sets to drop the follow-up (a newer
  request, a "stop"); the wait wakes at once.
* After ``timeout_s`` it gives up and ``on_timeout`` runs. Every outcome is logged.
* ``open_then`` never waits for the follow-up: one open request (bounded by
  ``open_timeout_s``), then a daemon thread that ends by ``timeout_s``.

Tests pass ``spawn=`` (or monkeypatch :func:`start_background`) to capture the
runner, then call it with ``sleep=`` / ``clock=`` fakes: synchronous, no threads.
"""

from __future__ import annotations

import functools
import logging
import threading
import time
from typing import Any, Callable, Optional

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_S = 30.0
DEFAULT_POLL_S = 1.5
# The phone answers open_app at once on CarPlay (it only queues the link); this
# bounds a phone that is slow to wake so the voice turn isn't held up.
OPEN_TIMEOUT_S = 10.0
OPEN_SKILL = "open_app"
OPEN_URL_SKILL = "open_url"


class Cancelled(Exception):
    """Raised by an action that must not run after all (see the module docstring)."""


def turn_device(session_id: Optional[str]) -> Optional[str]:
    """The paired device the current turn came from (webui/api/turn_origin.py), or
    None. A webui turn's ``task_id`` is its chat session id."""
    origin = turn_origin(session_id)
    return origin["device_id"] if origin else None


def turn_origin(session_id: Optional[str]) -> Optional[dict]:
    """The current turn's device — ``device_id``, ``name``, ``kind``, ``mac``,
    ``carplay`` (a voice turn the phone started in the car) — or None."""
    if not session_id:
        return None
    try:
        from api import turn_origin as _turn_origin

        origin = _turn_origin.origin_for_session(session_id)
        return {**origin, "carplay": _turn_origin.is_carplay_session(session_id)} if origin else None
    except Exception:
        return None


def turn_phone(session_id: Optional[str]) -> Optional[dict]:
    """``turn_origin`` when the turn came from his phone (the iPhone app), else None."""
    origin = turn_origin(session_id)
    if origin and str(origin.get("kind") or "").startswith("mobile"):
        return origin
    return None


def _invoke_device_skill(device_id: str, skill: str, args: dict, timeout: float = OPEN_TIMEOUT_S) -> dict:
    """Run a device skill: in process inside the webui, else over its HTTP API.
    Never raises; answers ``{"ok": ..., "result" | "error": ...}``."""
    try:
        from api import device_bridge

        in_process = device_bridge.in_process_available()
    except Exception:
        in_process = False
    try:
        if in_process:
            offered = {s.get("name") for s in device_bridge.skills_for_device(device_id) if isinstance(s, dict)}
            if skill not in offered:
                return {"ok": False, "error": f"that device has no {skill} skill"}
            return device_bridge.invoke_skill(device_id, skill, args, timeout=timeout)
        from tools.chrome_device_tool import invoke_skill_safe

        return invoke_skill_safe(device_id, skill, args)
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def request_open(app: str, device_id: str, *, url: Optional[str] = None, now: bool = False,
                 invoke: Optional[Callable[..., dict]] = None, timeout_s: float = OPEN_TIMEOUT_S) -> dict:
    """Ask ``device_id`` to open ``app`` — or, with ``url``, to open that link (the
    phone's ``open_url``; ``now`` asks it to open on the car's screen right away
    instead of after the reply, e.g. a ``spotify:track:`` link Spotify plays).
    Returns ``{"opened", "device_note", "error"}``; ``device_note`` is what the
    device said (on CarPlay: it opens on the car's screen when Jarvis finishes)."""
    if url:
        skill, args = OPEN_URL_SKILL, {"url": url, **({"now": True} if now else {})}
    else:
        skill, args = OPEN_SKILL, {"app": app}
    try:
        reply = invoke(device_id, skill, args) if invoke else _invoke_device_skill(
            device_id, skill, args, timeout=timeout_s)
    except Exception as exc:
        reply = {"ok": False, "error": str(exc)}
    if not isinstance(reply, dict) or not reply.get("ok"):
        error = reply.get("error") if isinstance(reply, dict) else None
        return {"opened": False, "device_note": "", "error": str(error or "the device did not answer")}
    inner = reply.get("result")
    if isinstance(inner, dict) and (inner.get("ok") is False or inner.get("launched") is False):
        return {"opened": False, "device_note": "", "error": str(inner.get("error") or f"{app} did not open")}
    note = str(inner.get("note") or "") if isinstance(inner, dict) else ""
    return {"opened": True, "device_note": note, "error": ""}


def run_followup(
    ready: Callable[[], Any],
    action: Callable[[Any], Any],
    *,
    timeout_s: float = DEFAULT_TIMEOUT_S,
    poll_s: float = DEFAULT_POLL_S,
    cancelled: Optional[threading.Event] = None,
    on_timeout: Optional[Callable[[], Any]] = None,
    label: str = "app follow-up",
    log: Optional[logging.Logger] = None,
    sleep: Optional[Callable[[float], Any]] = None,
    clock: Callable[[], float] = time.monotonic,
) -> str:
    """Wait for ``ready()``, then run ``action`` — synchronously.

    Returns ``"done"``, ``"cancelled"`` or ``"timeout"``. ``open_then`` runs it on
    a daemon thread; tests call it directly with a fake ``sleep``/``clock``.
    """
    log = log or logger
    wait = sleep or (cancelled.wait if cancelled is not None else time.sleep)
    started = clock()
    deadline = started + timeout_s
    last_error: Optional[BaseException] = None
    while True:
        wait(poll_s)
        if cancelled is not None and cancelled.is_set():
            log.info("%s cancelled: superseded before it ran", label)
            return "cancelled"
        try:
            value = ready()
        except Exception as exc:
            last_error, value = exc, None
        if value:
            try:
                action(value)
            except Cancelled as exc:
                log.info("%s cancelled: %s", label, exc or "superseded before it ran")
                return "cancelled"
            except Exception as exc:
                last_error = exc  # up, but not ready for the command yet: next tick
            else:
                log.info("%s done after %.1f s", label, clock() - started)
                return "done"
        if clock() >= deadline:
            if on_timeout is not None:
                try:
                    on_timeout()
                except Exception:
                    log.exception("%s: on_timeout failed", label)
            log.warning("%s gave up after %.0f s: the app never became ready%s", label, timeout_s,
                        f" (last error: {last_error})" if last_error else "")
            return "timeout"


def start_background(run: Callable[[], Any], name: str) -> threading.Thread:
    """Run ``run`` on a daemon thread; a crash is logged, never raised."""

    def _guarded() -> None:
        try:
            run()
        except Exception:
            logger.exception("background follow-up %s crashed", name)

    thread = threading.Thread(target=_guarded, name=name, daemon=True)
    thread.start()
    return thread


def follow_up(
    ready: Callable[[], Any],
    action: Callable[[Any], Any],
    *,
    timeout_s: float = DEFAULT_TIMEOUT_S,
    poll_s: float = DEFAULT_POLL_S,
    cancelled: Optional[threading.Event] = None,
    on_timeout: Optional[Callable[[], Any]] = None,
    label: str = "app follow-up",
    log: Optional[logging.Logger] = None,
    name: str = "app-follow-up",
    spawn: Optional[Callable[[Callable[..., str], str], Any]] = None,
) -> Any:
    """Start ``run_followup`` in the background (for a caller that did its own
    open request). Returns what ``spawn`` returns — the thread by default."""
    runner = functools.partial(
        run_followup, ready, action, timeout_s=timeout_s, poll_s=poll_s, cancelled=cancelled,
        on_timeout=on_timeout, label=label, log=log,
    )
    return (spawn or start_background)(runner, name)


def _app_title(app: str) -> str:
    app = app.strip()
    return app if any(c.isupper() for c in app) else app.title()


def open_then(
    app: str,
    device_id: Optional[str],
    ready: Callable[[], Any],
    action: Callable[[Any], Any],
    *,
    timeout_s: float = DEFAULT_TIMEOUT_S,
    poll_s: float = DEFAULT_POLL_S,
    cancelled: Optional[threading.Event] = None,
    on_timeout: Optional[Callable[[], Any]] = None,
    label: str = "",
    log: Optional[logging.Logger] = None,
    invoke: Optional[Callable[..., dict]] = None,
    open_timeout_s: float = OPEN_TIMEOUT_S,
    spawn: Optional[Callable[[Callable[..., str], str], Any]] = None,
) -> dict:
    """Ask the turn's device to open ``app``, then run ``action`` once ``ready()``.

    Returns at once with the pending result for the tool to hand the model:
    ``{"pending", "app", "device_id", "opened", "device_note", "error", "wait_s",
    "note"}``. ``note`` is a default model-facing line; tools usually write their
    own from ``opened`` / ``device_note``. With no ``device_id`` (or a device that
    won't open it) nothing opens, but the follow-up still waits — the model is
    told to open the app itself.
    """
    log = log or logger
    label = label or f"{app} follow-up"
    if device_id:
        opening = request_open(app, device_id, invoke=invoke, timeout_s=open_timeout_s)
    else:
        opening = {"opened": False, "device_note": "", "error": "no device to open it on"}
    follow_up(ready, action, timeout_s=timeout_s, poll_s=poll_s, cancelled=cancelled,
              on_timeout=on_timeout, label=label, log=log, spawn=spawn,
              name=f"open-then-{app.strip().lower().replace(' ', '-')}")
    wait_s = int(timeout_s)
    name = _app_title(app)
    if opening["opened"]:
        said = f" ({opening['device_note'].rstrip('.')})" if opening["device_note"] else ""
        note = (f"{name} is opening{said}; this runs by itself as soon as it's up, within {wait_s} s. "
                f"Don't open {name} or repeat the command.")
        log.info("%s: asked %s to open %s; waiting up to %d s", label, device_id, app, wait_s)
    else:
        note = (f"{name} isn't open yet. Open it with device_open_app: this runs by itself as soon as "
                f"{name} is up, within {wait_s} s. Don't repeat the command.")
        log.info("%s: %s not opened (%s); waiting up to %d s", label, app, opening["error"], wait_s)
    return {
        "pending": True,
        "app": app,
        "device_id": device_id,
        "opened": opening["opened"],
        "device_note": opening["device_note"],
        "error": opening["error"],
        "wait_s": wait_s,
        "note": note,
    }
