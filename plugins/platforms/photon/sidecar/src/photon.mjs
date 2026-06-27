// The Photon engine: the only place that touches `spectrum-ts`.
//
// Two implementations behind one interface so the HTTP server and the tests
// never branch on "real vs mock":
//
//   createEngine(config)  -> RealEngine (Spectrum cloud) or MockEngine
//
// Engine interface:
//   await start()                 connect (no-op for mock)
//   await stop()                  disconnect
//   get connected(): boolean
//   onInbound(fn) -> unsubscribe  fn receives a normalized inbound message
//   await send(address, text) -> { id }
//   await typing(address)         best-effort, may be a no-op
//   _injectInbound(msg)           test hook (mock only)
//
// Normalized inbound shape (what /inbound streams and the Python adapter parses):
//   { id, address, text, platform, timestamp, raw }

import { randomUUID } from "node:crypto";

function nowIso() {
  return new Date().toISOString();
}

const _sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Normalize a /send payload (string or object) into a stable rich shape.
// Photon iMessage supports far more than plain text (markdown, bubble/screen
// effects, attachments / stacked images); this is the shared schema both engines
// build from. Unknown fields are ignored.
function _normalizeSend(payload) {
  if (typeof payload === "string") return { text: payload, markdown: false, effect: "", attachments: [] };
  const p = payload || {};
  let attachments = [];
  if (Array.isArray(p.attachments)) {
    attachments = p.attachments
      .map((a) => (typeof a === "string" ? { path: a } : a || {}))
      .filter((a) => a && (a.path || a.url || a.id));
  }
  return {
    text: typeof p.text === "string" ? p.text : "",
    markdown: Boolean(p.markdown),
    effect: typeof p.effect === "string" ? p.effect : "",
    attachments,
  };
}

// Shared subscriber bookkeeping for both engines.
class InboundHub {
  constructor() {
    this._subs = new Set();
  }
  onInbound(fn) {
    this._subs.add(fn);
    return () => this._subs.delete(fn);
  }
  emit(msg) {
    for (const fn of this._subs) {
      try {
        fn(msg);
      } catch (err) {
        // A bad subscriber must never take down the stream loop.
        console.error("[photon] inbound subscriber threw:", err);
      }
    }
  }
}

export class MockEngine {
  constructor(config = {}) {
    this.config = config;
    this._hub = new InboundHub();
    this._connected = false;
    this.sent = []; // inspectable by tests
  }
  async start() {
    this._connected = true;
  }
  async stop() {
    this._connected = false;
  }
  get connected() {
    return this._connected;
  }
  get mock() {
    return true;
  }
  onInbound(fn) {
    return this._hub.onInbound(fn);
  }
  async send(address, payload) {
    const opts = _normalizeSend(payload);
    const id = randomUUID();
    this.sent.push({ address, id, ...opts });
    return { id };
  }
  async typing(_address) {
    /* no-op */
  }
  // Test/dev hook: simulate an inbound iMessage.
  _injectInbound({ address = "+15555550123", text = "hi", id } = {}) {
    const msg = {
      id: id || randomUUID(),
      address,
      text,
      platform: "imessage",
      timestamp: nowIso(),
      raw: { mock: true },
    };
    this._hub.emit(msg);
    return msg;
  }
}

export class RealEngine {
  constructor(config) {
    this.config = config;
    this._hub = new InboundHub();
    this._connected = false;
    this._app = null;
    this._im = null;
    this._streamTask = null;
    this._stopping = false;
  }

  get connected() {
    return this._connected;
  }
  get mock() {
    return false;
  }
  onInbound(fn) {
    return this._hub.onInbound(fn);
  }

  async _connectOnce() {
    // Dynamic import so mock mode never requires the SDK to be installed.
    //
    // NOTE: these import paths + method names follow the documented Spectrum
    // public API (https://photon.codes/docs). They are localized HERE on
    // purpose: if a package version renames something, this is the only file to
    // touch. Pin against the installed version during first bring-up (P0).
    const { Spectrum } = await import("spectrum-ts");
    const { imessage } = await import("spectrum-ts/providers/imessage");

    const providerCfg =
      this.config.imessageMode === "cloud"
        ? imessage.config()
        : imessage.config({ mode: this.config.imessageMode });

    this._app = await Spectrum({
      projectId: this.config.projectId,
      projectSecret: this.config.projectSecret,
      providers: [providerCfg],
    });
    this._im = imessage(this._app);
    this._connected = true;
  }

  async start() {
    // Fail the first connect loudly (surfaces to main → non-zero exit). After
    // that the supervisor self-heals dropped connections.
    await this._connectOnce();
    this._streamTask = this._supervise();
    console.log("[photon] connected to Spectrum cloud (iMessage)");
  }

  // Consume the inbound stream and reconnect with backoff if it drops. A dead
  // stream must not leave the engine silently "up" with a stale `_im` (which
  // would make send() fail in confusing ways) — on drop we clear `_im`,
  // reflect it in `connected`, and rebuild the Spectrum app.
  async _supervise() {
    const backoff = [2, 5, 10, 30, 60];
    let i = 0;
    while (!this._stopping) {
      if (!this._connected) {
        try {
          await this._connectOnce();
          console.log("[photon] reconnected to Spectrum cloud");
          i = 0;
        } catch (err) {
          const delay = backoff[Math.min(i++, backoff.length - 1)] * 1000;
          console.error(
            `[photon] reconnect failed, retrying in ${delay / 1000}s:`,
            err && err.message ? err.message : err
          );
          await _sleep(delay);
          continue;
        }
      }
      const startedMs = Date.now();
      try {
        for await (const [space, message] of this._app.messages) {
          if (this._stopping) break;
          const norm = this._normalize(space, message);
          if (norm) this._hub.emit(norm);
        }
      } catch (err) {
        if (this._stopping) break;
        console.error(
          "[photon] inbound stream error:",
          err && err.message ? err.message : err
        );
      }
      if (this._stopping) break;
      // Stream ended/failed → mark down, drop the stale handle, then back off.
      this._connected = false;
      this._im = null;
      if (Date.now() - startedMs >= 60000) i = 0;
      const delay = backoff[Math.min(i++, backoff.length - 1)] * 1000;
      console.warn(`[photon] inbound disconnected; reconnecting in ${delay / 1000}s`);
      await _sleep(delay);
    }
  }

  _normalize(space, message) {
    try {
      const content = message?.content || {};
      // Only surface text for now; attachments/reactions arrive as other arms.
      let text = "";
      if (content.type === "text") text = content.text || "";
      else if (typeof content.text === "string") text = content.text;
      const address =
        space?.phone ||
        message?.sender?.id ||
        space?.id ||
        "";
      if (!text) return null;
      return {
        id: message?.id || randomUUID(),
        address,
        text,
        platform: message?.platform || "imessage",
        timestamp: message?.timestamp || nowIso(),
        raw: { space, message },
      };
    } catch (err) {
      console.error("[photon] failed to normalize inbound message:", err);
      return null;
    }
  }

  async send(address, payload) {
    if (!this._im) throw new Error("Spectrum not connected");
    const opts = _normalizeSend(payload);
    // Resolve recipient → reuse the existing DM space if there is one, else
    // create one (proactive new conversation). This is the documented
    // im.user → im.space.create / im.space.get flow.
    const user = await this._im.user(address);
    let space = null;
    try {
      space = await this._im.space.get(`any;-;${address}`);
    } catch {
      space = null;
    }
    if (!space) {
      space = await this._im.space.create(user);
    }
    const contents = await this._buildContents(opts);
    const res = await space.send(...contents);
    return { id: (res && (res.id || res.guid)) || randomUUID() };
  }

  // Compose the Spectrum content list from a normalized send payload. Rich
  // builders (markdown/effect/attachment) are loaded defensively — if a package
  // version doesn't expose one, we degrade to plain text rather than throw.
  async _buildContents(opts) {
    let builders = {};
    try {
      builders = await import("spectrum-ts");
    } catch {
      builders = {};
    }
    const { markdown, effect, attachment } = builders;
    const contents = [];
    for (const att of opts.attachments) {
      const ref = att.path || att.url || att.id;
      if (!ref) continue;
      contents.push(typeof attachment === "function" ? attachment(ref, att.name) : ref);
    }
    if (opts.text) {
      let body =
        opts.markdown && typeof markdown === "function" ? markdown(opts.text) : opts.text;
      if (opts.effect && typeof effect === "function") body = effect(body, opts.effect);
      contents.push(body);
    }
    return contents.length ? contents : [opts.text || ""];
  }

  async typing(address) {
    if (!this._im) return;
    try {
      const space = await this._im.space.get(`any;-;${address}`);
      if (space && typeof space.typing === "function") await space.typing();
    } catch {
      /* typing is best-effort */
    }
  }

  async stop() {
    this._stopping = true;
    this._connected = false;
    try {
      if (this._app && typeof this._app.close === "function") {
        await this._app.close();
      }
    } catch (err) {
      console.error("[photon] error during close:", err);
    }
    this._app = null;
    this._im = null;
  }
}

export function createEngine(config) {
  return config.mock ? new MockEngine(config) : new RealEngine(config);
}
