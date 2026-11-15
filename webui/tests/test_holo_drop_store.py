"""Holo Drop's store: drops, files, expiry, bearings, LAN endpoints."""
from __future__ import annotations

import io
import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api.holo_drop_store import HoloStore, TooLarge  # noqa: E402


@pytest.fixture()
def st(tmp_path):
    clock = {"t": 1_000_000.0}
    s = HoloStore(tmp_path / "holo", clock=lambda: clock["t"])
    s._clock_box = clock
    return s


def test_lifecycle_keeps_text_and_file(st):
    d = st.create("link", sender="iphone-1", target="mac-1", action="open", url="https://a.b/c", title="A")
    assert d["state"] == "sent" and d["url"] == "https://a.b/c"
    f = st.create("image", sender="iphone-1", target="mac-1", action="save", name="IMG.HEIC", mime="image/heic")
    st.attach_file(f["id"], io.BytesIO(b"x" * 10), 10, max_bytes=100)
    assert st.content_path(f["id"]).read_bytes() == b"x" * 10
    st.set_state(f["id"], "landed", outcome="saved")
    assert st.get(f["id"])["outcome"] == "saved"
    hist = st.history(10)
    assert [h["id"] for h in hist] == [f["id"], d["id"]]
    assert "file" not in hist[0] and hist[1]["url"] == "https://a.b/c"


def test_cap_enforced_before_write(st):
    f = st.create("video", sender="a", target="b", name="big.mov")
    with pytest.raises(TooLarge):
        st.attach_file(f["id"], io.BytesIO(b""), 10_000, max_bytes=100)
    assert st.content_path(f["id"]) is None
    assert not any(st.files.iterdir())


def test_expiry_cleans_payload_keeps_history(st):
    f = st.create("file", sender="a", target="b", name="doc.pdf")
    st.attach_file(f["id"], io.BytesIO(b"pdf"), 3, max_bytes=100)
    st._clock_box["t"] += 25 * 3600
    assert st.sweep() == 1
    assert st.content_path(f["id"]) is None
    assert st.get(f["id"])["expired"] is True
    assert st.history(5)[0]["id"] == f["id"]


def test_concurrent_drops_distinct(st):
    ids = []

    def make():
        d = st.create("file", sender="a", target="b", name="same.txt")
        st.attach_file(d["id"], io.BytesIO(d["id"].encode()), len(d["id"]), max_bytes=100)
        ids.append(d["id"])

    threads = [threading.Thread(target=make) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert len(set(ids)) == 8
    assert {st.content_path(i).read_text() for i in ids} == set(ids)


def test_pending_and_bearings_and_lan(st):
    d = st.create("text", sender="a", target="mac-1", text="hi")
    st.set_state(d["id"], "held")
    assert [p["id"] for p in st.pending_for("mac-1")] == [d["id"]]
    st.put_bearings("iphone-1", [{"device": "mac-1", "deg": 40, "confidence": 0.8, "source": "look"}])
    assert st.bearings_for("iphone-1")["mac-1"]["deg"] == 40
    st.clear_bearing("iphone-1", "mac-1")
    assert st.bearings_for("iphone-1") == {}
    st.set_lan("mac-1", "http://10.0.0.5:5555", "tok", st._clock_box["t"] + 600)
    assert st.lan_for("mac-1")["token"] == "tok"
    st._clock_box["t"] += 601
    assert st.lan_for("mac-1") is None
