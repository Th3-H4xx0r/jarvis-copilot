'use strict';
// node --test webui/static/sse_parse.test.js
//
// Pure-logic tests for the extracted SSE line/record parser (review finding
// #3 on plan 5.1). No DOM/fetch/ReadableStream involved — feeds raw text
// chunks straight into createSSEStreamParser(), same as messages.js does
// after decoding bytes off the network.
const test = require('node:test');
const assert = require('node:assert/strict');
const { parseSSEBlock, createSSEStreamParser } = require('./sse_parse.js');

test('parseSSEBlock: multi-line data is newline-joined', () => {
  const r = parseSSEBlock('event: token\ndata: line one\ndata: line two\nid: 7');
  assert.equal(r.type, 'token');
  assert.equal(r.data, 'line one\nline two');
  assert.equal(r.id, '7');
  assert.equal(r.hasData, true);
});

test('parseSSEBlock: comment-only block has no data', () => {
  const r = parseSSEBlock(': keepalive');
  assert.equal(r.hasData, false);
});

test('parseSSEBlock: default event type is "message"', () => {
  const r = parseSSEBlock('data: hi');
  assert.equal(r.type, 'message');
  assert.equal(r.data, 'hi');
});

test('stream parser: a single chunk containing several records yields all of them in order', () => {
  const p = createSSEStreamParser();
  const events = p.push('event: start\ndata: {"a":1}\n\nevent: token\ndata: hello\n\n');
  assert.equal(events.length, 2);
  assert.equal(events[0].type, 'start');
  assert.equal(events[0].data, '{"a":1}');
  assert.equal(events[1].type, 'token');
  assert.equal(events[1].data, 'hello');
});

test('stream parser: a record split across chunks is only emitted once complete', () => {
  const p = createSSEStreamParser();
  let events = p.push('event: token\ndata: par');
  assert.equal(events.length, 0, 'incomplete record must not be emitted yet');
  events = p.push('tial\n\n');
  assert.equal(events.length, 1);
  assert.equal(events[0].data, 'partial');
});

test('stream parser: the blank-line separator itself split across chunks', () => {
  const p = createSSEStreamParser();
  let events = p.push('data: x\n');
  assert.equal(events.length, 0);
  events = p.push('\n');
  assert.equal(events.length, 1);
  assert.equal(events[0].data, 'x');
});

test('stream parser: multi-line data field split across chunks', () => {
  const p = createSSEStreamParser();
  let events = p.push('data: line one\ndata: li');
  assert.equal(events.length, 0);
  events = p.push('ne two\n\n');
  assert.equal(events.length, 1);
  assert.equal(events[0].data, 'line one\nline two');
});

test('stream parser: heartbeat comment lines between records are dropped, not surfaced', () => {
  const p = createSSEStreamParser();
  const events = p.push(': ping\n\ndata: real\n\n: ping again\n\n');
  assert.equal(events.length, 1);
  assert.equal(events[0].data, 'real');
});

test('stream parser: CRLF line endings and CRLF record separators both work', () => {
  const p = createSSEStreamParser();
  const events = p.push('event: token\r\ndata: hi\r\n\r\ndata: second\r\n\r\n');
  assert.equal(events.length, 2);
  assert.equal(events[0].type, 'token');
  assert.equal(events[0].data, 'hi');
  assert.equal(events[1].data, 'second');
});

test('stream parser: CRLF separator split exactly between the \\r\\n pairs', () => {
  const p = createSSEStreamParser();
  let events = p.push('data: x\r\n\r');
  assert.equal(events.length, 0, 'must wait for the rest of the CRLFCRLF separator');
  events = p.push('\n');
  assert.equal(events.length, 1);
  assert.equal(events[0].data, 'x');
});

test('stream parser: mixed LF and CRLF records across multiple push calls preserve order', () => {
  const p = createSSEStreamParser();
  const all = [];
  all.push.apply(all, p.push('data: one\n\n'));
  all.push.apply(all, p.push('data: two\r\n\r\n'));
  all.push.apply(all, p.push('data: thr'));
  all.push.apply(all, p.push('ee\n\n'));
  assert.deepEqual(all.map(e => e.data), ['one', 'two', 'three']);
});
