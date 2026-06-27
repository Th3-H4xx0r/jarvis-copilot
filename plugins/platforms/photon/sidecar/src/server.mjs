#!/usr/bin/env node
// Photon sidecar HTTP control plane (localhost only).
//
// The JarvisCopilot Python adapter is the sole client:
//   GET  /health   -> { ok, connected, mock }
//   GET  /inbound  -> NDJSON stream of inbound iMessages (one JSON object/line)
//   POST /send     -> { address, text } => { success, id }
//   POST /typing   -> { address }       => { success }
//
// Every request must carry `X-Photon-Token: <PHOTON_SIDECAR_TOKEN>` (unless the
// token is unset, which is dev-only). Bind to 127.0.0.1 so it is never exposed.

import http from "node:http";
import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";
import { loadConfig } from "./config.mjs";
import { createEngine } from "./photon.mjs";

const MAX_BODY_BYTES = 256 * 1024;

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("request body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf-8").trim();
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error("invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

function authed(req, config) {
  if (!config.token) return true; // dev-only: no token configured
  const got = req.headers["x-photon-token"];
  return typeof got === "string" && got === config.token;
}

// GET /inbound — newline-delimited JSON. Holds the connection open and writes one
// line per inbound message; periodic heartbeat comments keep proxies/clients from
// timing the idle connection out.
function handleInbound(req, res, engine, config) {
  res.writeHead(200, {
    "Content-Type": "application/x-ndjson; charset=utf-8",
    "Cache-Control": "no-cache, no-store",
    Connection: "keep-alive",
  });
  // Announce readiness so the client knows the stream is live even before any
  // message arrives.
  res.write(JSON.stringify({ type: "ready", connected: engine.connected }) + "\n");

  const unsubscribe = engine.onInbound((msg) => {
    try {
      res.write(JSON.stringify({ type: "message", message: msg }) + "\n");
    } catch {
      /* write after close — cleaned up below */
    }
  });

  const heartbeat = setInterval(() => {
    try {
      res.write(JSON.stringify({ type: "heartbeat" }) + "\n");
    } catch {
      /* ignore */
    }
  }, Math.max(1000, config.heartbeatMs));

  const cleanup = () => {
    clearInterval(heartbeat);
    unsubscribe();
  };
  req.on("close", cleanup);
  req.on("error", cleanup);
  res.on("error", cleanup);
}

export function createServer(engine, config) {
  return http.createServer(async (req, res) => {
    // Parse the path defensively. An unguarded `new URL(req.url, ...)` here would
    // throw on a malformed request line (e.g. "GET // HTTP/1.1") BEFORE the
    // try/catch below — an unhandled rejection that kills the process pre-auth.
    // We never use the query/host, so a plain split is sufficient and safe.
    const path = (req.url || "/").split("?")[0];

    if (!authed(req, config)) {
      return sendJson(res, 401, { error: "unauthorized" });
    }

    try {
      if (req.method === "GET" && path === "/health") {
        return sendJson(res, 200, {
          ok: true,
          connected: engine.connected,
          mock: engine.mock,
        });
      }

      if (req.method === "GET" && path === "/inbound") {
        return handleInbound(req, res, engine, config);
      }

      if (req.method === "POST" && path === "/send") {
        const body = await readJsonBody(req);
        const address = String(body.address || "").trim();
        const text = body.text == null ? "" : String(body.text);
        const attachments = Array.isArray(body.attachments) ? body.attachments : [];
        if (!address) return sendJson(res, 422, { error: "address required" });
        // A message must carry text and/or at least one attachment.
        if (!text && attachments.length === 0) {
          return sendJson(res, 422, { error: "text or attachments required" });
        }
        const out = await engine.send(address, {
          text,
          markdown: Boolean(body.markdown),
          effect: typeof body.effect === "string" ? body.effect : "",
          attachments,
        });
        return sendJson(res, 200, { success: true, id: out.id });
      }

      if (req.method === "POST" && path === "/typing") {
        const body = await readJsonBody(req);
        const address = String(body.address || "").trim();
        if (!address) return sendJson(res, 422, { error: "address required" });
        await engine.typing(address);
        return sendJson(res, 200, { success: true });
      }

      return sendJson(res, 404, { error: "not found" });
    } catch (err) {
      const msg = err && err.message ? err.message : String(err);
      console.error("[photon] request error:", msg);
      return sendJson(res, 500, { error: msg });
    }
  });
}

function _isLoopback(host) {
  return host === "127.0.0.1" || host === "::1" || host === "localhost";
}

async function main() {
  const config = loadConfig();

  // Fail closed: never expose an unauthenticated control plane beyond loopback.
  // (No token + a non-loopback bind would let the whole LAN send/read your
  // iMessages.)
  if (!config.token && !_isLoopback(config.host)) {
    console.error(
      `[photon] refusing to bind non-loopback host ${config.host} without ` +
        `PHOTON_SIDECAR_TOKEN. Set a token, or bind 127.0.0.1.`
    );
    process.exitCode = 1;
    return;
  }
  if (config.credsPartial) {
    console.error(
      "[photon] WARNING: only one of PHOTON_PROJECT_ID/PHOTON_PROJECT_SECRET is " +
        "set — running in MOCK mode. Messages will NOT be delivered. Set both."
    );
  }

  const engine = createEngine(config);
  try {
    await engine.start();
  } catch (err) {
    console.error("[photon] failed to start engine:", err);
    process.exitCode = 1;
    return;
  }

  const server = createServer(engine, config);
  server.listen(config.port, config.host, () => {
    console.log(
      `[photon] sidecar listening on http://${config.host}:${config.port} ` +
        `(mock=${engine.mock}, token=${config.token ? "set" : "UNSET"})`
    );
  });

  const shutdown = async (sig) => {
    console.log(`[photon] ${sig} — shutting down`);
    server.close();
    try {
      await engine.stop();
    } finally {
      process.exit(0);
    }
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

// Boot only when run directly (not when imported by tests). Resolve both sides
// to real paths so symlink/`bin` invocation and paths-with-spaces still match,
// and tests (argv[1] = the test file) never boot the server.
function _isMain() {
  try {
    return Boolean(process.argv[1]) &&
      fileURLToPath(import.meta.url) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}
if (_isMain()) {
  main();
}
