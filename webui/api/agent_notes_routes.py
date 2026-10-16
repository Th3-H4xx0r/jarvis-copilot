"""Pure HTTP dispatcher for the Mac voice features' server side: call notes
(``/api/agent-notes``) and Flow dictation's clean-up (``/api/flow/cleanup``).

:func:`handle_agent_notes_request` takes the method, the path after
``/api/agent-notes`` (query included), the parsed JSON body and (for tests) a
store, a summary scheduler and a publisher, and returns ``(status, payload)``;
``routes.py`` writes it with ``j(handler, payload, status=status)``.

Contract (``<path>`` is what follows ``/api/agent-notes``)::

    GET    ""                     -> 200 {"notes": [row…]}   newest first, no transcript
    GET    /<id>                  -> 200 note | 404
    GET    /<id>/markdown?tz=<min> -> 200 {"markdown", "filename"} | 404
    POST   "" {note…, summarize?} -> 200 {"note"}   create or replace (a re-upload keeps
                                     the server's summary); summarize → background job
                                     | 400 bad body / id
    POST   /<id> {title?, todos?, speakers?} -> 200 {"note"} | 404
    POST   /<id>/summarize        -> 200 {"note"} (summary_status "pending") | 404 | 409 no transcript
    DELETE /<id>                  -> 200 {"ok": true} | 404

Every change publishes ``notes`` {"id"[, "deleted"]} on the device bridge.

``POST /api/flow/cleanup {text, style, app?, words?, model?, provider?}`` → 200
``{"text", "cleaned"}`` (the words as heard and ``cleaned: false`` whenever the
model fails or answers something that isn't a clean-up) · 400 bad body. ``model``
/ ``provider`` are the pick in the Mac's Flow settings (an ``/api/models`` entry);
without one, ``auxiliary.flow_cleanup`` (else auto) decides.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import logging
from typing import Callable, Optional
from urllib.parse import parse_qs, urlsplit

log = logging.getLogger(__name__)

AGENT_NOTES_PATH_PREFIX = "/api/agent-notes"
FLOW_CLEANUP_PATH = "/api/flow/cleanup"

_STORE = None


def default_store():
    global _STORE
    if _STORE is None:
        from agent.agent_notes import NotesStore
        _STORE = NotesStore()
    return _STORE


def _publish(topic: str, data: dict) -> None:
    try:
        from api.device_bridge import publish
        publish(topic, data)
    except Exception:
        log.debug("agent notes: publish failed", exc_info=True)


def _default_summarize(publish: Callable[[str, dict], None]):
    def run(store, note_id):
        from agent.agent_notes import summarize_in_background
        summarize_in_background(store, note_id, on_done=lambda i: publish("notes", {"id": i}))
    return run


def handle_agent_notes_request(method: str, sub: str, body: Optional[dict], store=None,
                               summarize: Optional[Callable] = None,
                               publish: Optional[Callable[[str, dict], None]] = None) -> tuple:
    store = store or default_store()
    publish = publish or _publish
    summarize = summarize or _default_summarize(publish)
    split = urlsplit(sub or "")
    parts = [p for p in split.path.split("/") if p]
    query = parse_qs(split.query)

    from agent import agent_notes

    if not parts:
        if method == "GET":
            return 200, {"notes": store.list()}
        if method == "POST":
            if not isinstance(body, dict):
                return 400, {"error": "a note is a JSON object"}
            fields = dict(body)
            wants_summary = bool(fields.pop("summarize", False))
            try:
                note = store.put(fields)
            except ValueError as e:
                return 400, {"error": str(e)}
            if wants_summary and note["lines"] and note["summary_status"] in ("none", "failed"):
                summarize(store, note["id"])
                note = store.get(note["id"]) or note
            publish("notes", {"id": note["id"]})
            return 200, {"note": note}
        return 405, {"error": "method not allowed"}

    note_id = parts[0]
    if not agent_notes.valid_id(note_id) or len(parts) > 2:
        return 404, {"error": "no such note"}
    action = parts[1] if len(parts) == 2 else None

    if method == "GET" and action is None:
        note = store.get(note_id)
        return (200, note) if note else (404, {"error": "no such note"})
    if method == "GET" and action == "markdown":
        note = store.get(note_id)
        if not note:
            return 404, {"error": "no such note"}
        try:
            tz = int((query.get("tz") or ["0"])[0])
        except ValueError:
            tz = 0
        tz = max(-14 * 60, min(14 * 60, tz))
        return 200, {"markdown": agent_notes.markdown(note, tz_minutes=tz), "filename": agent_notes.filename(note)}
    if method == "POST" and action is None:
        note = store.update(note_id, body if isinstance(body, dict) else {})
        if not note:
            return 404, {"error": "no such note"}
        publish("notes", {"id": note_id})
        return 200, {"note": note}
    if method == "POST" and action == "summarize":
        note = store.get(note_id)
        if not note:
            return 404, {"error": "no such note"}
        if not note["lines"]:
            return 409, {"error": "this note has no transcript to summarize"}
        summarize(store, note_id)
        publish("notes", {"id": note_id})
        return 200, {"note": store.get(note_id) or note}
    if method == "DELETE" and action is None:
        if not store.delete(note_id):
            return 404, {"error": "no such note"}
        publish("notes", {"id": note_id, "deleted": True})
        return 200, {"ok": True}
    return 405, {"error": "method not allowed"}


def _picked_model_call(model: str, provider: str = "") -> Callable[[list], str]:
    """The clean-up on the model picked in Flow settings: resolved the web UI's
    way (``@provider:model``, custom providers, Anthropic picks on the Claude
    Code CLI) and called once, with no tools — the user is waiting to paste.
    Resolution happens inside the call, so a provider that can't be reached
    fails like a model error: the words are pasted as heard."""
    def call(messages: list) -> str:
        import api.config as cfg
        from agent.auxiliary_client import call_llm, extract_content_or_reasoning
        from jarviscopilot_cli.runtime_provider import resolve_runtime_provider

        name, prov, base_url = cfg.route_anthropic_via_claude_code(
            *cfg.resolve_model_provider(cfg.model_with_provider_context(model, provider)))
        runtime = resolve_runtime_provider(requested=prov) or {}
        response = call_llm(task="flow_cleanup", provider=prov or runtime.get("provider"), model=name,
                            base_url=base_url or runtime.get("base_url"), api_key=runtime.get("api_key"),
                            messages=messages, max_tokens=1024, temperature=0.0, timeout=10.0)
        return str(extract_content_or_reasoning(response) or "")
    return call


def handle_flow_cleanup(body: Optional[dict], call: Optional[Callable[[list], str]] = None) -> tuple:
    if not isinstance(body, dict) or not isinstance(body.get("text"), str):
        return 400, {"error": "text is required"}
    from agent import flow_cleanup
    words = body.get("words") if isinstance(body.get("words"), list) else []
    app = body.get("app") if isinstance(body.get("app"), str) else None
    model = body.get("model").strip() if isinstance(body.get("model"), str) else ""
    provider = body.get("provider").strip() if isinstance(body.get("provider"), str) else ""
    if call is None:
        call = _picked_model_call(model, provider) if model else flow_cleanup.default_model_call
    text, cleaned = flow_cleanup.clean(body["text"], str(body.get("style") or "natural"), app, words, call)
    return 200, {"text": text, "cleaned": cleaned}
