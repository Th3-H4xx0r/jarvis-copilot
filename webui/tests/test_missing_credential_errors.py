"""Missing-credential errors reach the user in chat and voice — no fallback hides them.

"No Anthropic API key configured" / "No Claude account connected" need the user to
set something up. The WebUI shows the message itself (not a generic "auth failed"),
voice speaks it, and the voice fast lane never reruns the turn in its place.
"""

from __future__ import annotations

import queue
import sys
import types
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from agent.error_classifier import MISSING_ANTHROPIC_API_KEY, NO_CLAUDE_ACCOUNT  # noqa: E402
from api import streaming, voice  # noqa: E402

MISSING_KEY_MSG = f"{MISSING_ANTHROPIC_API_KEY}. Add ANTHROPIC_API_KEY in Settings."
NO_ACCOUNT_MSG = f"{NO_CLAUDE_ACCOUNT}. Sign in with `claude /login` on the server."


# ── _classify_provider_error ────────────────────────────────────────────────


@pytest.mark.parametrize("msg", [MISSING_KEY_MSG, NO_ACCOUNT_MSG])
def test_classifier_returns_missing_credential_with_the_message(msg):
    c = streaming._classify_provider_error(msg, RuntimeError(msg))
    assert c["type"] == "missing_credential"
    assert c["message"] == msg
    # The message is the user-facing text — no generic auth wording on top.
    assert "auth" not in (c["label"] + c["hint"]).lower()


def test_classifier_checks_missing_credential_before_auth_and_rate_limit():
    # Wording that would otherwise trip the auth / rate-limit heuristics.
    msg = f"{NO_CLAUDE_ACCOUNT} (401 unauthorized, rate limit)"
    assert streaming._classify_provider_error(msg)["type"] == "missing_credential"


def test_classifier_leaves_other_auth_errors_alone():
    assert streaming._classify_provider_error("401 invalid x-api-key")["type"] == "auth_mismatch"


# ── voice ───────────────────────────────────────────────────────────────────


def test_fast_lane_never_reruns_a_missing_credential_turn():
    assert "missing_credential" not in voice._FAST_LANE_FALLBACK_CLASSES
    # Transient / provider failures still fall back to the fast lane.
    for cls in ("quota_exhausted", "rate_limit", "model_not_found", "error"):
        assert cls in voice._FAST_LANE_FALLBACK_CLASSES


@pytest.mark.parametrize(
    "seg",
    [
        {"kind": "error", "etype": "missing_credential", "label": "", "text": MISSING_KEY_MSG},
        # A generic apperror type is re-classified from the text.
        {"kind": "error", "etype": "apperror", "label": "", "text": MISSING_KEY_MSG},
    ],
)
def test_failure_class_is_missing_credential(seg):
    assert voice._failure_class(seg) == "missing_credential"


@pytest.mark.parametrize(
    "msg, phrase",
    [(MISSING_KEY_MSG, MISSING_ANTHROPIC_API_KEY), (NO_ACCOUNT_MSG, NO_CLAUDE_ACCOUNT)],
)
def test_spoken_failure_says_the_message(msg, phrase):
    spoken = voice._spoken_failure(
        {"kind": "error", "etype": "missing_credential", "label": "", "text": msg}
    )
    assert phrase in spoken
    assert "credentials aren't working" not in spoken
    assert "returned an error" not in spoken


# ── streaming agent build ───────────────────────────────────────────────────


class _FakeSession:
    def __init__(self, workspace):
        self.session_id = "missing-cred-session"
        self.title = "t"
        self.workspace = str(workspace)
        self.model = "claude-sonnet-5-5"
        self.model_provider = None
        self.profile = None
        self.personality = None
        self.messages = []
        self.context_messages = []
        self.tool_calls = []
        self.input_tokens = 0
        self.output_tokens = 0
        self.estimated_cost = None
        self.context_length = 0
        self.threshold_tokens = 0
        self.last_prompt_tokens = 0
        self.active_stream_id = None
        self.pending_user_message = None
        self.pending_attachments = []
        self.pending_started_at = None
        self.llm_title_generated = True

    def save(self, *args, **kwargs):
        return None

    def compact(self):
        return {"session_id": self.session_id, "title": self.title, "model": self.model}


def _drain(q):
    events = []
    while True:
        try:
            events.append(q.get_nowait())
        except queue.Empty:
            return events


def test_agent_build_surfaces_missing_credential_instead_of_running_keyless(tmp_path, monkeypatch):
    from api import config as cfg
    from api import oauth
    from jarviscopilot_cli.auth import AuthError

    built = []

    class _Agent:
        def __init__(self, **kwargs):
            built.append(kwargs)

        def run_conversation(self, **kwargs):  # pragma: no cover - must not run
            raise AssertionError("agent must not run without its credential")

        def interrupt(self, _message):
            return None

    def _raise_missing(_resolver, requested=None):
        raise AuthError(MISSING_KEY_MSG, provider="anthropic-api")

    session = _FakeSession(tmp_path)
    fake_state = types.ModuleType("jarviscopilot_state")
    fake_state.SessionDB = lambda: None

    monkeypatch.setattr(streaming, "get_session", lambda _sid: session)
    monkeypatch.setattr(streaming, "_get_ai_agent", lambda: _Agent)
    monkeypatch.setattr(
        streaming,
        "resolve_model_provider",
        lambda _model: ("claude-sonnet-5-5", "anthropic-api", None),
    )
    monkeypatch.setattr(streaming, "_maybe_schedule_title_refresh", lambda *a, **k: None)
    monkeypatch.setattr(oauth, "resolve_runtime_provider_with_anthropic_env_lock", _raise_missing)
    monkeypatch.setattr("api.config.get_config", lambda: {})
    monkeypatch.setattr("api.config._resolve_cli_toolsets", lambda _cfg: [])
    monkeypatch.setattr("api.config.load_settings", lambda: {})
    monkeypatch.setitem(sys.modules, "jarviscopilot_state", fake_state)

    with cfg.SESSION_AGENT_CACHE_LOCK:
        cfg.SESSION_AGENT_CACHE.clear()
    stream_id = "missing-cred-stream"
    session.active_stream_id = stream_id
    events_q = queue.Queue()
    streaming.STREAMS[stream_id] = events_q
    try:
        streaming._run_agent_streaming(
            session_id=session.session_id,
            msg_text="hello",
            model="claude-sonnet-5-5",
            model_provider="anthropic-api",
            workspace=str(tmp_path),
            stream_id=stream_id,
        )
        events = _drain(events_q)
    finally:
        streaming.STREAMS.pop(stream_id, None)

    assert built == [], "no agent may be built without its credential"
    errors = [data for name, data in events if name == "apperror"]
    assert errors, f"expected an apperror event, got {[name for name, _ in events]}"
    assert errors[-1]["type"] == "missing_credential"
    assert MISSING_ANTHROPIC_API_KEY in errors[-1]["message"]


def test_claude_login_check_runs_before_the_shared_env_lock(monkeypatch):
    """`claude auth status` can take up to 2 s — never while every chat waits on _ENV_LOCK."""
    import jarviscopilot_cli.auth as auth_mod
    from api.oauth import resolve_runtime_provider_with_anthropic_env_lock

    order = []
    monkeypatch.setattr(auth_mod, "claude_code_login_state",
                        lambda force=False: order.append("probe") or {"connected": True})

    def _resolver(**kwargs):
        order.append("resolve")
        return {"provider": kwargs.get("requested")}

    resolve_runtime_provider_with_anthropic_env_lock(_resolver, requested="claude-code")
    resolve_runtime_provider_with_anthropic_env_lock(_resolver, requested="anthropic-api")

    assert order == ["probe", "resolve", "resolve"]


def test_quality_voice_turn_speaks_a_missing_credential_error(monkeypatch):
    """iOS push-to-talk (/api/voice/quality-turn) used to drop error segments and just say nothing."""
    import io
    import json as _json

    from agent.error_classifier import MISSING_ANTHROPIC_API_KEY
    import api.voice as voice

    spoken = []
    monkeypatch.setattr(voice, "_tts_to_base64", lambda text: spoken.append(text) or "AUDIO")
    monkeypatch.setattr(
        voice, "_run_agent_turn_via_chat",
        lambda *a, **k: iter([{"kind": "error", "etype": "missing_credential", "label": "",
                               "text": f"{MISSING_ANTHROPIC_API_KEY}. Add ANTHROPIC_API_KEY in Settings."}]),
    )

    class _Handler:
        def __init__(self):
            self.wfile = io.BytesIO()
            self.headers = {}
            self.client_address = ("127.0.0.1", 0)

        def send_response(self, *_):
            pass

        def send_header(self, *_):
            pass

        def end_headers(self):
            pass

    h = _Handler()
    voice._voice_quality_turn(h, {"text": "hello", "session_id": "s1"})
    events = [_json.loads(line) for line in h.wfile.getvalue().decode().splitlines() if line.strip()]

    segments = [e for e in events if e.get("type") == "segment"]
    assert segments and "No Anthropic API key configured" in " ".join(s["text"] for s in segments)
    assert spoken, "the error must be synthesized so the phone actually says it"
    assert events[-1]["type"] == "done"
