// webui/static/live_labels.js
//
// The speaker-identity bookkeeping behind the Live Jarvis transcript, pulled
// out of live.js so it can be exercised with plain `node --test` (no DOM, no
// fetch, no EventSource) — same arrangement as sse_parse.js next door.
//
// Why this is its own file: provisional → confirmed relabelling is the one
// part of the live view that cannot be checked by looking at a screenshot. A
// `speaker` frame with op=merge has to relabel utterances that were painted
// minutes ago, including ones whose stored speaker_id is now a dead id, and it
// has to do it without a reload. That is logic, so it gets tests.
//
// The model:
//   - speaker.id is the identity; speaker.name is a mutable label on it
//     (§3 of the design). A rename therefore touches one row here too.
//   - a merge does NOT rewrite the segments we already hold. It records an
//     alias from_id → into_id, and every lookup resolves through the alias
//     chain. That is what makes a merge retroactive for free, and it also
//     survives a straggler `seg` frame that still carries the dead id.
//   - an unnamed voice is shown as "Speaker N". N is assigned on first sight
//     and never reused, so a name never shifts from under the reader's eyes.
//
// Usage:
//   const store = JCLiveLabels.createLabelStore();
//   store.setSpeakers(await api('/api/live/speakers'));
//   store.noteSegment(seg);
//   const { name, provisional } = store.labelFor(seg);
//   store.merge('spk_b', 'spk_a');   // now labelFor() on old segs returns A
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.JCLiveLabels = factory();
  }
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function createLabelStore() {
    const speakers = new Map();   // canonical id → speaker row
    const alias = new Map();      // dead id → id it was merged into
    const ordinals = new Map();   // canonical id → N for "Speaker N"
    let nextOrdinal = 1;

    // Follow the alias chain to the surviving id. Bounded so a server bug that
    // reports a cycle (a→b, b→a) degrades to "pick one" instead of hanging the
    // render loop.
    function canonical(id) {
      if (!id) return null;
      let cur = String(id);
      for (let hops = 0; hops < 32; hops++) {
        const next = alias.get(cur);
        if (!next || next === cur) return cur;
        cur = next;
      }
      return cur;
    }

    // "Speaker N" numbering. Server ids and the devices' own provisional
    // labels share ONE counter, because they share one screen: if the device
    // says "local:3" and the server independently hands its third voice the
    // ordinal 3, two different people both render as "Speaker 3". Keying both
    // kinds into the same space makes that impossible by construction. The
    // number shown is therefore ours, not the device's — the device's local
    // numbering is not surfaced anywhere else, so nothing contradicts it.
    function ordinal(key) {
      const k = String(key || '');
      if (!k) return null;
      if (!ordinals.has(k)) ordinals.set(k, nextOrdinal++);
      return ordinals.get(k);
    }

    function ordinalForSpeaker(id) {
      const cid = canonical(id);
      return cid ? ordinal(cid) : null;
    }

    // A device's provisional cluster is only meaningful inside its own live
    // session — "local:2" in two sessions is two different people — so the
    // session id is part of the key.
    function localKey(seg) {
      return 'local:' + String((seg && seg.live_session_id) || '') + ':' + String((seg && seg.local_label) || '');
    }

    function upsertSpeaker(row) {
      if (!row || !row.id) return;
      const cid = canonical(row.id);
      // A row for an id that has been merged away is stale by definition — a
      // /speakers response that was in flight when the merge landed, or a
      // client that has not refetched. Writing it through would overwrite the
      // SURVIVING voice with the dead one's kind, counters and samples, which
      // is exactly how "Me" turned back into "Speaker 1" on screen. Take only
      // a name the survivor is missing, and drop the rest.
      if (cid !== String(row.id)) {
        const survivor = speakers.get(cid);
        if (survivor && !survivor.name && row.name) { survivor.name = row.name; speakers.set(cid, survivor); }
        return;
      }
      const merged = Object.assign({}, speakers.get(cid) || {});
      // Copy only the fields actually supplied. Object.assign happily writes an
      // explicit `undefined` over a real value, which is how a `confirm` frame
      // that carries no name once erased a name the user had just typed.
      for (const [k, v] of Object.entries(row)) if (v !== undefined) merged[k] = v;
      merged.id = cid;
      speakers.set(cid, merged);
      ordinal(cid);   // claim an ordinal in first-seen order
    }

    // Accepts either the raw array or the {speakers:[...]} envelope, because
    // the server-side shape of GET /api/live/speakers is not pinned down in
    // the spec and a wrong guess here would blank the whole view.
    function setSpeakers(payload) {
      const list = Array.isArray(payload)
        ? payload
        : (payload && (payload.speakers || payload.items || payload.rows)) || [];
      for (const row of list) upsertSpeaker(row);
      return list.length;
    }

    function getSpeaker(id) {
      return speakers.get(canonical(id)) || null;
    }

    function rename(id, name) {
      const cid = canonical(id);
      if (!cid) return false;
      const row = speakers.get(cid) || { id: cid, kind: 'other' };
      row.name = name || null;
      speakers.set(cid, row);
      ordinal(cid);
      return true;
    }

    // from_id stops existing; into_id absorbs its counters. Returns the id that
    // survived so the caller can repaint chips for it.
    function merge(fromId, intoId) {
      const from = canonical(fromId), into = canonical(intoId);
      if (!from || !into || from === into) return into || null;
      alias.set(from, into);
      const src = speakers.get(from), dst = speakers.get(into) || { id: into, kind: 'other' };
      if (src) {
        // A merged-away voice may be the one that carried the human name, so
        // keep whichever name exists rather than blindly preferring the target.
        if (!dst.name && src.name) dst.name = src.name;
        if (src.kind === 'me') dst.kind = 'me';
        dst.segment_count = (dst.segment_count || 0) + (src.segment_count || 0);
        dst.speech_ms = (dst.speech_ms || 0) + (src.speech_ms || 0);
        if ((src.last_heard_at || 0) > (dst.last_heard_at || 0)) dst.last_heard_at = src.last_heard_at;
        speakers.delete(from);
      }
      speakers.set(into, dst);
      // The target keeps its own ordinal; the source's is retired, never
      // recycled, so "Speaker 4" can't later mean somebody else.
      ordinals.delete(from);
      ordinal(into);
      return into;
    }

    // Register ids seen only in the transcript. Without this, a voice the
    // /speakers call has not caught up with would have no ordinal and render
    // as "Speaker null".
    function noteSegment(seg) {
      if (!seg) return;
      const cid = canonical(seg.speaker_id);
      if (cid && !speakers.has(cid)) upsertSpeaker({ id: cid, kind: 'other', name: null });
      else if (cid) ordinal(cid);
      // Claim the counter for a device-local cluster too, in first-seen order,
      // so the numbering follows the transcript rather than the order the
      // /speakers call happened to return.
      else if (/^local:\d+$/.test(String(seg.local_label || ''))) ordinal(localKey(seg));
    }

    // What the chip on a segment should read, and whether it should be marked
    // as not-yet-settled.
    //
    // provisional is true whenever the label could still change: an explicit
    // label_state of "provisional", or no server-side speaker_id at all (the
    // device's own guess is all we have).
    function labelFor(seg) {
      const s = seg || {};
      const cid = canonical(s.speaker_id);
      const provisional = !cid || s.label_state !== 'confirmed';
      if (cid) {
        const row = speakers.get(cid);
        if (row && row.name) return { id: cid, name: row.name, provisional: provisional, kind: row.kind || 'other' };
        if (row && row.kind === 'me') return { id: cid, name: 'Me', provisional: provisional, kind: 'me' };
        return { id: cid, name: 'Speaker ' + ordinal(cid), provisional: provisional, kind: (row && row.kind) || 'other' };
      }
      // No server id yet — fall back to the device's provisional local label
      // ("me" or "local:3", §2.2). It is shown in the same "Speaker N" shape so
      // the chip does not visibly jump when the server resolves it; the
      // provisional marker is what tells the reader it is a guess. The number
      // comes from the shared ordinal counter, NOT from the device's own local
      // index, so it can never land on a number a server voice is already using.
      const local = String(s.local_label || '');
      if (local === 'me') return { id: null, name: 'Me', provisional: true, kind: 'me' };
      if (/^local:\d+$/.test(local)) {
        return { id: null, name: 'Speaker ' + ordinal(localKey(s)), provisional: true, kind: 'other' };
      }
      if (local) return { id: null, name: local, provisional: true, kind: 'other' };
      return { id: null, name: 'Unidentified', provisional: true, kind: 'other' };
    }

    // Apply a server `speaker` frame. Returns a description of what changed so
    // the view can repaint the minimum: {op, ids:[…], segSeqs:[…]}.
    //
    // op=confirm arrives in two shapes in practice — a whole voice becoming
    // confirmed, or specific segments being pinned to a voice — so both are
    // handled rather than guessing one.
    function applySpeakerEvent(ev) {
      const e = ev || {};
      const op = e.op || e.operation || '';
      if (op === 'rename') {
        const id = e.speaker_id || e.id;
        rename(id, e.name);
        return { op: 'rename', ids: [canonical(id)], segSeqs: [] };
      }
      if (op === 'merge') {
        const from = e.from_id || e.from, into = e.into_id || e.into;
        const survivor = merge(from, into);
        // Both ids are reported: chips still holding the dead id must repaint
        // too, which is the whole point of a retroactive merge.
        return { op: 'merge', ids: [String(from || ''), survivor].filter(Boolean), segSeqs: [] };
      }
      if (op === 'confirm') {
        const id = e.speaker_id || e.id;
        if (id) {
          upsertSpeaker({ id: canonical(id), kind: e.kind || undefined, name: e.name != null ? e.name : undefined });
          if (e.name != null) rename(id, e.name);
        }
        const seqs = [];
        if (Array.isArray(e.seqs)) for (const s of e.seqs) seqs.push(Number(s));
        else if (e.seq != null) seqs.push(Number(e.seq));
        return { op: 'confirm', ids: id ? [canonical(id)] : [], segSeqs: seqs };
      }
      return { op: op, ids: [], segSeqs: [] };
    }

    // A merge means every segment carrying the dead id now belongs to the
    // survivor. Callers hand in the segments they are holding; this rewrites
    // them in place so a later resync/append cannot resurrect the old label.
    function retagSegments(segs, deadId, survivorId) {
      const dead = String(deadId || ''), live = String(survivorId || '');
      if (!dead || !live || dead === live) return 0;
      let n = 0;
      for (const seg of (segs || [])) {
        if (seg && String(seg.speaker_id || '') === dead) { seg.speaker_id = live; n++; }
      }
      return n;
    }

    function listSpeakers() {
      return Array.from(speakers.values()).map(row =>
        Object.assign({}, row, { display: labelFor({ speaker_id: row.id, label_state: 'confirmed' }).name }));
    }

    return {
      setSpeakers: setSpeakers,
      upsertSpeaker: upsertSpeaker,
      getSpeaker: getSpeaker,
      listSpeakers: listSpeakers,
      canonical: canonical,
      ordinal: ordinalForSpeaker,
      rename: rename,
      merge: merge,
      noteSegment: noteSegment,
      labelFor: labelFor,
      applySpeakerEvent: applySpeakerEvent,
      retagSegments: retagSegments,
    };
  }

  // ── formatting shared by the transcript, speakers and storage views ───────

  function formatBytes(n) {
    const b = Number(n || 0);
    if (!isFinite(b) || b <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0, v = b;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    const digits = (i === 0 || v >= 100) ? 0 : (v >= 10 ? 1 : 2);
    return v.toFixed(digits) + ' ' + units[i];
  }

  function formatDuration(ms) {
    const total = Math.max(0, Math.round(Number(ms || 0) / 1000));
    const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
    if (h) return h + 'h ' + String(m).padStart(2, '0') + 'm';
    if (m) return m + 'm ' + String(s).padStart(2, '0') + 's';
    return s + 's';
  }

  // ts_start_ms is a device-supplied millisecond value and the protocol does
  // not say whether it is epoch or session-relative. Both happen: an iPhone
  // sending CMTime-derived offsets gives small numbers, a server-lane device
  // stamping Date.now() gives epoch. Anything past 2001 in epoch-ms is treated
  // as a wall clock; smaller values are treated as an offset from the session
  // start (and, if that is unknown, printed as an elapsed time).
  const EPOCH_MS_FLOOR = 1e12;

  function formatSegmentTime(tsMs, sessionStartedAtSec) {
    const ms = Number(tsMs || 0);
    if (ms >= EPOCH_MS_FLOOR) return formatClock(ms);
    const startSec = Number(sessionStartedAtSec || 0);
    if (startSec > 0) return formatClock(startSec * 1000 + ms);
    return formatElapsed(ms);
  }

  function formatClock(epochMs) {
    const d = new Date(epochMs);
    if (isNaN(d.getTime())) return '';
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0')
      + ':' + String(d.getSeconds()).padStart(2, '0');
  }

  function formatElapsed(ms) {
    const total = Math.max(0, Math.floor(Number(ms || 0) / 1000));
    const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
    const mm = String(m).padStart(2, '0'), ss = String(s).padStart(2, '0');
    return h ? (h + ':' + mm + ':' + ss) : (mm + ':' + ss);
  }

  return {
    createLabelStore: createLabelStore,
    formatBytes: formatBytes,
    formatDuration: formatDuration,
    formatSegmentTime: formatSegmentTime,
    formatClock: formatClock,
    formatElapsed: formatElapsed,
  };
});
