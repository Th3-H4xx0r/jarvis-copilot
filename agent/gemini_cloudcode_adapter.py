"""OpenAI-compatible facade that talks to Google's Cloud Code Assist backend.

This adapter lets JarvisCopilot use the ``google-gemini-cli`` provider as if it were
a standard OpenAI-shaped chat completion endpoint, while the underlying HTTP
traffic goes to ``cloudcode-pa.googleapis.com/v1internal:{generateContent,
streamGenerateContent}`` with a Bearer access token obtained via OAuth PKCE.

Architecture
------------
- ``GeminiCloudCodeClient`` exposes ``.chat.completions.create(**kwargs)``
  mirroring the subset of the OpenAI SDK that ``run_agent.py`` uses.
- Incoming OpenAI ``messages[]`` / ``tools[]`` / ``tool_choice`` are translated
  to Gemini's native ``contents[]`` / ``tools[].functionDeclarations`` /
  ``toolConfig`` / ``systemInstruction`` shape.
- The request body is wrapped ``{project, model, user_prompt_id, request}``
  per Code Assist API expectations.
- Responses (``candidates[].content.parts[]``) are converted back to
  OpenAI ``choices[0].message`` shape with ``content`` + ``tool_calls``.
- Streaming uses SSE (``?alt=sse``) and yields OpenAI-shaped delta chunks.

Attribution
-----------
Translation semantics follow jenslys/opencode-gemini-auth (MIT) and the public
Gemini API docs. Request envelope shape
(``{project, model, user_prompt_id, request}``) is documented nowhere; it is
reverse-engineered from the opencode-gemini-auth and clawdbot implementations.
"""

from __future__ import annotations

import json
import logging
import uuid
from types import SimpleNamespace
from typing import Any, Dict, Iterator, List, Optional

import httpx

from agent import google_oauth
from agent.gemini_native_adapter import (
    _GeminiChatNamespace,
    _GeminiStreamChunk,
    _iter_sse_events,
    _make_stream_chunk,
    _map_gemini_finish_reason,
    build_gemini_request as _build_native_gemini_request,
    google_error_details,
    parse_google_error,
    translate_gemini_response,
)
from agent.google_code_assist import (
    CODE_ASSIST_ENDPOINT,
    CodeAssistError,
    ProjectContext,
    resolve_project_context,
)

logger = logging.getLogger(__name__)


# =============================================================================
# Request translation: OpenAI → Gemini (shared with the native adapter)
# =============================================================================

# Code Assist rejects function calls whose thought signature came from outside
# its own chain, so every replayed call carries this sentinel instead
# (opencode-gemini-auth's approach).
_CODE_ASSIST_THOUGHT_SIGNATURE = "skip_thought_signature_validator"


def build_gemini_request(**kwargs: Any) -> Dict[str, Any]:
    """Build the inner Gemini request body (goes inside the ``request`` wrapper).

    Takes the keyword arguments of the native adapter's ``build_gemini_request``.
    """
    body = _build_native_gemini_request(thought_signature=_CODE_ASSIST_THOUGHT_SIGNATURE, **kwargs)
    system_instruction = body.get("systemInstruction")
    if system_instruction:
        system_instruction["role"] = "system"
    return body


def wrap_code_assist_request(
    *,
    project_id: str,
    model: str,
    inner_request: Dict[str, Any],
    user_prompt_id: Optional[str] = None,
) -> Dict[str, Any]:
    """Wrap the inner Gemini request in the Code Assist envelope."""
    return {
        "project": project_id,
        "model": model,
        "user_prompt_id": user_prompt_id or str(uuid.uuid4()),
        "request": inner_request,
    }


# =============================================================================
# Response translation: Gemini → OpenAI
# =============================================================================

def _unwrap(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Code Assist wraps the Gemini response inside ``response``."""
    inner = payload.get("response")
    return inner if isinstance(inner, dict) else payload


def _translate_gemini_response(resp: Dict[str, Any], model: str) -> SimpleNamespace:
    """Non-streaming Code Assist response -> OpenAI-shaped SimpleNamespace."""
    return translate_gemini_response(_unwrap(resp), model)


def _translate_stream_event(
    event: Dict[str, Any],
    model: str,
    tool_call_counter: List[int],
) -> List[_GeminiStreamChunk]:
    """Unwrap Code Assist envelope and emit OpenAI-shaped chunk(s).

    ``tool_call_counter`` is a single-element list used as a mutable counter
    across events in the same stream. Each ``functionCall`` part gets a
    fresh, unique OpenAI ``index`` — keying by function name would collide
    whenever the model issues parallel calls to the same tool (e.g. reading
    three files in one turn).
    """
    inner = _unwrap(event)
    candidates = inner.get("candidates") or []
    if not candidates:
        return []
    cand = candidates[0]
    if not isinstance(cand, dict):
        return []

    chunks: List[_GeminiStreamChunk] = []

    content = cand.get("content") or {}
    parts = content.get("parts") if isinstance(content, dict) else []
    for part in parts or []:
        if not isinstance(part, dict):
            continue
        if part.get("thought") is True and isinstance(part.get("text"), str):
            chunks.append(_make_stream_chunk(
                model=model, reasoning=part["text"],
            ))
            continue
        if isinstance(part.get("text"), str) and part["text"]:
            chunks.append(_make_stream_chunk(model=model, content=part["text"]))
        fc = part.get("functionCall")
        if isinstance(fc, dict) and fc.get("name"):
            name = str(fc["name"])
            idx = tool_call_counter[0]
            tool_call_counter[0] += 1
            try:
                args_str = json.dumps(fc.get("args") or {}, ensure_ascii=False)
            except (TypeError, ValueError):
                args_str = "{}"
            chunks.append(_make_stream_chunk(
                model=model,
                tool_call_delta={
                    "index": idx,
                    "name": name,
                    "arguments": args_str,
                },
            ))

    finish_reason_raw = str(cand.get("finishReason") or "")
    if finish_reason_raw:
        mapped = _map_gemini_finish_reason(finish_reason_raw)
        if tool_call_counter[0] > 0:
            mapped = "tool_calls"
        chunks.append(_make_stream_chunk(model=model, finish_reason=mapped))
    return chunks


# =============================================================================
# GeminiCloudCodeClient — OpenAI-compatible facade
# =============================================================================

MARKER_BASE_URL = "cloudcode-pa://google"


class GeminiCloudCodeClient:
    """Minimal OpenAI-SDK-compatible facade over Code Assist v1internal."""

    def __init__(
        self,
        *,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        default_headers: Optional[Dict[str, str]] = None,
        project_id: str = "",
        **_: Any,
    ):
        # `api_key` here is a dummy — real auth is the OAuth access token
        # fetched on every call via agent.google_oauth.get_valid_access_token().
        # We accept the kwarg for openai.OpenAI interface parity.
        self.api_key = api_key or "google-oauth"
        self.base_url = base_url or MARKER_BASE_URL
        self._default_headers = dict(default_headers or {})
        self._configured_project_id = project_id
        self._project_context: Optional[ProjectContext] = None
        self.chat = _GeminiChatNamespace(self)
        self.is_closed = False
        self._http = httpx.Client(timeout=httpx.Timeout(connect=15.0, read=600.0, write=30.0, pool=30.0))

    def close(self) -> None:
        self.is_closed = True
        try:
            self._http.close()
        except Exception:
            pass

    # Implement the OpenAI SDK's context-manager-ish closure check
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    def _ensure_project_context(self, access_token: str, model: str) -> ProjectContext:
        """Lazily resolve and cache the project context for this client."""
        if self._project_context is not None:
            return self._project_context

        env_project = google_oauth.resolve_project_id_from_env()
        creds = google_oauth.load_credentials()
        stored_project = creds.project_id if creds else ""

        # Prefer what's already baked into the creds
        if stored_project:
            self._project_context = ProjectContext(
                project_id=stored_project,
                managed_project_id=creds.managed_project_id if creds else "",
                tier_id="",
                source="stored",
            )
            return self._project_context

        ctx = resolve_project_context(
            access_token,
            configured_project_id=self._configured_project_id,
            env_project_id=env_project,
            user_agent_model=model,
        )
        # Persist discovered project back to the creds file so the next
        # session doesn't re-run the discovery.
        if ctx.project_id or ctx.managed_project_id:
            google_oauth.update_project_ids(
                project_id=ctx.project_id,
                managed_project_id=ctx.managed_project_id,
            )
        self._project_context = ctx
        return ctx

    def _create_chat_completion(
        self,
        *,
        model: str = "gemini-2.5-flash",
        messages: Optional[List[Dict[str, Any]]] = None,
        stream: bool = False,
        tools: Any = None,
        tool_choice: Any = None,
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        top_p: Optional[float] = None,
        stop: Any = None,
        extra_body: Optional[Dict[str, Any]] = None,
        timeout: Any = None,
        **_: Any,
    ) -> Any:
        access_token = google_oauth.get_valid_access_token()
        ctx = self._ensure_project_context(access_token, model)

        thinking_config = None
        if isinstance(extra_body, dict):
            thinking_config = extra_body.get("thinking_config") or extra_body.get("thinkingConfig")

        inner = build_gemini_request(
            messages=messages or [],
            tools=tools,
            tool_choice=tool_choice,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
            stop=stop,
            thinking_config=thinking_config,
        )
        wrapped = wrap_code_assist_request(
            project_id=ctx.project_id,
            model=model,
            inner_request=inner,
        )

        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {access_token}",
            "User-Agent": "jarviscopilot (gemini-cli-compat)",
            "X-Goog-Api-Client": "gl-python/hermes",
            "x-activity-request-id": str(uuid.uuid4()),
        }
        headers.update(self._default_headers)

        if stream:
            return self._stream_completion(model=model, wrapped=wrapped, headers=headers)

        url = f"{CODE_ASSIST_ENDPOINT}/v1internal:generateContent"
        response = self._http.post(url, json=wrapped, headers=headers)
        if response.status_code != 200:
            raise _gemini_http_error(response)
        try:
            payload = response.json()
        except ValueError as exc:
            raise CodeAssistError(
                f"Invalid JSON from Code Assist: {exc}",
                code="code_assist_invalid_json",
            ) from exc
        return _translate_gemini_response(payload, model=model)

    def _stream_completion(
        self,
        *,
        model: str,
        wrapped: Dict[str, Any],
        headers: Dict[str, str],
    ) -> Iterator[_GeminiStreamChunk]:
        """Generator that yields OpenAI-shaped streaming chunks."""
        url = f"{CODE_ASSIST_ENDPOINT}/v1internal:streamGenerateContent?alt=sse"
        stream_headers = dict(headers)
        stream_headers["Accept"] = "text/event-stream"

        def _generator() -> Iterator[_GeminiStreamChunk]:
            try:
                with self._http.stream("POST", url, json=wrapped, headers=stream_headers) as response:
                    if response.status_code != 200:
                        # Materialize error body for better diagnostics
                        response.read()
                        raise _gemini_http_error(response)
                    tool_call_counter: List[int] = [0]
                    for event in _iter_sse_events(response):
                        for chunk in _translate_stream_event(event, model, tool_call_counter):
                            yield chunk
            except httpx.HTTPError as exc:
                raise CodeAssistError(
                    f"Streaming request failed: {exc}",
                    code="code_assist_stream_error",
                ) from exc

        return _generator()


def _gemini_http_error(response: httpx.Response) -> CodeAssistError:
    """Translate an httpx response into a CodeAssistError with rich metadata.

    ``status_code`` enables the error classifier's rate_limit / auth paths,
    and ``response`` lets the main loop honor ``Retry-After`` just like it
    does for OpenAI SDK exceptions.  A few recognizable Google conditions are
    lifted into human-readable messages instead of a 500-char JSON dump:

        MODEL_CAPACITY_EXHAUSTED → "Gemini capacity exhausted for <model>..."
        RESOURCE_EXHAUSTED w/o reason → quota-style message
        404 → "Code Assist 404: <model> is not available..."
    """
    status = response.status_code
    err = parse_google_error(response)
    error_reason = err["reason"]
    err_status = err["status"]
    err_message = err["message"]
    retry_delay_seconds = err["retry_after"]

    # ``code_assist_rate_limited`` stays the default for 429s; the more
    # specific capacity tag doesn't change the rate_limit classification.
    code = f"code_assist_http_{status}"
    if status == 401:
        code = "code_assist_unauthorized"
    elif status == 429:
        code = "code_assist_rate_limited"
        if error_reason == "MODEL_CAPACITY_EXHAUSTED":
            code = "code_assist_capacity_exhausted"

    metadata = err["metadata"]
    model_hint = str(metadata.get("model") or metadata.get("modelId") or "").strip()

    if status == 429 and error_reason == "MODEL_CAPACITY_EXHAUSTED":
        target = model_hint or "this Gemini model"
        message = (
            f"Gemini capacity exhausted for {target} (Google-side throttle, "
            f"not a JarvisCopilot issue). Try a different Gemini model or set a "
            f"fallback_providers entry to a non-Gemini provider."
        )
        if retry_delay_seconds is not None:
            message += f" Google suggests retrying in {retry_delay_seconds:g}s."
    elif status == 429 and err_status == "RESOURCE_EXHAUSTED":
        message = (
            f"Gemini quota exhausted ({err_message or 'RESOURCE_EXHAUSTED'}). "
            f"Check /gquota for remaining daily requests."
        )
        if retry_delay_seconds is not None:
            message += f" Retry suggested in {retry_delay_seconds:g}s."
    elif status == 404:
        # Google returns 404 when a model has been retired or renamed.
        target = model_hint or (err_message or "model")
        message = (
            f"Code Assist 404: {target} is not available at "
            f"cloudcode-pa.googleapis.com. It may have been renamed or "
            f"retired. Check jarviscopilot_cli/models.py for the current list."
        )
    elif err_message:
        message = f"Code Assist HTTP {status} ({err_status or 'error'}): {err_message}"
    else:
        message = f"Code Assist returned HTTP {status}: {err['body_text'][:500]}"

    return CodeAssistError(
        message,
        code=code,
        status_code=status,
        response=response,
        retry_after=retry_delay_seconds,
        details=google_error_details(err),
    )
