"""Outbound delivery for Live Jarvis — one decision, then a form per device.

Ingress has been device-agnostic since day one: a client declares what it can
do and the server assigns it a lane. Egress was not. A watcher published an
`insight` frame and whoever was subscribed got the same JSON in the same shape,
which is fine while the only device is a phone with a screen and a voice, and
wrong the moment something else joins — glasses with one line of text, a pod
with a speaker and no display, a watch that can buzz.

So a watcher no longer emits a frame. It emits a DELIVERY INTENT — what
happened, how much it matters, which part of the transcript it is about — and
the form is chosen per device from what that device said it can present
(design §13). Adding a device type is a capability block, not a code path.

Two halves, deliberately split:

* `deliver()` decides WHAT to say, once, on the publishing side. It also
  persists (the bus records every insight) so a device that was asleep can
  still fetch it later — §13.4: delivery is not the only copy.
* `render()` decides HOW this one device shows it, on that device's own
  fan-out thread. It is pure, so a new form is a test, not a deployment risk,
  and a device that wants synthesised audio pays for its own synthesis without
  holding up anyone else's frame.

Rules that keep it honest (§13.4): never send a form a device did not declare;
truncation is visible, never a silent drop; a device that cannot be reached is
logged and skipped, because delivery failure is not capture failure.
"""
from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

URGENCY_NORMAL = "normal"
URGENCY_URGENT = "urgent"

# What a watcher's note is worth interrupting for. A verdict the user tapped a
# button for is being waited on; a rolling monitor note is not.
_URGENCY_BY_KIND = {
    "fact_check": URGENCY_URGENT,
    "factcheck": URGENCY_URGENT,
}

# Kinds that must never be spoken however `reply_mode` is set. A translation is
# a line of UI attached to an utterance — reading it aloud talks over the
# conversation it is translating.
_NEVER_SPOKEN = frozenset(("translation", "transcript"))

# The only container the server can synthesise today (api.voice returns base64
# mp3). A device that cannot decode it gets the text to speak itself rather
# than bytes it would drop.
SERVER_AUDIO_MIME = "audio/mpeg"
SERVER_AUDIO_CODEC = "mp3"

# Long enough that a phone or a web page is never trimmed, short enough that a
# runaway note cannot be pushed at a one-line display. Only applied when a
# device names its own smaller limit.
_ELLIPSIS = "…"


def deliver(live_session_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    """Publish one delivery intent for a live session.

    Takes the watcher's payload as-is so the watchers never learn about
    devices: `kind` and `text` are the intent, everything else rides along for
    clients that understand it. Returns the intent that was published.

    It goes onto the bus as an `insight`, which is what records it and what
    every existing client already reads — the per-device forms are derived from
    it at the other end of the fan-out, not here.
    """
    intent = dict(payload or {})
    intent.setdefault("live_session_id", live_session_id)
    kind = str(intent.get("kind") or "monitor")
    intent.setdefault("urgency", _URGENCY_BY_KIND.get(kind, URGENCY_NORMAL))
    if kind in _NEVER_SPOKEN:
        intent.setdefault("speak", False)
    try:
        from api.live_ws import LIVE_EVENTS
    except Exception:
        logger.debug("live: event bus unavailable; nothing delivered",
                     exc_info=True)
        return intent
    try:
        LIVE_EVENTS.publish(live_session_id, "insight", intent)
    except Exception:
        logger.exception("live: delivering a %s for %s failed", kind,
                         live_session_id[:8] or "?")
    return intent


def device_out(caps: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """What this device can present, from its `hello.caps`.

    Two shapes, on purpose:

    * a device that sends an `out` block gets exactly what it declared — "join
      by declaring less, no server change" (§13.1), and a form it did not claim
      is never sent to it;
    * a device with NO `out` block is one that predates the block. It is not
      silenced — that would have cut off the phone the day this landed — it
      gets the legacy behaviour: text, and speech if it set `caps.speak`.
    """
    caps = caps if isinstance(caps, dict) else {}
    block = caps.get("out")
    if not isinstance(block, dict):
        return {"text": True, "speak": bool(caps.get("speak")),
                "haptic": False, "max_chars": 0, "locale": "",
                "audio": [], "legacy": True}
    return {
        "text": bool(block.get("text")),
        "speak": bool(block.get("speak")),
        "haptic": bool(block.get("haptic")),
        "max_chars": _positive_int(block.get("max_chars")),
        "locale": str(block.get("locale") or "").strip(),
        "audio": _codec_list(block.get("audio")),
        "legacy": False,
    }


def render(intent: Dict[str, Any], out: Dict[str, Any], *,
           reply_mode: str = "text",
           say_speech_missing: bool = False) -> List[Dict[str, Any]]:
    """The frames THIS device should receive for one intent.

    Pure, and returns a list rather than sending: the caller owns the socket,
    the failure handling and the "was it delivered" question. An empty list is
    a correct answer — a device that declared no output receives nothing.

    Each frame carries its own `t`, because choosing the form IS this
    function's job: the caller must not have to infer "this one is speech"
    from the fields that happen to be on it.
    """
    text = str(intent.get("text") or "").strip()
    if not text:
        return []
    frames: List[Dict[str, Any]] = []
    wants_speech = _wants_speech(intent, reply_mode)
    can_speak = bool(out.get("speak"))

    if out.get("text"):
        frame = dict(intent, t="insight")
        fitted, truncated = fit(text, out.get("max_chars"))
        frame["text"] = fitted
        if truncated:
            # Visible, never silent (§13.4): the device knows there is more and
            # can say where to read it.
            frame["truncated"] = True
            frame["full_chars"] = len(text)
        if out.get("haptic") and intent.get("urgency") == URGENCY_URGENT:
            frame["haptic"] = True
        if wants_speech and not can_speak and say_speech_missing:
            # "Spoken replies, on a device that cannot speak" is a setting that
            # silently did nothing. It falls back to text and says so once.
            frame["spoken_unavailable"] = True
        frames.append(frame)

    if wants_speech and can_speak:
        # The full text, not the fitted one: a speaker has no line length, and
        # trimming what it says to fit a display nobody is reading would be a
        # silent drop of the interesting half.
        speech: Dict[str, Any] = {"t": "speak", "text": text,
                                  "kind": str(intent.get("kind") or "monitor"),
                                  "live_session_id": intent.get("live_session_id")}
        if intent.get("seq") is not None:
            speech["seq"] = intent.get("seq")
        speech.update(_server_audio(text, out))
        frames.append(speech)
    return frames


def fit(text: str, limit: Any) -> tuple:
    """Trim to `limit` characters at a word boundary. Returns (text, trimmed?).

    A limit of 0 (or none) is "no limit", which is what a phone and a browser
    declare. Cutting mid-word reads like a bug on a one-line display, so this
    backs up to the last space when there is one worth backing up to.
    """
    limit = _positive_int(limit)
    if not limit or len(text) <= limit:
        return text, False
    if limit <= len(_ELLIPSIS):
        return _ELLIPSIS[:limit], True
    body = text[:limit - len(_ELLIPSIS)]
    cut = body.rsplit(" ", 1)
    # Only honour a word boundary in the last quarter; a claim whose first word
    # is longer than the display would otherwise come out as one ellipsis.
    if len(cut) == 2 and len(cut[0]) >= (limit * 3) // 4:
        body = cut[0]
    return body.rstrip() + _ELLIPSIS, True


def _wants_speech(intent: Dict[str, Any], reply_mode: str) -> bool:
    """`speak` on the intent wins; otherwise the user's own setting decides."""
    explicit = intent.get("speak")
    if isinstance(explicit, bool):
        return explicit
    return str(reply_mode or "").strip().lower() == "spoken"


def _server_audio(text: str, out: Dict[str, Any]) -> Dict[str, Any]:
    """Synthesised bytes, but only for a device that asked for bytes.

    A phone and the web speak the text themselves, so the default is to send
    none: synthesising for them would cost a round trip and a megabyte to
    replace something they already do better. A device with no synthesiser
    names the codecs it can play, and gets audio only if the server can make
    one of them — never audio it would have to drop (§13.2).
    """
    codecs = out.get("audio") or []
    if not codecs:
        return {}
    if SERVER_AUDIO_CODEC not in codecs:
        logger.info("live: device accepts %s, the server can only make %s; "
                    "sending text to speak instead", codecs, SERVER_AUDIO_CODEC)
        return {}
    try:
        from api.voice import _tts_to_base64
        audio = _tts_to_base64(text)
    except Exception:
        logger.warning("live: speech synthesis failed; sending text to speak",
                       exc_info=True)
        return {}
    if not audio:
        # Not an error: a provider out of credit, or no TTS configured. The
        # device still hears the note if it can speak text itself.
        logger.info("live: no audio came back; sending text to speak")
        return {}
    return {"audio_b64": audio, "mime": SERVER_AUDIO_MIME}


def _positive_int(raw: Any) -> int:
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return 0
    return value if value > 0 else 0


def _codec_list(raw: Any) -> List[str]:
    """`"mp3"`, `["mp3", "opus"]` or nothing — clients are written by hand."""
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, (list, tuple)):
        return []
    return [str(item).strip().lower() for item in raw if str(item).strip()]
