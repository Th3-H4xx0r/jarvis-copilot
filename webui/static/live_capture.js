// webui/static/live_capture.js
//
// Live capture from the browser's mic — the web's Record button, doing what the
// phone's does over the same socket (/api/live/ws): hello, then 100 ms binary
// audio frames, `state` for pause/resume, `source` for the mic, `end` to stop.
//
// A browser cannot transcribe (Brave has no speech API), so it declares
// stt:"none" and sends 16 kHz PCM; the server hears it with its speech engine
// (api/live_speech.py). Without one it stores the audio and says so, and the
// page repeats it (`readyNote`) rather than showing an empty transcript as if
// nobody had spoken.
//
// The pure parts (framing, resampling, chunking, the hello) are exported for
// `node --test` (live_capture.test.js); the controller needs a browser.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.JcLiveCapture = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const RATE = 16000;
  const CHUNK = RATE / 10;               // 100 ms per frame, as the phone sends
  const HEADER = 12;                     // struct ">IQ": seq u32, ts_ms u64
  const MAX_BUFFERED = 600;              // 60 s kept across a dropped socket
  const PING_MS = 20000;
  const RETRY_MS = [1000, 2000, 5000, 10000];
  const DEVICE_KEY = 'jc.live.webDeviceId';
  const SESSION_KEY = 'jc.live.webSession';

  function encodeAudioFrame(seq, tsMs, pcm) {
    const buf = new ArrayBuffer(HEADER + pcm.length * 2);
    const view = new DataView(buf);
    view.setUint32(0, seq >>> 0);
    view.setBigUint64(4, BigInt(Math.max(0, Math.floor(tsMs))));
    for (let i = 0; i < pcm.length; i++) view.setInt16(HEADER + i * 2, pcm[i], true);
    return buf;
  }

  // Linear interpolation from the mic's rate to 16 kHz. `pos` is where the next
  // output falls, in input samples of the current block; -1 is the previous
  // block's last sample, which is how a block border stays seamless.
  class Resampler {
    constructor(fromRate, toRate) {
      this.step = fromRate / (toRate || RATE);
      this.pos = 0;
      this.last = 0;
    }

    push(input) {
      const n = input.length;
      const out = [];
      while (this.pos <= n - 1) {
        const i = Math.floor(this.pos);
        const frac = this.pos - i;
        const a = i < 0 ? this.last : input[i];
        const b = i + 1 <= n - 1 ? input[i + 1] : a;
        const v = frac === 0 ? a : a + (b - a) * frac;
        out.push(Math.max(-32768, Math.min(32767, Math.round(v * 32767))));
        this.pos += this.step;
      }
      if (n) {
        this.pos -= n;
        this.last = input[n - 1];
      }
      return Int16Array.from(out);
    }
  }

  class Chunker {
    constructor(size) {
      this.size = size || CHUNK;
      this.buf = new Int16Array(0);
    }

    push(samples) {
      const joined = new Int16Array(this.buf.length + samples.length);
      joined.set(this.buf);
      joined.set(samples, this.buf.length);
      const out = [];
      let at = 0;
      while (joined.length - at >= this.size) {
        out.push(joined.slice(at, at + this.size));
        at += this.size;
      }
      this.buf = joined.slice(at);
      return out;
    }
  }

  function helloFrame(opts) {
    const o = opts || {};
    const hello = {
      t: 'hello', device_id: o.deviceId, device_kind: 'web',
      source_label: o.sourceLabel || 'Browser microphone',
      caps: { audio: 'stream', text: 'none', stt: 'none', embed: 'none',
              codec: 'pcm16', rate: RATE, speak: false },
    };
    if (o.resumeSid) hello.resume = { live_session_id: o.resumeSid, after_seq: o.afterSeq || 0 };
    return hello;
  }

  function readyNote(ready) {
    if (ready && ready.lane === 'server' && !ready.engine) {
      return 'Recording, but nothing transcribes it: this browser cannot, and the server '
        + 'has no speech engine. Save a Soniox key in Settings → Speech.';
    }
    return '';
  }

  function rms(pcm) {
    if (!pcm.length) return 0;
    let sum = 0;
    for (let i = 0; i < pcm.length; i++) {
      const s = pcm[i] / 32768;
      sum += s * s;
    }
    return Math.min(1, Math.sqrt(sum / pcm.length));
  }

  function _stored(key) {
    try { return localStorage.getItem(key) || ''; } catch (e) { return ''; }
  }

  function _store(key, value) {
    try {
      if (value) localStorage.setItem(key, value); else localStorage.removeItem(key);
    } catch (e) { /* a private window: this device gets a new id each visit */ }
    return value || '';
  }

  function deviceId() {
    return _stored(DEVICE_KEY) || _store(DEVICE_KEY, 'web-' + Math.random().toString(36).slice(2, 12));
  }

  async function listMics() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return [];
    const all = await navigator.mediaDevices.enumerateDevices();
    return all.filter(d => d.kind === 'audioinput')
      .map((d, i) => ({ deviceId: d.deviceId, label: d.label || `Microphone ${i + 1}` }));
  }

  // The controller. `on` holds callbacks: state(s), level(0..1), ready(frame),
  // note(text), error(text). States: idle, starting, recording, paused,
  // reconnecting, stopping.
  function createCapture(on) {
    const cb = on || {};
    const emit = (name, arg) => {
      try { if (cb[name]) cb[name](arg); } catch (e) { console.warn('[live capture]', e); }
    };
    let state = 'idle';
    let ws = null, ctx = null, stream = null, node = null, sink = null;
    let resampler = null, chunker = null;
    let seq = 0, startedAt = 0, chunksMade = 0;
    let sessionId = _stored(SESSION_KEY);
    let lastSeq = 0, sourceLabel = '', pending = [], retry = 0;
    let pingTimer = null, retryTimer = null;

    function setState(s) { state = s; emit('state', s); }

    function sendJson(obj) {
      if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
    }

    function onSamples(block) {
      if (!resampler) return;
      for (const chunk of chunker.push(resampler.push(block))) {
        // Session time runs on the sample clock, so a paused stretch still moves it.
        const ts = startedAt + chunksMade * 100;
        chunksMade += 1;
        emit('level', rms(chunk));
        if (state !== 'recording' && state !== 'reconnecting' && state !== 'starting') continue;
        const frame = encodeAudioFrame(seq++, ts, chunk);
        if (ws && ws.readyState === 1 && state === 'recording') ws.send(frame);
        else {
          pending.push(frame);
          if (pending.length > MAX_BUFFERED) pending.shift();
        }
      }
    }

    function onMessage(sock, msg) {
      if (msg.t === 'ready') {
        retry = 0;
        if (msg.live_session_id !== sessionId) lastSeq = 0;
        sessionId = _store(SESSION_KEY, msg.live_session_id || '');
        if (state === 'paused') sendJson({ t: 'state', state: 'paused' });
        else setState('recording');
        const backlog = pending;
        pending = [];
        for (const frame of backlog) sock.send(frame);
        emit('note', readyNote(msg));
        emit('ready', msg);
      } else if (msg.t === 'seg' && msg.seq) {
        lastSeq = Math.max(lastSeq, Number(msg.seq) || 0);
      } else if (msg.t === 'error') {
        emit('error', msg.message || msg.code || 'Live refused the recording');
        if (msg.code === 'live_disabled') stop();
      } else if (msg.t === 'state' && msg.warning) {
        emit('note', msg.message || '');
      }
    }

    function connect() {
      const proto = location.protocol === 'https:' ? 'wss' : 'ws';
      const sock = new WebSocket(`${proto}://${location.host}/api/live/ws`);
      sock.binaryType = 'arraybuffer';
      ws = sock;
      sock.onopen = () => {
        sock.send(JSON.stringify(helloFrame({ deviceId: deviceId(), sourceLabel,
                                              resumeSid: sessionId, afterSeq: lastSeq })));
      };
      sock.onmessage = (ev) => {
        if (typeof ev.data !== 'string') return;
        let msg;
        try { msg = JSON.parse(ev.data); } catch (e) { return; }
        if (ws === sock) onMessage(sock, msg);
      };
      sock.onclose = () => {
        if (ws !== sock) return;
        ws = null;
        if (state === 'recording' || state === 'paused' || state === 'starting' || state === 'reconnecting') {
          if (state !== 'paused') setState('reconnecting');
          const wait = RETRY_MS[Math.min(retry, RETRY_MS.length - 1)];
          retry += 1;
          retryTimer = setTimeout(() => {
            retryTimer = null;
            if (state !== 'idle' && state !== 'stopping') connect();
          }, wait);
        }
      };
    }

    async function teardown() {
      if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
      if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
      try { if (node) node.disconnect(); } catch (e) { /* already gone */ }
      if (stream) stream.getTracks().forEach(t => t.stop());
      if (ctx) { try { await ctx.close(); } catch (e) { /* already closed */ } }
      node = sink = ctx = stream = resampler = chunker = null;
      pending = [];
    }

    async function start(opts) {
      if (state !== 'idle') return;
      const o = opts || {};
      setState('starting');
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: {
          deviceId: o.deviceId ? { exact: o.deviceId } : undefined,
          channelCount: 1,
          // The speech engine does better with the room as it is; the browser's
          // own clean-up is tuned for calls, not for transcription.
          echoCancellation: false, noiseSuppression: false, autoGainControl: true,
        } });
        const track = stream.getAudioTracks()[0];
        sourceLabel = (track && track.label) || o.sourceLabel || 'Browser microphone';
        const AC = window.AudioContext || window.webkitAudioContext;
        ctx = new AC();
        // Made after the mic prompt, the context can start suspended: the click
        // that asked for the mic no longer counts, and then no sound flows at all.
        if (ctx.state === 'suspended') {
          try { await ctx.resume(); } catch (e) { /* still suspended: see below */ }
        }
        if (ctx.state === 'suspended') {
          const running = ctx;
          emit('note', 'Click anywhere on the page to start the microphone.');
          document.addEventListener('pointerdown', () => {
            running.resume().then(() => emit('note', '')).catch(() => {});
          }, { once: true });
        }
        resampler = new Resampler(ctx.sampleRate, RATE);
        chunker = new Chunker(CHUNK);
        startedAt = Date.now();
        chunksMade = 0;
        const input = ctx.createMediaStreamSource(stream);
        sink = ctx.createGain();
        sink.gain.value = 0;                 // pulled by the graph, never heard
        sink.connect(ctx.destination);
        if (ctx.audioWorklet && window.AudioWorkletNode) {
          await ctx.audioWorklet.addModule('static/live_capture_worklet.js');
          node = new AudioWorkletNode(ctx, 'jc-live-capture');
          node.port.onmessage = (ev) => onSamples(ev.data);
        } else {
          node = ctx.createScriptProcessor(4096, 1, 1);
          node.onaudioprocess = (ev) => onSamples(ev.inputBuffer.getChannelData(0));
        }
        input.connect(node);
        node.connect(sink);
        connect();
        pingTimer = setInterval(() => sendJson({ t: 'ping' }), PING_MS);
      } catch (e) {
        await teardown();
        setState('idle');
        emit('error', e && e.name === 'NotAllowedError'
          ? 'The browser was not allowed to use the microphone.'
          : `Could not start recording: ${(e && e.message) || e}`);
      }
    }

    function pause() {
      if (state !== 'recording' && state !== 'reconnecting') return;
      setState('paused');
      sendJson({ t: 'state', state: 'paused' });
    }

    function resume() {
      if (state !== 'paused') return;
      setState(ws && ws.readyState === 1 ? 'recording' : 'reconnecting');
      sendJson({ t: 'state', state: 'recording' });
    }

    async function stop() {
      if (state === 'idle' || state === 'stopping') return;
      setState('stopping');
      const sock = ws;
      if (sock && sock.readyState === 1) {
        // The server finishes the engine's last line before it says it stopped.
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, 4000);
          sock.addEventListener('message', (ev) => {
            if (typeof ev.data !== 'string') return;
            try {
              const m = JSON.parse(ev.data);
              if (m.t === 'state' && m.recording === false) { clearTimeout(timer); resolve(); }
            } catch (e) { /* not the answer */ }
          });
          sock.send(JSON.stringify({ t: 'end' }));
        });
      }
      ws = null;
      try { if (sock) sock.close(); } catch (e) { /* closed */ }
      await teardown();
      setState('idle');
      emit('level', 0);
    }

    function setSource(label) {
      sourceLabel = label || sourceLabel;
      sendJson({ t: 'source', source_label: sourceLabel });
    }

    return {
      start, pause, resume, stop, setSource,
      get state() { return state; },
      get sessionId() { return sessionId; },
      get sourceLabel() { return sourceLabel; },
    };
  }

  return { encodeAudioFrame, Resampler, Chunker, helloFrame, readyNote, rms,
           deviceId, listMics, createCapture, RATE, CHUNK };
}));
