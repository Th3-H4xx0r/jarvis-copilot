"""Settings → Web & browser → Extraction model can be a harness: its Route picks
which model turns each page into JSON (agent/extract_model.py asks the web UI)."""
import json

import api.config  # noqa: F401  (puts the agent checkout on sys.path)
import api.harness_runner as hr
from api.harness_store import HarnessStore


def _design():
    return {"id": "extract", "name": "Extract", "nodes": [
        {"id": "in", "type": "message"},
        {"id": "r", "type": "route", "by": "rules", "labels": ["big"],
         "rules": [{"match": "keywords", "value": "table", "label": "big"}]},
        {"id": "fast", "type": "answer", "model": "@celeris:celeris-1"},
        {"id": "strong", "type": "answer", "model": "@anthropic-api:claude-sonnet-5-5"}],
        "edges": [{"from": "in", "to": "r"}, {"from": "r", "to": "strong", "when": "label:big"},
                  {"from": "r", "to": "fast", "when": "default"}]}


def test_the_harness_route_picks_the_extraction_model(tmp_path, monkeypatch):
    st = HarnessStore(tmp_path)
    st._designs_dir.mkdir(parents=True)
    (st._designs_dir / "extract.json").write_text(json.dumps(_design()))
    monkeypatch.setattr("api.harness_store.store_for_request", lambda: st)
    assert hr.extract_model_for("extract", "prices on this page", 1200) == "@celeris:celeris-1"
    assert hr.extract_model_for("extract", "the whole results table", 1200) == "@anthropic-api:claude-sonnet-5-5"
    assert hr.extract_model_for("missing", "x", 10) is None


def test_the_web_ui_registers_it():
    from agent import extract_model
    assert extract_model._resolver is hr.extract_model_for
