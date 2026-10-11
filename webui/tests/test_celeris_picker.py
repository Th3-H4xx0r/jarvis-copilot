"""Celeris in the model pickers + Settings → Providers; decision models listed apart
(so no chat picker — web, phone, Mac or an old build — ever offers a model that can't chat)."""

from api.config import picker_catalog


def test_decision_models_listed_apart_from_chat_groups():
    catalog = {"groups": [
        {"provider": "Celeris", "provider_id": "celeris",
         "models": [{"id": "@celeris:celeris-1", "label": "Celeris 1"}]},
        {"provider": "OpenRouter", "provider_id": "openrouter", "models": [{"id": "x/y", "label": "Y"}]},
    ]}
    shown = picker_catalog(catalog)
    assert shown["decision_models"] == [{"id": "@celeris:celeris-1-decision", "label": "Celeris 1 Decision",
                                         "provider": "Celeris", "provider_id": "celeris"}]
    ids = [m["id"] for g in shown["groups"] for m in g["models"]]
    assert not any("decision" in i for i in ids)


def test_no_celeris_group_no_decision_models():
    shown = picker_catalog({"groups": [{"provider": "OpenRouter", "provider_id": "openrouter", "models": []}]})
    assert shown["decision_models"] == []


def test_celeris_registered_for_pickers_and_key_card():
    from api.config import _PROVIDER_DISPLAY, _PROVIDER_MODELS
    from api.providers import _PROVIDER_ENV_VAR
    assert _PROVIDER_DISPLAY["celeris"] == "Celeris"
    assert {m["id"] for m in _PROVIDER_MODELS["celeris"]} == {"celeris-1", "celeris-1-magnus"}
    assert _PROVIDER_ENV_VAR["celeris"] == "CELERIS_API_KEY"
