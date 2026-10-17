"""The server loads jc-client's transcript merge by path (one implementation)."""
from agent.transcript_merge_shim import merge


def test_shim_exposes_the_same_merge():
    r = merge(['{"uuid":"a"}'], ['{"uuid":"a"}', '{"uuid":"b"}'], "claude")
    assert r.merged == ['{"uuid":"a"}', '{"uuid":"b"}'] and r.kind == "appended"
