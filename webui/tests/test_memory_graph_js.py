"""Long-term Memory map (web): pure graph helpers + panel/chip wiring.

The graph logic (query building, load/expand/merge/cap, force step + settle,
view transform, recall matching for the chat chip) lives in
webui/static/memory_graph.js and is tested with node's built-in runner
(memory_graph.test.js); this wrapper shells out to `node --test`. The static
checks pin how the map, side panel, recalls list and chat chip are wired.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
STATIC = REPO_ROOT / "webui" / "static"
TEST_FILE = STATIC / "memory_graph.test.js"


def _read(name):
    return (STATIC / name).read_text(encoding="utf-8")


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_memory_graph_js_node_tests_pass():
    result = subprocess.run(
        ["node", "--test", str(TEST_FILE)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"node --test failed for memory_graph.test.js\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
@pytest.mark.parametrize("name", ["memory_graph.js", "memory_map.js", "jarvis_memory.js"])
def test_scripts_parse(name):
    result = subprocess.run(["node", "--check", str(STATIC / name)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr


def test_scripts_loaded_in_order():
    html = _read("index.html")
    graph = html.index("static/memory_graph.js?v=__WEBUI_VERSION__")
    mapjs = html.index("static/memory_map.js?v=__WEBUI_VERSION__")
    panel = html.index("static/jarvis_memory.js?v=__WEBUI_VERSION__")
    assert graph < mapjs < panel


def test_map_uses_the_contract_endpoints():
    js = _read("memory_map.js")
    for path in (
        "api/jarvis-memory/entity?id=",
        "api/jarvis-memory/entity/merge",
        "api/jarvis-memory/entity/unlink",
        "api/jarvis-memory/graph/highlight?recall=",
    ):
        assert path in js, path
    assert '"api/jarvis-memory/entity"' in js  # rename / aliases / pin
    assert "var G = window.MemoryGraph" in js
    assert "G.graphUrl(" in js
    assert "G.mergeGraph(" in js
    assert "function esc(" in js
    # The animation loop stops when settled and when the panel is hidden.
    assert "G.isSettled(" in js
    assert "cancelAnimationFrame" in js


def test_panel_has_map_list_switch_recalls_and_chat_chip():
    js = _read("jarvis_memory.js")
    assert "jmemViewMap" in js and "jmemViewList" in js
    assert "MemoryGraph.recallsUrl" in js
    assert "jmemRecalls" in js
    # Chat chip: one request per chat (cached), matched by user text, never breaks rendering.
    assert "MemoryGraph.matchRecalls" in js
    assert "jmem-recall-chip" in js
    assert "MutationObserver" in js


def test_review_fixes_are_wired():
    js = _read("memory_map.js")
    # Drags can't stick: non-primary mouse buttons ignored; every way a pointer ends, ends the drag.
    assert "G.acceptsPointer(e)" in js
    assert "G.tapSlop(e.pointerType)" in js
    for ev in ('"lostpointercapture"', '"contextmenu"', '"pointercancel"'):
        assert ev in js, ev
    # Late async results don't land on a reloaded map.
    assert js.count("seq === st.seq") + js.count("seq !== st.seq") >= 6
    # Phone width: the node panel becomes a sheet over the canvas.
    assert "(max-width: 730px)" in js and "layoutSide()" in js
    # Stale base graph reloads on show(); DPR changes are picked up; Escape + a focusable canvas.
    assert "G.isStale(st.loadedAt" in js
    assert "(resolution: " in js
    assert 'tabindex="0"' in js and '"Escape"' in js
    assert "G.memoriesHeading(" in js
    assert "under the current filters" not in js

    panel = _read("jarvis_memory.js")
    assert "MemoryGraph.chatSignature(msgs)" in panel
    assert "panelVisible()" in panel
    assert "MemoryMap.invalidate()" in panel
    open_recall = panel[panel.index("function openRecall("):panel.index("window.JarvisMemory =")]
    assert "window.loadJarvisMemory()" in open_recall
    assert "if (fresh)" not in open_recall
    assert "confirm(" not in panel


# The memory model's backup and its "paused" line (Long-term Memory + the
# iMessage card). pausedLine is run for real: the panel script loads under a
# stub document that never fires init, so only its pure helpers run.
_PAUSED_JS = r"""
const fs = require('fs'), vm = require('vm'), assert = require('assert/strict');
const window = {};
vm.runInNewContext(fs.readFileSync(process.argv[1], 'utf8'),
  { window, document: { readyState: 'loading', addEventListener() {} }, console });
const line = window.JarvisMemory.pausedLine;
const soon = Date.now() / 1000 + 3600;
assert.equal(line(null), '');
assert.equal(line(undefined), '');
const covered = line({ model: 'GPT Luna', until: soon, reason: 'limit', using: 'backup', backup: 'Claude Haiku 5.5' });
assert.ok(covered.startsWith('GPT Luna is at its usage limit until '), covered);
assert.ok(covered.endsWith(' · using Claude Haiku 5.5'), covered);
const waits = line({ model: 'GPT Luna', until: soon, reason: 'limit', using: 'waiting', backup: '' });
assert.ok(waits.endsWith(' · memory waits until then, nothing is lost'), waits);
assert.equal(line({ model: 'GPT Luna', until: null, reason: 'limit', using: 'waiting' }),
  'GPT Luna is at its usage limit · memory waits, nothing is lost');
assert.equal(line({ model: 'GPT Luna', until: null, reason: 'error', using: 'waiting' }),
  "GPT Luna isn't working right now · memory waits, nothing is lost");
const retry = line({ model: 'GPT Luna', until: soon, reason: 'error', using: 'backup', backup: 'Haiku' });
assert.ok(retry.startsWith("GPT Luna isn't working right now · trying again at "), retry);
assert.equal(line({ model: '', reason: 'limit', using: 'waiting' }, { pending: 1 }),
  'The memory model is at its usage limit · memory waits, nothing is lost · 1 message waiting');
assert.ok(line({ model: 'X', using: 'waiting' }, { pending: 5 }).endsWith(' · 5 messages waiting'));
assert.ok(!line({ model: 'X', using: 'waiting' }, { pending: 0 }).includes('waiting ·'));
"""


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_paused_line_wording():
    result = subprocess.run(["node", "-e", _PAUSED_JS, str(STATIC / "jarvis_memory.js")],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


def test_memory_model_has_a_backup_select():
    js = _read("jarvis_memory.js")
    load = js[js.index("async function loadModel("):js.index("// ── Cleanup & map")]
    assert 'id="jmemBackupSel"' in load and "While it\\'s at its limit, use" in load
    assert ">Nothing, wait for it</option>" in load
    # The model choices without Same as Default; "nothing" posts backup: null.
    assert "noDefault: true" in load
    assert "backup: v === BACKUP_NONE ? null : agentFrom(v)" in load
    assert "pausedLine(d.paused)" in load
    assert "pausedLine: pausedLine" in js


def test_imessage_card_shows_the_paused_line_and_already_remembered():
    js = _read("imessage_memory.js")
    assert "jm.pausedLine(c.paused, { pending: c.totals && c.totals.pending })" in js
    hint = js.index("Uses the memory model")
    assert "${paused ?" in js[hint:hint + 200]
    # Backfill "skipped" = already covered by an earlier conversation, not dropped.
    assert js.count("already remembered") >= 2
    assert "skipped}</span>" not in js and ".skipped} skipped" not in js
