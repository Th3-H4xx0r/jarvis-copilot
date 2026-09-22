'use strict';
// node --test webui/static/live_labels.test.js
//
// Pure-logic tests for the Live Jarvis speaker-label store. No DOM, no fetch,
// no EventSource — the same arrangement as sse_parse.test.js next door.
//
// What these exist to protect: a `speaker` frame must relabel utterances that
// are already on screen, retroactively for a merge, without a reload. That is
// invisible to a screenshot, so it is pinned here.
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createLabelStore, formatBytes, formatDuration, formatSegmentTime, formatElapsed,
} = require('./live_labels.js');

function seg(over) {
  return Object.assign({
    live_session_id: 'ls1', seq: 1, ts_start_ms: 0, ts_end_ms: 1000,
    speaker_id: null, speaker_conf: null, label_state: 'provisional',
    local_label: null, text: 'hello', lang: 'en', translation: null,
    device_id: 'iphone', audio_ref: null,
  }, over || {});
}

// ── unnamed voices ──────────────────────────────────────────────────────────

test('an unnamed speaker renders as "Speaker N" in first-seen order', () => {
  const s = createLabelStore();
  const a = seg({ speaker_id: 'spk_a', label_state: 'confirmed' });
  const b = seg({ seq: 2, speaker_id: 'spk_b', label_state: 'confirmed' });
  s.noteSegment(a); s.noteSegment(b);
  assert.equal(s.labelFor(a).name, 'Speaker 1');
  assert.equal(s.labelFor(b).name, 'Speaker 2');
});

test('ordinals are stable across repeated lookups', () => {
  const s = createLabelStore();
  const a = seg({ speaker_id: 'spk_a' });
  const first = s.labelFor(a).name;
  s.noteSegment(seg({ speaker_id: 'spk_z' }));
  assert.equal(s.labelFor(a).name, first);
});

test('a segment with no speaker_id falls back to the device local label', () => {
  const s = createLabelStore();
  assert.equal(s.labelFor(seg({ local_label: 'me' })).name, 'Me');
  assert.equal(s.labelFor(seg({ local_label: 'local:3' })).name, 'Speaker 1');   // ours, not the device's index
  assert.equal(s.labelFor(seg({ local_label: null })).name, 'Unidentified');
});

// Regression: caught on screen in live_fixture.html before this existed. A
// device cluster "local:3" and the server's third voice both rendered as
// "Speaker 3" — two different people, one chip.
test('a device-local label never collides with a server voice ordinal', () => {
  const s = createLabelStore();
  const unresolved = seg({ seq: 3, speaker_id: null, local_label: 'local:3' });
  const resolved = seg({ seq: 4, speaker_id: 'spk_c', label_state: 'confirmed' });
  s.noteSegment(unresolved); s.noteSegment(resolved);
  const a = s.labelFor(unresolved).name, b = s.labelFor(resolved).name;
  assert.notEqual(a, b);
  assert.match(a, /^Speaker \d+$/);
  assert.match(b, /^Speaker \d+$/);
});

test('the same local index in two sessions is two different voices', () => {
  const s = createLabelStore();
  const one = seg({ live_session_id: 'lsA', local_label: 'local:2' });
  const two = seg({ live_session_id: 'lsB', local_label: 'local:2' });
  s.noteSegment(one); s.noteSegment(two);
  assert.notEqual(s.labelFor(one).name, s.labelFor(two).name);
});

test('a local label keeps its number as more voices appear', () => {
  const s = createLabelStore();
  const local = seg({ local_label: 'local:7' });
  const first = s.labelFor(local).name;
  s.noteSegment(seg({ speaker_id: 'x' }));
  s.noteSegment(seg({ speaker_id: 'y' }));
  assert.equal(s.labelFor(local).name, first);
});

test('label_state drives the provisional flag, and a missing id is always provisional', () => {
  const s = createLabelStore();
  assert.equal(s.labelFor(seg({ speaker_id: 'spk_a', label_state: 'confirmed' })).provisional, false);
  assert.equal(s.labelFor(seg({ speaker_id: 'spk_a', label_state: 'provisional' })).provisional, true);
  assert.equal(s.labelFor(seg({ speaker_id: null, label_state: 'confirmed' })).provisional, true);
});

// ── setSpeakers envelope tolerance ───────────────────────────────────────────

test('setSpeakers accepts a bare array or a {speakers:[…]} envelope', () => {
  const a = createLabelStore();
  assert.equal(a.setSpeakers([{ id: 'x', name: 'Ada' }]), 1);
  assert.equal(a.labelFor(seg({ speaker_id: 'x', label_state: 'confirmed' })).name, 'Ada');
  const b = createLabelStore();
  assert.equal(b.setSpeakers({ speakers: [{ id: 'x', name: 'Ada' }] }), 1);
  assert.equal(b.labelFor(seg({ speaker_id: 'x', label_state: 'confirmed' })).name, 'Ada');
  const c = createLabelStore();
  assert.equal(c.setSpeakers(null), 0);   // 404 / empty body must not throw
});

test('kind "me" with no name reads as Me', () => {
  const s = createLabelStore();
  s.setSpeakers([{ id: 'spk_me', kind: 'me', name: null }]);
  assert.equal(s.labelFor(seg({ speaker_id: 'spk_me', label_state: 'confirmed' })).name, 'Me');
});

// ── rename ──────────────────────────────────────────────────────────────────

test('op=rename relabels an already-rendered segment in place', () => {
  const s = createLabelStore();
  const old = seg({ speaker_id: 'spk_a', label_state: 'confirmed' });
  s.noteSegment(old);
  assert.equal(s.labelFor(old).name, 'Speaker 1');
  const change = s.applySpeakerEvent({ op: 'rename', speaker_id: 'spk_a', name: 'Priya' });
  assert.deepEqual(change.ids, ['spk_a']);
  assert.equal(s.labelFor(old).name, 'Priya');
});

test('a rename to empty falls back to the ordinal rather than a blank chip', () => {
  const s = createLabelStore();
  const x = seg({ speaker_id: 'spk_a', label_state: 'confirmed' });
  s.applySpeakerEvent({ op: 'rename', speaker_id: 'spk_a', name: 'Priya' });
  s.applySpeakerEvent({ op: 'rename', speaker_id: 'spk_a', name: '' });
  assert.equal(s.labelFor(x).name, 'Speaker 1');
});

// ── merge: the retroactive case ──────────────────────────────────────────────

test('op=merge retroactively relabels segments still carrying the dead id', () => {
  const s = createLabelStore();
  s.setSpeakers([{ id: 'spk_a', name: 'Priya' }, { id: 'spk_b', name: null }]);
  const older = seg({ seq: 1, speaker_id: 'spk_b', label_state: 'confirmed' });
  assert.equal(s.labelFor(older).name, 'Speaker 2');
  const change = s.applySpeakerEvent({ op: 'merge', from_id: 'spk_b', into_id: 'spk_a' });
  assert.equal(change.op, 'merge');
  assert.deepEqual(change.ids, ['spk_b', 'spk_a']);   // both repaint
  // The segment object is untouched, yet reads as Priya — that is what makes
  // the merge retroactive without rewriting the transcript.
  assert.equal(older.speaker_id, 'spk_b');
  assert.equal(s.labelFor(older).name, 'Priya');
});

test('a straggler segment arriving with the dead id still reads as the survivor', () => {
  const s = createLabelStore();
  s.setSpeakers([{ id: 'spk_a', name: 'Priya' }]);
  s.merge('spk_b', 'spk_a');
  const late = seg({ seq: 99, speaker_id: 'spk_b', label_state: 'confirmed' });
  assert.equal(s.labelFor(late).name, 'Priya');
});

test('merges chain transitively (c→b, b→a all read as a)', () => {
  const s = createLabelStore();
  s.setSpeakers([{ id: 'a', name: 'Ada' }]);
  s.merge('c', 'b');
  s.merge('b', 'a');
  assert.equal(s.canonical('c'), 'a');
  assert.equal(s.labelFor(seg({ speaker_id: 'c', label_state: 'confirmed' })).name, 'Ada');
});

test('a merge cycle degrades instead of hanging', () => {
  const s = createLabelStore();
  s.merge('a', 'b');
  s.merge('b', 'a');
  const got = s.canonical('a');
  assert.ok(got === 'a' || got === 'b');
});

test('the human name survives a merge even when it was on the dead id', () => {
  const s = createLabelStore();
  s.setSpeakers([{ id: 'spk_a', name: null }, { id: 'spk_b', name: 'Priya' }]);
  s.merge('spk_b', 'spk_a');
  assert.equal(s.labelFor(seg({ speaker_id: 'spk_a', label_state: 'confirmed' })).name, 'Priya');
});

test('a merge sums the absorbed counters and drops the dead row', () => {
  const s = createLabelStore();
  s.setSpeakers([
    { id: 'spk_a', name: 'Ada', segment_count: 4, speech_ms: 4000, last_heard_at: 10 },
    { id: 'spk_b', name: null, segment_count: 3, speech_ms: 1500, last_heard_at: 20 },
  ]);
  s.merge('spk_b', 'spk_a');
  const a = s.getSpeaker('spk_a');
  assert.equal(a.segment_count, 7);
  assert.equal(a.speech_ms, 5500);
  assert.equal(a.last_heard_at, 20);
  assert.equal(s.listSpeakers().length, 1);
  assert.equal(s.getSpeaker('spk_b').id, 'spk_a');   // resolves through the alias
});

// Regression: caught in live_fixture.html. A /speakers response that still
// listed the merged-away voice overwrote the SURVIVOR's kind, counters and
// samples, so "Me" turned back into "Speaker 1".
test('a stale row for a merged-away id does not overwrite the survivor', () => {
  const s = createLabelStore();
  s.setSpeakers([
    { id: 'spk_a', kind: 'me', name: null, segment_count: 412, speech_ms: 1920000 },
    { id: 'spk_c', kind: 'other', name: null, segment_count: 6, speech_ms: 21000 },
  ]);
  s.merge('spk_c', 'spk_a');
  // The refetch has not caught up and still carries spk_c.
  s.setSpeakers([
    { id: 'spk_a', kind: 'me', name: null, segment_count: 418, speech_ms: 1941000 },
    { id: 'spk_c', kind: 'other', name: null, segment_count: 6, speech_ms: 21000 },
  ]);
  const a = s.getSpeaker('spk_a');
  assert.equal(a.kind, 'me');
  assert.equal(a.segment_count, 418);
  assert.equal(s.labelFor(seg({ speaker_id: 'spk_a', label_state: 'confirmed' })).name, 'Me');
  assert.equal(s.listSpeakers().length, 1);
});

test('a stale row may still contribute a name the survivor is missing', () => {
  const s = createLabelStore();
  s.setSpeakers([{ id: 'a', name: null }, { id: 'b', name: null }]);
  s.merge('b', 'a');
  s.setSpeakers([{ id: 'b', name: 'Priya' }]);
  assert.equal(s.labelFor(seg({ speaker_id: 'a', label_state: 'confirmed' })).name, 'Priya');
});

test('a retired ordinal is never handed to a different voice', () => {
  const s = createLabelStore();
  s.noteSegment(seg({ speaker_id: 'one' }));     // Speaker 1
  s.noteSegment(seg({ speaker_id: 'two' }));     // Speaker 2
  s.merge('two', 'one');
  s.noteSegment(seg({ speaker_id: 'three' }));
  assert.equal(s.labelFor(seg({ speaker_id: 'three', label_state: 'confirmed' })).name, 'Speaker 3');
});

test('merging a voice into itself is a no-op', () => {
  const s = createLabelStore();
  s.setSpeakers([{ id: 'a', name: 'Ada', segment_count: 2 }]);
  s.merge('a', 'a');
  assert.equal(s.getSpeaker('a').segment_count, 2);
  assert.equal(s.labelFor(seg({ speaker_id: 'a', label_state: 'confirmed' })).name, 'Ada');
});

// ── confirm ─────────────────────────────────────────────────────────────────

test('op=confirm reports the segments to repaint, single or batched', () => {
  const s = createLabelStore();
  const one = s.applySpeakerEvent({ op: 'confirm', speaker_id: 'a', seq: 7 });
  assert.deepEqual(one.segSeqs, [7]);
  const many = s.applySpeakerEvent({ op: 'confirm', speaker_id: 'a', seqs: [1, 2, 3] });
  assert.deepEqual(many.segSeqs, [1, 2, 3]);
});

// Regression: caught in live_fixture.html. A confirm frame with no name in it
// blanked a name the user had just typed, because the undefined was copied
// over the stored value.
test('op=confirm without a name leaves an existing name alone', () => {
  const s = createLabelStore();
  s.applySpeakerEvent({ op: 'rename', speaker_id: 'a', name: 'Priya' });
  s.applySpeakerEvent({ op: 'confirm', speaker_id: 'a', seq: 2, speaker_conf: 0.97 });
  assert.equal(s.labelFor(seg({ speaker_id: 'a', label_state: 'confirmed' })).name, 'Priya');
});

test('upsertSpeaker does not blank fields it was not given', () => {
  const s = createLabelStore();
  s.upsertSpeaker({ id: 'a', name: 'Ada', kind: 'other', speech_ms: 100 });
  s.upsertSpeaker({ id: 'a', last_heard_at: 5 });
  const row = s.getSpeaker('a');
  assert.equal(row.name, 'Ada');
  assert.equal(row.speech_ms, 100);
  assert.equal(row.last_heard_at, 5);
});

test('op=confirm carrying a name applies it too', () => {
  const s = createLabelStore();
  s.applySpeakerEvent({ op: 'confirm', speaker_id: 'a', name: 'Sam', seq: 1 });
  assert.equal(s.labelFor(seg({ speaker_id: 'a', label_state: 'confirmed' })).name, 'Sam');
});

test('an unknown op is reported without throwing', () => {
  const s = createLabelStore();
  const change = s.applySpeakerEvent({ op: 'somethingelse' });
  assert.equal(change.op, 'somethingelse');
  assert.deepEqual(change.segSeqs, []);
  assert.deepEqual(s.applySpeakerEvent(null).segSeqs, []);
});

// ── retagSegments ───────────────────────────────────────────────────────────

test('retagSegments rewrites only the dead id', () => {
  const s = createLabelStore();
  const segs = [seg({ seq: 1, speaker_id: 'b' }), seg({ seq: 2, speaker_id: 'c' }), seg({ seq: 3, speaker_id: 'b' })];
  assert.equal(s.retagSegments(segs, 'b', 'a'), 2);
  assert.deepEqual(segs.map(x => x.speaker_id), ['a', 'c', 'a']);
  assert.equal(s.retagSegments(segs, 'a', 'a'), 0);
  assert.equal(s.retagSegments(null, 'a', 'b'), 0);
});

// ── formatting ──────────────────────────────────────────────────────────────

test('formatBytes scales and keeps the unit readable', () => {
  assert.equal(formatBytes(0), '0 B');
  assert.equal(formatBytes(512), '512 B');
  assert.equal(formatBytes(1024), '1.00 KB');
  assert.equal(formatBytes(1536), '1.50 KB');
  assert.equal(formatBytes(11 * 1024 * 1024), '11.0 MB');
  assert.equal(formatBytes(150 * 1024 * 1024), '150 MB');
});

test('formatDuration reads as speech time, not milliseconds', () => {
  assert.equal(formatDuration(0), '0s');
  assert.equal(formatDuration(45000), '45s');
  assert.equal(formatDuration(90000), '1m 30s');
  assert.equal(formatDuration(3720000), '1h 02m');
});

test('formatSegmentTime treats a large value as a wall clock and a small one as an offset', () => {
  // Session-relative: 65s into the session, no session start known.
  assert.equal(formatSegmentTime(65000, 0), '01:05');
  // Session-relative with a known start resolves to a real clock time.
  const start = new Date(2026, 8, 21, 14, 30, 0).getTime() / 1000;
  assert.equal(formatSegmentTime(65000, start), '14:31:05');
  // Epoch-ms input is a wall clock regardless of the session start.
  const epochMs = new Date(2026, 8, 21, 9, 5, 7).getTime();
  assert.equal(formatSegmentTime(epochMs, start), '09:05:07');
});

test('formatElapsed grows an hours field only when needed', () => {
  assert.equal(formatElapsed(0), '00:00');
  assert.equal(formatElapsed(59000), '00:59');
  assert.equal(formatElapsed(3600000), '1:00:00');
});
