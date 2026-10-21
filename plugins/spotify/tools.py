"""Native Spotify tools for JarvisCopilot (registered via plugins/spotify)."""

from __future__ import annotations

import functools
import logging
import threading
import time
from typing import Any, Callable, Dict, List, Optional

from jarviscopilot_cli.auth import get_auth_status
from plugins.spotify.client import (
    SpotifyAPIError,
    SpotifyAuthRequiredError,
    SpotifyClient,
    SpotifyError,
    normalize_spotify_id,
    normalize_spotify_uri,
    normalize_spotify_uris,
)
from tools import car_app_followup
from tools.registry import tool_error, tool_result

logger = logging.getLogger(__name__)

# A play that finds no Spotify device at all waits this long (polling every
# interval) for one to come online — e.g. the phone opening Spotify on CarPlay
# a few seconds after Jarvis finishes speaking.
_PENDING_PLAY_WINDOW_S = 30.0
_PENDING_PLAY_POLL_INTERVAL_S = 1.5


def _check_spotify_available() -> bool:
    try:
        return bool(get_auth_status("spotify").get("logged_in"))
    except Exception:
        return False


def _spotify_client() -> SpotifyClient:
    return SpotifyClient()


def _spotify_tool_error(exc: Exception) -> str:
    if isinstance(exc, (SpotifyError, SpotifyAuthRequiredError)):
        return tool_error(str(exc))
    if isinstance(exc, SpotifyAPIError):
        return tool_error(str(exc), status_code=exc.status_code)
    return tool_error(f"Spotify tool failed: {type(exc).__name__}: {exc}")


def _coerce_limit(raw: Any, *, default: int = 20, minimum: int = 1, maximum: int = 50) -> int:
    try:
        value = int(raw)
    except Exception:
        value = default
    return max(minimum, min(maximum, value))


def _coerce_bool(raw: Any, default: bool = False) -> bool:
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, str):
        cleaned = raw.strip().lower()
        if cleaned in {"1", "true", "yes", "on"}:
            return True
        if cleaned in {"0", "false", "no", "off"}:
            return False
    return default


def _as_list(raw: Any) -> List[str]:
    if raw is None:
        return []
    if isinstance(raw, list):
        return [str(item).strip() for item in raw if str(item).strip()]
    return [str(raw).strip()] if str(raw).strip() else []


def _describe_empty_playback(payload: Any, *, action: str) -> dict | None:
    if not isinstance(payload, dict) or not payload.get("empty"):
        return None
    if action == "get_currently_playing":
        return {
            "success": True,
            "action": action,
            "is_playing": False,
            "status_code": payload.get("status_code", 204),
            "message": payload.get("message") or "Spotify is not currently playing anything.",
        }
    if action == "get_state":
        return {
            "success": True,
            "action": action,
            "has_active_device": False,
            "status_code": payload.get("status_code", 204),
            "message": payload.get("message") or "No active Spotify playback session was found.",
        }
    return None


# ── Pending play: wait for a Spotify device to come online ─────────────────


class _PendingPlay:
    """One play request waiting for a Spotify Connect device to appear."""

    def __init__(self, play_kwargs: Dict[str, Any], phones_only: bool = False,
                 computers_only: bool = False) -> None:
        self.play_kwargs = play_kwargs
        self.phones_only = phones_only  # a phone turn: never the MacBook at home
        self.computers_only = computers_only  # a turn from his Mac: the Mac, never his phone
        self.cancelled = threading.Event()
        self.sent = 0  # plays sent that Spotify took but the device hasn't started yet
        self.waited = 0  # checks since the last one, while it loads


class _NotPlayingYet(Exception):
    """Spotify took the play but the device isn't playing it yet: look again — and
    send it again — on the follow-up's next tick."""


# Held while a pending play starts playback, and by every new play request
# before it starts its own: an old pending song can never land after a newer one.
_pending_lock = threading.Lock()
_pending_play: Optional[_PendingPlay] = None
_play_generation = 0


def _current_pending_play() -> Optional[_PendingPlay]:
    with _pending_lock:
        return _pending_play


def _cancel_pending_play() -> None:
    global _pending_play
    with _pending_lock:
        if _pending_play is not None:
            _pending_play.cancelled.set()
            _pending_play = None


def _begin_play_request() -> int:
    """Supersede any pending play; return this request's ticket."""
    global _pending_play, _play_generation
    with _pending_lock:
        _play_generation += 1
        if _pending_play is not None:
            _pending_play.cancelled.set()
            _pending_play = None
        return _play_generation


def _register_pending_play(ticket: int, play_kwargs: Dict[str, Any],
                           phones_only: bool = False, computers_only: bool = False) -> Optional[_PendingPlay]:
    """Make this the one pending play, unless a newer play request already started."""
    global _pending_play
    with _pending_lock:
        if ticket != _play_generation:
            return None
        pending = _PendingPlay(play_kwargs, phones_only=phones_only, computers_only=computers_only)
        _pending_play = pending
        return pending


def _is_smartphone(device: Dict[str, Any]) -> bool:
    return str(device.get("type") or "").lower() == "smartphone"


def _is_his_iphone(device: Dict[str, Any]) -> bool:
    """His iPhone's Spotify — not another phone Spotify lists on his Wi-Fi (2026-10-21:
    "Nandhini's Z Flip7"). iOS gives apps the name "iPhone"."""
    return _is_smartphone(device) and "iphone" in str(device.get("name") or "").lower()


def _is_computer(device: Dict[str, Any]) -> bool:
    return str(device.get("type") or "").lower() == "computer"


def _pick_device(devices_payload: Any, *, phones_only: bool = False, computers_only: bool = False,
                 exclude: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """Best device to play on: unrestricted first, then smartphones, then the
    active one. ``phones_only`` (a turn from his phone): only an unrestricted
    smartphone — never the MacBook at home. ``computers_only`` (a turn from his
    Mac): only a computer — never his phone. ``exclude``: a device that just failed."""
    devices = devices_payload.get("devices") if isinstance(devices_payload, dict) else None
    candidates = [d for d in devices or [] if isinstance(d, dict) and d.get("id") and d.get("id") != exclude
                  and (_is_his_iphone(d) or not _is_smartphone(d))]  # never a guest's phone on his Wi-Fi
    if phones_only:
        # His iPhone, never another phone Spotify lists on his Wi-Fi ("Nandhini's Z Flip7", 2026-10-21).
        candidates = [d for d in candidates if _is_his_iphone(d) and not d.get("is_restricted")]
    if computers_only:
        candidates = [d for d in candidates if _is_computer(d)]
    if not candidates:
        return None
    return min(
        candidates,
        key=lambda d: (bool(d.get("is_restricted")), not _is_smartphone(d), not d.get("is_active")),
    )


def _play_uri(play_kwargs: Dict[str, Any]) -> Optional[str]:
    """The spotify: link that plays the request: the (first) track, else the context."""
    uris = play_kwargs.get("uris") or []
    return (uris[0] if uris else None) or play_kwargs.get("context_uri")


def _playback_state(client: Any) -> Dict[str, Any]:
    try:
        state = client.get_playback_state()
    except Exception as exc:
        return {"error": str(exc)}
    return state if isinstance(state, dict) else {}


def _holds(state: Dict[str, Any], device: Dict[str, Any], play_kwargs: Dict[str, Any]) -> bool:
    """Whether ``device`` has what was asked loaded (playing or not). A track
    Spotify swapped for his country's copy names the asked one in ``linked_from``."""
    want_track = (play_kwargs.get("uris") or [None])[0]
    want_context = play_kwargs.get("context_uri")
    if not (want_track or want_context) or state.get("empty") or not state.get("device"):
        return False
    if str((state.get("device") or {}).get("id") or "") != str(device.get("id")):
        return False
    if want_track:
        item = state.get("item") or {}
        return want_track in (str(item.get("uri") or ""), str((item.get("linked_from") or {}).get("uri") or ""))
    return str((state.get("context") or {}).get("uri") or "") == want_context


def _already_playing(client: Any, device: Dict[str, Any], play_kwargs: Dict[str, Any]) -> bool:
    """Whether ``device`` already plays what was asked (Spotify started the link
    the phone opened) — then starting it again would only restart it."""
    state = _playback_state(client)
    return bool(state.get("is_playing")) and _holds(state, device, play_kwargs)


def _describe_state(state: Dict[str, Any]) -> str:
    if state.get("error"):
        return f"no state ({state['error']})"
    if state.get("empty") or not state.get("device"):
        return "nothing playing anywhere"
    device = state.get("device") or {}
    item = state.get("item") or {}
    linked = (item.get("linked_from") or {}).get("uri")
    return (f"{'playing' if state.get('is_playing') else 'paused'} on {device.get('name') or '?'} "
            f"({device.get('id')}, active={device.get('is_active')}): {item.get('uri')}"
            f"{f' (for {linked})' if linked else ''} at {state.get('progress_ms')} ms")


def _status(result: Any) -> str:
    """What Spotify answered a player command: its HTTP status (204 done, 202 queued)."""
    return f"HTTP {result.get('status_code')}" if isinstance(result, dict) and result.get("status_code") else "taken"


def _device_label(device: Dict[str, Any]) -> str:
    return str(device.get("name") or device.get("id"))


# Checks a taken play gets to start before it is sent again: each play restarts the
# song, so one sent every check (2026-10-18 16:02: 15 in 30 s) never finishes loading.
_RESEND_AFTER_CHECKS = 3


def _start_pending_play(pending: _PendingPlay, client: Any, device: Dict[str, Any]) -> None:
    """The follow-up's action: play on the device that showed up, unless a newer
    play or a pause got there first (checked under the lock every play takes)."""
    global _pending_play
    with _pending_lock:
        if pending.cancelled.is_set():
            raise car_app_followup.Cancelled("superseded by a newer request")
        state = _playback_state(client)
        logger.info("Spotify reports for the play on %s: %s", _device_label(device), _describe_state(state))
        holds = _holds(state, device, pending.play_kwargs)
        playing = holds and bool(state.get("is_playing"))
        started = not playing
        if started:
            if holds:
                # Loaded but paused: carry on from there, not from the top.
                client.start_playback(device_id=device["id"])  # raises → next tick
            elif pending.sent and pending.waited < _RESEND_AFTER_CHECKS:
                pending.waited += 1
                raise _NotPlayingYet(f"{_device_label(device)} took play #{pending.sent}; still loading")
            else:
                if pending.sent and not state.get("device"):
                    # The last play never reached its player (16:56, 17:03: "nothing playing
                    # anywhere" after three plays): move playback to the phone, which wakes it.
                    moved = client.transfer_playback(device_id=device["id"], play=True)
                    logger.info("Spotify: moved playback to %s (%s)", _device_label(device), _status(moved))
                took = client.start_playback(device_id=device["id"], **pending.play_kwargs)  # raises → next tick
                logger.info("Spotify: play sent to %s (%s)", _device_label(device), _status(took))
            # Spotify takes a play for a phone that only just came up and then
            # never starts it (2026-10-18 06:49: "started", and silence). Done is
            # when Spotify says the phone plays the song — a resume has nothing to
            # check, so for that the take is enough.
            if _play_uri(pending.play_kwargs):
                pending.sent += 1
                pending.waited = 0
                raise _NotPlayingYet(f"{_device_label(device)} took play #{pending.sent}; not playing yet")
        pending.cancelled.set()
        if _pending_play is pending:
            _pending_play = None
    logger.info(
        "Spotify pending play %s on %s (%s)",
        f"playing after {pending.sent} play(s)" if pending.sent else ("started" if started else "was already playing"),
        _device_label(device),
        device.get("type") or "unknown type",
    )


def _drop_pending_play(pending: _PendingPlay) -> None:
    global _pending_play
    with _pending_lock:
        pending.cancelled.set()
        if _pending_play is pending:
            _pending_play = None


def _pending_play_followup(pending: _PendingPlay, client: Any, *, timeout_s: Optional[float] = None,
                           label: str = "Spotify pending play") -> Dict[str, Any]:
    """A pending play as a car_app_followup follow-up: ready once Spotify lists a
    device (only a smartphone on a phone turn), then play there unless it already
    plays it. ``pending.cancelled`` drops it (newest play wins, pause cancels)."""
    return {
        "ready": lambda: _pick_device(client.get_devices(), phones_only=pending.phones_only,
                                      computers_only=pending.computers_only),
        "action": functools.partial(_start_pending_play, pending, client),
        "timeout_s": _PENDING_PLAY_WINDOW_S if timeout_s is None else timeout_s,
        "poll_s": _PENDING_PLAY_POLL_INTERVAL_S,
        "cancelled": pending.cancelled,
        "on_timeout": functools.partial(_drop_pending_play, pending),
        "label": label,
        "log": logger,
    }


def _run_pending_play(
    pending: _PendingPlay,
    client: Any,
    *,
    window_s: Optional[float] = None,
    interval_s: Optional[float] = None,
    sleep: Optional[Callable[[float], Any]] = None,
    clock: Callable[[], float] = time.monotonic,
) -> str:
    """Poll for a device and start ``pending`` on the first one that shows up.

    Returns ``"played"``, ``"cancelled"`` (a newer play or a pause superseded
    it) or ``"timeout"``. Synchronous so tests can drive it with a fake clock;
    production runs it on a daemon thread (``_spawn_pending_play_poller``).
    """
    followup = _pending_play_followup(pending, client)
    if window_s is not None:
        followup["timeout_s"] = window_s
    if interval_s is not None:
        followup["poll_s"] = interval_s
    outcome = car_app_followup.run_followup(**followup, sleep=sleep, clock=clock)
    return "played" if outcome == "done" else outcome


def _spawn_pending_play_poller(pending: _PendingPlay, client: Any) -> threading.Thread:
    return car_app_followup.start_background(
        functools.partial(_run_pending_play, pending, client), "spotify-pending-play")


def _opening_note(device_note: str, window: int) -> str:
    """What the model hears when the turn's phone is opening Spotify itself."""
    said = device_note.strip()
    said = f" \u2014 {said[:1].lower()}{said[1:].rstrip('.')}" if said else ""
    return (
        f"Opening Spotify{said}. The song starts as soon as it's up (within {window} s); "
        "don't call open_app or play again."
    )


# After the song's link opened on his phone: how often to look, for how long, and how
# soon to open the link again while nothing plays.
_PHONE_CHECK_S = 2.0
_PHONE_SETTLE_S = 30.0
_PHONE_REOPEN_S = 4.0


def _server_phone_skill(device_id: str, skill: str, args: Dict[str, Any], timeout: float) -> Any:
    """Run a phone skill only the server may run, through the webui's own device bridge — the
    HTTP route refuses those (2026-10-20 22:44: every App Remote try got "'spotify_remote_play'
    is only run by the server itself")."""
    try:
        from api import device_bridge

        return device_bridge.invoke_skill(device_id, skill, args, timeout=timeout)
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def _ask_app_remote(phone_id: str, uri: str, credentials: Dict[str, str], label: str) -> Optional[str]:
    """One ask: what the phone did — "played" (its Spotify app was connected and took it) or
    "woke" (it opened Spotify's wake link) — or None when it couldn't. The token never goes in a log."""
    result = _server_phone_skill(phone_id, "spotify_remote_play", {"uri": uri, **credentials}, timeout=15)
    if isinstance(result, dict) and result.get("ok", True) and not result.get("error"):
        said = ", ".join(result["result"]) if isinstance(result.get("result"), dict) else "taken"
        logger.info("Spotify: the phone's Spotify app took %s (App Remote, %s: %s)", uri, label, said)
        return said
    logger.info("Spotify: App Remote %s didn't play it: %s", label,
                (result or {}).get("error") if isinstance(result, dict) else result)
    return None


def _app_remote_credentials(client: Any) -> Optional[Dict[str, str]]:
    try:
        return client.app_remote_credentials()
    except Exception:
        return None


def _phone_playing_note(phone: Dict[str, Any], opening: Dict[str, Any]) -> str:
    if phone.get("carplay"):
        return "Playing it in Spotify on the car."
    said = str(opening.get("device_note") or "").strip().rstrip(".")
    return "Playing it in Spotify on his phone" + (f" ({said})." if said else ".")


def _switch_on_phone(client: Any, phone_id: str, uri: str, credentials: Optional[Dict[str, str]],
                     device: Dict[str, Any]) -> bool:
    """Another song plays on his phone: its Spotify app switches it (App Remote takes a
    connection while Spotify plays). Else pause it, so the link opened next plays (a link
    opened while a song plays only shows the song — live 2026-10-21 00:12). True: switched."""
    if credentials and _ask_app_remote(phone_id, uri, credentials, "switch") == "played":
        return True
    try:
        logger.info("Spotify: paused the phone to open the song (%s)",
                    _status(client.pause_playback(device_id=device.get("id"))))
    except SpotifyAPIError as exc:
        logger.info("Spotify: the phone didn't pause (%s)", exc)
    return False


def _settle_on_phone(pending: _PendingPlay, client: Any, phone_id: str, uri: str,
                     credentials: Optional[Dict[str, str]], *, sleep: Optional[Callable[[float], Any]] = None,
                     clock: Callable[[], float] = time.monotonic) -> str:
    """Make sure the song plays on his phone, the ways his iPhone's Spotify takes (tested live
    2026-10-21 00:10-00:14, Spotify up in CarPlay):

    * a link Spotify is opened on plays when Spotify isn't playing — a phone that holds
      nothing gets the link again (Spotify is in front by then);
    * a play with no body (resume) starts the song it holds paused;
    * a song already playing is switched by its Spotify app, or paused and the link opened;
    * never a Web API play naming the song: Spotify answers 204 and drops to an empty player
      ("None at 0 ms") — Jarvis's own play stopped the songs its links had started.

    Returns "played", "cancelled" (a newer play or a pause) or "timeout"."""
    wait = sleep or time.sleep
    started = opened_at = clock()
    woken = False
    while clock() - started < _PHONE_SETTLE_S:
        wait(_PHONE_CHECK_S)
        if pending.cancelled.is_set():
            return "cancelled"
        state = _playback_state(client)
        logger.info("Spotify reports for the play on the phone: %s", _describe_state(state))
        device = state.get("device") or {}
        on_phone = _is_his_iphone(device)
        holds = on_phone and _holds(state, device, pending.play_kwargs)
        if holds and state.get("is_playing"):
            _drop_pending_play(pending)
            logger.info("Spotify: %s plays on the phone", uri)
            return "played"
        if holds:
            try:
                logger.info("Spotify: resumed the phone on it (%s)",
                            _status(client.resume_playback(device_id=device.get("id"))))
            except SpotifyAPIError as exc:
                logger.info("Spotify: the phone didn't resume (%s)", exc)
            continue
        if on_phone and state.get("is_playing"):
            if _switch_on_phone(client, phone_id, uri, credentials, device):
                continue
            opened_at = -1e9  # paused: open the song right away
        elif on_phone:
            opened_at = -1e9  # active, paused on another song: the link opened now plays (live 00:12)
        elif not woken:
            # Not Spotify's active player ("nothing playing anywhere" for 30 s, 00:18): a resume
            # aimed at the listed iPhone is what made it play from cold (live 00:10).
            listed = _pick_device(client.get_devices(), phones_only=True)
            if listed is not None:
                woken = True
                try:
                    logger.info("Spotify: woke the phone's player with a resume (%s)",
                                _status(client.resume_playback(device_id=listed["id"])))
                except SpotifyAPIError as exc:
                    logger.info("Spotify: the phone's player didn't wake (%s)", exc)
                continue
        if clock() - opened_at >= _PHONE_REOPEN_S:
            opened_at = clock()
            again = car_app_followup.request_open("spotify", phone_id, url=uri, now=True)
            logger.info("Spotify: opened %s on the phone again (%s)", uri,
                        "opened" if again["opened"] else again["error"])
    _drop_pending_play(pending)
    logger.warning("Spotify play on the phone gave up after %d s: %s never played there", int(_PHONE_SETTLE_S), uri)
    return "timeout"


def _open_on_phone(pending: _PendingPlay, client: Any, phone: Dict[str, Any], uri: str) -> Optional[str]:
    """Play the song on the turn's phone: switched by its Spotify app when another song plays
    there, else opened on it now (on CarPlay: on the car's screen; Spotify plays what it's
    opened on), then made sure of in the background (``_settle_on_phone``). None: the phone
    couldn't open it."""
    who = phone.get("name") or phone["device_id"]
    credentials = _app_remote_credentials(client)
    state = _playback_state(client)
    device = state.get("device") or {}
    settle = functools.partial(_settle_on_phone, pending, client, phone["device_id"], uri, credentials)
    if _is_his_iphone(device) and state.get("is_playing") and _holds(state, device, pending.play_kwargs):
        _drop_pending_play(pending)
        return tool_result({"success": True, "action": "play", "note": "It's already playing."})
    if _is_his_iphone(device) and state.get("is_playing"):
        if _switch_on_phone(client, phone["device_id"], uri, credentials, device):
            car_app_followup.start_background(settle, "spotify-phone-play")
            return tool_result({"success": True, "action": "play", "note": _phone_playing_note(phone, {})})
    opening = car_app_followup.request_open("spotify", phone["device_id"], url=uri, now=True)
    if not opening["opened"]:
        logger.info("Spotify play: the phone couldn't open %s (%s)", uri, opening["error"])
        return None
    car_app_followup.start_background(settle, "spotify-phone-play")
    logger.info("Spotify play: asked %s to open %s; making sure it plays there", who, uri)
    return tool_result({
        "success": True,
        "action": "play",
        "pending": True,
        "note": _phone_playing_note(phone, opening),
    })

def _names_another_device(client: Any, device_id: str) -> bool:
    """Whether ``device_id`` is a listed device that isn't a phone (he asked for his MacBook)."""
    try:
        devices = (client.get_devices() or {}).get("devices") or []
    except Exception:
        return False
    return any(isinstance(d, dict) and d.get("id") == device_id and not _is_smartphone(d) for d in devices)


_MAC_PLAY_SKILL = "spotify_play"


def _device_offers(device_id: str, skill: str) -> bool:
    try:
        from api import device_bridge

        return any(isinstance(s, dict) and s.get("name") == skill for s in device_bridge.skills_for_device(device_id))
    except Exception:
        return False


def _play_on_turn_mac(client: Any, ticket: int, play_kwargs: Dict[str, Any],
                      turn_session: Optional[str], device_id: Optional[str]) -> Optional[str]:
    """A turn from his Mac plays in the Mac's Spotify app. With no device named the Web API
    sends a play to whatever player is active — his iPhone after a drive — and says done while
    nothing plays (2026-10-20 23:34). The Mac's Spotify app takes the song itself (the Mac
    client's `spotify_play`, AppleScript), opening if it's closed; an older Mac client goes
    through the Web API, to the Mac only. None: not a Mac turn, or a device he named that
    Spotify lists."""
    origin = car_app_followup.turn_origin(turn_session)
    if not (origin and origin.get("mac")):
        return None
    devices = client.get_devices()
    listed = (devices or {}).get("devices") or [] if isinstance(devices, dict) else []
    if device_id and any(isinstance(d, dict) and d.get("id") == device_id for d in listed):
        return None
    uri = _play_uri(play_kwargs)
    mac_id = origin["device_id"]
    if uri and _device_offers(mac_id, _MAC_PLAY_SKILL):
        _begin_play_request()  # a pending play elsewhere must not land after this
        reply = car_app_followup._invoke_device_skill(mac_id, _MAC_PLAY_SKILL, {"uri": uri}, timeout=40)
        inner = reply.get("result") if isinstance(reply, dict) and reply.get("ok") else None
        logger.info("Spotify play on the Mac (%s): %s", uri, inner if isinstance(inner, dict) else reply)
        if not isinstance(inner, dict):
            error = (reply or {}).get("error") if isinstance(reply, dict) else None
            return tool_error(f"The Mac's Spotify app couldn't play it: {error or 'no answer'}")
        if inner.get("playing"):
            return tool_result({"success": True, "action": "play", "device": "his Mac",
                                "note": f"Playing {inner.get('track') or 'it'} in Spotify on the Mac."})
        return tool_result({"success": False, "action": "play",
                            "note": str(inner.get("note") or "Spotify on the Mac took it but isn't playing.")})
    mac = _pick_device(devices, computers_only=True)
    if mac is None:
        return _play_without_active_device(
            client, ticket, play_kwargs, SpotifyAPIError("Spotify isn't open on the Mac", status_code=404),
            turn_session=turn_session)
    try:
        result = client.start_playback(device_id=mac["id"], **play_kwargs)
    except SpotifyAPIError as exc:
        if exc.status_code != 404:
            raise
        return _play_without_active_device(client, ticket, play_kwargs, exc, turn_session=turn_session,
                                           failed_device=mac["id"])
    return tool_result({"success": True, "action": "play",
                        "device": {"id": mac["id"], "name": _device_label(mac), "type": mac.get("type")},
                        "result": result})


def _play_on_turn_phone(client: Any, ticket: int, play_kwargs: Dict[str, Any],
                        turn_session: Optional[str], device_id: Optional[str]) -> Optional[str]:
    """A phone turn's song is opened on the phone and made sure of there (``_open_on_phone``),
    never sent as a Web API play naming it — his iPhone's Spotify takes that (HTTP 204) and
    drops to an empty player. None leaves it to the Web API: not a phone turn, nothing to open
    (a resume), a play aimed at another device (his MacBook), or a phone that can't open it."""
    phone = car_app_followup.turn_phone(turn_session)
    uri = _play_uri(play_kwargs)
    if not (phone and uri):
        return None
    if device_id and _names_another_device(client, device_id):
        return None
    pending = _register_pending_play(ticket, play_kwargs, phones_only=True)
    if pending is None:  # a newer play request took over meanwhile
        return None
    opened = _open_on_phone(pending, client, phone, uri)
    if opened is None:
        _drop_pending_play(pending)
    return opened


def _play_without_active_device(
    client: Any,
    ticket: int,
    play_kwargs: Dict[str, Any],
    original: SpotifyAPIError,
    turn_session: Optional[str] = None,
    failed_device: Optional[str] = None,
) -> str:
    """Play found no device to play on (404 NO_ACTIVE_DEVICE, or the explicit
    device of a turn from one of his devices 404'd).

    * A listed device takes it — on a phone turn only a smartphone, on a turn
      from his Mac a computer first.
    * A phone turn otherwise asks the phone to open the song's spotify: link now
      (on CarPlay: on the car's screen; Spotify opens and plays it) and makes sure
      in the background that the phone plays exactly that.
    * Else (no open_url, nothing to open, or the web/Mac): open Spotify on the
      turn's device and wait for a Spotify device to show up.
    """
    origin = car_app_followup.turn_origin(turn_session)
    phone = car_app_followup.turn_phone(turn_session)
    from_mac = bool(origin and origin.get("mac"))
    device = _pick_device(client.get_devices(), phones_only=bool(phone),
                          computers_only=from_mac, exclude=failed_device)
    if device is not None:
        label = _device_label(device)
        try:
            result = client.start_playback(device_id=device["id"], **play_kwargs)
        except SpotifyAPIError as exc:
            if not (phone and exc.status_code == 404):
                raise
            logger.info("Spotify play: %s is listed but didn't take it (%s); opening it on the phone", label, exc)
        else:
            return tool_result({
                "success": True,
                "action": "play",
                "device": {"id": device["id"], "name": label, "type": device.get("type")},
                "note": f"No Spotify device was active, so this is playing on {label}.",
                "result": result,
            })
    pending = _register_pending_play(ticket, play_kwargs, phones_only=bool(phone), computers_only=from_mac)
    if pending is None:  # a newer play request took over meanwhile
        raise original
    uri = _play_uri(play_kwargs)
    if phone and uri:
        opened = _open_on_phone(pending, client, phone, uri)
        if opened is not None:
            return opened
    window = int(_PENDING_PLAY_WINDOW_S)
    device_id = phone["device_id"] if phone else car_app_followup.turn_device(turn_session)
    if device_id:
        # The bare app: on CarPlay the phone opens it on the car's screen once
        # Jarvis has spoken; the follow-up plays as soon as Spotify lists a device.
        opening = car_app_followup.open_then("spotify", device_id, **_pending_play_followup(pending, client))
        if opening["opened"]:
            return tool_result({
                "success": True,
                "action": "play",
                "pending": True,
                "opening": "spotify",
                "note": _opening_note(opening["device_note"], window),
            })
        # The device couldn't open it; the follow-up still waits for the model to.
    else:
        _spawn_pending_play_poller(pending, client)
    logger.info("Spotify play pending: no device online, waiting up to %d s for one", window)
    return tool_result({
        "success": True,
        "action": "play",
        "pending": True,
        "note": (
            "Spotify isn't open on any device yet. Open the Spotify app (open_app spotify): "
            f"this starts playing as soon as Spotify is up, within {window} s. "
            "Don't call play again."
        ),
    })


def _handle_spotify_playback(args: dict, **kw) -> str:
    action = str(args.get("action") or "get_state").strip().lower()
    client = _spotify_client()
    try:
        if action == "get_state":
            payload = client.get_playback_state(market=args.get("market"))
            empty_result = _describe_empty_playback(payload, action=action)
            return tool_result(empty_result or payload)
        if action == "get_currently_playing":
            payload = client.get_currently_playing(market=args.get("market"))
            empty_result = _describe_empty_playback(payload, action=action)
            return tool_result(empty_result or payload)
        if action == "play":
            offset = args.get("offset")
            if isinstance(offset, dict):
                payload_offset = {k: v for k, v in offset.items() if v is not None}
            else:
                payload_offset = None
            uris = normalize_spotify_uris(_as_list(args.get("uris")), "track") if args.get("uris") else None
            context_uri = None
            if args.get("context_uri"):
                raw_context = str(args.get("context_uri"))
                context_type = None
                if raw_context.startswith("spotify:album:") or "/album/" in raw_context:
                    context_type = "album"
                elif raw_context.startswith("spotify:playlist:") or "/playlist/" in raw_context:
                    context_type = "playlist"
                elif raw_context.startswith("spotify:artist:") or "/artist/" in raw_context:
                    context_type = "artist"
                context_uri = normalize_spotify_uri(raw_context, context_type)
            play_kwargs = {
                "context_uri": context_uri,
                "uris": uris,
                "offset": payload_offset,
                "position_ms": args.get("position_ms"),
            }
            ticket = _begin_play_request()
            turn = kw.get("task_id")
            on_phone = _play_on_turn_phone(client, ticket, play_kwargs, turn, args.get("device_id"))
            if on_phone is not None:
                return on_phone
            on_mac = _play_on_turn_mac(client, ticket, play_kwargs, turn, args.get("device_id"))
            if on_mac is not None:
                return on_mac
            try:
                result = client.start_playback(device_id=args.get("device_id"), **play_kwargs)
            except SpotifyAPIError as exc:
                # A turn from one of his devices whose explicit device 404s (his phone's
                # Spotify id asleep, or an id from an earlier turn: the car's iPhone on a
                # turn from the Mac, 2026-10-20 23:06) goes the same way as no active device.
                explicit_404 = bool(args.get("device_id")) and exc.status_code == 404
                if not exc.is_no_active_device and not (explicit_404 and car_app_followup.turn_device(turn)):
                    raise
                return _play_without_active_device(client, ticket, play_kwargs, exc, turn_session=turn,
                                                   failed_device=args.get("device_id"))
            return tool_result({"success": True, "action": action, "result": result})
        if action == "pause":
            _cancel_pending_play()  # "stop" must not let a waiting song start later
            result = client.pause_playback(device_id=args.get("device_id"))
            return tool_result({"success": True, "action": action, "result": result})
        if action == "next":
            result = client.skip_next(device_id=args.get("device_id"))
            return tool_result({"success": True, "action": action, "result": result})
        if action == "previous":
            result = client.skip_previous(device_id=args.get("device_id"))
            return tool_result({"success": True, "action": action, "result": result})
        if action == "seek":
            if args.get("position_ms") is None:
                return tool_error("position_ms is required for action='seek'")
            result = client.seek(position_ms=int(args["position_ms"]), device_id=args.get("device_id"))
            return tool_result({"success": True, "action": action, "result": result})
        if action == "set_repeat":
            state = str(args.get("state") or "").strip().lower()
            if state not in {"track", "context", "off"}:
                return tool_error("state must be one of: track, context, off")
            result = client.set_repeat(state=state, device_id=args.get("device_id"))
            return tool_result({"success": True, "action": action, "result": result})
        if action == "set_shuffle":
            result = client.set_shuffle(state=_coerce_bool(args.get("state")), device_id=args.get("device_id"))
            return tool_result({"success": True, "action": action, "result": result})
        if action == "set_volume":
            if args.get("volume_percent") is None:
                return tool_error("volume_percent is required for action='set_volume'")
            result = client.set_volume(volume_percent=max(0, min(100, int(args["volume_percent"]))), device_id=args.get("device_id"))
            return tool_result({"success": True, "action": action, "result": result})
        if action == "recently_played":
            after = args.get("after")
            before = args.get("before")
            if after and before:
                return tool_error("Provide only one of 'after' or 'before'")
            return tool_result(client.get_recently_played(
                limit=_coerce_limit(args.get("limit"), default=20),
                after=int(after) if after is not None else None,
                before=int(before) if before is not None else None,
            ))
        return tool_error(f"Unknown spotify_playback action: {action}")
    except Exception as exc:
        return _spotify_tool_error(exc)


def _handle_spotify_devices(args: dict, **kw) -> str:
    action = str(args.get("action") or "list").strip().lower()
    client = _spotify_client()
    try:
        if action == "list":
            return tool_result(client.get_devices())
        if action == "transfer":
            device_id = str(args.get("device_id") or "").strip()
            if not device_id:
                return tool_error("device_id is required for action='transfer'")
            result = client.transfer_playback(device_id=device_id, play=_coerce_bool(args.get("play")))
            return tool_result({"success": True, "action": action, "result": result})
        return tool_error(f"Unknown spotify_devices action: {action}")
    except Exception as exc:
        return _spotify_tool_error(exc)


def _handle_spotify_queue(args: dict, **kw) -> str:
    action = str(args.get("action") or "get").strip().lower()
    client = _spotify_client()
    try:
        if action == "get":
            return tool_result(client.get_queue())
        if action == "add":
            uri = normalize_spotify_uri(str(args.get("uri") or ""), None)
            result = client.add_to_queue(uri=uri, device_id=args.get("device_id"))
            return tool_result({"success": True, "action": action, "uri": uri, "result": result})
        return tool_error(f"Unknown spotify_queue action: {action}")
    except Exception as exc:
        return _spotify_tool_error(exc)


def _handle_spotify_search(args: dict, **kw) -> str:
    client = _spotify_client()
    query = str(args.get("query") or "").strip()
    if not query:
        return tool_error("query is required")
    raw_types = _as_list(args.get("types") or args.get("type") or ["track"])
    search_types = [value.lower() for value in raw_types if value.lower() in {"album", "artist", "playlist", "track", "show", "episode", "audiobook"}]
    if not search_types:
        return tool_error("types must contain one or more of: album, artist, playlist, track, show, episode, audiobook")
    try:
        return tool_result(client.search(
            query=query,
            search_types=search_types,
            limit=_coerce_limit(args.get("limit"), default=10),
            offset=max(0, int(args.get("offset") or 0)),
            market=args.get("market"),
            include_external=args.get("include_external"),
        ))
    except Exception as exc:
        return _spotify_tool_error(exc)


def _handle_spotify_playlists(args: dict, **kw) -> str:
    action = str(args.get("action") or "list").strip().lower()
    client = _spotify_client()
    try:
        if action == "list":
            return tool_result(client.get_my_playlists(
                limit=_coerce_limit(args.get("limit"), default=20),
                offset=max(0, int(args.get("offset") or 0)),
            ))
        if action == "get":
            playlist_id = normalize_spotify_id(str(args.get("playlist_id") or ""), "playlist")
            return tool_result(client.get_playlist(playlist_id=playlist_id, market=args.get("market")))
        if action == "create":
            name = str(args.get("name") or "").strip()
            if not name:
                return tool_error("name is required for action='create'")
            return tool_result(client.create_playlist(
                name=name,
                public=_coerce_bool(args.get("public")),
                collaborative=_coerce_bool(args.get("collaborative")),
                description=args.get("description"),
            ))
        if action == "add_items":
            playlist_id = normalize_spotify_id(str(args.get("playlist_id") or ""), "playlist")
            uris = normalize_spotify_uris(_as_list(args.get("uris")))
            return tool_result(client.add_playlist_items(
                playlist_id=playlist_id,
                uris=uris,
                position=args.get("position"),
            ))
        if action == "remove_items":
            playlist_id = normalize_spotify_id(str(args.get("playlist_id") or ""), "playlist")
            uris = normalize_spotify_uris(_as_list(args.get("uris")))
            return tool_result(client.remove_playlist_items(
                playlist_id=playlist_id,
                uris=uris,
                snapshot_id=args.get("snapshot_id"),
            ))
        if action == "update_details":
            playlist_id = normalize_spotify_id(str(args.get("playlist_id") or ""), "playlist")
            return tool_result(client.update_playlist_details(
                playlist_id=playlist_id,
                name=args.get("name"),
                public=args.get("public"),
                collaborative=args.get("collaborative"),
                description=args.get("description"),
            ))
        return tool_error(f"Unknown spotify_playlists action: {action}")
    except Exception as exc:
        return _spotify_tool_error(exc)


def _handle_spotify_albums(args: dict, **kw) -> str:
    action = str(args.get("action") or "get").strip().lower()
    client = _spotify_client()
    try:
        album_id = normalize_spotify_id(str(args.get("album_id") or args.get("id") or ""), "album")
        if action == "get":
            return tool_result(client.get_album(album_id=album_id, market=args.get("market")))
        if action == "tracks":
            return tool_result(client.get_album_tracks(
                album_id=album_id,
                limit=_coerce_limit(args.get("limit"), default=20),
                offset=max(0, int(args.get("offset") or 0)),
                market=args.get("market"),
            ))
        return tool_error(f"Unknown spotify_albums action: {action}")
    except Exception as exc:
        return _spotify_tool_error(exc)


def _handle_spotify_library(args: dict, **kw) -> str:
    """Unified handler for saved tracks + saved albums (formerly two tools)."""
    kind = str(args.get("kind") or "").strip().lower()
    if kind not in {"tracks", "albums"}:
        return tool_error("kind must be one of: tracks, albums")
    action = str(args.get("action") or "list").strip().lower()
    item_type = "track" if kind == "tracks" else "album"
    client = _spotify_client()
    try:
        if action == "list":
            limit = _coerce_limit(args.get("limit"), default=20)
            offset = max(0, int(args.get("offset") or 0))
            market = args.get("market")
            if kind == "tracks":
                return tool_result(client.get_saved_tracks(limit=limit, offset=offset, market=market))
            return tool_result(client.get_saved_albums(limit=limit, offset=offset, market=market))
        if action == "save":
            uris = normalize_spotify_uris(_as_list(args.get("uris") or args.get("items")), item_type)
            return tool_result(client.save_library_items(uris=uris))
        if action == "remove":
            ids = [normalize_spotify_id(item, item_type) for item in _as_list(args.get("ids") or args.get("items"))]
            if not ids:
                return tool_error("ids/items is required for action='remove'")
            if kind == "tracks":
                return tool_result(client.remove_saved_tracks(track_ids=ids))
            return tool_result(client.remove_saved_albums(album_ids=ids))
        return tool_error(f"Unknown spotify_library action: {action}")
    except Exception as exc:
        return _spotify_tool_error(exc)


COMMON_STRING = {"type": "string"}

SPOTIFY_PLAYBACK_SCHEMA = {
    "name": "spotify_playback",
    "description": "Control Spotify playback, inspect the active playback state, or fetch recently played tracks.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["get_state", "get_currently_playing", "play", "pause", "next", "previous", "seek", "set_repeat", "set_shuffle", "set_volume", "recently_played"]},
            "device_id": COMMON_STRING,
            "market": COMMON_STRING,
            "context_uri": COMMON_STRING,
            "uris": {"type": "array", "items": COMMON_STRING},
            "offset": {"type": "object"},
            "position_ms": {"type": "integer"},
            "state": {"description": "For set_repeat use track/context/off. For set_shuffle use boolean-like true/false.", "oneOf": [{"type": "string"}, {"type": "boolean"}]},
            "volume_percent": {"type": "integer"},
            "limit": {"type": "integer", "description": "For recently_played: number of tracks (max 50)"},
            "after": {"type": "integer", "description": "For recently_played: Unix ms cursor (after this timestamp)"},
            "before": {"type": "integer", "description": "For recently_played: Unix ms cursor (before this timestamp)"},
        },
        "required": ["action"],
    },
}

SPOTIFY_DEVICES_SCHEMA = {
    "name": "spotify_devices",
    "description": "List Spotify Connect devices or transfer playback to a different device.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["list", "transfer"]},
            "device_id": COMMON_STRING,
            "play": {"type": "boolean"},
        },
        "required": ["action"],
    },
}

SPOTIFY_QUEUE_SCHEMA = {
    "name": "spotify_queue",
    "description": "Inspect the user's Spotify queue or add an item to it.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["get", "add"]},
            "uri": COMMON_STRING,
            "device_id": COMMON_STRING,
        },
        "required": ["action"],
    },
}

SPOTIFY_SEARCH_SCHEMA = {
    "name": "spotify_search",
    "description": "Search the Spotify catalog for tracks, albums, artists, playlists, shows, or episodes.",
    "parameters": {
        "type": "object",
        "properties": {
            "query": COMMON_STRING,
            "types": {"type": "array", "items": COMMON_STRING},
            "type": COMMON_STRING,
            "limit": {"type": "integer"},
            "offset": {"type": "integer"},
            "market": COMMON_STRING,
            "include_external": COMMON_STRING,
        },
        "required": ["query"],
    },
}

SPOTIFY_PLAYLISTS_SCHEMA = {
    "name": "spotify_playlists",
    "description": "List, inspect, create, update, and modify Spotify playlists.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["list", "get", "create", "add_items", "remove_items", "update_details"]},
            "playlist_id": COMMON_STRING,
            "market": COMMON_STRING,
            "limit": {"type": "integer"},
            "offset": {"type": "integer"},
            "name": COMMON_STRING,
            "description": COMMON_STRING,
            "public": {"type": "boolean"},
            "collaborative": {"type": "boolean"},
            "uris": {"type": "array", "items": COMMON_STRING},
            "position": {"type": "integer"},
            "snapshot_id": COMMON_STRING,
        },
        "required": ["action"],
    },
}

SPOTIFY_ALBUMS_SCHEMA = {
    "name": "spotify_albums",
    "description": "Fetch Spotify album metadata or album tracks.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["get", "tracks"]},
            "album_id": COMMON_STRING,
            "id": COMMON_STRING,
            "market": COMMON_STRING,
            "limit": {"type": "integer"},
            "offset": {"type": "integer"},
        },
        "required": ["action"],
    },
}

SPOTIFY_LIBRARY_SCHEMA = {
    "name": "spotify_library",
    "description": "List, save, or remove the user's saved Spotify tracks or albums. Use `kind` to select which.",
    "parameters": {
        "type": "object",
        "properties": {
            "kind": {"type": "string", "enum": ["tracks", "albums"], "description": "Which library to operate on"},
            "action": {"type": "string", "enum": ["list", "save", "remove"]},
            "limit": {"type": "integer"},
            "offset": {"type": "integer"},
            "market": COMMON_STRING,
            "uris": {"type": "array", "items": COMMON_STRING},
            "ids": {"type": "array", "items": COMMON_STRING},
            "items": {"type": "array", "items": COMMON_STRING},
        },
        "required": ["kind", "action"],
    },
}
