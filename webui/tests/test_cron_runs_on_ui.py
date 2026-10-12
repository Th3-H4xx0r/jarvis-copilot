"""The schedule form's "Runs on" picker (Tasks + Integrations), replacing the
per-job Profile select.

The value/label/option logic lives in webui/static/cron_runs_on.js and is tested
with node's built-in runner (cron_runs_on.test.js); the static checks pin how
panels.js / integrations.js use it.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


def _function_body(src: str, name: str) -> str:
    start = src.index(f"function {name}(")
    brace = src.index("{", src.index(")", start))
    depth = 0
    for idx in range(brace, len(src)):
        if src[idx] == "{":
            depth += 1
        elif src[idx] == "}":
            depth -= 1
            if depth == 0:
                return src[brace + 1:idx]
    raise AssertionError(f"{name} body did not terminate")


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_cron_runs_on_js_node_tests_pass():
    result = subprocess.run(["node", "--test", str(STATIC / "cron_runs_on.test.js")],
                            cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"


def test_script_loaded_before_panels_and_precached():
    html = _read("index.html")
    assert html.index("static/cron_runs_on.js") < html.index("static/panels.js")
    assert "'./static/cron_runs_on.js' + VQ" in _read("sw.js")


def test_form_has_runs_on_and_no_profile():
    panels = _read("panels.js")
    form = _function_body(panels, "_renderCronForm")
    assert 'id="cronFormRunsOn"' in form and "cron_runs_on_label" in form
    assert "CronRunsOn.optionsHtml" in form
    assert "cronFormProfile" not in panels and "_cronProfile" not in panels


def test_save_sends_runs_on_fields_on_create_and_update():
    save = _function_body(_read("panels.js"), "saveCronForm")
    assert save.count("CronRunsOn.body(") >= 1
    assert "Object.assign(updates, runsOn)" in save and "Object.assign(body, runsOn)" in save
    assert "profile" not in save


def test_choices_come_from_api_models_and_the_harness_list():
    panels = _read("panels.js")
    load = _function_body(panels, "loadCronRunsOnChoices")
    assert "/api/models" in load and "HarnessGraph.modelOptions" in load
    ctx = _function_body(panels, "_cronRunsOnCtx")
    assert "Harness.list()" in ctx


def test_detail_and_integration_badge_show_runs_on():
    detail = _function_body(_read("panels.js"), "_renderCronDetail")
    assert "cron_runs_on_label" in detail and "CronRunsOn.label" in detail
    assert "cron_profile_label" not in detail
    intg = _read("integrations.js")
    assert "_intgRunsOnBadge(s)" in intg and "cron-runs-on-badge" in intg
    assert "_cronProfile" not in intg and "_intgProfileBadge" not in intg
    css = _read("style.css")
    assert ".cron-runs-on-badge" in css and ".cron-profile-badge" not in css


def test_i18n_has_runs_on_in_every_locale_and_no_profile_keys():
    i18n = _read("i18n.js")
    assert "cron_profile_" not in i18n
    locales = len(re.findall(r"^  (?:[a-z]{2}|'[A-Za-z-]+'): \{", i18n, re.M))
    assert locales > 1
    for key in ("cron_runs_on_label", "cron_runs_on_default", "cron_runs_on_models",
                "cron_runs_on_harnesses", "cron_runs_on_hint", "cron_runs_on_missing"):
        assert len(re.findall(rf"^\s+{key}:", i18n, re.M)) == locales, key


def test_a_failed_model_load_is_not_cached():
    load = _function_body(_read("panels.js"), "loadCronRunsOnChoices")
    catch = load[load.index("catch"):]
    assert "_cronModelChoices =" not in catch
