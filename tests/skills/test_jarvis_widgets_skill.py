"""Tests for skills/jarviscopilot/widgets — the widget designs SKILL.md and CLI.

The fake transport stands in for the devices skill's host-signed client: widget
requests go to the real webui dispatcher over a WidgetStore on tmp_path, device
skill requests are answered from canned rows. No network.
"""
from __future__ import annotations

import importlib.util
import io
import json
import re
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "webui"))

from api import widget_schema  # noqa: E402
from api.widget_routes import WIDGETS_PATH_PREFIX, handle_widgets_request  # noqa: E402
from api.widget_store import WidgetStore  # noqa: E402

SKILL_DIR = REPO_ROOT / "skills" / "jarviscopilot" / "widgets"
SKILL_MD = SKILL_DIR / "SKILL.md"
SCRIPT_PATH = SKILL_DIR / "scripts" / "widgets.py"

PHONE = "0123456789abcdef0123456789abcdef"
OLD_PHONE = "11111111111111111111111111111111"
MAC = "fedcba9876543210fedcba9876543210"


def load_module():
    spec = importlib.util.spec_from_file_location("jarvis_widgets_skill", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def skill_row(device_id, name, device_name):
    return {"device_id": device_id, "device_name": device_name, "name": name,
            "description": "", "input_schema": {"type": "object", "properties": {}}}


PHONE_SKILLS = [
    skill_row(MAC, "chrome_snapshot", "MacBook"),
    skill_row(PHONE, "wearables_list", "iPhone"),
    skill_row(PHONE, "widgets_refresh", "iPhone"),
]


def steps_design(**extra):
    return {"schema": 1, "id": "steps", "name": "Steps", "icon": "figure.walk",
            "presentations": {"small": {"type": "stat", "value": {"src": "health.steps"},
                                        "caption": "steps"}}, **extra}


class FakeTransport:
    """(method, path, body, timeout) -> (status, data), recording every call."""

    def __init__(self, store, skills=None, invoke_reply=None):
        self.store = store
        self.skills = PHONE_SKILLS if skills is None else skills
        self.invoke_reply = invoke_reply or (200, {"ok": True, "result": {"ok": True}})
        self.calls = []

    def __call__(self, method, path, body=None, timeout=30.0):
        self.calls.append({"method": method, "path": path, "body": body, "timeout": timeout})
        if path.startswith(WIDGETS_PATH_PREFIX + "/"):
            return handle_widgets_request(method, path[len(WIDGETS_PATH_PREFIX):], body, self.store)
        if (method, path) == ("GET", "/api/devices/skills"):
            return 200, {"skills": self.skills}
        if (method, path) == ("POST", "/api/devices/skills/invoke"):
            return self.invoke_reply
        return 404, {"error": "not found"}

    @property
    def invokes(self):
        return [c["body"] for c in self.calls if c["path"] == "/api/devices/skills/invoke"]


@pytest.fixture
def mod():
    return load_module()


@pytest.fixture
def store(tmp_path):
    return WidgetStore(tmp_path / "state")


@pytest.fixture
def run(mod, capsys):
    """Runs the CLI against a transport; returns (exit code, stdout JSON|None, stderr JSON|None)."""
    def _run(argv, transport, stdin=None):
        if stdin is not None:
            sys.stdin = io.StringIO(stdin)
        try:
            code = mod.main(argv, transport=transport)
        finally:
            sys.stdin = sys.__stdin__
        out, err = capsys.readouterr()
        return code, (json.loads(out) if out.strip() else None), (json.loads(err) if err.strip() else None)
    return _run


def write_json(tmp_path, obj, name="design.json"):
    path = tmp_path / name
    path.write_text(json.dumps(obj), encoding="utf-8")
    return str(path)


# ── SKILL.md ─────────────────────────────────────────────────────────────────

def _frontmatter_field(name):
    m = re.search(rf"^{name}: (.*)$", SKILL_MD.read_text(encoding="utf-8"), re.MULTILINE)
    assert m, f"SKILL.md has no {name}"
    return m.group(1).strip()


def test_description_is_one_short_sentence():
    description = _frontmatter_field("description")
    assert len(description) <= 60, len(description)
    assert description.endswith(".")
    assert description.count(". ") == 0, "one sentence"


def test_frontmatter_names_the_skill_and_credits_the_human_first():
    assert _frontmatter_field("name") == SKILL_DIR.name
    assert _frontmatter_field("author").startswith("Pranav Krishna")


def test_body_uses_the_modern_section_order():
    text = SKILL_MD.read_text(encoding="utf-8")
    order = ["# Widgets Skill", "## When to Use", "## Prerequisites", "## How to Run",
             "## Quick Reference", "## Procedure", "## Pitfalls", "## Verification"]
    positions = [text.find(f"\n{heading}\n") for heading in order]
    assert all(p >= 0 for p in positions), dict(zip(order, positions))
    assert positions == sorted(positions)


def test_the_doc_covers_every_node_type_size_and_device_the_server_accepts():
    text = SKILL_MD.read_text(encoding="utf-8")
    for name in [*widget_schema.WIDGET_NODE_TYPES, *widget_schema.SIZES,
                 *widget_schema.MODEL_DEVICES, *widget_schema.CHART_STYLES]:
        assert f"`{name}`" in text, name


def _example_designs():
    blocks = re.findall(r"```json\n(.*?)```", SKILL_MD.read_text(encoding="utf-8"), re.DOTALL)
    return [d for d in (json.loads(b) for b in blocks) if isinstance(d, dict) and "presentations" in d]


def test_every_example_design_in_the_doc_is_valid():
    examples = _example_designs()
    assert len(examples) >= 3
    for design in examples:
        errors, _ = widget_schema.validate_design(design)
        assert errors == [], (design["id"], errors)


def test_the_examples_use_the_new_blocks():
    used = json.dumps(_example_designs())
    for node_type in ("chart", "model", "button"):
        assert f'"type": "{node_type}"' in used, node_type


# ── reading ──────────────────────────────────────────────────────────────────

def test_list_is_compact(run, store):
    store.upsert_design(steps_design(builder={"rows": []}))
    store.set_catalog([{"key": "health.steps", "label": "Steps", "area": "health", "kind": "number"}])
    code, out, err = run(["list"], FakeTransport(store))
    assert code == 0 and err is None
    assert out["designs"] == [{"id": "steps", "name": "Steps", "version": 1, "icon": "figure.walk",
                               "sizes": ["small"], "builder": True}]
    assert out["catalog_keys"] == 1


def test_show_prints_the_design(run, store):
    store.upsert_design(steps_design())
    code, out, _ = run(["show", "steps"], FakeTransport(store))
    assert code == 0 and out == store.get_design("steps")


def test_show_missing_design_fails(run, store):
    code, out, err = run(["show", "ghost"], FakeTransport(store))
    assert code == 1 and out is None and "not found" in err["error"]


def test_show_rejects_a_bad_id_without_calling_the_server(run, store):
    transport = FakeTransport(store)
    code, _, err = run(["show", "../etc"], transport)
    assert code == 1 and "id" in err["error"] and transport.calls == []


def test_catalog(run, store):
    entries = [{"key": "health.steps", "label": "Steps", "area": "health", "kind": "number"}]
    store.set_catalog(entries)
    code, out, _ = run(["catalog"], FakeTransport(store))
    assert code == 0 and out["catalog"] == entries and "note" not in out


def test_empty_catalog_says_why(run, store):
    code, out, _ = run(["catalog"], FakeTransport(store))
    assert code == 0 and out["catalog"] == [] and "phone" in out["note"]


# ── upsert ───────────────────────────────────────────────────────────────────

def test_upsert_from_a_file_saves_and_refreshes_the_phone(run, mod, store, tmp_path):
    store.set_catalog([{"key": "health.steps", "label": "Steps", "area": "health", "kind": "number"}])
    transport = FakeTransport(store)
    code, out, err = run(["upsert", write_json(tmp_path, steps_design())], transport)
    assert code == 0 and err is None
    assert out["ok"] is True and out["id"] == "steps" and out["version"] == 1
    assert out["sizes"] == ["small"] and out["warnings"] == []
    assert "iPhone" in out["phone"]
    assert store.get_design("steps")["name"] == "Steps"
    assert transport.invokes == [{"device_id": PHONE, "skill": "widgets_refresh", "args": {},
                                  "timeout": mod.REFRESH_TIMEOUT}]


def test_upsert_from_stdin_bumps_the_version(run, store):
    store.upsert_design(steps_design())
    code, out, _ = run(["upsert", "-"], FakeTransport(store), stdin=json.dumps(steps_design()))
    assert code == 0 and out["version"] == 2


def test_upsert_prints_catalog_warnings(run, store, tmp_path):
    store.set_catalog([{"key": "health.steps", "label": "Steps", "area": "health", "kind": "number"}])
    design = steps_design(presentations={"small": {"type": "stat", "value": {"src": "pod.battery"}}})
    code, out, _ = run(["upsert", write_json(tmp_path, design)], FakeTransport(store))
    assert code == 0 and any("pod.battery" in w for w in out["warnings"])


def test_invalid_design_prints_the_errors_and_skips_the_phone(run, store, tmp_path):
    transport = FakeTransport(store)
    design = steps_design(presentations={"small": {"type": "chart"}})
    code, out, err = run(["upsert", write_json(tmp_path, design)], transport)
    assert code == 1 and out is None
    # The summary names the problem itself (the phone shows only this line).
    assert "series" in err["error"] and any("series" in e for e in err["errors"])
    assert transport.invokes == [] and store.list_designs() == []


@pytest.mark.parametrize("content, needle", [("{not json", "JSON"), ("[1, 2]", "object")])
def test_bad_input_fails_before_any_request(run, store, tmp_path, content, needle):
    path = tmp_path / "bad.json"
    path.write_text(content, encoding="utf-8")
    transport = FakeTransport(store)
    code, _, err = run(["upsert", str(path)], transport)
    assert code == 1 and needle in err["error"] and transport.calls == []


def test_missing_file_fails(run, store, tmp_path):
    code, _, err = run(["upsert", str(tmp_path / "nope.json")], FakeTransport(store))
    assert code == 1 and "nope.json" in err["error"]


def test_no_refresh_flag(run, store, tmp_path):
    transport = FakeTransport(store)
    code, out, _ = run(["upsert", write_json(tmp_path, steps_design()), "--no-refresh"], transport)
    assert code == 0 and "phone" not in out
    assert not any(c["path"].startswith("/api/devices") for c in transport.calls)


# ── the phone is best-effort ─────────────────────────────────────────────────

def test_no_phone_offering_the_refresh_is_a_note(run, store, tmp_path):
    transport = FakeTransport(store, skills=[skill_row(MAC, "chrome_snapshot", "MacBook")])
    code, out, _ = run(["upsert", write_json(tmp_path, steps_design())], transport)
    assert code == 0 and out["ok"] is True
    assert "next time" in out["phone"] and transport.invokes == []


@pytest.mark.parametrize("reply", [
    (502, {"ok": False, "error": "device timed out"}),
    (200, {"ok": True, "result": {"ok": False, "error": "busy"}}),
    (-1, {"error": "connection refused"}),
])
def test_an_unreachable_phone_is_a_note_not_an_error(run, store, tmp_path, reply):
    transport = FakeTransport(store, invoke_reply=reply)
    code, out, err = run(["upsert", write_json(tmp_path, steps_design())], transport)
    assert code == 0 and err is None and out["ok"] is True
    assert "iPhone" in out["phone"] and "next time" in out["phone"]
    assert store.get_design("steps") is not None


def test_a_transport_that_raises_during_refresh_is_a_note(mod, store, tmp_path, capsys):
    transport = FakeTransport(store)

    def flaky(method, path, body=None, timeout=30.0):
        if path.startswith("/api/devices"):
            raise OSError("socket closed")
        return transport(method, path, body, timeout)

    code = mod.main(["upsert", write_json(tmp_path, steps_design())], transport=flaky)
    out = json.loads(capsys.readouterr().out)
    assert code == 0 and "next time" in out["phone"]


def test_every_phone_offering_the_refresh_is_asked(run, store, tmp_path):
    skills = [*PHONE_SKILLS, skill_row(OLD_PHONE, "widgets_refresh", "Old iPhone")]
    transport = FakeTransport(store, skills=skills)
    code, out, _ = run(["upsert", write_json(tmp_path, steps_design())], transport)
    assert code == 0
    assert [b["device_id"] for b in transport.invokes] == [PHONE, OLD_PHONE]


# ── delete ───────────────────────────────────────────────────────────────────

def test_delete_removes_and_refreshes(run, store):
    store.upsert_design(steps_design())
    transport = FakeTransport(store)
    code, out, _ = run(["delete", "steps"], transport)
    assert code == 0 and out["ok"] is True and out["id"] == "steps" and "iPhone" in out["phone"]
    assert store.get_design("steps") is None
    assert [c["method"] for c in transport.calls if c["path"].startswith("/api/widgets")] == ["DELETE"]
    assert len(transport.invokes) == 1


def test_delete_missing_fails_without_refreshing(run, store):
    transport = FakeTransport(store)
    code, _, err = run(["delete", "ghost"], transport)
    assert code == 1 and "not found" in err["error"] and transport.invokes == []


# ── transport ────────────────────────────────────────────────────────────────

def test_the_cli_uses_the_devices_skill_client_by_default(mod, monkeypatch, store, capsys):
    transport = FakeTransport(store)
    monkeypatch.setattr(mod, "load_devices_module", lambda: SimpleNamespace(_http=transport))
    assert mod.main(["catalog"]) == 0
    assert transport.calls[0]["path"] == "/api/widgets/catalog"


def test_unreachable_webui_is_an_error(run):
    code, _, err = run(["list"], lambda *a, **k: (-1, {"error": "connection refused"}))
    assert code == 1 and "web UI" in err["error"]


def test_usage_errors_keep_the_json_contract(run, store):
    with pytest.raises(SystemExit) as exc:
        run(["frobnicate"], FakeTransport(store))
    assert exc.value.code == 1
