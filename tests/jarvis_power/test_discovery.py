"""Power integrations: discovery of the built-in modules and their validation."""
from __future__ import annotations

import pytest

from jarvis_power import PowerError, discovery

GOOD = '''
from jarvis_power import PowerIntegration, Setting

class Good(PowerIntegration):
    id = "good"
    name = "Good"
    icon = "bolt"
    summary = "A well-formed integration."
    settings = (Setting("mode", "Mode", "picker", default="a", options=(("a", "A"), ("b", "B"))),)
'''


def test_template_is_never_discovered():
    discovery.reset()
    found = discovery.integrations()
    assert all("_template" not in type(p).__module__ for p in found.values())


def test_discovers_one_subclass_per_package(fake_pkg):
    fake_pkg({"good": GOOD})
    found = discovery.integrations()
    assert list(found) == ["good"]
    assert discovery.get("good").name == "Good"
    with pytest.raises(PowerError):
        discovery.get("missing")


def test_two_subclasses_in_one_package_raises(fake_pkg):
    fake_pkg({"twice": GOOD + '''
class Second(PowerIntegration):
    id = "second"
    name = "Second"
    icon = "bolt"
    summary = "Another one."
'''})
    with pytest.raises(PowerError, match="exactly one"):
        discovery.integrations()


def test_validate_reports_every_problem(fake_pkg):
    fake_pkg({"broken": {
        "source": '''
from jarvis_power import PowerIntegration, Setting

class Broken(PowerIntegration):
    id = "broken"
    name = "Broken"
    icon = "bolt"
    summary = "Wrong in five ways."
    toolsets = ("nope",)
    surfaces = ("ios.nowhere",)
    settings = (
        Setting("a", "A", "toggle", default=False),
        Setting("a", "A again", "toggle", default=True),
        Setting("mode", "Mode", "picker", default="z", options=(("x", "X"),)),
    )
    actions = ()
''',
        "ui": {"presentations": {"card": {"type": "button", "label": "Go", "action": "go"}}},
    }})
    problems = discovery.validate(discovery.get("broken"))
    text = "\n".join(problems)
    assert len(problems) >= 5, problems
    assert "duplicate setting" in text
    assert "nope" in text
    assert "ios.nowhere" in text
    assert "mode" in text
    assert "go" in text


def test_template_copy_is_valid(fake_pkg):
    fake_pkg({"sample": None})
    [p] = discovery.integrations().values()
    assert discovery.validate(p) == []


def test_every_real_integration_validates():
    discovery.reset()
    found = discovery.integrations()
    ids = [p.id for p in found.values()]
    assert len(ids) == len(set(ids))
    for p in found.values():
        assert discovery.validate(p) == [], (p.id, discovery.validate(p))
