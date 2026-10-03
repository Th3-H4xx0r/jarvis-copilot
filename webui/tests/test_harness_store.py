from api.harness_builtins import builtin_harnesses
from api.harness_schema import validate_harness
from api.harness_store import DEFAULT_ASSIGNMENTS, HarnessStore

DOC = {"id": "mine", "name": "Mine", "nodes": [
    {"id": "in", "type": "message"}, {"id": "a", "type": "answer", "model": "@x:y"}],
    "edges": [{"from": "in", "to": "a"}]}


def test_builtins_all_validate():
    for doc in builtin_harnesses("@ollama-cloud:gemma4:31b", "@claude-code:claude-sonnet-5-5"):
        assert validate_harness(doc)[1] == [], doc["id"]


def test_upsert_bumps_version_and_lists(tmp_path):
    st = HarnessStore(tmp_path)
    saved, errors = st.upsert_design(DOC)
    assert errors == [] and saved["version"] == 1
    assert st.upsert_design(DOC)[0]["version"] == 2
    assert [d["id"] for d in st.list_designs()] == ["mine"] and st.get("mine")["name"] == "Mine"


def test_builtin_ids_cannot_be_overwritten_or_deleted(tmp_path):
    st = HarnessStore(tmp_path)
    _, errors = st.upsert_design({**DOC, "id": "single"})
    assert errors and "built-in" in errors[0]["message"]
    assert st.delete_design("single") is False


def test_invalid_design_is_rejected(tmp_path):
    saved, errors = HarnessStore(tmp_path).upsert_design({"id": "bad", "nodes": [], "edges": []})
    assert saved is None and errors


def test_assignments_default_set_and_reset_on_delete(tmp_path):
    st = HarnessStore(tmp_path)
    assert st.get_assignments() == DEFAULT_ASSIGNMENTS
    assert st.set_assignment("chat", "router") is True and st.get_assignments()["chat"] == "router"
    assert st.set_assignment("chat", "nope") is False and st.set_assignment("toaster", "router") is False
    st.upsert_design(DOC)
    st.set_assignment("voice", "mine")
    st.delete_design("mine")
    assert st.get_assignments()["voice"] == DEFAULT_ASSIGNMENTS["voice"]


def test_corrupt_file_reads_as_empty(tmp_path):
    st = HarnessStore(tmp_path)
    st._designs_dir.mkdir(parents=True)
    (st._designs_dir / "x.json").write_text("{not json")
    assert st.list_designs() == []


def test_all_harnesses_reports_problems(tmp_path):
    st = HarnessStore(tmp_path)
    st._designs_dir.mkdir(parents=True)
    (st._designs_dir / "broken.json").write_text('{"id": "broken", "nodes": [], "edges": []}')
    broken = next(h for h in st.all_harnesses() if h["id"] == "broken")
    assert broken["problems"]


def test_unsafe_id_is_not_read(tmp_path):
    assert HarnessStore(tmp_path).get("../etc/passwd") is None
