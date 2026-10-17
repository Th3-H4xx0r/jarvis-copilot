// node --test webui/static/agents_panel.test.js
//
// The Agents panel (agents.js), driven in node.
//
// * Retry on a failed message: one that failed because its Mac was asleep must
//   not vanish when Retry is tapped while the session still can't take it —
//   nothing was sent, so the bubble stays, and a later Retry sends those words.
// * A session waiting on an approval or a question takes no message: it would
//   be typed into Claude's menu, and the Return picks the highlighted "Yes".
// * One session is never asked to continue twice at once (a row's Continue
//   while "Continue all" is on its way): two moves could start it twice.
//
// agents.js is an IIFE over the DOM; this drives it through its real entry
// points (window.loadAgents and the panel's delegated listeners) with just
// enough of a document for those paths.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(path.join(__dirname, 'agents.js'), 'utf8');

function conv(over) {
  return Object.assign({
    ckey: 'claude|s1', key: 'mac-1|claude|s1', agent: 'claude', session_id: 's1',
    title: 'Fix the router', project_id: 'p1', project: 'app', cwd: '/Users/p/app',
    owner: 'mac-1', owner_name: 'MacBook', status: 'live', state: 'idle',
    last_event_at: 1781000000, terminal_app: 'vscode', can_send: true, deliveries: [],
  }, over || {});
}
function listWith(c) {
  return { card: null, needs_you: [], projects: [{ id: 'p1', name: 'app', sessions: [c] }],
    usage: null, usage_codex: null, ts: 1781000000 };
}

function harness() {
  const handlers = {};
  const sends = [];
  const continues = [];
  const els = {};
  const state = { list: listWith(conv()), failNextSend: true };
  const root = {
    innerHTML: '',
    querySelector: () => null,
    addEventListener: (type, fn) => { handlers[type] = fn; },
    contains: () => false,
  };
  els.mainAgents = root;
  els.agentsInput = { value: '', disabled: false, id: 'agentsInput' };
  const document = {
    hidden: false,
    activeElement: null,
    getElementById: (id) => els[id] || null,
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener: () => {},
  };
  async function api(url, opts) {
    if (url.startsWith('/api/coding/agents/list')) return JSON.parse(JSON.stringify(state.list));
    if (url.startsWith('/api/coding/permission/pending')) return { pending: [] };
    if (url.startsWith('/api/coding/agents/messages')) return { messages: [], total: 0, start: 0 };
    if (url.startsWith('/api/coding/agents/continue')) {
      continues.push(JSON.parse(opts.body));
      return new Promise(() => {});          // still moving
    }
    if (url.startsWith('/api/coding/agents/send')) {
      const body = JSON.parse(opts.body);
      sends.push(body);
      if (state.failNextSend) {
        state.failNextSend = false;
        const err = new Error('HTTP 409');
        err.status = 409;
        err.body = JSON.stringify({ delivery: { id: 'd1', state: 'failed', reason: 'owner_offline' } });
        throw err;
      }
      return { delivery: { id: 'd2', state: 'sent' } };
    }
    return {};
  }
  const window = { localStorage: undefined };
  const sandbox = {
    window, document, api, location: { search: '' }, CSS: { escape: (s) => s },
    setTimeout: () => 0, clearTimeout: () => {}, console, URLSearchParams, JSON, Date, Math,
    Promise, Number, String, Array, Object, Set, Map, Error, encodeURIComponent,
  };
  vm.createContext(sandbox);
  vm.runInContext(SRC, sandbox);
  const settle = () => new Promise((r) => setImmediate(r));
  const click = async (dataset) => {
    const t = { disabled: false, dataset, closest: () => null, getAttribute: () => null };
    t.closest = (sel) => (sel === '[data-act]' ? t : null);
    handlers.click({ target: t });
    await settle(); await settle();
  };
  return { window, handlers, sends, continues, els, state, click, settle };
}

test('Retry while the Mac still sleeps keeps the message, and a later Retry sends it', async () => {
  const h = harness();
  await h.window.loadAgents();
  await h.click({ act: 'open', ckey: 'claude|s1' });

  // Send: the Mac is asleep by the time it lands, so it fails (owner_offline).
  h.els.agentsInput.value = 'run the tests';
  h.handlers.submit({ target: { id: 'agentsForm' }, preventDefault() {} });
  await h.settle(); await h.settle();
  assert.strictEqual(h.sends.length, 1);

  // The list now says the Mac is asleep: the session can't take a message.
  h.state.list = listWith(conv({ status: 'asleep', state: 'asleep', can_send: false, can_continue_server: true }));
  await h.window.loadAgents();
  await h.click({ act: 'retry-send', oid: '1' });
  assert.strictEqual(h.sends.length, 1, 'nothing can be sent while it sleeps');

  // The Mac is back: Retry on the same bubble sends the same words.
  h.state.list = listWith(conv());
  await h.window.loadAgents();
  await h.click({ act: 'retry-send', oid: '1' });
  assert.strictEqual(h.sends.length, 2, 'the failed message was dropped by the first Retry');
  assert.strictEqual(h.sends[1].text, 'run the tests');
  assert.strictEqual(h.sends[1].ckey, 'claude|s1');
});

test('A session waiting on an approval or a question takes no typed message', async () => {
  for (const state of ['approval', 'question']) {
    const h = harness();
    h.state.list = listWith(conv({ state, pending: { kind: state, fingerprint: 'fp1', tool: 'Bash',
      summary: 'Bash: rm -rf build' } }));
    await h.window.loadAgents();
    await h.click({ act: 'open', ckey: 'claude|s1' });
    h.els.agentsInput.value = 'no, stop';
    h.handlers.submit({ target: { id: 'agentsForm' }, preventDefault() {} });
    await h.settle(); await h.settle();
    assert.strictEqual(h.sends.length, 0, state + ': the message would be typed into its menu');
  }
});

test('A session already moving is not asked to continue again', async () => {
  const h = harness();
  const a = conv({ ckey: 'claude|a', session_id: 'a', status: 'asleep', state: 'asleep', can_send: false,
    can_continue_server: true });
  const b = conv({ ckey: 'claude|b', session_id: 'b', status: 'asleep', state: 'asleep', can_send: false,
    can_continue_server: true });
  h.state.list = { card: { device_id: 'mac-1', device_name: 'MacBook', kind: 'sleep', since: 1781000000,
    sessions: [{ ckey: 'claude|a', title: 'A', project: 'app', was: 'working', agent: 'claude' },
      { ckey: 'claude|b', title: 'B', project: 'app', was: 'idle', agent: 'claude' }] },
    needs_you: [], projects: [{ id: 'p1', name: 'app', sessions: [a, b] }], ts: 1781000000 };
  await h.window.loadAgents();
  await h.click({ act: 'continue', to: 'server', scope: 'card', name: 'MacBook', ckeys: 'claude|a,claude|b' });
  await h.click({ act: 'continue', to: 'server', scope: 'card', name: 'MacBook', ckeys: 'claude|a' });
  await h.click({ act: 'continue', to: 'server', scope: 'card', name: 'MacBook', ckeys: 'claude|b' });
  assert.strictEqual(h.continues.length, 1, 'a session on its way to the server was sent again');
  assert.deepStrictEqual(h.continues[0].ckeys, ['claude|a', 'claude|b']);
});
