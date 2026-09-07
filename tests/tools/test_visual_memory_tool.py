"""Visual memories: reference photos of people/places that come BACK as pixels,
so the model can actually recognise a face in a new photo instead of saying it
has no visual reference."""
import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import tools.visual_memory_tool as vm  # noqa: E402

_PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
    "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")


def _store(tmp_path, monkeypatch):
    monkeypatch.setattr(vm, "_visual_dir", lambda: tmp_path)
    # Assume a vision-capable model unless a test says otherwise.
    monkeypatch.setattr(vm, "_model_sees_images", lambda: True)
    return tmp_path


def _photo(tmp_path, name="p.png"):
    p = tmp_path / name
    p.write_bytes(_PNG_1PX)
    return str(p)


def test_save_then_recall_returns_the_reference_image(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    src = _photo(tmp_path)
    saved = json.loads(vm.visual_memory("save", name="Anjali",
                                        description="Pranav's sister", image_path=src))
    assert saved["ok"] is True and saved["name"] == "Anjali"

    out = vm.visual_memory("recall", query="anjali")
    assert isinstance(out, dict), "a recall with images must be a multimodal result"
    assert out["_multimodal"] is True
    kinds = [c["type"] for c in out["content"]]
    assert "image_url" in kinds, "the reference photo itself must reach the model"
    text = " ".join(c["text"] for c in out["content"] if c["type"] == "text")
    assert "Anjali" in text and "sister" in text


def test_recall_matches_on_the_description_too(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    vm.visual_memory("save", name="Anjali", description="Pranav's sister",
                     image_path=_photo(tmp_path))
    out = vm.visual_memory("recall", query="sister")
    assert isinstance(out, dict) and out["_multimodal"] is True


def test_recall_with_no_query_returns_every_reference(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    vm.visual_memory("save", name="Anjali", image_path=_photo(tmp_path, "a.png"))
    vm.visual_memory("save", name="Rahul", image_path=_photo(tmp_path, "b.png"))
    out = vm.visual_memory("recall")
    text = " ".join(c["text"] for c in out["content"] if c["type"] == "text")
    assert "Anjali" in text and "Rahul" in text


def test_recall_with_nothing_stored_is_a_plain_answer(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    out = json.loads(vm.visual_memory("recall", query="anyone"))
    assert out["ok"] is True and out["results"] == []


def test_saving_the_same_name_twice_adds_another_angle(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    vm.visual_memory("save", name="Anjali", image_path=_photo(tmp_path, "a.png"))
    vm.visual_memory("save", name="Anjali", image_path=_photo(tmp_path, "b.png"))
    listed = json.loads(vm.visual_memory("list"))
    assert len(listed["people"]) == 1, "one person…"
    assert listed["people"][0]["images"] == 2, "…with two reference photos"


def test_forget_removes_the_person_and_their_files(tmp_path, monkeypatch):
    vault = _store(tmp_path / "vault", monkeypatch)
    vm.visual_memory("save", name="Anjali", image_path=_photo(tmp_path))
    stored = list((vault / "images").glob("*"))
    assert stored
    out = json.loads(vm.visual_memory("forget", name="anjali"))
    assert out["ok"] is True and out["forgotten"] == "Anjali"
    assert json.loads(vm.visual_memory("list"))["people"] == []
    assert not list((vault / "images").glob("*")), "the image files go too"


def test_save_requires_a_readable_image(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    out = json.loads(vm.visual_memory("save", name="X", image_path=str(tmp_path / "nope.png")))
    assert out.get("error")


def test_save_requires_a_name(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    out = json.loads(vm.visual_memory("save", name="  ", image_path=_photo(tmp_path)))
    assert out.get("error")


def test_save_accepts_base64_straight_from_a_device_skill(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    b64 = base64.b64encode(_PNG_1PX).decode()
    out = json.loads(vm.visual_memory("save", name="Rahul", image_base64=b64, mime="image/png"))
    assert out["ok"] is True
    assert json.loads(vm.visual_memory("list"))["people"][0]["name"] == "Rahul"


def test_an_unknown_action_is_rejected(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    assert json.loads(vm.visual_memory("dance")).get("error")


def test_reference_images_are_capped_per_person(tmp_path, monkeypatch):
    _store(tmp_path / "vault", monkeypatch)
    for i in range(vm.MAX_IMAGES_PER_PERSON + 3):
        vm.visual_memory("save", name="Anjali", image_path=_photo(tmp_path, f"{i}.png"))
    assert json.loads(vm.visual_memory("list"))["people"][0]["images"] == vm.MAX_IMAGES_PER_PERSON


def test_visual_memory_is_in_the_memory_toolset():
    """A tool whose name is missing from its TOOLSETS entry is silently dropped
    before the model ever sees it."""
    from toolsets import TOOLSETS
    assert "visual_memory" in TOOLSETS["memory"]["tools"]


def test_visual_memory_is_registered_and_discoverable():
    from tools.registry import discover_builtin_tools, registry
    discover_builtin_tools()
    assert "visual_memory" in registry.get_tool_names_for_toolset("memory")


def test_recall_gives_a_text_only_model_names_not_a_data_url(tmp_path, monkeypatch):
    """Same rule as device photos: a model that cannot take image parts must
    never be handed a base64 data URL, or it echoes it into the chat."""
    _store(tmp_path / "vault", monkeypatch)
    monkeypatch.setattr(vm, "_model_sees_images", lambda: False)
    vm.visual_memory("save", name="Anjali", description="Pranav's sister",
                     image_path=_photo(tmp_path))
    out = vm.visual_memory("recall", query="anjali")
    assert isinstance(out, str)
    assert "data:image" not in out and "base64," not in out
    parsed = json.loads(out)
    assert parsed["results"][0]["name"] == "Anjali"
    assert "cannot see images" in parsed["note"] or "no_vision" in json.dumps(parsed)
