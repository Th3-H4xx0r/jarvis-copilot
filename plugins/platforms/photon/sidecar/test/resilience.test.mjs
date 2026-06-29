// Resilience tests — the drop/failure points that cause "sometimes Photon
// doesn't reply": the inbound replay buffer (no message lost in the reconnect /
// reload window), send-during-reconnect surfacing as a RETRYABLE 503 (so the
// adapter retries instead of dropping the reply), and the /send 503 mapping.
//
// No credentials / network: drives the MockEngine and a fake RealEngine-shaped
// engine over a real http.Server on an ephemeral port.

import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "../src/server.mjs";
import {
  MockEngine,
  RealEngine,
  RetryableEngineError,
} from "../src/photon.mjs";

const TOKEN = "test-token";
const auth = { "X-Photon-Token": TOKEN };

// ---------------------------------------------------------------------------
// InboundHub replay buffer — the reconnect/reload-window loss fix
// ---------------------------------------------------------------------------

test("inbound emitted with NO subscriber is buffered and replayed to the next", async () => {
  // A message that lands while the adapter is mid-reconnect (zero /inbound
  // subscribers) must NOT be lost — it's buffered and flushed to the next
  // subscriber that attaches. This is the core reconnect/reload-window fix.
  const eng = new MockEngine();
  await eng.start();

  // No subscriber yet — inject inbound (emits into the hub with 0 subs).
  const injected = eng._injectInbound({ text: "while nobody listened", id: "buf1" });
  assert.ok(injected);

  // Now a subscriber attaches (simulating the adapter reconnecting).
  const received = [];
  const unsub = eng.onInbound((m) => received.push(m));
  // The buffered message is replayed immediately on subscribe.
  assert.equal(received.length, 1);
  assert.equal(received[0].id, "buf1");
  assert.equal(received[0].text, "while nobody listened");

  // It is drained, not re-replayed to a second subscriber.
  const received2 = [];
  eng.onInbound((m) => received2.push(m));
  assert.equal(received2.length, 0);

  unsub();
});

test("a live subscriber gets the message directly (no buffering)", async () => {
  const eng = new MockEngine();
  await eng.start();
  const received = [];
  eng.onInbound((m) => received.push(m));
  eng._injectInbound({ text: "live", id: "live1" });
  assert.equal(received.length, 1);
  assert.equal(received[0].id, "live1");
});

// ---------------------------------------------------------------------------
// GET /inbound — a message buffered during the gap is delivered on reconnect
// ---------------------------------------------------------------------------

async function startServer(engine, config = {}) {
  await engine.start();
  const server = createServer(engine, { token: TOKEN, heartbeatMs: 60000, ...config });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  return { server, base: `http://127.0.0.1:${port}` };
}

async function readLines(res, expected, controller) {
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const lines = [];
  while (lines.length < expected) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let nl;
    while ((nl = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (line) lines.push(JSON.parse(line));
    }
  }
  return lines;
}

test("GET /inbound replays a message that arrived while disconnected", async () => {
  const engine = new MockEngine();
  const { server, base } = await startServer(engine);
  try {
    // No /inbound connection yet — a message arrives (reconnect gap). It is
    // buffered on the hub rather than dropped.
    engine._injectInbound({ text: "arrived during the gap", id: "gap1" });

    // Now the adapter (re)connects to /inbound.
    const controller = new AbortController();
    const res = await fetch(`${base}/inbound`, { headers: auth, signal: controller.signal });
    assert.equal(res.status, 200);

    // We expect: the `ready` line, then the REPLAYED buffered message.
    const lines = await readLines(res, 2, controller);
    assert.equal(lines[0].type, "ready");
    assert.equal(lines[1].type, "message");
    assert.equal(lines[1].message.id, "gap1");
    assert.equal(lines[1].message.text, "arrived during the gap");
    controller.abort();
  } finally {
    server.close();
  }
});

// ---------------------------------------------------------------------------
// /send during reconnect → RETRYABLE 503 (not a hard 500/permanent failure)
// ---------------------------------------------------------------------------

// A RealEngine whose Spectrum link is down (`_im` null) and never comes back
// within the wait window. send() must raise a RetryableEngineError, which the
// server maps to 503 so the Python adapter retries instead of dropping.
class DisconnectedRealEngine extends RealEngine {
  constructor() {
    super({ mock: false });
    this._im = null; // never connected
  }
  // Make the wait return immediately so the test isn't slow.
  async _waitForConnection() {
    return false;
  }
}

test("POST /send while Spectrum is reconnecting returns a retryable 503", async () => {
  const engine = new DisconnectedRealEngine();
  // Don't call the real start() (it would try a live Spectrum connect). The
  // server only needs `connected`/`mock`/`send`.
  const server = createServer(engine, { token: TOKEN, heartbeatMs: 60000 });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  try {
    const res = await fetch(`${base}/send`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ address: "+15555550100", text: "hi" }),
    });
    // 503 + retryable so the adapter retries with backoff (a 500 would be
    // treated as permanent → dropped reply).
    assert.equal(res.status, 503);
    const body = await res.json();
    assert.equal(body.retryable, true);
    assert.match(body.error, /not connected|reconnect/i);
  } finally {
    server.close();
  }
});

test("send() raises RetryableEngineError when the link is down", async () => {
  const engine = new DisconnectedRealEngine();
  await assert.rejects(
    () => engine.send("+15555550100", { text: "hi" }),
    (err) => err instanceof RetryableEngineError && err.retryable === true
  );
});

test("edit() raises RetryableEngineError when the link is down", async () => {
  const engine = new DisconnectedRealEngine();
  await assert.rejects(
    () => engine.edit("some-id", "new text"),
    (err) => err instanceof RetryableEngineError && err.retryable === true
  );
});
