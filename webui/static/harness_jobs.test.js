'use strict';
// node --test webui/static/harness_jobs.test.js
//
// The background-job card under a reply (harness Background jobs): how its
// clock, durations and one-line summaries read, and which state a stored card
// is really in once the server's live list is known.
const test = require('node:test');
const assert = require('node:assert/strict');
const J = require('./harness_jobs.js');

const card = (over = {}) => Object.assign({
  id: 'j1', node: 'bg', label: 'Long Running', model: '@anthropic-api:claude-sonnet-5-5',
  status: 'running', started_at: 1000, completed_at: null, steps: 0, activity: '',
}, over);

test('clock ticks as m:ss, then h:mm:ss', () => {
  assert.equal(J.clock(0), '0:00');
  assert.equal(J.clock(42.7), '0:42');
  assert.equal(J.clock(252), '4:12');
  assert.equal(J.clock(3909), '1:05:09');
  assert.equal(J.clock(-5), '0:00');
});

test('duration reads like speech', () => {
  assert.equal(J.duration(42), '42 s');
  assert.equal(J.duration(252), '4m 12s');
  assert.equal(J.duration(3900), '1h 05m');
});

test('a running card shows its step, model and clock', () => {
  const v = J.view(card({ steps: 6, activity: 'Searching the web' }), 1102);
  assert.equal(v.state, 'running');
  assert.equal(v.title, 'Long Running');
  assert.equal(v.model, 'Claude Sonnet 5.5');
  assert.equal(v.detail, 'Searching the web · step 6');
  assert.equal(v.clock, '1:42');
});

test('a running card with nothing to say yet is starting', () => {
  assert.equal(J.view(card(), 1001).detail, 'Starting');
});

test('ended cards collapse to one line', () => {
  assert.equal(J.view(card({ status: 'done', completed_at: 1252, steps: 18 }), 9999).line,
    'Long Running · finished in 4m 12s · 18 steps');
  assert.equal(J.view(card({ status: 'done', completed_at: 1001, steps: 1 }), 9999).line,
    'Long Running · finished in 1 s · 1 step');
  assert.equal(J.view(card({ status: 'failed', completed_at: 1063 }), 9999).line,
    "Long Running · couldn't finish (after 1m 03s)");
  assert.equal(J.view(card({ status: 'stopped', completed_at: 1130 }), 9999).line,
    'Long Running · stopped after 2m 10s');
  assert.equal(J.view(card({ status: 'lost' }), 9999).line,
    'Long Running · stopped when the server restarted');
});

test('resolve: an ended stored card is final, otherwise the live card wins', () => {
  const running = card();
  assert.equal(J.resolve(running, {}).status, 'running');                                   // nothing newer yet
  assert.equal(J.resolve(running, { j1: card({ status: 'done', completed_at: 1010 }) }).status, 'done');
  assert.equal(J.resolve(running, { j1: card({ status: 'lost' }) }).status, 'lost');          // the server said so
  // A stale live "running" (its end was missed while away) never beats the saved end.
  assert.equal(J.resolve(card({ status: 'done', completed_at: 1010 }), { j1: card({ steps: 3 }) }).status, 'done');
});

test('merge treats lost like an end', () => {
  const live = {};
  J.merge(live, card({ status: 'lost' }));
  J.merge(live, card({ steps: 2 }));
  assert.equal(live.j1.status, 'lost');
});

test('a failed catch-up waits before asking again (no request per re-render)', async () => {
  let calls = 0;
  globalThis.api = async () => { calls += 1; throw new Error('offline'); };
  try {
    await J.catchUp('s-fail');
    await J.catchUp('s-fail');
    assert.equal(calls, 1);
  } finally {
    delete globalThis.api;
  }
});

test('a late running update never revives an ended card', () => {
  const live = {};
  J.merge(live, card({ status: 'done', completed_at: 1010 }));
  J.merge(live, card({ steps: 9, activity: 'Writing the reply' }));
  assert.equal(live.j1.status, 'done');
  J.merge(live, card({ id: 'j2', steps: 1 }));
  J.merge(live, card({ id: 'j2', steps: 2 }));
  assert.equal(live.j2.steps, 2);
});

test('a card being stopped says so and offers no second Stop', () => {
  const html = J.cardHtml(card({ stopping: true, steps: 3, activity: 'Reading files' }), 1010);
  assert.match(html, /Stopping…/);
  assert.match(html, /disabled/);
});

test('cards render as one element each, ended ones without a Stop button', () => {
  const html = J.cardHtml(card({ steps: 2, activity: 'Reading web pages' }), 1010);
  assert.match(html, /data-job-id="j1"/);
  assert.match(html, /harness-job-stop/);
  assert.match(html, /Reading web pages · step 2/);
  const done = J.cardHtml(card({ status: 'done', completed_at: 1020 }), 1030);
  assert.doesNotMatch(done, /harness-job-stop/);
  assert.match(done, /finished in 20 s/);
  assert.doesNotMatch(J.cardHtml(card({ label: '<b>x</b>' }), 1000), /<b>x/);
});

// ── approvals on the card ────────────────────────────────────────────────
const waiting = (over = {}) => card({
  activity: 'Needs your approval', steps: 3, worker_session: 'chat~bg1',
  approval: Object.assign({ session_id: 'chat~bg1', approval_id: 'a1', fingerprint: 'f', kind: 'command',
                            command: 'rm -rf build', description: 'delete files', can_always: true }, over),
});

test('a card waiting on an approval offers Allow / Always / Deny', () => {
  const html = J.cardHtml(waiting(), 1010);
  assert.match(html, /harness-job-waiting/);
  assert.match(html, /data-job-approve="once"[^>]*>Allow</);
  assert.match(html, /data-job-approve="always"[^>]*>Always</);
  assert.match(html, /data-job-approve="deny"[^>]*>Deny</);
  assert.match(html, /rm -rf build/);
  assert.doesNotMatch(J.cardHtml(waiting({ can_always: false }), 1010), /data-job-approve="always"/);
});

test('a send waiting on a yes reads Send / Don\'t send, never Always', () => {
  const html = J.cardHtml(waiting({ kind: 'send', can_always: false, command: 'Text Mom: on my way' }), 1010);
  assert.match(html, />Send</);
  assert.match(html, />Don't send</);
  assert.match(html, /Text Mom: on my way/);
  assert.doesNotMatch(html, /data-job-approve="always"/);
});

test('an ended card never offers approval buttons, and every card opens its view', () => {
  const done = J.cardHtml(Object.assign(waiting(), { status: 'done', completed_at: 1020 }), 1030);
  assert.doesNotMatch(done, /data-job-approve/);
  assert.match(done, /data-job-open="j1"/);
  assert.match(J.cardHtml(card(), 1000), /data-job-open="j1"/);
});

test('answering hides the buttons at once; a failure brings them back', async () => {
  const sent = [];
  globalThis.api = async (url, opts) => { sent.push([url, JSON.parse(opts.body)]); };
  try {
    J.merge({}, waiting());
    await J.respond({ session_id: 'chat~bg1', approval_id: 'a1' }, 'once');
    assert.deepEqual(sent, [['api/approval/respond', { session_id: 'chat~bg1', choice: 'once', approval_id: 'a1' }]]);
    assert.equal(J.isAnswered('a1'), true);
    const html = J.cardHtml(waiting(), 1010);
    assert.doesNotMatch(html, /data-job-approve/);
    assert.match(html, /Working · step 3/);
    globalThis.api = async () => { throw new Error('offline'); };
    await assert.rejects(J.respond({ session_id: 'chat~bg1', approval_id: 'a2' }, 'deny'));
    assert.equal(J.isAnswered('a2'), false);
  } finally {
    delete globalThis.api;
  }
});

// ── the job's chat view: its stream as chat messages ─────────────────────
const V = require('./harness_job_view.js');

test('the stream becomes the chat\'s messages: text, thinking, tools, text after a tool', () => {
  const f = V.createFeed('Find flights');
  V.feedEvent(f, 'reasoning', { text: 'Let me ' });
  V.feedEvent(f, 'reasoning', { text: 'look.' });
  V.feedEvent(f, 'token', { text: 'Searching' });
  V.feedEvent(f, 'tool', { name: 'web_search', preview: 'flights', args: { q: 'flights' } });
  V.feedEvent(f, 'tool_snippet', { name: 'web_search', snippet: '3 results' });
  V.feedEvent(f, 'tool_complete', { name: 'web_search', duration: 1.2 });
  V.feedEvent(f, 'token', { text: 'Found 3.' });
  assert.deepEqual(f.messages.map(m => [m.role, m.content]),
    [['user', 'Find flights'], ['assistant', 'Searching'], ['assistant', 'Found 3.']]);
  assert.equal(f.messages[1].reasoning, 'Let me look.');
  assert.equal(f.messages[1].tool_calls.length, 1);
  assert.equal(f.toolCalls.length, 1);
  assert.equal(f.toolCalls[0].assistant_msg_idx, 1);
  assert.equal(f.toolCalls[0].done, true);
  assert.equal(f.toolCalls[0].snippet, '3 results');
});

test('an approval in the stream waits until the job moves on', () => {
  const f = V.createFeed('x');
  V.feedEvent(f, 'tool', { name: 'terminal' });
  V.feedEvent(f, 'approval', { approval_id: 'a9', command: 'ls', pattern_keys: ['ls'] });
  assert.equal(f.approval.approval_id, 'a9');
  assert.equal(V.canAlways(f.approval), true);
  V.feedEvent(f, 'tool_complete', { name: 'terminal' });
  assert.equal(f.approval, null);
  assert.equal(V.canAlways({ kind: 'send', pattern_keys: ['x'] }), false);
});

test('errors and cancels end the feed with a line like the chat\'s', () => {
  const f = V.createFeed('x');
  V.feedEvent(f, 'token', { text: 'Working' });
  V.feedEvent(f, 'apperror', { message: 'rate limited' });
  assert.equal(f.ended, true);
  assert.equal(f.messages[f.messages.length - 1].content, '**Error:** rate limited');
  const g = V.createFeed('x');
  V.feedEvent(g, 'tool', { name: 'terminal' });
  V.feedEvent(g, 'stream_end', {});
  assert.equal(g.ended, true);
  assert.equal(g.toolCalls[0].done, true);
});
