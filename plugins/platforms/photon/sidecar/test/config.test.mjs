// Config tests — the sidecar must read the SHARED JarvisCopilot .env so creds
// entered in the WebUI/mobile setup screen are picked up, with real process env
// taking precedence.

import test from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig } from "../src/config.mjs";

function envFileWith(contents) {
  const dir = mkdtempSync(join(tmpdir(), "photon-cfg-"));
  const file = join(dir, ".env");
  writeFileSync(file, contents);
  return file;
}

test("reads PHOTON_* from the shared .env file", () => {
  const file = envFileWith(
    "PHOTON_PROJECT_ID=pid\nPHOTON_PROJECT_SECRET=sec\nPHOTON_SIDECAR_TOKEN=tok\n"
  );
  const cfg = loadConfig({ PHOTON_ENV_FILE: file });
  assert.equal(cfg.token, "tok");
  assert.equal(cfg.projectId, "pid");
  assert.equal(cfg.mock, false); // both creds present → real mode
  assert.equal(cfg.credsPartial, false);
});

test("real process env overrides the .env file", () => {
  const file = envFileWith("PHOTON_SIDECAR_TOKEN=fromfile\n");
  const cfg = loadConfig({ PHOTON_ENV_FILE: file, PHOTON_SIDECAR_TOKEN: "fromenv" });
  assert.equal(cfg.token, "fromenv");
});

test("partial creds flagged and mock stays on", () => {
  const file = envFileWith("PHOTON_PROJECT_ID=only-id\n");
  const cfg = loadConfig({ PHOTON_ENV_FILE: file });
  assert.equal(cfg.credsPartial, true);
  assert.equal(cfg.mock, true);
});

test("ignores comments and blank lines, strips quotes", () => {
  const file = envFileWith('# a comment\n\nPHOTON_SIDECAR_TOKEN="quoted-tok"\n');
  const cfg = loadConfig({ PHOTON_ENV_FILE: file });
  assert.equal(cfg.token, "quoted-tok");
});

test("missing .env file is harmless (mock mode)", () => {
  const cfg = loadConfig({ PHOTON_ENV_FILE: "/nonexistent/path/.env" });
  assert.equal(cfg.mock, true);
  assert.equal(cfg.token, "");
});
