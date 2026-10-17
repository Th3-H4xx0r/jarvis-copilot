import tools.coding_session_tool  # noqa: F401  (registers tools on import)
from tools.registry import registry
import toolsets


def _registered_names():
    return set(getattr(registry, "_tools", {}).keys())


def test_tools_registered():
    names = {"coding_session_launch", "coding_session_list", "coding_session_status",
             "coding_session_message", "coding_session_stop",
             "coding_project_create", "coding_project_list"}
    assert names <= _registered_names()


def test_toolset_is_a_toolsets_key():
    # the gotcha: a tool whose toolset isn't a TOOLSETS key is dropped by
    # _get_platform_tools (see jarviscopilot_cli/tools_config.py).
    assert "coding_sessions" in toolsets.TOOLSETS


def test_tool_names_in_core():
    core = toolsets._HERMES_CORE_TOOLS
    for n in ("coding_session_launch", "coding_session_message", "coding_session_stop"):
        assert n in core


def test_launch_handler_errors_cleanly_without_cwd():
    import json
    from tools.coding_session_tool import _h_launch
    out = json.loads(_h_launch({}))
    assert "error" in out


def test_launch_requires_some_cwd():
    # relative/~/new paths are now ACCEPTED (manager resolves+creates them);
    # only a completely missing cwd is an error. (Don't pass a real cwd here —
    # that would attempt a real launch.)
    import json
    from tools.coding_session_tool import _h_launch
    out = json.loads(_h_launch({"cwd": ""}))
    assert "error" in out


def test_launch_rejects_injection_model(tmp_path):
    import json
    from tools.coding_session_tool import _h_launch
    out = json.loads(_h_launch({"cwd": str(tmp_path), "model": "opus; rm -rf ~"}))
    assert "error" in out and "invalid model" in out["error"]


class _FakeHandoff:
    def __init__(self):
        self.sent = []

    def send(self, ckey, text):
        self.sent.append((ckey, text))
        return {"id": "d1", "state": "sent", "reason": None}


class _FakeConv:
    def get(self, ckey):
        return {"ckey": ckey, "status": "live"} if ckey == "claude|s1" else None


class _FakeCore:
    def __init__(self):
        self.launched, self.stopped = [], []
        self.handoff, self.conv = _FakeHandoff(), _FakeConv()

    def launch(self, body):
        self.launched.append(body)
        return {"ok": True}

    def stop(self, ckey):
        self.stopped.append(ckey)
        return {"ok": True}

    def list_payload(self):
        return {"card": None, "needs_you": [{"ckey": "claude|w", "title": "Wait", "state": "approval"}],
                "projects": [{"name": "app", "sessions": [{"ckey": "claude|s1", "title": "Fix",
                                                           "state": "working", "status": "live"}]}]}


def _with_core(monkeypatch):
    import tools.coding_session_tool as t
    fake = _FakeCore()
    monkeypatch.setattr(t, "_core", lambda: fake)
    return t, fake


def test_launch_goes_to_the_agents_core_as_a_background_session(monkeypatch, tmp_path):
    import json
    t, fake = _with_core(monkeypatch)
    out = json.loads(t._h_launch({"cwd": str(tmp_path), "prompt": "hi", "skip_permissions": True,
                                  "model": "sonnet"}))
    assert out["ok"] is True
    assert fake.launched == [{"cwd": str(tmp_path), "where": "server", "agent": "claude",
                              "prompt": "hi", "model": "sonnet",
                              "permission_mode": "bypassPermissions"}]


def test_list_returns_conversations(monkeypatch):
    import json
    t, _ = _with_core(monkeypatch)
    out = json.loads(t._h_list({}))
    assert [s["ckey"] for s in out["sessions"]] == ["claude|w", "claude|s1"]


def test_message_reports_its_delivery(monkeypatch):
    import json
    t, fake = _with_core(monkeypatch)
    out = json.loads(t._h_message({"session_id": "s1", "text": "run tests"}))
    assert out["delivery"]["state"] == "sent" and fake.handoff.sent == [("claude|s1", "run tests")]


def test_stop_and_status_take_a_bare_session_id(monkeypatch):
    import json
    t, fake = _with_core(monkeypatch)
    assert json.loads(t._h_stop({"session_id": "s1"}))["ok"] is True and fake.stopped == ["claude|s1"]
    assert json.loads(t._h_status({"session_id": "s1"}))["session"]["ckey"] == "claude|s1"


def test_without_the_agents_service_says_so(monkeypatch):
    import json
    import tools.coding_session_tool as t
    monkeypatch.setattr(t, "_core", lambda: None)
    assert "Jarvis app" in json.loads(t._h_list({}))["error"]


def test_no_tmux_in_the_tool():
    import tools.coding_session_tool as t
    src = open(t.__file__).read()
    assert "tmux" not in src and "coding_session_manager" not in src
