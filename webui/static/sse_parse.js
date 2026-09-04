// webui/static/sse_parse.js
//
// Pure Server-Sent-Events line/record parser (review finding #3 on plan 5.1).
// Extracted out of messages.js's _makeFetchSSESource so the parsing logic can
// be exercised with plain `node --test` (no DOM/fetch/ReadableStream
// involved here) instead of only being covered indirectly through the
// fetch-based SSE shim. messages.js loads this the same way voice.js loads
// voice_endpoint.js: a dynamically-injected <script> tag next to its own
// script src (see _loadSSEParseModule() in messages.js), so no index.html
// edit is needed and no build step is introduced.
//
// Usage:
//   const parser = createSSEStreamParser();
//   const events = parser.push(chunkOfText);   // => [{type,data,id}, ...]
//   // call push() again for each subsequent chunk; state (partial records,
//   // CRLF vs LF) carries across calls.
//
// SSE record format (https://html.spec.whatwg.org/#server-sent-events):
//   - a record is a run of "field: value" lines terminated by a blank line
//     (record separator is "\n\n" or "\r\n\r\n" — both must be handled since
//     servers vary, and a chunk boundary can split a separator in half).
//   - "event:" sets the event type (default "message").
//   - "data:" lines accumulate, newline-joined, as multiple data: lines is
//     how SSE spreads one multi-line payload across several lines.
//   - "id:" sets the event's last-event-id.
//   - a line starting with ":" is a comment (servers use this for heartbeat
//     keepalives) — parsed but must never surface as an event.
//   - a record with no data: line at all is dropped (comment/keepalive-only
//     block), matching the WHATWG "if data buffer is empty, return" rule.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.JCSSEParse = factory();
  }
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  // Parses one already-isolated record block (no trailing blank line) into
  // {type, data, id, hasData}. hasData distinguishes "data: " (empty string
  // payload, still a real event) from no data: line at all (comment-only).
  function parseSSEBlock(block) {
    let type = 'message';
    const dataLines = [];
    let id = '';
    block.split(/\r\n|\n/).forEach(function (line) {
      if (line === '' || line.charAt(0) === ':') return; // comment/heartbeat
      const ci = line.indexOf(':');
      const field = ci === -1 ? line : line.slice(0, ci);
      let value = ci === -1 ? '' : line.slice(ci + 1);
      if (value.charAt(0) === ' ') value = value.slice(1);
      if (field === 'event') type = value;
      else if (field === 'data') dataLines.push(value);
      else if (field === 'id') id = value;
      // Any other field (e.g. "retry") is intentionally ignored — no
      // consumer in this codebase needs it.
    });
    return { type: type, data: dataLines.join('\n'), id: id, hasData: dataLines.length > 0 };
  }

  // Stateful incremental parser: feed it raw text chunks (already decoded to
  // a JS string — callers using a byte stream must run it through a
  // TextDecoder with {stream:true} first) as they arrive over the wire, get
  // back the complete records found so far. Handles a record separator (or
  // even a single field/value line) being split across two chunks, and
  // either LF or CRLF line endings — a chunk boundary can land anywhere,
  // including mid-separator.
  function createSSEStreamParser() {
    let buf = '';

    function push(chunkText) {
      buf += chunkText;
      const events = [];
      for (;;) {
        const nl = buf.indexOf('\n\n');
        const crnl = buf.indexOf('\r\n\r\n');
        let idx = -1, sep = 2;
        if (nl !== -1 && (crnl === -1 || nl < crnl)) { idx = nl; sep = 2; }
        else if (crnl !== -1) { idx = crnl; sep = 4; }
        if (idx === -1) break; // no complete record yet — wait for more chunks
        const block = buf.slice(0, idx);
        buf = buf.slice(idx + sep);
        const parsed = parseSSEBlock(block);
        if (!parsed.hasData) continue; // comment-only / keepalive block
        events.push({ type: parsed.type, data: parsed.data, id: parsed.id });
      }
      return events;
    }

    return { push: push };
  }

  return { parseSSEBlock: parseSSEBlock, createSSEStreamParser: createSSEStreamParser };
});
