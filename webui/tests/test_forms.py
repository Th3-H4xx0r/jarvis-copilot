"""Forms the agent draws in the conversation."""
from __future__ import annotations

import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.forms as forms  # noqa: E402
import api.helpers as helpers  # noqa: E402

GOOD = {
    "title": "Gym Sessions",
    "intro": "A few details and I'll build it.",
    "fields": [
        {"key": "name", "label": "What should I call it?", "type": "text",
         "placeholder": "Gym Sessions", "required": True},
        {"key": "cadence", "label": "How often?", "type": "choice",
         "options": ["Daily", "Weekly", "Monthly"]},
        {"key": "notify", "label": "Tell me when it runs?", "type": "toggle"},
    ],
}


@pytest.fixture()
def home(tmp_path, monkeypatch):
    monkeypatch.setattr(forms, "_path", lambda: tmp_path / "forms.json")
    return tmp_path


@pytest.fixture()
def sent(monkeypatch):
    box: dict = {}

    def fake_j(handler, body, status=200):
        box["body"] = body
        box["status"] = status
        return True

    monkeypatch.setattr(helpers, "j", fake_j)
    return box


def test_a_form_is_stored_open_with_nothing_answered(home):
    form = forms.ask(dict(GOOD))
    assert form["status"] == "open" and form["values"] == {}
    assert [f["key"] for f in form["fields"]] == ["name", "cadence", "notify"]
    assert form["submit_label"] == "Done"
    assert forms.get(form["id"])["title"] == "Gym Sessions"


def test_the_bad_field_is_named(home):
    with pytest.raises(forms.FormError, match="at least one field"):
        forms.ask({"title": "X", "fields": []})
    with pytest.raises(forms.FormError, match=r"fields\[0\].label is required"):
        forms.ask({"title": "X", "fields": [{"key": "a"}]})
    with pytest.raises(forms.FormError, match="choice with no options"):
        forms.ask({"title": "X", "fields": [{"key": "a", "label": "A", "type": "choice"}]})
    with pytest.raises(forms.FormError, match="must be one of"):
        forms.ask({"title": "X", "fields": [{"key": "a", "label": "A", "type": "slider"}]})
    with pytest.raises(forms.FormError, match="two fields both called"):
        forms.ask({"title": "X", "fields": [{"key": "a", "label": "A"},
                                            {"key": "a", "label": "B"}]})
    with pytest.raises(forms.FormError, match="at most"):
        forms.ask({"title": "X", "fields": [{"key": f"k{i}", "label": "A"}
                                            for i in range(forms.MAX_FIELDS + 1)]})


def test_submitting_records_the_answers_and_writes_the_reply(home):
    form = forms.ask(dict(GOOD))
    out = forms.submit(form["id"], {"name": "Gym Sessions", "cadence": "Weekly",
                                    "notify": True})

    assert out["form"]["status"] == "answered"
    assert out["form"]["values"]["notify"] is True
    # The reply is what the user's next message says, so the agent reads it normally.
    assert "What should I call it? Gym Sessions" in out["reply"]
    assert "Tell me when it runs? yes" in out["reply"]


def test_a_form_is_answered_once(home):
    form = forms.ask(dict(GOOD))
    forms.submit(form["id"], {"name": "A"})
    with pytest.raises(forms.FormError, match="already answered"):
        forms.submit(form["id"], {"name": "B"})
    with pytest.raises(forms.FormError, match="no form"):
        forms.submit("nope", {})


def test_what_the_form_asked_for_is_what_it_accepts(home):
    form = forms.ask(dict(GOOD))
    with pytest.raises(forms.FormError, match="What should I call it\\? is required"):
        forms.submit(form["id"], {"cadence": "Weekly"})

    form = forms.ask(dict(GOOD))
    with pytest.raises(forms.FormError, match="not one of the choices"):
        forms.submit(form["id"], {"name": "A", "cadence": "Whenever"})


def test_an_open_form_is_never_trimmed_away(home):
    """Its card is still on screen; losing it turns the card into an error."""
    first = forms.ask(dict(GOOD))
    for i in range(60):
        done = forms.ask({**GOOD, "title": f"Thing {i}"})
        forms.submit(done["id"], {"name": "x"})
    assert forms.get(first["id"]) is not None


def test_the_http_surface(home, sent):
    form = forms.ask(dict(GOOD))
    assert forms.handle_get(object(), urlparse(f"/api/forms/{form['id']}")) is True
    assert sent["body"]["title"] == "Gym Sessions"

    assert forms.handle_get(object(), urlparse("/api/forms/nope")) is True
    assert sent["status"] == 404

    assert forms.handle_post(object(), urlparse(f"/api/forms/{form['id']}/submit"),
                             {"values": {"name": "Gym"}}) is True
    assert sent["body"]["form"]["status"] == "answered"

    assert forms.handle_post(object(), urlparse(f"/api/forms/{form['id']}/submit"),
                             {"values": {"name": "Gym"}}) is True
    assert sent["status"] == 400
    assert forms.handle_get(object(), urlparse("/api/integrations")) is False
