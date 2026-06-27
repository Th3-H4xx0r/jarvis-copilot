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
import { writeFile, mkdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";

function nowIso() {
  return new Date().toISOString();
}

const _MIME_EXT = {
  "image/jpeg": ".jpg",
  "image/jpg": ".jpg",
  "image/png": ".png",
  "image/gif": ".gif",
  "image/heic": ".heic",
  "image/heif": ".heic",
  "image/webp": ".webp",
  "image/tiff": ".tiff",
  "audio/mpeg": ".mp3",
  "audio/mp4": ".m4a",
  "audio/aac": ".m4a",
  "audio/ogg": ".ogg",
  "audio/amr": ".amr",
  "audio/wav": ".wav",
  "video/mp4": ".mp4",
  "video/quicktime": ".mov",
  "application/pdf": ".pdf",
};

function _extFor(mime, name) {
  if (name && name.includes(".")) {
    const e = name.slice(name.lastIndexOf(".")).toLowerCase();
    if (e.length <= 6) return e;
  }
  return _MIME_EXT[(mime || "").toLowerCase()] || ".bin";
}

function _kindFor(mime) {
  mime = (mime || "").toLowerCase();
  if (mime.startsWith("image/")) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  return "file";
}

const _HEIC_BRANDS = new Set([
  "heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis",
]);

function _isHeic(buf, mimeType) {
  if ((mimeType || "").toLowerCase().includes("hei")) return true; // image/heic, image/heif
  // ISOBMFF: a `ftyp` box at offset 4 with a HEIF/HEIC brand.
  return (
    buf.length >= 12 &&
    buf.slice(4, 8).toString("latin1") === "ftyp" &&
    _HEIC_BRANDS.has(buf.slice(8, 12).toString("latin1"))
  );
}

// HEIC isn't decodable by Pillow-without-plugins or Claude vision, so transcode
// to JPEG here (pure-JS, no system libs). Falls back to the original bytes if
// heic-convert isn't installed or the decode fails.
async function _maybeConvertHeic(buf, mimeType, name) {
  if (!_isHeic(buf, mimeType)) return { buf, mimeType, name };
  try {
    const { default: heicConvert } = await import("heic-convert");
    const out = await heicConvert({ buffer: buf, format: "JPEG", quality: 0.92 });
    const base = name && name.includes(".") ? name.slice(0, name.lastIndexOf(".")) : name || "photo";
    return { buf: Buffer.from(out), mimeType: "image/jpeg", name: `${base}.jpg` };
  } catch (err) {
    console.error(
      "[photon] HEIC→JPEG conversion failed (is heic-convert installed?):",
      err && err.message ? err.message : err
    );
    return { buf, mimeType, name };
  }
}

const _sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Pull a sendable handle out of a Spectrum DM space GUID. iMessage DM spaces are
// "any;-;+1555…" / "iMessage;-;+1555…"; the part after the last ";-;" is the
// phone/email. A bare handle (no ";-;") is returned unchanged.
function _handleFromTarget(target) {
  if (typeof target === "string") {
    const i = target.lastIndexOf(";-;");
    if (i >= 0) {
      const h = target.slice(i + 3).trim();
      if (h) return h;
    }
  }
  return target;
}

// space.send returns a Message (single content) or Message[] (variadic). Pull a
// stable id from whichever shape, falling back to a generated one.
function _msgId(res) {
  const m = Array.isArray(res) ? res[res.length - 1] : res;
  return (m && (m.id || m.guid)) || randomUUID();
}

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
  _injectInbound({ handle = "+15555550123", spaceId = "imsg;dm;+15555550123", text = "hi", id } = {}) {
    const msg = {
      id: id || randomUUID(),
      spaceId,
      handle,
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
    // Cache live inbound Space objects by id so a REPLY targets the original
    // conversation (space.send) instead of reconstructing one from a handle.
    // That's the correct Spectrum reply path and sidesteps the "Target not
    // allowed for this project" restriction on un-provisioned recipients.
    this._spaces = new Map();
    this._spacesMax = 500;
    // Where inbound attachment bytes are spooled for the Python adapter to read.
    this._inboundDir = path.join(os.tmpdir(), "photon-inbound");
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

  _cacheSpace(space) {
    const id = space && space.id;
    if (!id) return;
    this._spaces.set(id, space);
    if (this._spaces.size > this._spacesMax) {
      this._spaces.delete(this._spaces.keys().next().value);
    }
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
          this._cacheSpace(space);
          const norm = await this._normalize(space, message);
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

  // Download an inbound attachment/voice arm's bytes to a temp file the Python
  // adapter reads + caches for the agent (vision/audio). The `attachment` &
  // `voice` content arms expose read(): Promise<Buffer>.
  async _dumpAttachment(content) {
    try {
      if (!content || typeof content.read !== "function") return null;
      const raw = await content.read();
      if (!raw || !raw.length) return null;
      // iPhone photos are HEIC by default, which neither the gateway's image
      // validator nor Claude vision accepts — transcode to JPEG up front.
      const { buf, mimeType, name } = await _maybeConvertHeic(
        raw,
        content.mimeType || "application/octet-stream",
        content.name || "attachment"
      );
      await mkdir(this._inboundDir, { recursive: true });
      const file = path.join(this._inboundDir, `${randomUUID()}${_extFor(mimeType, name)}`);
      await writeFile(file, buf);
      return { path: file, name, mimeType, kind: _kindFor(mimeType) };
    } catch (err) {
      console.error(
        "[photon] inbound attachment download failed:",
        err && err.message ? err.message : err
      );
      return null;
    }
  }

  // Map a Spectrum inbound message to the wire shape the adapter consumes:
  // { id, spaceId, handle, text, attachments[], platform, timestamp }. Handles
  // text, photos/files/stickers (attachment), voice memos, multi-attachment
  // groups, reactions, contacts, rich links and polls — instead of dropping
  // everything that isn't text. spaceId routes the reply back to this thread.
  async _normalize(space, message) {
    try {
      const content = message?.content || {};
      const t = content.type;
      const handle =
        space?.phone || message?.sender?.phone || message?.sender?.id || "";
      const base = {
        id: message?.id || randomUUID(),
        spaceId: space?.id || "",
        handle,
        platform: message?.platform || "imessage",
        timestamp: message?.timestamp || nowIso(),
        raw: { contentType: t },
      };
      const make = (text, attachments = []) => {
        if (!text && !attachments.length) return null;
        return { ...base, text: text || "", attachments };
      };

      if (t === "text") return make(content.text || "");
      if (t === "attachment" || t === "voice") {
        const att = await this._dumpAttachment(content);
        return att ? make("", [att]) : null;
      }
      if (t === "group") {
        const atts = [];
        let text = "";
        for (const item of content.items || []) {
          const ic = item && item.content;
          if (!ic) continue;
          if (ic.type === "attachment" || ic.type === "voice") {
            const a = await this._dumpAttachment(ic);
            if (a) atts.push(a);
          } else if (ic.type === "text" && ic.text) {
            text = text ? `${text}\n${ic.text}` : ic.text;
          }
        }
        return make(text, atts);
      }
      if (t === "effect" && content.content) {
        return this._normalize(space, { ...message, content: content.content });
      }
      if (t === "reaction") {
        const tgt = content?.target?.content?.text;
        const snip = tgt ? ` to: "${String(tgt).slice(0, 80)}"` : "";
        return make(`(reacted ${content.emoji || ""}${snip})`.trim());
      }
      if (t === "richlink") {
        return make(content.url ? String(content.url) : "");
      }
      if (t === "contact") {
        const nm =
          content?.name?.formatted ||
          [content?.name?.first, content?.name?.last].filter(Boolean).join(" ") ||
          "contact";
        const phones = (content.phones || []).map((p) => p.value).filter(Boolean).join(", ");
        const emails = (content.emails || []).map((e) => e.value).filter(Boolean).join(", ");
        const bits = [`(shared a contact) ${nm}`];
        if (phones) bits.push(`phones: ${phones}`);
        if (emails) bits.push(`emails: ${emails}`);
        return make(bits.join(" — "));
      }
      if (t === "poll") {
        const opts = (content?.poll?.options || []).map((o) => o.title).filter(Boolean).join(", ");
        return make(`(poll) ${content?.poll?.title || ""}${opts ? `: ${opts}` : ""}`.trim());
      }
      // typing / rename / avatar / custom / unknown → nothing actionable.
      return null;
    } catch (err) {
      console.error("[photon] failed to normalize inbound message:", err);
      return null;
    }
  }

  // Resolve a Space for a `target` that is EITHER a cached inbound space id
  // (reply in-thread — preferred) OR a handle. On a cache MISS (e.g. after a
  // sidecar restart the cache is empty but the gateway still replies to the old
  // space GUID "any;-;+1555…"), extract the handle from the GUID so im.space()
  // gets a real user ref instead of a GUID — otherwise Spectrum 500s.
  async _resolveSpace(target) {
    const cached = target && this._spaces.get(target);
    if (cached) return cached;
    return this._im.space([_handleFromTarget(target)]);
  }

  async send(target, payload) {
    if (!this._im) throw new Error("Spectrum not connected");
    const opts = _normalizeSend(payload);
    const space = await this._resolveSpace(target);
    const contents = await this._buildContents(opts);
    // Never send an empty content list (Spectrum rejects empty text with a
    // "too_small" validation error) — surface a clear error instead.
    if (!contents.length) {
      throw new Error("Photon send: nothing to send (no text and no valid attachment)");
    }
    let res;
    try {
      res = await space.send(...contents);
    } catch (err) {
      // Rich content (attachments) may not match this SDK build — never lose the
      // text. Retry text-only if we sent anything richer than a bare string.
      const textOnly = contents.length === 1 && contents[0] === opts.text;
      if (opts.text && !textOnly) {
        res = await space.send(opts.text);
      } else {
        throw err;
      }
    }
    return { id: _msgId(res) };
  }

  // Compose the Spectrum content list. A plain string IS a valid text
  // ContentInput (iMessage renders markdown), so text needs no builder.
  // Attachments use the main-module `attachment(input, opts)` builder
  // (input = string | Buffer | URL). Local files (path or file:// URL) are read
  // into a Buffer so the SDK doesn't have to guess path-vs-URL; remote URLs pass
  // as a URL. Returns [] when nothing valid built (caller guards against empty).
  async _buildContents(opts) {
    const contents = [];
    if (opts.attachments.length) {
      let attachment;
      try {
        ({ attachment } = await import("spectrum-ts"));
      } catch {
        attachment = null;
      }
      if (typeof attachment === "function") {
        for (const att of opts.attachments) {
          const c = await this._attachmentContent(attachment, att);
          if (c != null) contents.push(c);
        }
      }
    }
    if (opts.text) contents.push(opts.text);
    return contents;
  }

  async _attachmentContent(attachment, att) {
    const o = {};
    if (att.name) o.name = att.name;
    if (att.mimeType) o.mimeType = att.mimeType;
    try {
      // Local file (explicit path, or a file:// URL) → read bytes (unambiguous).
      if (att.path || (att.url && String(att.url).startsWith("file://"))) {
        const p = att.path || fileURLToPath(att.url);
        const buf = await readFile(p);
        return attachment(buf, o);
      }
      if (att.url) return attachment(new URL(att.url), o);
      return null;
    } catch (err) {
      console.error(
        "[photon] outbound attachment build failed:",
        err && err.message ? err.message : err
      );
      return null;
    }
  }

  async typing(target) {
    if (!this._im) return;
    try {
      const space = await this._resolveSpace(target);
      if (typeof space.startTyping === "function") await space.startTyping();
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
