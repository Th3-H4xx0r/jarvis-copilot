"""Game streaming store: paired cache, live state, session history."""
from __future__ import annotations

from api.game_streaming_store import GameStreamingStore


def test_paired_roundtrip_and_known_certs(tmp_path):
    s = GameStreamingStore(tmp_path)
    s.upsert_paired([{"name": "Mac", "uuid": "u1"}, {"name": "TV", "uuid": "u2"}])
    paired = s.get_paired()
    assert {d["name"] for d in paired} == {"Mac", "TV"}
    assert s.known_certs() == {"Mac", "TV"}


def test_live_roundtrip(tmp_path):
    s = GameStreamingStore(tmp_path)
    assert s.get_live()["active"] is False
    s.set_live({"active": True, "client": "Mac", "app": "Cyberpunk 2077"})
    live = s.get_live()
    assert live["active"] is True
    assert live["app"] == "Cyberpunk 2077"


def test_sessions_record_and_recent(tmp_path):
    s = GameStreamingStore(tmp_path)
    s.record_session({"kind": "stream_start", "client": "Mac", "app": "Halo"})
    s.record_session({"kind": "stream_stop", "client": "Mac", "app": "Halo"})
    recent = s.recent_sessions()
    assert len(recent) == 2
    assert {r["kind"] for r in recent} == {"stream_start", "stream_stop"}
