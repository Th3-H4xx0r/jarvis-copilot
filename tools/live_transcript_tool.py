"""Interrogating conversations Jarvis overheard, without reading them.

An ambient transcript is enormous and mostly uninteresting, so this tool never
hands one to the model. It is deliberately coarse-then-fine: rolling-window
digests are searched first to find *which* stretch of talk matters, and only then
are the exact utterances pulled from that stretch. That is what makes a
months-long archive answerable inside a normal context window — searching raw
utterances first would return a thousand equally plausible lines from a year of
speech.

Everything is read-only. Renaming a voice, deleting a recording and stopping a
capture are the user's calls, made in the UI, not the agent's.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from tools.registry import registry

_DEFAULT_LIMIT = 20
_MAX_LIMIT = 100
_TEXT_CHARS = 400

_SCHEMA = {
    "name": "live_transcript",
    "description": (
        "Search conversations recorded in Live mode. Use search_digests first — "
        "it finds which stretch of talk is relevant across the whole archive — "
        "then search_segments or range for the exact words said. Also lists "
        "recorded sessions and the voices heard in them."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["search_digests", "search_segments", "range",
                         "speakers", "sessions"],
                "description": (
                    "search_digests: coarse — window summaries matching a query. "
                    "search_segments: fine — exact utterances matching a query. "
                    "range: every utterance between two timestamps of one "
                    "recording. speakers: the voices on record. sessions: the "
                    "recordings themselves."
                ),
            },
            "query": {
                "type": "string",
                "description": "Words to look for. Required by both search actions.",
            },
            "live_session_id": {
                "type": "string",
                "description": (
                    "Restrict to one recording. Required by range; optional "
                    "elsewhere."
                ),
            },
            "ts_from_ms": {
                "type": "integer",
                "description": "range: start offset in milliseconds from the recording's start.",
            },
            "ts_to_ms": {
                "type": "integer",
                "description": "range: end offset in milliseconds from the recording's start.",
            },
            "speaker_id": {
                "type": "string",
                "description": "speakers: return sample utterances for this one voice.",
            },
            "limit": {
                "type": "integer",
                "description": f"Maximum rows to return (default {_DEFAULT_LIMIT}).",
            },
        },
        "required": ["action"],
    },
}


def _live_store():
    """The webui's live transcript store.

    The store lives in the webui package because that is where the recorder and
    its STATE_DIR live; this tool runs in the agent, which may or may not have
    been started from that directory. Mirrors tools/form_tools.py.
    """
    try:
        from api import live_store
        return live_store
    except Exception:
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "webui"))
        from api import live_store
        return live_store


def _fail(message: str) -> str:
    return json.dumps({"ok": False, "error": message}, ensure_ascii=False)


def _limit(args: dict) -> int:
    try:
        value = int(args.get("limit") or _DEFAULT_LIMIT)
    except (TypeError, ValueError):
        return _DEFAULT_LIMIT
    return max(1, min(_MAX_LIMIT, value))


def _json_list(value: Any) -> list:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except (ValueError, TypeError):
            return []
    if isinstance(value, (list, tuple)):
        return [str(v) for v in value if str(v or "").strip()]
    return []


def _clip(text: Any) -> str:
    body = str(text or "").strip()
    return body if len(body) <= _TEXT_CHARS else body[:_TEXT_CHARS] + "…"


def _digest_row(row: dict) -> dict:
    return {
        "digest_id": row.get("id"),
        "live_session_id": row.get("live_session_id"),
        "scope": row.get("scope") or "window",
        "seq_from": row.get("seq_from"),
        "seq_to": row.get("seq_to"),
        "ts_start_ms": row.get("ts_start_ms"),
        "ts_end_ms": row.get("ts_end_ms"),
        "summary": _clip(row.get("summary")),
        "topics": _json_list(row.get("topics")),
        "actions": _json_list(row.get("actions")),
    }


def _segment_row(row: dict, names: dict) -> dict:
    speaker_id = str(row.get("speaker_id") or "")
    out = {
        "live_session_id": row.get("live_session_id"),
        "seq": row.get("seq"),
        "ts_start_ms": row.get("ts_start_ms"),
        "speaker": (names.get(speaker_id) or "")
                   or str(row.get("local_label") or "")
                   or "Unknown",
        "label_state": row.get("label_state"),
        "text": _clip(row.get("text")),
    }
    if speaker_id:
        out["speaker_id"] = speaker_id
    translation = str(row.get("translation") or "").strip()
    if translation:
        out["translation"] = _clip(translation)
    if row.get("lang"):
        out["lang"] = row.get("lang")
    return out


def _speaker_names(store) -> dict:
    try:
        return {str(s["id"]): str(s.get("name") or "")
                for s in store.list_speakers()}
    except Exception:
        return {}


def live_transcript(args: dict) -> str:
    action = str((args or {}).get("action") or "").strip()
    if not action:
        return _fail("action is required")
    try:
        store = _live_store()
    except Exception as exc:
        return _fail(f"the live transcript store is unavailable: {exc}")

    limit = _limit(args or {})
    session_id = str((args or {}).get("live_session_id") or "").strip()
    query = str((args or {}).get("query") or "").strip()

    try:
        if action == "search_digests":
            if not query:
                return _fail("query is required for search_digests")
            rows = store.search_digests(query, limit=limit)
            if session_id:
                rows = [r for r in rows
                        if str(r.get("live_session_id")) == session_id]
            return json.dumps({
                "ok": True,
                "action": action,
                "count": len(rows),
                "digests": [_digest_row(r) for r in rows],
                "next": ("Pull the exact words from a promising window with "
                         "action='range' on its live_session_id and "
                         "ts_start_ms/ts_end_ms."),
            }, ensure_ascii=False)

        if action == "search_segments":
            if not query:
                return _fail("query is required for search_segments")
            rows = store.search_segments(query, limit=limit,
                                         live_session_id=session_id)
            names = _speaker_names(store)
            return json.dumps({
                "ok": True,
                "action": action,
                "count": len(rows),
                "segments": [_segment_row(r, names) for r in rows],
            }, ensure_ascii=False)

        if action == "range":
            if not session_id:
                return _fail("live_session_id is required for range")
            try:
                ts_from = int((args or {}).get("ts_from_ms") or 0)
                ts_to = int((args or {}).get("ts_to_ms") or 0)
            except (TypeError, ValueError):
                return _fail("ts_from_ms and ts_to_ms must be milliseconds")
            if ts_to <= 0:
                return _fail("ts_to_ms is required for range")
            rows = store.segment_range(session_id, ts_from, ts_to, limit=limit)
            names = _speaker_names(store)
            return json.dumps({
                "ok": True,
                "action": action,
                "live_session_id": session_id,
                "count": len(rows),
                "segments": [_segment_row(r, names) for r in rows],
            }, ensure_ascii=False)

        if action == "speakers":
            one = str((args or {}).get("speaker_id") or "").strip()
            if one:
                speaker = store.get_speaker(one)
                if speaker is None:
                    return _fail(f"no speaker {one}")
                return json.dumps({
                    "ok": True,
                    "action": action,
                    "speaker": {
                        "speaker_id": speaker.get("id"),
                        "name": speaker.get("name"),
                        "kind": speaker.get("kind"),
                        "segment_count": speaker.get("segment_count"),
                        "speech_ms": speaker.get("speech_ms"),
                    },
                    "samples": [{"live_session_id": s.get("live_session_id"),
                                 "seq": s.get("seq"),
                                 "ts_start_ms": s.get("ts_start_ms"),
                                 "text": _clip(s.get("text"))}
                                for s in store.speaker_samples(one, limit=limit)],
                }, ensure_ascii=False)
            rows = store.list_speakers()[:limit]
            return json.dumps({
                "ok": True,
                "action": action,
                "count": len(rows),
                "speakers": [{"speaker_id": r.get("id"),
                              "name": r.get("name"),
                              "kind": r.get("kind"),
                              "segment_count": r.get("segment_count"),
                              "speech_ms": r.get("speech_ms")} for r in rows],
            }, ensure_ascii=False)

        if action == "sessions":
            rows = store.list_sessions(limit=limit)
            return json.dumps({
                "ok": True,
                "action": action,
                "count": len(rows),
                "sessions": [{"live_session_id": r.get("id"),
                              "title": r.get("title"),
                              "started_at": r.get("started_at"),
                              "ended_at": r.get("ended_at"),
                              "state": r.get("state"),
                              "source_label": r.get("source_label"),
                              "device_id": r.get("device_id"),
                              "chat_session_id": r.get("chat_session_id"),
                              "segments": r.get("last_seq")} for r in rows],
            }, ensure_ascii=False)
    except Exception as exc:
        return _fail(str(exc))

    return _fail(f"unknown action {action!r}")


registry.register(
    name="live_transcript",
    toolset="live",
    schema=_SCHEMA,
    handler=lambda args, **_kw: live_transcript(args or {}),
    emoji="🎙️",
)
