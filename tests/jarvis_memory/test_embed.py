from plugins.memory.jarvis_memory.embed import FakeEmbedder, make_embedder


def test_fake_embedder_deterministic_and_normalized():
    e = FakeEmbedder(dim=64)
    a = e.embed_one("the auth migration shipped on friday")
    b = e.embed_one("the auth migration shipped on friday")
    assert a == b  # deterministic
    assert len(a) == 64 == e.dim
    assert abs(sum(x * x for x in a) ** 0.5 - 1.0) < 1e-6  # L2-normalized
    assert e.signature == "fake:bow:64"


def _cos(x, y):
    return sum(p * q for p, q in zip(x, y))


def test_fake_embedder_similar_texts_closer():
    e = FakeEmbedder(dim=128)
    q = e.embed_one("how do I deploy the watch app")
    near = e.embed_one("deploy the watch app to the device")
    far = e.embed_one("favorite pizza topping recipe")
    assert _cos(q, near) > _cos(q, far)


def test_make_embedder_fake():
    e = make_embedder({"embedder": "fake", "embed_dim": 32})
    assert e.dim == 32 and e.signature == "fake:bow:32"


def test_ollama_embeds_a_list_in_one_request(monkeypatch):
    import io
    import json
    import urllib.request
    from plugins.memory.jarvis_memory.embed import OllamaEmbedder
    calls = []

    class Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=None):
        body = json.loads(req.data.decode())
        calls.append((req.full_url, body))
        return Resp(json.dumps({"embeddings": [[1.0, 0.0, 0.0, 0.0]] * len(body["input"])}).encode())
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    out = OllamaEmbedder(dim=4).embed(["a", "b", "c"])
    assert len(out) == 3 and len(calls) == 1
    url, body = calls[0]
    assert url.endswith("/api/embed") and body["input"] == ["a", "b", "c"] and body["keep_alive"] == "24h"
