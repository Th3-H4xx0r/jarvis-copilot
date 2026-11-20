"""Skill argument near-misses (live 2026-11-20: device_open_app {app: …} failed with "unexpected args: ['app']")."""
import pytest

from jc_client import skills


@pytest.fixture
def opener():
    seen = {}

    @skills.skill("t_open_thing", "test", {"type": "object", "properties": {"name": {"type": "string"}},
                                            "required": ["name"]})
    def t_open_thing(name: str, wait: bool = False) -> dict:
        seen.update(name=name, wait=wait)
        return {"ok": True}
    yield seen
    with skills._REGISTRY_LOCK:
        skills._REGISTRY.pop("t_open_thing", None)


def test_one_wrong_name_for_the_one_missing_arg_is_taken_as_it(opener):
    assert skills.invoke("t_open_thing", {"app": "Discord"}) == {"ok": True}
    assert opener == {"name": "Discord", "wait": False}


def test_an_unknown_arg_beside_the_right_one_still_fails_and_says_what_it_takes(opener):
    with pytest.raises(TypeError) as e:
        skills.invoke("t_open_thing", {"name": "Discord", "app": "x"})
    assert "app" in str(e.value) and "name" in str(e.value)


def test_two_unknown_args_still_fail(opener):
    with pytest.raises(TypeError):
        skills.invoke("t_open_thing", {"app": "Discord", "foo": 1})
