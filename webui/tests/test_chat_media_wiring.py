"""Chat images on the server side: a finished reply's web images are saved into
the chat (backstop), a background job's card carries the pictures it found, and
deleting a chat removes its pictures unless a continuation still shows them."""
import io
import queue
from types import SimpleNamespace

import pytest
from PIL import Image

import api.config  # noqa: F401  (puts the agent checkout on sys.path)
import api.harness_runner as hr
from agent import chat_media, escalation
import api.session_routes as session_routes


def _png(w=500, h=400):
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (1, 2, 3)).save(buf, format="PNG")
    return buf.getvalue()


@pytest.fixture(autouse=True)
def _clean_registry(monkeypatch):
    escalation.reset_for_tests()
    monkeypatch.setattr(chat_media, "fetch_image", lambda url, timeout=8.0: _png())
    yield
    escalation.reset_for_tests()


class FakeSession(SimpleNamespace):
    def save(self, **kw):
        self.saved = True


def test_deliver_result_localizes_web_images(monkeypatch):
    sess = FakeSession(session_id="s1", messages=[], context_messages=[])
    monkeypatch.setattr(hr, "_load_session", lambda sid: sess)
    monkeypatch.setattr(hr, "_listener_count", lambda sid: 1)
    hr.deliver_result("s1", node={"id": "bg", "model": "m", "deliver": "post"}, kind="background",
                      text="Rokid:\n\nMEDIA:https://example.com/rokid.jpg", ms=1)
    content = sess.messages[-1]["content"]
    assert "https://" not in content
    assert "MEDIA:" + str(chat_media.media_dir("s1")) in content


def test_job_card_carries_images():
    card = hr.job_card({"job_id": "j", "status": "running",
                        "images": [{"src": "/x/a_10x10.png", "caption": "A"}]})
    assert card["images"] == [{"src": "/x/a_10x10.png", "caption": "A"}]
    assert hr.job_card({"job_id": "j"})["images"] == []


def test_watch_loop_records_chat_image_thumbnails(monkeypatch):
    sent = []
    monkeypatch.setattr(hr, "_publish_job", lambda sid, card: sent.append(dict(card)))
    with escalation._lock:
        escalation._jobs["j1"] = {"job_id": "j1", "session_id": "s1", "status": "running",
                                  "started_at": 0.0, "worker_session": "s1~bg",
                                  "parent": {"node_id": "bg", "kind": "background"}}
    for i in range(5):
        chat_media.save_image_bytes(_png(300 + i, 300), "s1", worker_session="s1~bg", caption=f"c{i}")
    chat_media.save_image_bytes(_png(301, 301), "s1", worker_session="s1~other", caption="other")
    q = queue.Queue()
    q.put(("tool", {"name": "chat_image", "event_type": "tool.started"}))
    q.put(("tool", {"name": "chat_image", "event_type": "tool.completed"}))
    q.put(("stream_end", {}))
    hr._watch_progress(q, "s1", "j1")
    images = escalation.get_job("j1")["images"]
    assert [i["caption"] for i in images] == ["c1", "c2", "c3", "c4"]
    assert images[0]["src"].startswith(str(chat_media.media_dir("s1")))
    assert sent[-1]["images"] == images


def test_localize_turn_images_only_touches_this_turns_assistant_messages():
    from api.streaming import _localize_turn_images
    old = "earlier MEDIA:https://example.com/old.jpg"
    msgs = [{"role": "assistant", "content": old},
            {"role": "user", "content": "show me MEDIA:https://example.com/u.jpg"},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "x"}]},
            {"role": "tool", "content": "MEDIA:https://example.com/t.jpg"},
            {"role": "assistant", "content": "Here:\n\n![Cat](https://example.com/cat.jpg)"}]
    _localize_turn_images(msgs, "s1")
    assert msgs[0]["content"] == old
    assert "https://example.com/u.jpg" in msgs[1]["content"]
    assert msgs[3]["content"] == "MEDIA:https://example.com/t.jpg"
    assert msgs[4]["content"].startswith("Here:\n\n![Cat](" + str(chat_media.media_dir("s1")))


def test_delete_chat_removes_media_unless_continued(monkeypatch):
    import api.models as models
    chat_media.save_image_bytes(_png(), "aaa1")
    chat_media.save_image_bytes(_png(), "bbb2")
    monkeypatch.setattr(models, "all_sessions",
                        lambda *a, **k: [{"session_id": "ccc3", "parent_session_id": "bbb2"}])
    session_routes.delete_chat_session("aaa1")
    session_routes.delete_chat_session("bbb2")
    assert not chat_media.media_dir("aaa1").exists()
    assert chat_media.media_dir("bbb2").exists()
