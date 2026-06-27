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

test("POST /edit rewrites a cached message and records the edit", async () => {
  const { engine, server, base } = await startServer();
  try {
    // Send first so the engine caches the Message by id.
    const sendRes = await fetch(`${base}/send`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ address: "+15555550100", text: "partial" }),
    });
    const { id } = await sendRes.json();
    assert.ok(id);

    // Now edit it by id.
    const editRes = await fetch(`${base}/edit`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ id, text: "partial — done" }),
    });
    assert.equal(editRes.status, 200);
    const editBody = await editRes.json();
    assert.equal(editBody.success, true);
    assert.equal(editBody.id, id);

    // The edit was recorded and the cached record reflects the new text.
    assert.equal(engine.edits.length, 1);
    assert.equal(engine.edits[0].id, id);
    assert.equal(engine.edits[0].text, "partial — done");
    assert.equal(engine.sent[0].text, "partial — done");
  } finally {
    server.close();
  }
});

test("POST /edit on an unknown id returns a clear error (422)", async () => {
  const { engine, server, base } = await startServer();
  try {
    const res = await fetch(`${base}/edit`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ id: "does-not-exist", text: "hi" }),
    });
    assert.equal(res.status, 422);
    const body = await res.json();
    assert.match(body.error, /unknown message id/i);
    assert.equal(engine.edits.length, 0);
  } finally {
    server.close();
  }
});

test("POST /edit validates id and text", async () => {
  const { server, base } = await startServer();
  try {
    // Missing id.
    const r1 = await fetch(`${base}/edit`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ text: "hi" }),
    });
    assert.equal(r1.status, 422);
    // Missing text.
    const r2 = await fetch(`${base}/edit`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ id: "abc", text: "" }),
    });
    assert.equal(r2.status, 422);
  } finally {
    server.close();
  }
});

test("POST /edit requires the token", async () => {
  const { server, base } = await startServer();
  try {
    const res = await fetch(`${base}/edit`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: "abc", text: "hi" }),
    });
    assert.equal(res.status, 401);
  } finally {
    server.close();
  }
});

test("POST /reload swaps the engine and stays healthy", async () => {
  const { server, base } = await startServer();
  // Force mock + an empty env file so reload's loadConfig is deterministic and
  // never tries a real Spectrum connection on the test host.
  const prevMock = process.env.PHOTON_SIDECAR_MOCK;
  const prevEnvFile = process.env.PHOTON_ENV_FILE;
  process.env.PHOTON_SIDECAR_MOCK = "1";
  process.env.PHOTON_ENV_FILE = "/nonexistent/photon/.env";
  try {
    const res = await fetch(`${base}/reload`, { method: "POST", headers: auth });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(body.mock, true);
    const h = await (await fetch(`${base}/health`, { headers: auth })).json();
    assert.equal(h.ok, true);
  } finally {
    if (prevMock === undefined) delete process.env.PHOTON_SIDECAR_MOCK;
    else process.env.PHOTON_SIDECAR_MOCK = prevMock;
    if (prevEnvFile === undefined) delete process.env.PHOTON_ENV_FILE;
    else process.env.PHOTON_ENV_FILE = prevEnvFile;
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
    engine._injectInbound({ handle: "+15555550123", spaceId: "sp1", text: "yo jarvis" });
    await pump(2);
    assert.equal(lines[1].type, "message");
    assert.equal(lines[1].message.text, "yo jarvis");
    assert.equal(lines[1].message.handle, "+15555550123");
    assert.equal(lines[1].message.spaceId, "sp1");
    assert.equal(lines[1].message.platform, "imessage");

    controller.abort();
  } finally {
    server.close();
  }
});
