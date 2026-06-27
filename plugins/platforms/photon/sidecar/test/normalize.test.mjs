// RealEngine._normalize tests — exercise inbound content-arm mapping (text,
// attachment, group, reaction, richlink) without a live Spectrum connection.

import test from "node:test";
import assert from "node:assert/strict";
import { readFile, rm } from "node:fs/promises";
import { RealEngine } from "../src/photon.mjs";

const space = { id: "sp1", phone: "+15555550123" };

function attachmentContent(bytes, mimeType = "image/png", name = "x.png") {
  return { type: "attachment", name, mimeType, read: async () => Buffer.from(bytes) };
}

test("normalizes a text message (spaceId + handle)", async () => {
  const eng = new RealEngine({});
  const n = await eng._normalize(space, { id: "m", content: { type: "text", text: "hi" } });
  assert.equal(n.text, "hi");
  assert.equal(n.spaceId, "sp1");
  assert.equal(n.handle, "+15555550123");
  assert.equal(n.attachments.length, 0);
});

test("spools an inbound photo attachment to a temp file", async () => {
  const eng = new RealEngine({});
  const n = await eng._normalize(space, {
    id: "m1",
    content: attachmentContent([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]),
  });
  assert.equal(n.attachments.length, 1);
  assert.equal(n.attachments[0].kind, "image");
  assert.equal(n.attachments[0].mimeType, "image/png");
  assert.ok(n.attachments[0].path.endsWith(".png"));
  const bytes = await readFile(n.attachments[0].path);
  assert.equal(bytes.length, 7);
  await rm(n.attachments[0].path, { force: true });
});

test("group message yields one attachment per item", async () => {
  const eng = new RealEngine({});
  const n = await eng._normalize(space, {
    id: "g1",
    content: {
      type: "group",
      items: [
        { content: attachmentContent([1, 2], "image/jpeg", "a.jpg") },
        { content: attachmentContent([3, 4], "image/jpeg", "b.jpg") },
        { content: { type: "text", text: "two pics" } },
      ],
    },
  });
  assert.equal(n.attachments.length, 2);
  assert.equal(n.text, "two pics");
  for (const a of n.attachments) await rm(a.path, { force: true });
});

test("reaction and richlink surface as text", async () => {
  const eng = new RealEngine({});
  const r = await eng._normalize(space, {
    id: "r1",
    content: { type: "reaction", emoji: "❤️", target: { content: { type: "text", text: "nice" } } },
  });
  assert.match(r.text, /❤️/);
  const l = await eng._normalize(space, {
    id: "l1",
    content: { type: "richlink", url: "https://example.com" },
  });
  assert.equal(l.text, "https://example.com");
});

test("typing/unknown arms are dropped (null)", async () => {
  const eng = new RealEngine({});
  const n = await eng._normalize(space, { id: "t", content: { type: "typing", state: "start" } });
  assert.equal(n, null);
});
