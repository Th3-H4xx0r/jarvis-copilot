'use strict';
// node --test webui/static/cron_runs_on.test.js
//
// The schedule form's "Runs on" choice: Default, a model or a harness. Pure
// value/label/option logic; no DOM.
const test = require('node:test');
const assert = require('node:assert/strict');
const R = require('./cron_runs_on.js');

const ctx = {
  defaultModel: 'claude-sonnet-5-5',
  modelGroups: [
    { label: 'Anthropic API', options: [{ value: '@anthropic-api:claude-haiku-5-5', label: 'Claude Haiku 5.5' }] },
    { label: 'Ollama Cloud', options: [{ value: '@ollama-cloud:gemma4:31b', label: 'gemma4:31b' }] },
  ],
  harnesses: [{ id: 'mail', name: 'Mail triage', icon: '📬' }],
  t: key => key,  // untranslated keys fall back to English
};

test('value for each kind of job', () => {
  assert.equal(R.valueFor({}), 'default');
  assert.equal(R.valueFor({ harness_id: 'mail' }), 'harness:mail');
  assert.equal(R.valueFor({ model: 'gemma4:31b', provider: 'ollama-cloud' }), 'model:@ollama-cloud:gemma4:31b');
  assert.equal(R.valueFor({ model: 'bare-model' }), 'model:bare-model');
  assert.equal(R.valueFor({ runs_on: { value: 'harness:x' }, model: 'ignored' }), 'harness:x');
});

test('the body sends all three fields so a change clears the others', () => {
  assert.deepEqual(R.body('default'), { model: '', provider: '', harness_id: '' });
  assert.deepEqual(R.body('harness:mail'), { model: '', provider: '', harness_id: 'mail' });
  assert.deepEqual(R.body('model:@ollama-cloud:gemma4:31b'),
    { model: '@ollama-cloud:gemma4:31b', provider: '', harness_id: '' });
  assert.deepEqual(R.body(''), R.body('default'));
});

test('options: default with the server model, model groups, harnesses, selection', () => {
  const html = R.optionsHtml('harness:mail', ctx);
  assert.match(html, /<option value="default">Default \(claude-sonnet-5-5\)<\/option>/);
  assert.match(html, /<optgroup label="Models · Anthropic API">/);
  assert.match(html, /value="model:@ollama-cloud:gemma4:31b">gemma4:31b</);
  assert.match(html, /<optgroup label="Harnesses"><option value="harness:mail" selected>📬 Mail triage</);
  assert.equal((html.match(/ selected/g) || []).length, 1);
});

test('an unknown current value is kept as its own option', () => {
  const html = R.optionsHtml('harness:gone', Object.assign({ currentRunsOn: { value: 'harness:gone', label: 'gone', missing: true } }, ctx));
  assert.match(html, /<option value="harness:gone" selected>gone \(not found — runs on Default\) \(current\)<\/option>/);
  const model = R.optionsHtml('model:@x:y', ctx);
  assert.match(model, /<option value="model:@x:y" selected>y \(current\)<\/option>/);
});

test('labels for the detail view and the integration badge', () => {
  assert.equal(R.label({}, ctx), 'Default');
  assert.equal(R.label({ harness_id: 'mail' }, ctx), '📬 Mail triage');
  assert.equal(R.label({ runs_on: { kind: 'harness', value: 'harness:gone', label: 'gone', missing: true } }, ctx),
    'gone (not found — runs on Default)');
  assert.equal(R.label({ model: 'claude-haiku-5-5', provider: 'anthropic-api' }, ctx), 'Claude Haiku 5.5');
  assert.equal(R.label({ model: 'other', provider: 'p' }, {}), 'other');
});

test('escapes names', () => {
  const html = R.optionsHtml('default', { harnesses: [{ id: 'h', name: '<b>x</b>' }] });
  assert.ok(!html.includes('<b>x</b>') && html.includes('&lt;b&gt;x&lt;/b&gt;'));
});
