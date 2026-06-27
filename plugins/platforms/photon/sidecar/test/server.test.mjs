// Sidecar tests — run with `npm test` (node --test). No credentials / network:
// they drive a real http.Server backed by the MockEngine on an ephemeral port.

import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "../src/server.mjs";
import { MockEngine } from "../src/photon.mjs";

const TOKEN = "test-token";

async function startServer() {
  const engine = new MockEngine();
  await engine.start();
  const config = { token: TOKEN, heartbeatMs: 60000 };
  const server = createServer(engine, config);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  return { engine, server, base };
}

const auth = { "X-Photon-Token": TOKEN };

test("health reports mock + connected", async () => {
  const { server, base } = await startServer();
  try {
    const res = await fetch(`${base}/health`, { headers: auth });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(body.mock, true);
    assert.equal(body.connected, true);
  } finally {
    server.close();
  }
});

test("requests without the token are rejected", async () => {
  const { server, base } = await startServer();
  try {
    const res = await fetch(`${base}/health`);
    assert.equal(res.status, 401);
  } finally {
    server.close();
  }
});

test("POST /send records the message and returns an id", async () => {
  const { engine, server, base } = await startServer();
  try {
    const res = await fetch(`${base}/send`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ address: "+15555550100", text: "hello there" }),
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.success, true);
    assert.ok(body.id);
    assert.equal(engine.sent.length, 1);
    assert.equal(engine.sent[0].address, "+15555550100");
    assert.equal(engine.sent[0].text, "hello there");
  } finally {
    server.close();
  }
});

test("POST /send validates address and (text or attachments)", async () => {
  const { server, base } = await startServer();
  try {
    const r1 = await fetch(`${base}/send`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ text: "no address" }),
    });
    assert.equal(r1.status, 422);
    // No text AND no attachments → rejected.
    const r2 = await fetch(`${base}/send`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ address: "+1555", text: "" }),
    });
    assert.equal(r2.status, 422);
  } finally {
    server.close();
  }
});

test("POST /send carries rich fields (markdown + attachments)", async () => {
  const { engine, server, base } = await startServer();
  try {
    // Attachment-only message (no text) is valid.
    const r1 = await fetch(`${base}/send`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ address: "+1555", attachments: ["/tmp/a.png"] }),
    });
    assert.equal(r1.status, 200);
    assert.equal(engine.sent[0].attachments.length, 1);
    assert.equal(engine.sent[0].attachments[0].path, "/tmp/a.png");

    const r2 = await fetch(`${base}/send`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ address: "+1555", text: "**bold**", markdown: true, effect: "confetti" }),
    });
    assert.equal(r2.status, 200);
    assert.equal(engine.sent[1].markdown, true);
    assert.equal(engine.sent[1].effect, "confetti");
  } finally {
    server.close();
  }
});

test("GET /inbound streams a ready line then injected messages", async () => {
  const { engine, server, base } = await startServer();
  try {
    const controller = new AbortController();
    const res = await fetch(`${base}/inbound`, {
      headers: auth,
      signal: controller.signal,
    });
    assert.equal(res.status, 200);

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    const lines = [];

    async function pump(expected) {
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
    }

    // First line is the readiness announcement.
    await pump(1);
    assert.equal(lines[0].type, "ready");

    // Inject an inbound message and confirm it streams through.
    engine._injectInbound({ address: "+15555550123", text: "yo jarvis" });
    await pump(2);
    assert.equal(lines[1].type, "message");
    assert.equal(lines[1].message.text, "yo jarvis");
    assert.equal(lines[1].message.address, "+15555550123");
    assert.equal(lines[1].message.platform, "imessage");

    controller.abort();
  } finally {
    server.close();
  }
});
