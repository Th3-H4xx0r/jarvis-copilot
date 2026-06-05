/*
 * Voice tab — orb visualizer, mic capture, WS realtime client, karaoke reply.
 *
 * Realtime-only, hands-free (tap-to-toggle):
 *   tap button → open WS /api/voice/s2s/ws → stream 16kHz PCM binary frames
 *   continuously; client-side VAD signals end_turn → server streams back
 *   transcript, assistant_text, audio_meta + binary PCM frames @ 24kHz. Tap
 *   again to end the session. The assistant reply is shown karaoke-style:
 *   words highlight one at a time, driven by the audio playback clock (see the
 *   Karaoke controller + the PcmPlayer per-clip timing hook).
 *
 * Exposed (used by panels.js):
 *   initVoicePanel()       — first entry into the Voice tab
 *   onVoicePanelLeave()    — pause anything streaming when user switches away
 */

(function () {
  'use strict';

  // ---- shared state ----
  const STATE = {
    fsm: 'idle',              // idle | connecting | listening | thinking | speaking | error
    muted: false,
    initialized: false,
    voice: '',
    voices: [],
    status: null,             // /api/voice/status response cache
    orb: null,                // VoiceOrb instance
    mic: null,                // MicCapture instance
    player: null,             // PcmPlayer instance
    ws: null,                 // RealtimeWS instance
    bargeInThreshold: 0.40,   // mic amplitude above this while speaking → interrupt
  };

  // ---- DOM helpers ----
  function $(id) { return document.getElementById(id); }

  function tr(key, fallback) {
    if (typeof t === 'function') {
      const v = t(key);
      if (v && v !== key) return v;
    }
    return fallback || key;
  }

  function setStatus(state, customLabel) {
    STATE.fsm = state;
    const dot = document.querySelector('#voiceStatusLine .voice-status-dot');
    const textEl = document.querySelector('#voiceStatusLine .voice-status-text');
    const stateLabel = $('voiceStateLabel');
    if (dot) dot.dataset.status = state;
    const labels = {
      idle: tr('voice_status_idle', 'Ready'),
      connecting: tr('voice_status_connecting', 'Connecting…'),
      listening: tr('voice_status_listening', 'Listening…'),
      thinking: tr('voice_status_thinking', 'Thinking…'),
      speaking: tr('voice_status_speaking', 'Speaking…'),
      error: tr('voice_status_error', 'Error'),
    };
    const label = customLabel || labels[state] || state;
    if (textEl) textEl.textContent = label;
    if (stateLabel) {
      stateLabel.textContent = label;
      stateLabel.dataset.state = state;
    }
    if (STATE.orb) STATE.orb.setState(state);
    _updateMuteButtonLabel();
    _updateToggleButton();
  }

  // The Mute button does double duty: in Realtime mode while listening, it
  // acts as a "I'm done, process my turn" trigger (sends end_turn). Reflect
  // that in the label so users know which action will fire.
  function _updateMuteButtonLabel() {
    const btn = document.getElementById('voiceMuteBtn');
    if (!btn) return;
    // Only offer end-turn/interrupt when a realtime session is actually live —
    // not during e.g. the TTS-test preview, which also drives the FSM.
    if (STATE.ws && STATE.fsm === 'listening') {
      btn.textContent = tr('voice_btn_done_speaking', 'Done speaking');
      btn.dataset.action = 'end-turn';
      return;
    }
    if (STATE.ws && (STATE.fsm === 'thinking' || STATE.fsm === 'speaking')) {
      btn.textContent = tr('voice_btn_interrupt', 'Interrupt');
      btn.dataset.action = 'interrupt';
      return;
    }
    btn.textContent = STATE.muted
      ? tr('voice_btn_unmute', 'Unmute')
      : tr('voice_btn_mute', 'Mute');
    btn.dataset.action = 'mute-toggle';
  }

  function showError(msg) {
    const el = $('voiceError');
    if (!el) return;
    el.textContent = msg || '';
    el.style.display = msg ? '' : 'none';
  }

  function setTranscript(text, who) {
    const id = who === 'assistant' ? 'voiceAssistantLine' : 'voiceUserLine';
    const el = $(id);
    if (!el) return;
    if (!text) {
      el.style.display = 'none';
      el.textContent = '';
      return;
    }
    el.textContent = text;
    el.style.display = '';
  }

  function clearTranscript() {
    setTranscript('', 'user');
    setTranscript('', 'assistant');
  }

  // ---- VoiceOrbCanvas2D — Canvas particle-sphere visualizer (fallback) ----
  // Ports the spirit of JarvisClaw's VoiceWaveform (apps/web/src/components/
  // VoiceWaveform.tsx) — rotating particle sphere, additive blending, chrome
  // rings, amplitude-driven spike rim, state-driven color. ~250 LOC vs ~430
  // in the React/SVG source; we drop the SVG layer and render everything in
  // a single canvas to keep the dependency surface at zero. Used when WebGL /
  // Three.js is unavailable; otherwise VoiceOrbGL renders the MCU orb.
  class VoiceOrbCanvas2D {
    constructor(canvas) {
      this.canvas = canvas;
      this.ctx = canvas.getContext('2d');
      this.dpr = Math.min(window.devicePixelRatio || 1, 2);
      this.w = 0; this.h = 0;
      this.t = 0;
      this.amp = 0;             // smoothed mic amplitude 0..1
      this.target = 0;          // raw input amplitude (set externally)
      this.state = 'idle';
      this.particles = [];
      // Glass-ribbon orb (matches mobile/watch): wavy loops on a sphere.
      // [amp, k, phase, rx, ry, rz]
      this._strands = [
        [0.20, 2, 0.0, 0.55, 0.30, 0.15],
        [0.26, 2, 2.1, 0.72, 0.58, 0.10],
        [0.18, 1, 4.2, 0.42, 0.85, 0.22],
      ];
      this._t0 = 0;
      this.running = false;
      this._rafId = 0;
      this._resize = this._resize.bind(this);
      this._tick = this._tick.bind(this);
      window.addEventListener('resize', this._resize);
      this._resize();
      this._seedParticles();
    }

    _seedParticles() {
      const N = 360;
      this.particles = new Array(N);
      for (let i = 0; i < N; i++) {
        // Even sphere distribution via golden-spiral
        const golden = Math.PI * (3 - Math.sqrt(5));
        const y = 1 - (i / (N - 1)) * 2;
        const r = Math.sqrt(1 - y * y);
        const theta = golden * i;
        this.particles[i] = {
          x: Math.cos(theta) * r,
          y: y,
          z: Math.sin(theta) * r,
          phase: Math.random() * Math.PI * 2,
        };
      }
    }

    _resize() {
      const parent = this.canvas.parentElement || this.canvas;
      const rect = parent.getBoundingClientRect();
      // Logical size: clamp inside the wrap, square aspect.
      const side = Math.max(120, Math.min(rect.width, rect.height, 360));
      this.w = side;
      this.h = side;
      this.canvas.style.width = side + 'px';
      this.canvas.style.height = side + 'px';
      this.canvas.width = Math.round(side * this.dpr);
      this.canvas.height = Math.round(side * this.dpr);
    }

    setState(state) { this.state = state; }
    setAmplitude(a) { this.target = Math.max(0, Math.min(1, a)); }

    _stateColors() {
      // [innerStop, midStop, outerStop, ringColor]
      switch (this.state) {
        case 'listening':  return ['#9ce8ff', '#3aa7ff', '#1147b8', '#9ce8ff'];
        case 'thinking':   return ['#e0c2ff', '#a263ff', '#3a1080', '#cda1ff'];
        case 'speaking':   return ['#ffd9a8', '#ff8a3a', '#7a2d00', '#ffd9a8'];
        case 'error':      return ['#ff9090', '#ff3030', '#6e0000', '#ff8080'];
        default:           return ['#cfd9ff', '#6080ff', '#10204a', '#a9bcff']; // idle
      }
    }

    start() {
      if (this.running) return;
      this.running = true;
      this._tick();
    }
    stop() {
      this.running = false;
      if (this._rafId) cancelAnimationFrame(this._rafId);
      this._rafId = 0;
    }

    // Per-state palette [highlight, core, accent] — matches mobile/watch orb.
    _palette() {
      switch (this.state) {
        case 'listening': return { hi: '#AFF0FF', core: '#2FB8FF', accent: '#6FD0FF' };
        case 'thinking':  return { hi: '#BFA8FF', core: '#6A5CFF', accent: '#9C8CFF' };
        case 'speaking':  return { hi: '#9FE0FF', core: '#3A86FF', accent: '#7C5CFF' };
        case 'error':     return { hi: '#FFB0BA', core: '#FF6B7E', accent: '#FF9AA6' };
        default:          return { hi: '#8FD8FF', core: '#3A86FF', accent: '#7C5CFF' };
      }
    }

    // Wavy loop on a unit sphere → 3D tilt (+ slow wander) → ortho project.
    _buildStrand(s, rs, gt, undu, t) {
      const amp = s[0], k = s[1], phase = s[2];
      const rx = s[3] + 0.16 * Math.sin(t * 0.11 + phase);
      const ry = s[4] + 0.14 * Math.sin(t * 0.090 + phase * 1.7 + 1.0);
      const rz = s[5] + 0.11 * Math.sin(t * 0.070 + phase * 0.7 + 2.0);
      const cx = Math.cos(rx), sx = Math.sin(rx), cy = Math.cos(ry), sy = Math.sin(ry), cz = Math.cos(rz), sz = Math.sin(rz);
      const M = 80, pts = new Array(M), depth = new Array(M); let sumF = 0;
      for (let i = 0; i < M; i++) {
        const u = i / M * 2 * Math.PI;
        const theta = Math.PI / 2 + amp * Math.sin(k * u + phase + undu);
        const phi = u + gt;
        let x = Math.sin(theta) * Math.cos(phi), y = Math.sin(theta) * Math.sin(phi), z = Math.cos(theta);
        const y1 = y * cx - z * sx, z1 = y * sx + z * cx; y = y1; z = z1;          // Rx
        const x1 = x * cy + z * sy, z2 = -x * sy + z * cy; x = x1; z = z2;         // Ry
        const x2 = x * cz - y * sz, y2 = x * sz + y * cz; x = x2; y = y2;          // Rz
        pts[i] = { x: rs * x, y: -rs * y }; depth[i] = z; sumF += (z + 1) / 2;
      }
      return { pts, depth, meanFront: sumF / M };
    }

    // Filled band: offset the centerline ± a depth-scaled half-width.
    _ribbonPath(b, halfBase) {
      const n = b.pts.length, left = [], right = [];
      for (let i = 0; i < n; i++) {
        const p = b.pts[i], pp = b.pts[(i - 1 + n) % n], pn = b.pts[(i + 1) % n];
        let tx = pn.x - pp.x, ty = pn.y - pp.y; const len = Math.hypot(tx, ty) || 1; tx /= len; ty /= len;
        const nx = -ty, ny = tx; const hw = halfBase * (0.35 + 0.75 * ((b.depth[i] + 1) / 2));
        left.push([p.x + nx * hw, p.y + ny * hw]); right.push([p.x - nx * hw, p.y - ny * hw]);
      }
      const path = new Path2D(); path.moveTo(left[0][0], left[0][1]);
      for (let i = 1; i < n; i++) path.lineTo(left[i][0], left[i][1]);
      for (let i = n - 1; i >= 0; i--) path.lineTo(right[i][0], right[i][1]);
      path.closePath(); return path;
    }

    // Split centerline into front (z≥0) / back polylines for depth shading.
    _edgePaths(b) {
      const n = b.pts.length, front = new Path2D(), back = new Path2D();
      let fOpen = false, bOpen = false;
      for (let i = 0; i <= n; i++) {
        const idx = i % n, p = b.pts[idx];
        if (b.depth[idx] >= -0.05) {
          if (!fOpen) { front.moveTo(p.x, p.y); fOpen = true; } else front.lineTo(p.x, p.y);
          bOpen = false;
        } else {
          if (!bOpen) { back.moveTo(p.x, p.y); bOpen = true; } else back.lineTo(p.x, p.y);
          fOpen = false;
        }
      }
      return { front, back };
    }

    _tick() {
      if (!this.running) return;
      this._rafId = requestAnimationFrame(this._tick);
      const now = (typeof performance !== 'undefined' ? performance.now() : Date.now()) / 1000;
      if (!this._t0) this._t0 = now;
      const t = now - this._t0;
      // smooth amplitude (fast attack / quick release)
      const k = this.target > this.amp ? 0.30 : 0.16;
      this.amp += (this.target - this.amp) * k;

      const ctx = this.ctx, W = this.canvas.width, H = this.canvas.height;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, W, H);
      ctx.save();
      ctx.translate(W / 2, H / 2);
      const R = Math.min(W, H) / 2;
      const pal = this._palette();

      const breath = 0.5 + 0.5 * Math.sin(t * 0.9);
      const talk = 0.5 + 0.5 * Math.sin(t * 3.4);
      const pulse = 0.5 + 0.5 * Math.sin(t * 1.7);
      let reactive = 0, spin = 0.05, energy = 0.34, unduRate = 0.55;
      switch (this.state) {
        case 'listening': reactive = 1 - Math.exp(-5 * this.amp); spin = 0.10; energy = 0.46; unduRate = 0.34 + 0.28 * reactive; break;
        case 'speaking':  reactive = 0.30 + 0.45 * talk; spin = 0.12; energy = 0.55; break;
        case 'thinking':  reactive = 0.10 + 0.22 * pulse; spin = 0.14; energy = 0.58; break;
        default:          reactive = 0.06 + 0.13 * pulse; spin = 0.13; energy = 0.42; break; // idle, lively
      }
      const wander = 0.20 * Math.sin(t * 0.13) + 0.12 * Math.sin(t * 0.22 + 2.1);
      const gt = t * spin + wander;
      const undu = t * unduRate;
      const scale = 1 + 0.025 * breath + 0.34 * reactive;
      const rs = R * 0.56 * scale;
      const bright = Math.min(0.80 + 0.28 * energy + 0.36 * reactive, 1.45);

      ctx.globalCompositeOperation = 'lighter';

      // halo (additive radial gradient)
      const haloR = rs * (1.5 + 0.30 * reactive);
      const halo = ctx.createRadialGradient(0, 0, 0, 0, 0, haloR);
      halo.addColorStop(0, this._withAlpha(pal.core, 0.20 * bright));
      halo.addColorStop(0.55, this._withAlpha(pal.accent, 0.08 * bright));
      halo.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = halo; ctx.beginPath(); ctx.arc(0, 0, haloR, 0, Math.PI * 2); ctx.fill();

      // ribbons, back → front
      const built = this._strands.map(s => this._buildStrand(s, rs, gt, undu, t));
      built.sort((a, b) => a.meanFront - b.meanFront);
      const halfBase = rs * 0.17 * (1 + 0.45 * reactive);
      const sheetCol = this._lerpColor(pal.core, pal.hi, 0.4);
      const edgeCol = this._lerpColor(pal.hi, '#ffffff', 0.5);
      const supportsFilter = ('filter' in ctx);
      for (const b of built) {
        const band = this._ribbonPath(b, halfBase);
        ctx.save();
        if (supportsFilter) ctx.filter = `blur(${(rs * 0.05).toFixed(1)}px)`;
        ctx.fillStyle = this._withAlpha(sheetCol, Math.min((0.26 + 0.18 * b.meanFront) * bright, 0.72));
        ctx.fill(band);
        ctx.restore();
        const eg = this._edgePaths(b);
        ctx.lineCap = 'round';
        ctx.strokeStyle = this._withAlpha(edgeCol, Math.min(0.22 * bright, 0.5));
        ctx.lineWidth = rs * 0.014; ctx.stroke(eg.back);
        ctx.strokeStyle = this._withAlpha(edgeCol, Math.min(0.55 * bright, 0.85));
        ctx.lineWidth = rs * 0.020; ctx.stroke(eg.front);
      }

      // fresnel rim
      ctx.save();
      if (supportsFilter) ctx.filter = `blur(${(rs * 0.04).toFixed(1)}px)`;
      ctx.strokeStyle = this._withAlpha(this._lerpColor(pal.core, '#ffffff', 0.5), Math.min(0.45 * bright, 0.7));
      ctx.lineWidth = rs * 0.03;
      ctx.beginPath(); ctx.arc(0, 0, rs, 0, Math.PI * 2); ctx.stroke();
      ctx.restore();

      ctx.globalCompositeOperation = 'source-over';
      ctx.restore();
    }

    _chromeRing(ctx, r, rot, segments) {
      ctx.save();
      ctx.rotate(rot);
      ctx.beginPath();
      const segLen = (Math.PI * 2) / segments;
      const gap = segLen * 0.35;
      for (let i = 0; i < segments; i++) {
        const a0 = i * segLen;
        const a1 = a0 + (segLen - gap);
        ctx.moveTo(Math.cos(a0) * r, Math.sin(a0) * r);
        ctx.arc(0, 0, r, a0, a1);
      }
      ctx.stroke();
      ctx.restore();
    }

    _withAlpha(hex, a) {
      const c = this._hex(hex);
      return `rgba(${c.r},${c.g},${c.b},${a})`;
    }
    _hex(hex) {
      const m = hex.replace('#', '');
      const v = m.length === 3
        ? m.split('').map(c => c + c).join('')
        : m;
      return {
        r: parseInt(v.substring(0, 2), 16),
        g: parseInt(v.substring(2, 4), 16),
        b: parseInt(v.substring(4, 6), 16),
      };
    }
    _lerpColor(h1, h2, t) {
      const a = this._hex(h1), b = this._hex(h2);
      const r = Math.round(a.r + (b.r - a.r) * t);
      const g = Math.round(a.g + (b.g - a.g) * t);
      const bb = Math.round(a.b + (b.b - a.b) * t);
      return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${bb.toString(16).padStart(2, '0')}`;
    }
  }

  // ---- VoiceOrbGL — MCU JARVIS orb (WebGL / Three.js) ----
  // A DENSE amber particle shell rendered with a custom additive shader:
  // front-facing points glow brighter (depth fade) and twinkle per-point, so
  // the cloud reads as a luminous holographic sphere instead of scattered
  // dots. A tight white-hot core, an ambient bloom halo, and three slow
  // gyroscopic reticle rings (clean full circles) complete the look. Same
  // public API as VoiceOrbCanvas2D (constructor(canvas), start, stop,
  // setState, setAmplitude, _resize) so the call site is interchangeable.
  function _radialTexture(THREE, stops) {
    const c = document.createElement('canvas');
    c.width = c.height = 128;
    const g = c.getContext('2d');
    const grd = g.createRadialGradient(64, 64, 0, 64, 64, 64);
    for (const [stop, color] of stops) grd.addColorStop(stop, color);
    g.fillStyle = grd;
    g.fillRect(0, 0, 128, 128);
    const t = new THREE.Texture(c);
    t.needsUpdate = true;
    return t;
  }

  // Per-point: depth-faded brightness (front of the sphere glows) + twinkle,
  // size attenuated by distance and pumped by amplitude.
  const _ORB_VERT = `
    attribute float aSize;
    attribute float aPhase;
    uniform float uTime;
    uniform float uAmp;
    uniform float uSize;
    uniform float uPixelRatio;
    varying float vAlpha;
    void main() {
      vec4 mv = modelViewMatrix * vec4(position, 1.0);
      float depth = -mv.z;
      float front = smoothstep(4.8, 2.2, depth);          // 1 near camera, 0 far
      float tw = 0.55 + 0.45 * sin(uTime * 1.8 + aPhase);  // per-point twinkle
      vAlpha = (0.22 + 0.78 * front) * tw;
      gl_Position = projectionMatrix * mv;
      gl_PointSize = uSize * aSize * uPixelRatio * (1.0 + uAmp * 0.5) / depth;
    }
  `;
  // Round soft point with a hot center; additive blending sums the overlaps
  // into the shell glow.
  const _ORB_FRAG = `
    precision mediump float;
    uniform vec3 uColor;
    uniform vec3 uHot;
    varying float vAlpha;
    void main() {
      vec2 uv = gl_PointCoord - 0.5;
      float d = length(uv);
      if (d > 0.5) discard;
      float core = smoothstep(0.5, 0.0, d);
      vec3 col = mix(uColor, uHot, pow(core, 3.0) * 0.7);
      gl_FragColor = vec4(col, pow(core, 2.2) * vAlpha);
    }
  `;

  class VoiceOrbGL {
    constructor(canvas) {
      const THREE = window.THREE;
      this.canvas = canvas;
      this.state = 'idle';
      this.amp = 0;        // smoothed amplitude
      this.target = 0;     // raw input amplitude
      this._raf = 0;
      this._t = 0;

      this.renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
      this.renderer.setClearColor(0x000000, 0);
      this.scene = new THREE.Scene();
      this.camera = new THREE.PerspectiveCamera(45, 1, 0.1, 100);
      this.camera.position.z = 3.6;
      this.group = new THREE.Group();
      this.scene.add(this.group);

      // Ambient bloom halo behind everything (fakes the glow without an
      // expensive post-process bloom pass).
      this.halo = new THREE.Sprite(new THREE.SpriteMaterial({
        map: _radialTexture(THREE, [
          [0.0, 'rgba(255,150,40,0.55)'],
          [0.35, 'rgba(255,110,0,0.18)'],
          [1.0, 'rgba(255,90,0,0)'],
        ]),
        transparent: true, depthWrite: false, depthTest: false,
        blending: THREE.AdditiveBlending, opacity: 0.5,
      }));
      this.halo.scale.set(3.4, 3.4, 1);
      this.halo.position.z = -0.5;
      this.scene.add(this.halo);

      // Dense particle shell — Fibonacci distribution with small jitter so the
      // golden-spiral lattice doesn't read as visible "arms".
      const N = 9000;
      const pos = new Float32Array(N * 3);
      const aSize = new Float32Array(N);
      const aPhase = new Float32Array(N);
      const golden = Math.PI * (3 - Math.sqrt(5));
      for (let i = 0; i < N; i++) {
        const y = 1 - (i / (N - 1)) * 2;
        const r = Math.sqrt(Math.max(0, 1 - y * y));
        const phi = golden * i;
        const jr = 1 + (Math.random() - 0.5) * 0.06;
        pos[i * 3]     = (Math.cos(phi) * r + (Math.random() - 0.5) * 0.03) * jr;
        pos[i * 3 + 1] = (y            + (Math.random() - 0.5) * 0.03) * jr;
        pos[i * 3 + 2] = (Math.sin(phi) * r + (Math.random() - 0.5) * 0.03) * jr;
        aSize[i] = 0.5 + Math.random() * 1.1;
        aPhase[i] = Math.random() * Math.PI * 2;
      }
      const geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
      geo.setAttribute('aSize', new THREE.BufferAttribute(aSize, 1));
      geo.setAttribute('aPhase', new THREE.BufferAttribute(aPhase, 1));
      this.uniforms = {
        uTime: { value: 0 },
        uAmp: { value: 0 },
        uSize: { value: 6.5 },
        uPixelRatio: { value: 1 },
        uColor: { value: new THREE.Color(0xff8a1e) },
        uHot: { value: new THREE.Color(0xfff1d6) },
      };
      this.mat = new THREE.ShaderMaterial({
        uniforms: this.uniforms,
        vertexShader: _ORB_VERT,
        fragmentShader: _ORB_FRAG,
        transparent: true, depthTest: false, depthWrite: false,
        blending: THREE.AdditiveBlending,
      });
      this.points = new THREE.Points(geo, this.mat);
      this.group.add(this.points);

      // Gyroscopic reticle rings — clean full circles at fixed tilts, each
      // spinning slowly on its own axis (the orbital-gyroscope HUD look).
      const ringDefs = [
        { rx: 1.25, ry: 0.0, rad: 1.50, op: 0.32 },
        { rx: -0.6, ry: 0.9, rad: 1.62, op: 0.22 },
        { rx: 0.2, ry: -0.7, rad: 1.16, op: 0.40 },
      ];
      this.rings = [];
      for (const def of ringDefs) {
        const segs = 220;
        const rp = new Float32Array((segs + 1) * 3);
        for (let i = 0; i <= segs; i++) {
          const a = (i / segs) * Math.PI * 2;
          rp[i * 3] = Math.cos(a) * def.rad;
          rp[i * 3 + 1] = Math.sin(a) * def.rad;
          rp[i * 3 + 2] = 0;
        }
        const rg = new THREE.BufferGeometry();
        rg.setAttribute('position', new THREE.BufferAttribute(rp, 3));
        const rl = new THREE.Line(rg, new THREE.LineBasicMaterial({
          color: 0xffa23a, transparent: true, opacity: def.op,
          blending: THREE.AdditiveBlending, depthTest: false,
        }));
        rl.rotation.x = def.rx;
        rl.rotation.y = def.ry;
        rl.userData.spin = -0.004 + (Math.random() - 0.5) * 0.01;
        this.scene.add(rl);
        this.rings.push(rl);
      }

      // Tight white-hot core.
      this.core = new THREE.Sprite(new THREE.SpriteMaterial({
        map: _radialTexture(THREE, [
          [0.0, 'rgba(255,255,250,1)'],
          [0.3, 'rgba(255,220,160,0.85)'],
          [0.7, 'rgba(255,140,40,0.25)'],
          [1.0, 'rgba(255,120,0,0)'],
        ]),
        transparent: true, depthWrite: false, depthTest: false,
        blending: THREE.AdditiveBlending,
      }));
      this.core.scale.set(0.7, 0.7, 1);
      this.scene.add(this.core);

      this._tick = this._tick.bind(this);
      this._resize = this._resize.bind(this);
      window.addEventListener('resize', this._resize);
      this._resize();
    }

    setState(state) { this.state = state; }
    setAmplitude(a) { this.target = Math.max(0, Math.min(1, a)); }

    _resize() {
      const parent = this.canvas.parentElement || this.canvas;
      const rect = parent.getBoundingClientRect();
      const side = Math.max(80, Math.min(rect.width || 320, rect.height || 320, 640));
      const pr = Math.min(window.devicePixelRatio || 1, 2);
      this.renderer.setPixelRatio(pr);
      this.renderer.setSize(side, side);  // updateStyle=true → sets CSS + buffer
      this.uniforms.uPixelRatio.value = pr;
      this.camera.aspect = 1;
      this.camera.updateProjectionMatrix();
    }

    start() { if (!this._raf) this._raf = requestAnimationFrame(this._tick); }
    stop() {
      if (this._raf) cancelAnimationFrame(this._raf);
      this._raf = 0;
    }

    _tick() {
      this._raf = requestAnimationFrame(this._tick);
      // Smooth amplitude towards the input (snappier on rise).
      const k = this.target > this.amp ? 0.30 : 0.10;
      this.amp += (this.target - this.amp) * k;
      this._t += 1 / 60;
      const now = this._t;

      const active = this.state === 'listening' || this.state === 'speaking';
      const thinking = this.state === 'thinking';
      const speed = thinking ? 0.020 : (active ? 0.010 : 0.0045);
      this.group.rotation.y += speed;
      this.group.rotation.x = Math.sin(now * 0.15) * 0.18;
      for (const r of this.rings) r.rotation.z += r.userData.spin;

      // Effective "energy" drives glow: real amplitude when active, a gentle
      // breathing pulse when idle/thinking so the orb is always alive.
      const idlePulse = 0.5 + 0.5 * Math.sin(now * 1.1);
      const energy = active ? this.amp : idlePulse * (thinking ? 0.35 : 0.12);

      this.uniforms.uTime.value = now;
      this.uniforms.uAmp.value = energy;

      const scale = 1
        + (active ? this.amp * 0.16 : 0)
        + (thinking ? 0.03 * Math.sin(now * 5.5) : 0);
      this.group.scale.setScalar(scale);

      const coreS = 0.6 + energy * 0.5;
      this.core.scale.set(coreS, coreS, 1);
      this.core.material.opacity = 0.7 + energy * 0.3;
      this.halo.material.opacity = 0.35 + energy * 0.35;

      this.renderer.render(this.scene, this.camera);
    }
  }

  // Choose the WebGL orb when Three.js + a WebGL context are available, else
  // the Canvas-2D fallback. Probes on a throwaway canvas so we never consume
  // the real canvas's context with the wrong type before WebGLRenderer claims
  // it.
  function createVoiceOrb(canvas) {
    // Always use the Canvas-2D glass-ribbon orb so the WebUI matches the
    // mobile/watch orb exactly. (VoiceOrbGL is kept above but no longer used.)
    return new VoiceOrbCanvas2D(canvas);
  }

  // Back-compat: the call site does `new VoiceOrb(canvas)`. A constructor that
  // returns an object yields that object from `new`, so this thin wrapper keeps
  // the call site unchanged while transparently selecting GL-or-2D.
  function VoiceOrb(canvas) { return createVoiceOrb(canvas); }

  // ---- MicCapture — WebAudio mic → 16 kHz mono int16 PCM ----
  // Uses ScriptProcessorNode (deprecated but ubiquitous) + manual decimation.
  // We avoid AudioWorklet to keep the file self-contained — no separate
  // worklet module to ship.
  class MicCapture {
    constructor() {
      this.stream = null;
      this.ctx = null;
      this.source = null;
      this.proc = null;
      this.analyser = null;
      this.targetSampleRate = 16000;
      this.onFrame = null;          // (int16Array) => void
      this.onAmplitude = null;      // (float 0..1) => void
      this._ampBuf = new Float32Array(1024);
    }

    async start() {
      if (this.stream) return;
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        }
      });
      const AC = window.AudioContext || window.webkitAudioContext;
      this.ctx = new AC();
      this.source = this.ctx.createMediaStreamSource(this.stream);
      this.analyser = this.ctx.createAnalyser();
      this.analyser.fftSize = 1024;
      this.source.connect(this.analyser);
      // Tap audio for processing — we use ScriptProcessor (deprecated, fine here).
      const bufSize = 4096;
      this.proc = this.ctx.createScriptProcessor(bufSize, 1, 1);
      this.proc.onaudioprocess = (ev) => this._onAudio(ev);
      this.source.connect(this.proc);
      // ScriptProcessor must connect to a destination to fire callbacks in
      // some browsers — wire it to a muted gain so we don't loop audio out.
      const mute = this.ctx.createGain();
      mute.gain.value = 0;
      this.proc.connect(mute);
      mute.connect(this.ctx.destination);
    }

    stop() {
      try { this.proc && this.proc.disconnect(); } catch (e) {}
      try { this.source && this.source.disconnect(); } catch (e) {}
      try { this.analyser && this.analyser.disconnect(); } catch (e) {}
      try { this.stream && this.stream.getTracks().forEach(t => t.stop()); } catch (e) {}
      try { this.ctx && this.ctx.close(); } catch (e) {}
      this.stream = null; this.ctx = null; this.source = null;
      this.proc = null; this.analyser = null;
    }

    _onAudio(ev) {
      const input = ev.inputBuffer.getChannelData(0);
      // Amplitude (peak in this buffer)
      let peak = 0;
      for (let i = 0; i < input.length; i++) {
        const v = Math.abs(input[i]);
        if (v > peak) peak = v;
      }
      if (this.onAmplitude) this.onAmplitude(peak);
      // Downsample to 16 kHz via linear interpolation.
      const inSR = this.ctx.sampleRate;
      const ratio = inSR / this.targetSampleRate;
      const outLen = Math.floor(input.length / ratio);
      const out = new Int16Array(outLen);
      let idx = 0;
      for (let i = 0; i < outLen; i++) {
        const srcIdx = i * ratio;
        const i0 = Math.floor(srcIdx);
        const frac = srcIdx - i0;
        const s = input[i0] * (1 - frac) + (input[i0 + 1] || input[i0]) * frac;
        const clamped = Math.max(-1, Math.min(1, s));
        out[idx++] = clamped < 0 ? clamped * 0x8000 : clamped * 0x7FFF;
      }
      if (this.onFrame) this.onFrame(out);
    }
  }

  // ---- LiveSpeech — interim transcript via browser SpeechRecognition ----
  // Browser-side STT (Chrome/Brave/Safari/Edge — not Firefox) gives a near-zero
  // latency interim transcript while the user speaks. JarvisCopilot's server-side
  // STT still runs in parallel and provides the canonical transcript that
  // drives the LLM call; this class only feeds the on-screen user line so
  // the user sees their words appear as they say them. Falls back gracefully
  // on unsupported browsers — just no live display.
  class LiveSpeech {
    constructor() {
      const Recog = window.SpeechRecognition || window.webkitSpeechRecognition;
      this.supported = !!Recog;
      this.recog = null;
      this.onInterim = null;   // (text:string, isFinal:boolean) => void
      this.onError = null;     // (errEvent) => void
      if (!this.supported) return;
      this.recog = new Recog();
      this.recog.continuous = true;
      this.recog.interimResults = true;
      this.recog.lang = (navigator.language || 'en-US').replace('_', '-');
      this.recog.onresult = (event) => {
        let interim = '';
        let final = '';
        for (let i = event.resultIndex; i < event.results.length; i++) {
          const r = event.results[i];
          if (r.isFinal) final += r[0].transcript;
          else interim += r[0].transcript;
        }
        const text = (final + interim).trim();
        if (text && this.onInterim) {
          this.onInterim(text, !!final && !interim);
        }
      };
      this.recog.onerror = (e) => {
        // 'no-speech' fires constantly while quiet — ignore it, it isn't fatal
        if (e && e.error === 'no-speech') return;
        if (this.onError) this.onError(e);
      };
    }
    start() {
      if (!this.supported || !this.recog) return false;
      try { this.recog.start(); return true; } catch (e) { return false; }
    }
    stop() {
      if (!this.supported || !this.recog) return;
      try { this.recog.stop(); } catch (e) {}
      try { this.recog.abort(); } catch (e) {}
    }
  }

  // ---- PcmPlayer — queue + play 24 kHz int16 PCM frames via WebAudio ----
  class PcmPlayer {
    constructor() {
      this.ctx = null;
      this.sampleRate = 24000;
      this.queueEnd = 0;
      this.playing = false;
      this.onAmplitude = null;       // (float 0..1) for orb feedback
      // Karaoke timing hooks. setClipTag() tags the segment whose audio is
      // about to stream in; onClipStart(tag, startAtSec) fires once when that
      // segment's first audio is scheduled; onClipDur(tag, ms) accrues as PCM
      // frames arrive (the karaoke schedules words across this duration).
      this.onClipStart = null;
      this.onClipDur = null;
      this._clipTag = null;
      this._clipStarted = false;
    }
    setClipTag(tag) { this._clipTag = tag; this._clipStarted = false; }
    nowSec() { return this.ctx ? this.ctx.currentTime : 0; }
    _noteClip(startAt, durSec) {
      if (this._clipTag == null) return;
      if (!this._clipStarted) {
        this._clipStarted = true;
        if (this.onClipStart) this.onClipStart(this._clipTag, startAt);
      }
      if (this.onClipDur) this.onClipDur(this._clipTag, durSec * 1000);
    }
    _ensureCtx() {
      if (this.ctx) return;
      const AC = window.AudioContext || window.webkitAudioContext;
      this.ctx = new AC({ sampleRate: this.sampleRate });
    }
    pushPcm16le(arrayBuffer) {
      this._ensureCtx();
      const view = new Int16Array(arrayBuffer);
      const buf = this.ctx.createBuffer(1, view.length, this.sampleRate);
      const ch = buf.getChannelData(0);
      let peak = 0;
      for (let i = 0; i < view.length; i++) {
        const s = view[i] / 0x8000;
        ch[i] = s;
        const a = Math.abs(s);
        if (a > peak) peak = a;
      }
      if (this.onAmplitude) this.onAmplitude(peak);
      const src = this.ctx.createBufferSource();
      src.buffer = buf;
      src.connect(this.ctx.destination);
      const startAt = Math.max(this.ctx.currentTime, this.queueEnd);
      src.start(startAt);
      this.queueEnd = startAt + buf.duration;
      this.playing = true;
      this._noteClip(startAt, buf.duration);
    }
    async playMp3Bytes(uint8) {
      this._ensureCtx();
      // Snapshot the tag BEFORE the async decode — a later segment's
      // setClipTag() during the await must not retarget this (whole) clip.
      const clipTag = this._clipTag;
      const buf = await this.ctx.decodeAudioData(uint8.buffer.slice(uint8.byteOffset, uint8.byteOffset + uint8.byteLength));
      const src = this.ctx.createBufferSource();
      src.buffer = buf;
      src.connect(this.ctx.destination);
      const startAt = Math.max(this.ctx.currentTime, this.queueEnd);
      src.start(startAt);
      this.queueEnd = startAt + buf.duration;
      this.playing = true;
      // MP3 arrives as one complete clip per call, so report start + full
      // duration directly against the snapshotted tag.
      if (clipTag != null) {
        if (this.onClipStart) this.onClipStart(clipTag, startAt);
        if (this.onClipDur) this.onClipDur(clipTag, buf.duration * 1000);
      }
      return new Promise(res => { src.onended = res; });
    }
    stop() {
      if (this.ctx) {
        try { this.ctx.close(); } catch (e) {}
      }
      this.ctx = null;
      this.queueEnd = 0;
      this.playing = false;
      this._clipTag = null;
      this._clipStarted = false;
    }
  }

  // ---- RealtimeWS — WebSocket client for /api/voice/s2s/ws ----
  class RealtimeWS {
    constructor() {
      this.ws = null;
      this.onText = null;     // (obj) => void
      this.onBinary = null;   // (ArrayBuffer) => void
      this.onClose = null;
      this.onError = null;
      this.format = 'pcm_s16le';
      this.sampleRate = 24000;
    }
    open() {
      return new Promise((resolve, reject) => {
        const proto = location.protocol === 'https:' ? 'wss' : 'ws';
        const url = `${proto}://${location.host}/api/voice/s2s/ws`;
        let ws;
        try { ws = new WebSocket(url); } catch (e) { return reject(e); }
        ws.binaryType = 'arraybuffer';
        ws.onopen = () => { this.ws = ws; resolve(); };
        ws.onerror = (e) => { if (this.onError) this.onError(e); reject(new Error('ws error')); };
        ws.onclose = () => {
          if (this.onClose) this.onClose();
          this.ws = null;
        };
        ws.onmessage = (ev) => {
          if (typeof ev.data === 'string') {
            let obj = null;
            try { obj = JSON.parse(ev.data); } catch (e) {}
            if (obj && obj.type === 'audio_meta') {
              this.format = obj.format || 'pcm_s16le';
              this.sampleRate = obj.sample_rate || 24000;
            }
            if (this.onText && obj) this.onText(obj);
          } else if (ev.data instanceof ArrayBuffer) {
            if (this.onBinary) this.onBinary(ev.data);
          }
        };
      });
    }
    sendJson(obj) {
      if (!this.ws || this.ws.readyState !== 1) return false;
      try { this.ws.send(JSON.stringify(obj)); return true; } catch (e) { return false; }
    }
    sendBinary(ab) {
      if (!this.ws || this.ws.readyState !== 1) return false;
      try { this.ws.send(ab); return true; } catch (e) { return false; }
    }
    close() {
      if (this.ws) {
        try { this.ws.close(); } catch (e) {}
      }
      this.ws = null;
    }
    isOpen() { return !!this.ws && this.ws.readyState === 1; }
  }

  // Voice needs a chat session to route the turn through (so it gets tools +
  // segmented responses). In the mini popup there's no chat UI to pick one, so
  // auto-create one on first use via the global newSession() — the same call
  // the chat surface makes when none exists. Returns the session id ("" if it
  // couldn't be created, e.g. newSession unavailable).
  async function _ensureVoiceSession() {
    const _sid = () => (typeof S !== 'undefined' && S && S.session && S.session.session_id) || '';
    let sid = _sid();
    if (sid) return sid;
    // Preferred: the app's own creator (keeps S + the session list in sync).
    if (typeof newSession === 'function') {
      try { await newSession(); } catch (e) { console.warn('[voice] newSession() failed:', e); }
      sid = _sid();
      if (sid) return sid;
    }
    // Fallback: create the session directly so the mini popup works even if
    // newSession() isn't available or threw.
    try {
      const profile = (typeof S !== 'undefined' && S && S.activeProfile) || 'default';
      const res = await fetch('api/session/new', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ profile }),
      });
      if (res.ok) {
        const data = await res.json().catch(() => ({}));
        const s = data && data.session;
        if (s && s.session_id) {
          if (typeof S !== 'undefined' && S) { S.session = s; S.messages = s.messages || []; }
          return s.session_id;
        }
      } else {
        console.warn('[voice] /api/session/new failed:', res.status);
      }
    } catch (e) {
      console.warn('[voice] /api/session/new error:', e);
    }
    return '';
  }

  // ---- Realtime conversation (WS streaming) ----
  async function startRealtime() {
    // STATE.ws is non-null from 'connecting' onward, so this also rejects a
    // second tap during the connect window (which would otherwise overwrite
    // STATE.ws and leak the first socket).
    if (STATE.ws) return;
    showError('');
    // Clear the stale "what you said" line, but KEEP the previous reply on
    // screen — it's replaced only when this conversation's reply streams in
    // (Karaoke.beginReply), so the last answer stays visible meanwhile.
    setTranscript('', 'user');
    STATE._asstActive = false;
    if (!STATE.mic) STATE.mic = new MicCapture();
    if (!STATE.player) STATE.player = new PcmPlayer();
    STATE.player.onAmplitude = (a) => { if (STATE.orb) STATE.orb.setAmplitude(a); };
    STATE.player.onClipStart = (tag, startAt) => Karaoke.onClipStart(tag, startAt);
    STATE.player.onClipDur = (tag, ms) => Karaoke.accrueDur(tag, ms);
    setStatus('connecting');
    const ws = new RealtimeWS();
    STATE.ws = ws;
    ws.onText = onRealtimeText;
    ws.onBinary = onRealtimeBinary;
    // Guard the close/error callbacks on identity so a stale socket (e.g. one
    // the server idle-closes after we've started a new session) can't clobber
    // the current session's state.
    ws.onError = () => {
      if (STATE.ws !== ws) return;
      showError(tr('voice_err_ws_failed', 'Realtime connection failed.'));
      setStatus('error');
    };
    ws.onClose = () => {
      if (STATE.ws !== ws) return;
      STATE.ws = null;
      STATE._asstActive = false;
      Karaoke.finishReply();
      setStatus('idle');
    };
    try {
      await ws.open();
    } catch (e) {
      if (STATE.ws === ws) STATE.ws = null;
      showError(tr('voice_err_ws_failed', 'Realtime connection failed.'));
      setStatus('error');
      return;
    }
    if (STATE.ws !== ws) return;  // torn down during open()
    try {
      await STATE.mic.start();
    } catch (e) {
      showError(tr('voice_err_no_mic', 'Microphone access denied or unavailable.'));
      setStatus('error');
      ws.close();
      if (STATE.ws === ws) STATE.ws = null;
      return;
    }
    // Realtime mode also routes through the user's active chat session so
    // it gets tools + segmented ack-tool-confirm responses. Auto-create one if
    // none exists (e.g. the mini popup) instead of falling back to a tool-less
    // reply.
    const _sid = await _ensureVoiceSession();
    if (STATE.ws !== ws) return;  // torn down during mic.start() / session create
    ws.sendJson({ type: 'begin_turn', sample_rate: 16000, session_id: _sid });
    setStatus('listening');
    _startLiveSpeech();
    // VAD heuristic — two phases per turn so a quiet room doesn't fire
    // end_turn the moment you tap-to-start:
    //   PHASE 1: wait for actual speech (amp > SPEECH_THRESHOLD). Until we
    //            see it, we don't accumulate silence. The orb stays in
    //            listening state with no clock ticking.
    //   PHASE 2: once you've started speaking, count silence (amp <
    //            SILENCE_THRESHOLD) toward end_turn. ~1.5s of quiet ends
    //            the utterance.
    // Thresholds are tuned for a normal indoor mic on a laptop/phone: speech
    // routinely peaks above 0.08; ambient room noise + fan stays under 0.04.
    STATE._silenceMs = 0;
    STATE._lastFrameAt = performance.now();
    STATE._hasSpoken = false;
    const SPEECH_THRESHOLD = 0.08;   // amp above this = user is talking
    const SILENCE_THRESHOLD = 0.04;  // amp below this = silence within an utterance
    const END_TURN_SILENCE_MS = 1500;
    STATE.mic.onFrame = (int16) => {
      if (!STATE.ws || !STATE.ws.isOpen()) return;
      if (STATE.muted) return;
      if (STATE.fsm === 'speaking' && peakOf(int16) < STATE.bargeInThreshold) return;
      STATE.ws.sendBinary(int16.buffer.slice(0));
    };
    STATE.mic.onAmplitude = (a) => {
      if (STATE.orb && STATE.fsm !== 'speaking') STATE.orb.setAmplitude(a);
      const now = performance.now();
      const dt = now - STATE._lastFrameAt;
      STATE._lastFrameAt = now;
      if (STATE.fsm === 'listening') {
        if (!STATE._hasSpoken) {
          // PHASE 1: ignore everything until we hear real speech. This is
          // what stops a quiet room from triggering end_turn the instant
          // you click Tap to start.
          if (a >= SPEECH_THRESHOLD) STATE._hasSpoken = true;
          return;
        }
        // PHASE 2: end-of-utterance silence detection.
        if (a < SILENCE_THRESHOLD) STATE._silenceMs += dt;
        else STATE._silenceMs = 0;
        if (STATE._silenceMs > END_TURN_SILENCE_MS) {
          STATE._silenceMs = 0;
          STATE._hasSpoken = false;  // reset for the next turn
          STATE.ws.sendJson({ type: 'end_turn' });
          setStatus('thinking');
        }
      } else if (STATE.fsm === 'speaking') {
        // Barge-in detection — user spoke loudly during assistant playback
        if (a > STATE.bargeInThreshold) {
          STATE.ws.sendJson({ type: 'interrupt' });
        }
      }
    };
  }

  function onRealtimeText(obj) {
    const t = (obj && obj.type) || '';
    if (t === 'ready') {
      // The server is in bridge mode — already noted in status
    } else if (t === 'transcript') {
      setTranscript(obj.text || '', 'user');
    } else if (t === 'assistant_text') {
      // Each chunk is a karaoke segment paired with the audio clip that
      // follows it. beginReply() clears the previous turn's text; the flag is
      // cleared on end_turn so the next reply starts fresh.
      if (!STATE._asstActive) { Karaoke.beginReply(); STATE._asstActive = true; }
      if (obj.text) {
        Karaoke.addSegment(obj.text);
        // Tag the player so the binary frames that follow are timed against
        // this segment for the word highlight.
        if (STATE.player) STATE.player.setClipTag(Karaoke.segs.length - 1);
      }
      setStatus('speaking');
    } else if (t === 'audio_meta') {
      // Format/sample-rate stashed by RealtimeWS already.
      if (obj.format === 'mp3') {
        // Server is shipping a single MP3 blob; we'll get one binary frame
        // and decode via WebAudio.decodeAudioData.
        STATE._mp3Buf = [];
      }
    } else if (t === 'audio_end') {
      if (STATE._mp3Buf && STATE._mp3Buf.length) {
        const merged = mergeUint8(STATE._mp3Buf);
        STATE._mp3Buf = null;
        if (STATE.player) STATE.player.playMp3Bytes(merged).catch(() => {});
      }
    } else if (t === 'end_turn') {
      // Next assistant reply should start a fresh accumulation.
      STATE._asstActive = false;
      Karaoke.finishReply();
      // Resume listening for the next user utterance, but only when
      // any queued audio has finished playing.
      const wait = STATE.player ? Math.max(0, (STATE.player.queueEnd - STATE.player.ctx?.currentTime) * 1000) : 0;
      setTimeout(() => {
        if (STATE.ws && STATE.ws.isOpen()) {
          setStatus('listening');
          // Clear the user transcript line so the next interim display
          // starts fresh; the assistant line stays visible until next reply.
          setTranscript('', 'user');
          _startLiveSpeech();
        }
      }, wait);
      // Reset VAD state for the next utterance so we wait for actual
      // speech before counting silence again.
      STATE._silenceMs = 0;
      STATE._hasSpoken = false;
    }
  }

  function onRealtimeBinary(ab) {
    if (STATE.ws && STATE.ws.format === 'mp3') {
      if (!STATE._mp3Buf) STATE._mp3Buf = [];
      STATE._mp3Buf.push(new Uint8Array(ab));
    } else {
      // pcm_s16le @ 24kHz
      if (STATE.player) STATE.player.pushPcm16le(ab);
    }
  }

  function stopRealtime() {
    if (STATE.ws) {
      try { STATE.ws.sendJson({ type: 'interrupt' }); } catch (e) {}
      STATE.ws.close();
      STATE.ws = null;
    }
    if (STATE.mic) STATE.mic.stop();
    _stopLiveSpeech();
    if (STATE.player) { STATE.player.stop(); STATE.player = null; }
    STATE._asstActive = false;
    // Keep the last reply on screen (fully lit) rather than wiping it — it's
    // replaced when the next conversation's reply starts (beginReply).
    Karaoke.finishReply();
    setStatus('idle');
  }

  // Browser SpeechRecognition is per-turn — it auto-stops when the user goes
  // silent for a moment, so we re-start it whenever the next turn begins.
  function _startLiveSpeech() {
    if (!STATE.liveSpeech) STATE.liveSpeech = new LiveSpeech();
    if (!STATE.liveSpeech.supported) return;
    STATE.liveSpeech.onInterim = (text) => {
      // Show interim text; the server-side STT result will overwrite once it
      // lands (JarvisCopilot's transcript is the canonical one used for the LLM).
      setTranscript(text, 'user');
    };
    STATE.liveSpeech.start();
  }
  function _stopLiveSpeech() {
    if (STATE.liveSpeech) STATE.liveSpeech.stop();
  }

  // ---- Util ----
  function uint8ToBase64(bytes) {
    // Streaming-safe: chunk to avoid String.fromCharCode stack overflows.
    return new Promise(resolve => {
      const reader = new FileReader();
      reader.onload = () => {
        const dataUrl = reader.result;
        const idx = dataUrl.indexOf(',');
        resolve(dataUrl.substring(idx + 1));
      };
      reader.readAsDataURL(new Blob([bytes]));
    });
  }
  function base64ToUint8(b64) {
    const raw = atob(b64);
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }
  function peakOf(int16) {
    let p = 0;
    for (let i = 0; i < int16.length; i++) {
      const a = Math.abs(int16[i]);
      if (a > p) p = a;
    }
    return p / 0x8000;
  }
  function mergeUint8(chunks) {
    let total = 0;
    for (const c of chunks) total += c.length;
    const out = new Uint8Array(total);
    let off = 0;
    for (const c of chunks) { out.set(c, off); off += c.length; }
    return out;
  }

  // ---- Karaoke scheduler (pure) — ported from mobile _Seg.schedule/advance ----
  // These are deliberately DOM-free so webui/tests/test_voice_karaoke.py can
  // extract + eval them under node.

  // Word ranges: [startOffset, endOffset) for each whitespace-delimited token.
  function karaokeWordRanges(text) {
    const ranges = [];
    const re = /\S+/g; let m;
    while ((m = re.exec(text || '')) !== null) ranges.push([m.index, m.index + m[0].length]);
    return ranges;
  }

  // Cumulative start time (ms) of each word across a clip of clipMs, weighted by
  // word length plus a pause after sentence/clause punctuation. starts[0] === 0.
  function karaokeSchedule(words, clipMs) {
    const n = words.length;
    if (n === 0) return [];
    const weights = new Array(n); let total = 0;
    for (let i = 0; i < n; i++) {
      const w = words[i]; let wt = w.length + 1.0;
      const last = w.length ? w[w.length - 1] : '';
      if ('.!?'.includes(last)) wt += 6.0;        // sentence end → long pause
      else if (',;:'.includes(last)) wt += 3.0;   // clause break → short pause
      weights[i] = wt; total += wt;
    }
    const starts = new Array(n); let cum = 0;
    for (let i = 0; i < n; i++) {
      starts[i] = total > 0 ? (cum / total) * clipMs : 0;
      cum += weights[i];
    }
    return starts;
  }

  // Monotonic spoken-word count: words whose start <= posMs, never decreasing
  // below prevSpoken (so a position jitter backwards never un-highlights).
  function karaokeAdvanceSpoken(starts, posMs, prevSpoken) {
    const prev = prevSpoken || 0;
    let k = prev;
    while (k < starts.length && starts[k] <= posMs) k++;
    return k > prev ? k : prev;
  }

  function _escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  // ---- Karaoke runtime — mobile-style word-by-word reply highlight ----
  // Each assistant_text chunk is a segment paired with the audio clip that
  // follows it. As that clip plays (PcmPlayer per-clip hook), words light up
  // one at a time driven by the audio clock — no server-side timestamps.
  // Spoken words use the spoken color, the rest stay muted (see voice.css).
  const Karaoke = {
    segs: [],
    cur: -1,            // index of the segment whose audio is currently playing
    raf: 0,
    active: false,      // a reply is in progress (first assistant_text → end_turn)

    _el() { return $('voiceAssistantLine'); },

    reset() {
      this.segs = []; this.cur = -1; this.active = false;
      this._stopTick();
      const el = this._el();
      if (el) { el.innerHTML = ''; el.style.display = 'none'; }
    },

    // First assistant_text of a fresh turn — clear the previous reply.
    beginReply() { this.reset(); this.active = true; },

    addSegment(text) {
      text = (text == null ? '' : String(text));
      if (!text.trim()) return;
      const ranges = karaokeWordRanges(text);
      const words = ranges.map(r => text.slice(r[0], r[1]));
      this.segs.push({ text, ranges, words, starts: [], clipStart: 0, durMs: 0, spoken: 0, audioStarted: false });
      if (this.cur < 0) this.cur = 0;
      this.render();
      this._startTick();
    },

    onClipStart(tag, startAtSec) {
      const seg = this.segs[tag];
      if (!seg) return;
      seg.clipStart = startAtSec;
      seg.audioStarted = true;
      if (tag >= this.cur) this.cur = tag;
      this._startTick();
    },

    accrueDur(tag, ms) {
      const seg = this.segs[tag];
      if (!seg) return;
      seg.durMs += ms;
      seg.starts = karaokeSchedule(seg.words, seg.durMs);
    },

    // end_turn: stop accepting new segments, let the tick play out whatever
    // audio is still queued, then guarantee a fully-lit final state.
    finishReply() { this.active = false; this._startTick(); },

    _audioPlaying() {
      return !!(STATE.player && STATE.player.queueEnd > STATE.player.nowSec() + 0.05);
    },
    _ticking() {
      if (this.active) return true;
      // Keep advancing only while audio is actually playing; once it drains (or
      // the player is stopped, e.g. on Stop) we finalize instead of spinning.
      return this._audioPlaying();
    },
    // Light up everything once the reply is over — covers audio that under-ran
    // the text and a trailing text-only segment that never received audio (a
    // real path when server-side TTS fails for the final segment).
    _finalize() {
      if (!this.segs.length) return;
      let changed = false;
      for (const s of this.segs) {
        if (s.spoken !== s.words.length) { s.spoken = s.words.length; changed = true; }
      }
      this.cur = this.segs.length - 1;
      if (changed) { this.render(); this.follow(); }
    },
    _startTick() {
      if (this.raf || typeof requestAnimationFrame !== 'function') return;
      const loop = () => {
        this.raf = 0;
        this._advance();
        if (this._ticking()) this.raf = requestAnimationFrame(loop);
        else this._finalize();   // reply done + audio drained → ensure 100% lit
      };
      this.raf = requestAnimationFrame(loop);
    },
    _stopTick() {
      if (this.raf && typeof cancelAnimationFrame === 'function') cancelAnimationFrame(this.raf);
      this.raf = 0;
    },

    _advance() {
      if (!STATE.player || this.cur < 0) return;
      const seg = this.segs[this.cur];
      if (!seg || !seg.audioStarted) return;
      const posMs = (STATE.player.nowSec() - seg.clipStart) * 1000;
      const next = karaokeAdvanceSpoken(seg.starts, posMs, seg.spoken);
      let changed = false;
      if (next !== seg.spoken) { seg.spoken = next; changed = true; }
      // Hand off to the next segment once this one is fully spoken and its
      // successor's audio has started.
      if (seg.spoken >= seg.words.length &&
          this.cur + 1 < this.segs.length && this.segs[this.cur + 1].audioStarted) {
        seg.spoken = seg.words.length;
        this.cur++;
        changed = true;
      }
      if (changed) { this.render(); this.follow(); }
    },

    render() {
      const el = this._el();
      if (!el) return;
      let html = '';
      let cursorPlaced = false;
      for (let si = 0; si < this.segs.length; si++) {
        const seg = this.segs[si];
        const spokenCount = si < this.cur ? seg.words.length
          : (si === this.cur ? seg.spoken : 0);
        let last = 0;
        for (let i = 0; i < seg.ranges.length; i++) {
          const s = seg.ranges[i][0], e = seg.ranges[i][1];
          if (s > last) html += _escHtml(seg.text.slice(last, s));
          if (si === this.cur && i === spokenCount && !cursorPlaced) {
            html += '<span class="kw-cursor" aria-hidden="true"></span>';
            cursorPlaced = true;
          }
          html += '<span class="kw ' + (i < spokenCount ? 'spoken' : 'unspoken') + '">'
            + _escHtml(seg.text.slice(s, e)) + '</span>';
          last = e;
        }
        if (last < seg.text.length) html += _escHtml(seg.text.slice(last));
        if (si < this.segs.length - 1) html += ' ';
      }
      el.innerHTML = html;
      el.style.display = this.segs.length ? '' : 'none';
    },

    follow() {
      const el = this._el();
      if (!el) return;
      const c = el.querySelector('.kw-cursor');
      if (c && c.scrollIntoView) c.scrollIntoView({ block: 'center', behavior: 'smooth' });
    },
  };

  // ---- Mode toggle ----
  // Single tap-to-toggle button. Idle → "Tap to talk" (tap starts the realtime
  // conversation); active (connecting/listening/thinking/speaking) → "Stop"
  // (tap ends the session). Driven by the FSM via setStatus().
  function _updateToggleButton() {
    const btn = $('voicePttBtn');
    const label = $('voicePttLabel');
    if (!btn) return;
    // Gate on an actual session (STATE.ws), so unrelated FSM changes (e.g. the
    // TTS-test preview which flips to 'speaking') don't flip the button to
    // "Stop" when there's nothing to stop.
    const active = !!STATE.ws && STATE.fsm !== 'idle' && STATE.fsm !== 'error';
    btn.classList.toggle('active', active);
    btn.setAttribute('aria-pressed', active ? 'true' : 'false');
    if (label) {
      label.textContent = active
        ? tr('voice_btn_stop_talk', 'Stop')
        : tr('voice_btn_talk', 'Tap to talk');
    }
  }

  // ---- Voice picker ----
  async function loadVoices() {
    try {
      const res = await fetch('api/voice/voices');
      if (!res.ok) return;
      const data = await res.json();
      STATE.voices = data.voices || [];
      STATE.provider = data.provider || '';
      const sel = $('voiceVoiceSelect');
      if (!sel) return;
      sel.innerHTML = '';
      if (!STATE.voices.length) {
        const opt = document.createElement('option');
        opt.value = '';
        opt.textContent = data.provider ? `(default for ${data.provider})` : '(default)';
        sel.appendChild(opt);
        return;
      }
      for (const v of STATE.voices) {
        const opt = document.createElement('option');
        opt.value = v.id; opt.textContent = v.name || v.id;
        sel.appendChild(opt);
      }
      // Pre-select whatever JarvisCopilot config.yaml currently has set, falling
      // back to the first option. The `selected` field is set by
      // /api/voice/voices to the short ID matching the active voice path.
      const desired = (data.selected || '').trim();
      const found = desired && STATE.voices.some(v => v.id === desired);
      sel.value = found ? desired : STATE.voices[0].id;
      STATE.voice = sel.value;
    } catch (e) {}
  }

  // Exposed so other modules (panels.js personality picker) can request a
  // re-pull of the voice list after switching personality + TTS provider.
  window.refreshVoicePickerVoices = function () { return loadVoices(); };

  // ---- Engine picker (Voice tab sidebar, above the Voice dropdown) ----
  async function loadEngines() {
    const sel = $('voiceEngineSelect');
    if (!sel) return;
    let data = null;
    try {
      const res = await fetch('api/voice/engines');
      if (!res.ok) return;
      data = await res.json();
    } catch (e) { return; }
    const engines = (data && data.engines) || [];
    const active = (data && data.active) || '';
    sel.innerHTML = '';
    if (!engines.length) {
      const opt = document.createElement('option');
      opt.value = ''; opt.textContent = '(no engines enabled)';
      sel.appendChild(opt);
      return;
    }
    for (const e of engines) {
      const opt = document.createElement('option');
      opt.value = e.id;
      const flag = e.configured ? '' : ' (not configured)';
      opt.textContent = (e.name || e.id) + flag;
      if (!e.configured) opt.disabled = false; // still selectable, just hinted
      sel.appendChild(opt);
    }
    if (active && engines.some(e => e.id === active)) {
      sel.value = active;
    } else if (engines[0]) {
      sel.value = engines[0].id;
    }
    STATE.engineCatalog = engines;
  }

  async function _onEngineChange() {
    const sel = $('voiceEngineSelect');
    if (!sel) return;
    const newEngine = sel.value;
    if (!newEngine) return;
    const entry = (STATE.engineCatalog || []).find(e => e.id === newEngine);
    // Block the switch if the engine isn't configured — typing into the
    // voice tab and getting silent TTS failures is a worse UX than a
    // pointed "go set up your API key" prompt.
    if (entry && !entry.configured) {
      const proceed = window.confirm(
        `${entry.name || newEngine} isn't configured yet.\n\n` +
        `Open Settings → Voice Providers to add the missing fields?`
      );
      // Revert the dropdown to whatever IS active so the UI doesn't lie
      // about the running engine.
      const active = (STATE.engineCatalog || []).find(e => e.active);
      sel.value = (active && active.id) || '';
      if (proceed && typeof switchPanel === 'function') {
        try { await switchPanel('settings'); } catch (e) {}
        if (typeof switchSettingsSection === 'function') {
          try { switchSettingsSection('conversation'); } catch (e) {}
        }
        // Smooth-scroll the providers list into view once the pane is
        // mounted; the next paint is when the elements actually exist.
        setTimeout(() => {
          const target = document.getElementById('voiceProvidersList');
          if (target && typeof target.scrollIntoView === 'function') {
            target.scrollIntoView({ behavior: 'smooth', block: 'start' });
          }
        }, 250);
      }
      return;
    }
    try {
      await fetch('api/voice/engine', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: newEngine }),
      });
    } catch (e) { /* ignore */ }
    // Reload voices for the new engine
    await loadVoices();
    _refreshCustomVoiceIdInput();
  }

  // Some engines (Fish Audio) use a free-form voice ID instead of a fixed
  // dropdown list. Show the inline text input for those, hide it otherwise.
  // Saves to the per-engine config on blur so the user doesn't lose their
  // paste if they navigate away.
  function _refreshCustomVoiceIdInput() {
    const sel = $('voiceEngineSelect');
    const input = $('voiceCustomVoiceId');
    if (!sel || !input) return;
    const engineId = sel.value;
    const entry = (STATE.engineCatalog || []).find(e => e.id === engineId);
    if (!entry || entry.voice_kind !== 'custom') {
      input.style.display = 'none';
      input.value = '';
      return;
    }
    input.style.display = '';
    input.placeholder = entry.voice_id_hint || 'Custom voice ID';
    input.value = entry.voice_id || '';
    if (!input.dataset.bound) {
      input.dataset.bound = '1';
      const save = async () => {
        const v = input.value.trim();
        const cur = sel.value;
        try {
          await fetch('api/voice/provider-config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engine: cur, voice_id: v }),
          });
        } catch (e) { /* ignore */ }
      };
      input.addEventListener('blur', save);
      input.addEventListener('change', save);
    }
  }

  async function loadStatus() {
    try {
      const res = await fetch('api/voice/status');
      if (!res.ok) return;
      STATE.status = await res.json();
      if (!STATE.status.stt_ok) {
        showError(tr('voice_err_stt_unavailable', 'Speech-to-text is unavailable on this server.'));
      } else if (!STATE.status.tts_ok) {
        showError(tr('voice_err_tts_unavailable', 'Text-to-speech is unavailable on this server.'));
      }
    } catch (e) {}
  }

  // ---- Wiring ----
  function wireOnce() {
    if (STATE.initialized) return;
    STATE.initialized = true;
    const canvas = $('voiceOrbCanvas');
    if (canvas) {
      STATE.orb = new VoiceOrb(canvas);
      STATE.orb.start();
    }
    const ptt = $('voicePttBtn');
    if (ptt) {
      // Single tap-to-toggle: tap to start the realtime conversation, tap
      // again to stop it. (Hold-to-talk / Quality mode is gone.)
      const toggle = (e) => {
        if (e) e.preventDefault();
        // STATE.ws is non-null while connecting OR live, so this stops a
        // session in either state (and a fresh tap after it's cleared starts).
        if (STATE.ws) stopRealtime();
        else startRealtime();
      };
      ptt.addEventListener('click', toggle);
    }
    const muteBtn = $('voiceMuteBtn');
    if (muteBtn) muteBtn.addEventListener('click', () => {
      // Mute button is mode-aware (see _updateMuteButtonLabel for the
      // canonical mapping). dataset.action is the source of truth so the
      // click handler doesn't drift from the displayed label.
      const action = muteBtn.dataset.action || 'mute-toggle';
      if (action === 'end-turn' && STATE.ws && STATE.ws.isOpen()) {
        STATE._silenceMs = 0;
        STATE._hasSpoken = false;
        STATE.ws.sendJson({ type: 'end_turn' });
        setStatus('thinking');
        return;
      }
      if (action === 'interrupt' && STATE.ws && STATE.ws.isOpen()) {
        STATE.ws.sendJson({ type: 'interrupt' });
        // Server will short-circuit any in-flight pipeline; FSM will move
        // back to listening on the next end_turn message from the server.
        return;
      }
      // Default: simple mute toggle — frames stop being sent over the
      // wire while muted, but the mic stream stays alive for fast resume.
      STATE.muted = !STATE.muted;
      muteBtn.setAttribute('aria-pressed', STATE.muted);
      _updateMuteButtonLabel();
    });
    const voiceSel = $('voiceVoiceSelect');
    if (voiceSel) voiceSel.addEventListener('change', () => { STATE.voice = voiceSel.value; });
    const engineSel = $('voiceEngineSelect');
    if (engineSel && !engineSel.dataset.bound) {
      engineSel.dataset.bound = '1';
      engineSel.addEventListener('change', _onEngineChange);
    }

    const ttsBtn = $('voiceTtsTestBtn');
    const ttsInput = $('voiceTtsTestInput');
    if (ttsBtn && ttsInput) {
      ttsBtn.addEventListener('click', async () => {
        const text = (ttsInput.value || '').trim();
        if (!text) return;
        setStatus('speaking');
        try {
          const res = await fetch('api/voice/synthesize', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text, format: 'mp3' }),
          });
          if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            showError(err.error || 'TTS failed');
            setStatus('error');
            return;
          }
          const buf = await res.arrayBuffer();
          if (!STATE.player) STATE.player = new PcmPlayer();
          STATE.player.onAmplitude = (a) => { if (STATE.orb) STATE.orb.setAmplitude(a); };
          await STATE.player.playMp3Bytes(new Uint8Array(buf));
        } catch (e) {
          showError(String(e && e.message || e));
        } finally {
          setStatus('idle');
        }
      });
    }
  }

  // ---- Public entry points ----
  window.initVoicePanel = function initVoicePanel() {
    wireOnce();
    setStatus('idle');
    // Re-resize the orb canvas now that the panel is visible (zero size
    // while hidden via display:none in many layouts).
    if (STATE.orb) {
      setTimeout(() => STATE.orb._resize(), 0);
    }
    if (!STATE.voices.length) loadVoices();
    if (!STATE.status) loadStatus();
    // Engines are cheap to fetch and may have changed (user toggled one in
    // Settings) — refresh every time the Voice tab opens, not just first time.
    loadEngines().then(() => _refreshCustomVoiceIdInput());
  };
  window.onVoicePanelLeave = function onVoicePanelLeave() {
    // Be polite: don't keep mic/WS alive once user has navigated away.
    if (STATE.ws) stopRealtime();
    setStatus('idle');
  };
})();
