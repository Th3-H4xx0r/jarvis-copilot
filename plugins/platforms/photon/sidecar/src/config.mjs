// Configuration for the Photon sidecar.
//
// Values come from the environment, with a fallback to the SHARED JarvisCopilot
// `.env` file (the same one the WebUI/mobile "Photon provider" setup screens
// write to via _write_env_file). That means whatever you enter in the UI
// (PHOTON_PROJECT_ID/SECRET, the iMessage handle, the sidecar token) is picked up
// by the sidecar on its next start — no separate config to keep in sync. Real
// process env (e.g. a systemd EnvironmentFile) always wins over the .env file.
//
// The sidecar runs on localhost (same host as the gateway/webui) and is the one
// process that holds a live `spectrum-ts` connection to photon.codes. The Python
// adapter talks to it over HTTP and authenticates with the shared token so
// nothing else on the box can drive your iMessage.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Resolve the shared JarvisCopilot .env path the same way the Python side does:
// an explicit override, else $JARVISCOPILOT_HOME/.env, else ~/.jarviscopilot/.env.
function _envFilePath(env) {
  if (env.PHOTON_ENV_FILE) return env.PHOTON_ENV_FILE;
  const home = env.JARVISCOPILOT_HOME
    ? env.JARVISCOPILOT_HOME
    : path.join(os.homedir(), ".jarviscopilot");
  return path.join(home, ".env");
}

// Minimal .env parser: KEY=VALUE per line, `#` comments, optional surrounding
// quotes. Missing/unreadable file → {} (never throws).
function _parseEnvFile(file) {
  let text;
  try {
    text = fs.readFileSync(file, "utf-8");
  } catch {
    return {};
  }
  const out = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    out[key] = val;
  }
  return out;
}

export function loadConfig(env = process.env) {
  const fileEnv = _parseEnvFile(_envFilePath(env));
  // Real process env wins; the shared .env file is the fallback.
  const get = (n, f = "") => {
    const v = env[n] != null ? env[n] : fileEnv[n];
    return v == null ? f : String(v).trim();
  };
  const getBool = (n, f = false) => {
    const v = get(n).toLowerCase();
    if (!v) return f;
    return v === "1" || v === "true" || v === "yes" || v === "on";
  };
  const getInt = (n, f) => {
    const v = parseInt(get(n), 10);
    return Number.isFinite(v) ? v : f;
  };

  const projectId = get("PHOTON_PROJECT_ID");
  const projectSecret = get("PHOTON_PROJECT_SECRET");

  // Mock mode runs the sidecar with no Spectrum SDK / no credentials. It is the
  // default whenever credentials are absent, so `node src/server.mjs` always
  // boots (and tests never touch the network). Force with PHOTON_SIDECAR_MOCK=1.
  const bothCreds = Boolean(projectId) && Boolean(projectSecret);
  // Exactly one credential set = a likely typo/misconfig. We still run (in mock)
  // but main() warns loudly so "messages look sent but aren't" is visible.
  const credsPartial = Boolean(projectId) !== Boolean(projectSecret);
  const mock = getBool("PHOTON_SIDECAR_MOCK", false) || !bothCreds;

  return {
    credsPartial,
    host: get("PHOTON_SIDECAR_HOST", "127.0.0.1"),
    // 8799, NOT 8787 — 8787 is the JarvisCopilot WebUI port.
    port: getInt("PHOTON_SIDECAR_PORT", 8799),
    // Shared secret for the localhost control plane. Empty = no auth (dev only).
    token: get("PHOTON_SIDECAR_TOKEN"),
    projectId,
    projectSecret,
    mock,
    // iMessage provider mode. "cloud" = Photon-hosted (no Mac). Anything else is
    // passed through verbatim for the rare local/dedicated setups.
    imessageMode: get("PHOTON_IMESSAGE_MODE", "cloud"),
    // How long an idle /inbound stream waits between heartbeat comments (ms).
    heartbeatMs: getInt("PHOTON_SIDECAR_HEARTBEAT_MS", 25000),
    // Where we read the shared .env from (for diagnostics).
    envFile: _envFilePath(env),
  };
}
