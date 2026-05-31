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
