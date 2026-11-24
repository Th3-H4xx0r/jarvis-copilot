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


_PICKER_JS = r"""
const fs = require('fs'), vm = require('vm'), assert = require('assert/strict');
const [jmFile, croFile, immFile] = process.argv.slice(1);
const R = require(croFile);
const choices = {
  defaultModel: 'claude-sonnet-5-5',
  modelGroups: [{ label: 'Anthropic API', options: [{ value: '@anthropic-api:claude-haiku-5-5', label: 'Claude Haiku 5.5' }] }],
  harnesses: [{ id: 'fast', name: 'Fast' }],
};
let mapPayload = { agent: { harness_id: 'fast' }, label: 'Fast', backup: null, backup_label: '', paused: null };
const requests = [];
const body = { innerHTML: '', style: {}, listeners: {},
  querySelector(sel) {
    if (sel === '.imm') return {};
    if (sel === '#immModelSel' || sel === '#immBackupSel') return { addEventListener: (ev, fn) => { body.listeners[sel] = fn; } };
    return null;
  },
  querySelectorAll() { return []; } };
const window = { CronRunsOn: R };
const ctx = vm.createContext({
  window, CronRunsOn: R, console, setTimeout() {}, clearTimeout() {},
  document: { readyState: 'loading', addEventListener() {} },
  _cronRunsOnCtx: () => choices,
  fetch: async (url, init) => {
    requests.push([url, init && init.body ? JSON.parse(init.body) : null]);
    if (init && init.method === 'POST') mapPayload = Object.assign({}, mapPayload, JSON.parse(init.body));
    return { json: async () => mapPayload };
  },
  // the iMessage card's page globals
  $: id => (id === 'taskDetailBody' ? body : null),
  api: async () => card,
  esc: s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  _intgView: 'imessage-memory',
});
let card = { enabled: true, memory_active: true, mac_seen_at: 1, chats: [], skip: [], jobs: [],
  totals: { memories: 3, pending: 7 }, runs_on: 'Fast',
  paused: { model: 'GPT Luna', until: null, reason: 'limit', using: 'waiting', backup: '' } };
vm.runInContext(fs.readFileSync(jmFile, 'utf8'), ctx);
vm.runInContext(fs.readFileSync(immFile, 'utf8'), ctx);
const jm = window.JarvisMemory;

// The two selects: the memory model can be Same as Default, a backup never is.
const html = jm.modelPickerHtml(mapPayload, { prefix: 'imm', rowClass: 'imm-row', selectClass: 'imm-input' });
const modelSel = html.slice(html.indexOf('id="immModelSel"'), html.indexOf('id="immBackupSel"'));
const backupSel = html.slice(html.indexOf('id="immBackupSel"'));
assert.match(html, /<div class="imm-row"><label for="immModelSel">Memory model<\/label><select id="immModelSel" class="imm-input">/);
assert.match(html, /<label for="immBackupSel">While it&#39;s at its limit, use<\/label>/);
assert.ok(modelSel.includes('value="default"'));
assert.match(modelSel, /value="harness:fast" selected/);
assert.match(backupSel, /^id="immBackupSel" class="imm-input"><option value="none" selected>Nothing, wait for it<\/option>/);
assert.ok(!backupSel.includes('value="default"'), 'a backup is never Same as Default');
assert.ok(backupSel.includes('value="model:@anthropic-api:claude-haiku-5-5"') && backupSel.includes('value="harness:fast"'));
const picked = jm.modelPickerHtml({ agent: null, backup: { model: '@anthropic-api:claude-haiku-5-5', provider: null } }, {});
assert.match(picked, /<select id="jmemModelSel" style=/, 'Long-term Memory keeps its own look');
assert.match(picked, /<option value="none">Nothing, wait for it/);
assert.match(picked.slice(picked.indexOf('jmemBackupSel')), /value="model:@anthropic-api:claude-haiku-5-5" selected/);

(async () => {
  // The iMessage card: both selects, the footnote, the paused line with what's waiting.
  vm.runInContext('_immCard = null; _immMap = null;', ctx);
  await vm.runInContext('_immLoadMap()', ctx);
  vm.runInContext('_immCard = ' + JSON.stringify(card) + '; _immRender();', ctx);
  assert.ok(body.innerHTML.includes('id="immModelSel"') && body.innerHTML.includes('id="immBackupSel"'));
  assert.ok(body.innerHTML.includes('Also used for chat memories and the memory map.'));
  assert.ok(!body.innerHTML.includes('change it in Long-term Memory'));
  assert.ok(body.innerHTML.includes('GPT Luna is at its usage limit · memory waits, nothing is lost · 7 messages waiting'));

  // A pick POSTs map-settings, reads it again and redraws the card.
  requests.length = 0;
  card = Object.assign({}, card, { runs_on: 'Claude Haiku 5.5' });
  await body.listeners['#immBackupSel']({ target: { value: 'model:@anthropic-api:claude-haiku-5-5' } });
  assert.deepEqual(requests[0], ['api/jarvis-memory/map-settings',
    { backup: { model: '@anthropic-api:claude-haiku-5-5', provider: null } }]);
  assert.deepEqual(requests[1], ['api/jarvis-memory/map-settings', null], 'the setting is read again');
  assert.ok(body.innerHTML.includes('Runs on: Claude Haiku 5.5'), 'the card redrew');
  const redrawn = body.innerHTML.slice(body.innerHTML.indexOf('id="immBackupSel"'));
  assert.match(redrawn, /value="model:@anthropic-api:claude-haiku-5-5" selected/);
  requests.length = 0;
  await body.listeners['#immBackupSel']({ target: { value: 'none' } });
  await body.listeners['#immModelSel']({ target: { value: 'default' } });
  assert.deepEqual(requests.filter(r => r[1]).map(r => r[1]), [{ backup: null }, { agent: null }]);

  // No setting (an older server, a failed read): the card says where to change it.
  ctx.fetch = async () => { throw new Error('offline'); };
  assert.equal(await jm.loadMapSettings(), null);
  await vm.runInContext('_immLoadMap()', ctx);
  vm.runInContext('_immRender();', ctx);
  assert.ok(body.innerHTML.includes('Uses the memory model — change it in Long-term Memory.'));
  assert.ok(!body.innerHTML.includes('immModelSel'));
})().catch(e => { console.error(e); process.exit(1); });
"""


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_memory_model_pickers_on_long_term_memory_and_the_imessage_card():
    result = subprocess.run(["node", "-e", _PICKER_JS, str(STATIC / "jarvis_memory.js"),
                             str(STATIC / "cron_runs_on.js"), str(STATIC / "imessage_memory.js")],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


def test_the_pickers_are_shared_not_copied():
    js = _read("jarvis_memory.js")
    for name in ("pausedLine: pausedLine", "loadMapSettings: loadMapSettings",
                 "modelPickerHtml: modelPickerHtml", "bindModelPicker: bindModelPicker"):
        assert name in js, name
    load = js[js.index("async function loadModel("):js.index("// ── Cleanup & map")]
    assert "modelPickerHtml(d, {" in load and 'bindModelPicker(el, "jmem", loadModel)' in load
    assert "pausedLine(d.paused)" in load
    imm = _read("imessage_memory.js")
    assert "jm.modelPickerHtml(_immMap" in imm and "jm.bindModelPicker(body, 'imm', _immModelSaved)" in imm
    assert "Promise.all([api('/api/imessage-memory'), _immLoadMap()])" in imm
    for quote in ("'", '"', "`"):
        assert quote + "api/jarvis-memory/map-settings" not in imm, "the iMessage card posts through jarvis_memory.js"


def test_imessage_card_shows_the_paused_line_and_already_remembered():
    js = _read("imessage_memory.js")
    assert "jm.pausedLine(c.paused, { pending: c.totals && c.totals.pending })" in js
    foot = js.index("Also used for chat memories and the memory map.")
    assert "${paused ?" in js[foot:foot + 300]
    # Backfill "skipped" = already covered by an earlier conversation, not dropped.
    assert js.count("already remembered") >= 2
    assert "skipped}</span>" not in js and ".skipped} skipped" not in js
