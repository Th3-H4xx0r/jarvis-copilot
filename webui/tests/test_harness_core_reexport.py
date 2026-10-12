"""The web UI's harness modules re-export the core package the scheduler uses."""
from dataclasses import asdict

from api import harness_runner, harness_store  # first: puts the core checkout on sys.path

from agent.harness import planner as core_planner  # noqa: E402
from agent.harness import store as core_store  # noqa: E402

DOC = {
    "id": "mail", "name": "Mail",
    "nodes": [
        {"id": "in", "type": "message"},
        {"id": "route", "type": "route", "by": "rules", "labels": ["deep"],
         "rules": [{"match": "surface", "value": "schedule", "label": "deep"}]},
        {"id": "fast", "type": "answer", "model": "@ollama-cloud:gemma4:31b"},
        {"id": "big", "type": "answer", "model": "@anthropic-api:claude-sonnet-5-5", "tools": "all"},
    ],
    "edges": [
        {"from": "in", "to": "route", "when": "always"},
        {"from": "route", "to": "big", "when": "label:deep"},
        {"from": "route", "to": "fast", "when": "default"},
    ],
}


def test_webui_plan_equals_core_plan():
    for surface in ("schedule", "chat"):
        kw = dict(session_model="m", session_provider=None, text="hi", surface=surface, has_attachments=False)
        web, core = harness_runner.plan_turn(DOC, **kw), core_planner.plan_turn(DOC, **kw)
        assert asdict(web) == asdict(core)
    assert harness_runner.TurnPlan is core_planner.TurnPlan
    assert harness_runner.RouteDecision is core_planner.RouteDecision


def test_webui_store_writes_what_the_core_store_reads(tmp_path):
    web = harness_store.HarnessStore(tmp_path, "default")
    saved, errors = web.upsert_design(DOC)
    assert not errors and saved["version"] == 1
    assert core_store.HarnessStore(tmp_path, "default").get("mail")["name"] == "Mail"
    assert isinstance(web, core_store.HarnessStore)
