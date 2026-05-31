import json

from plugins.memory.jarvis_memory import JarvisMemoryProvider


def _provider(tmp_path):
    p = JarvisMemoryProvider()
    p.initialize("sess-1", hermes_home=str(tmp_path), platform="cli",
                 _config_override={"embedder": "fake", "embed_dim": 64})
    return p


def test_provider_basic_contract(tmp_path):
    p = _provider(tmp_path)
    assert p.name == "jarvis_memory"
    assert p.is_available() is True
    names = {t["name"] for t in p.get_tool_schemas()}
    assert {"memory_recall", "memory_store", "memory_forget"} <= names
    p.shutdown()


def test_capture_warm_then_prefetch_recalls(tmp_path):
    p = _provider(tmp_path)
    # Default capture is user-only, so put the recall target in the user turn.
    p.sync_turn("the watch app deploys via deploy_both.sh from mobile_client",
                "Got it.", session_id="sess-1")
    p._flush()
    # prefetch is hot-path-safe: it returns the block warmed by queue_prefetch,
    # never a synchronous embed. Warm it, then read.
    p.queue_prefetch("deploy watch app", session_id="sess-1")
    p._flush()
    block = p.prefetch("deploy watch app", session_id="sess-1")
    assert "deploy_both.sh" in block
    # prefetch consumes the cache (one-shot) — second read is empty until re-warmed.
    assert p.prefetch("deploy watch app", session_id="sess-1") == ""
    p.shutdown()


def test_memory_store_and_recall_tool(tmp_path):
    p = _provider(tmp_path)
    out = json.loads(p.handle_tool_call("memory_store", {"content": "Pranav commits straight to main"}))
    assert out.get("ok") is True
    res = json.loads(p.handle_tool_call("memory_recall", {"query": "how does pranav use git"}))
    assert any("main" in r["body"] for r in res.get("results", []))
    p.shutdown()


def test_memory_forget_tool(tmp_path):
    p = _provider(tmp_path)
    stored = json.loads(p.handle_tool_call("memory_store", {"content": "ephemeral fact about x"}))
    cid = stored["id"]
    out = json.loads(p.handle_tool_call("memory_forget", {"id": cid}))
    assert out.get("deleted") is True
    p.shutdown()
