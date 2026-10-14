"""The server loads the very same engine file jc-client runs (no hand copy)."""
import os


def test_shim_loads_the_client_engine_file():
    from agent import agent_engine_shim as shim

    eng = shim.Engine(clock=lambda: 100.0)
    eng.ingest("server", "claude", {"hook_event_name": "UserPromptSubmit",
                                     "session_id": "s", "cwd": "/srv/app", "prompt": "hi"})
    key = shim.session_key("server", "claude", "s", "/srv/app")
    assert eng.session(key)["state"] == "thinking"
    expected = os.path.join("desktop_client", "jc_client", "agent_engine.py")
    assert shim.module.__file__.endswith(expected)
    assert shim.fingerprint is shim.module.fingerprint
