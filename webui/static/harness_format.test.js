'use strict';
// node --test webui/static/harness_format.test.js
//
// The "answered by" line under assistant replies (agent harnesses). Pure
// formatting of the server's turn_meta / _meta dict; no DOM.
const test = require('node:test');
const assert = require('node:assert/strict');
const F = require('./harness_format.js');

test('answer with hand-off', () => {
  assert.equal(F.answeredBy({ model: '@ollama-cloud:gemma4:31b', ms: 900, handed_off: true, kind: 'answer' }),
    'gemma4:31b · 0.9 s · handed off');
});

test('background reply', () => {
  assert.equal(F.answeredBy({ model: '@claude-code:claude-sonnet-5-5', ms: 41000, kind: 'background' }),
    'Claude Sonnet 5.5 · background · 41 s');
});

test('review + note', () => {
  assert.equal(F.answeredBy({ model: 'x', kind: 'review', note: "harness 'q' not found" }),
    "x · review · harness 'q' not found");
});

test('empty meta', () => {
  assert.equal(F.answeredBy(null), '');
  assert.equal(F.answeredBy({}), '');
});

test('shortModel drops provider prefixes and keeps dotted Claude versions', () => {
  assert.equal(F.shortModel('anthropic/claude-sonnet-4.6'), 'Claude Sonnet 4.6');
  assert.equal(F.shortModel('claude-opus-4-6-20260101'), 'Claude Opus 4.6');
  assert.equal(F.shortModel('@openrouter:openai/gpt-4o'), 'gpt-4o');
  assert.equal(F.shortModel(''), '');
});

test('isSideReply flags background and review replies only', () => {
  assert.equal(F.isSideReply({ kind: 'background' }), true);
  assert.equal(F.isSideReply({ kind: 'review' }), true);
  assert.equal(F.isSideReply({ kind: 'answer' }), false);
  assert.equal(F.isSideReply(null), false);
});
