// Configuration for the Photon sidecar, read entirely from the environment.
//
// The sidecar runs on localhost (same host as the JarvisCopilot gateway/webui)
// and is the single process that holds a live `spectrum-ts` connection to
// photon.codes. The Python adapter talks to it over HTTP and authenticates with
// a shared token so nothing else on the box can drive your iMessage.

function envStr(name, fallback = "") {
  const v = process.env[name];
  return v === undefined || v === null ? fallback : String(v).trim();
}

function envBool(name, fallback = false) {
  const v = envStr(name).toLowerCase();
  if (!v) return fallback;
  return v === "1" || v === "true" || v === "yes" || v === "on";
}

function envInt(name, fallback) {
  const v = parseInt(envStr(name), 10);
  return Number.isFinite(v) ? v : fallback;
}

export function loadConfig(env = process.env) {
  // Re-read against the passed env so tests can inject overrides.
  const get = (n, f = "") => {
    const v = env[n];
    return v === undefined || v === null ? f : String(v).trim();
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
    port: getInt("PHOTON_SIDECAR_PORT", 8787),
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
  };
}

export { envStr, envBool, envInt };
