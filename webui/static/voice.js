/*
 * Voice tab — orb visualizer, mic capture, mode FSM, WS realtime client.
 *
 * Quality mode  (push-to-talk):
 *   hold button → record 16kHz mono PCM via WebAudio → release → POST
 *   /api/voice/quality-turn → { transcript, reply, audio_base64 } → play MP3.
 *
 * Realtime mode (tap-to-toggle):
 *   tap button → open WS /api/voice/s2s/ws → stream 16kHz PCM binary frames
 *   continuously; client-side VAD signals end_turn → server streams back
 *   transcript, assistant_text, audio_meta + binary PCM frames @ 24kHz.
 *
 * Exposed (used by panels.js):
 *   initVoicePanel()       — first entry into the Voice tab
 *   onVoicePanelLeave()    — pause anything streaming when user switches away
 */

(function () {
  'use strict';

  // ---- shared state ----
  const STATE = {
    mode: 'quality',          // 'quality' | 'realtime'
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
    audioEl: null,            // <audio> element for Quality-mode playback
    inflight: false,
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
  }

  // The Mute button does double duty: in Realtime mode while listening, it
  // acts as a "I'm done, process my turn" trigger (sends end_turn). Reflect
  // that in the label so users know which action will fire.
  function _updateMuteButtonLabel() {
    const btn = document.getElementById('voiceMuteBtn');
    if (!btn) return;
    if (STATE.mode === 'realtime' && STATE.fsm === 'listening') {
      btn.textContent = tr('voice_btn_done_speaking', 'Done speaking');
      btn.dataset.action = 'end-turn';
      return;
    }
    if (STATE.mode === 'realtime' && (STATE.fsm === 'thinking' || STATE.fsm === 'speaking')) {
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
      const rect = this.canvas.parentElement.getBoundingClientRect();
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

    _tick() {
      if (!this.running) return;
      this._rafId = requestAnimationFrame(this._tick);
      this.t += 1 / 60;
      // Smooth amplitude towards target (snappier on rise, gentler on fall)
      const rise = 0.30, fall = 0.06;
      const k = this.target > this.amp ? rise : fall;
      this.amp = this.amp + (this.target - this.amp) * k;

      const ctx = this.ctx;
      const W = this.canvas.width, H = this.canvas.height;
      ctx.clearRect(0, 0, W, H);
      ctx.save();
      ctx.translate(W / 2, H / 2);
      const scale = Math.min(W, H) / 2;

      const [c0, c1, c2, ringC] = this._stateColors();

      // Background radial gradient (cool/warm core glow)
      const bgRad = scale * 0.95;
      const grad = ctx.createRadialGradient(0, 0, 0, 0, 0, bgRad);
      grad.addColorStop(0, this._withAlpha(c0, 0.22));
      grad.addColorStop(0.45, this._withAlpha(c1, 0.10));
      grad.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = grad;
      ctx.beginPath(); ctx.arc(0, 0, bgRad, 0, Math.PI * 2); ctx.fill();

      // Outer chrome rings — two counter-rotating
      ctx.lineWidth = Math.max(1, scale * 0.012);
      ctx.strokeStyle = this._withAlpha(ringC, 0.30);
      this._chromeRing(ctx, scale * 0.86, this.t * 0.3, 18);
      ctx.strokeStyle = this._withAlpha(ringC, 0.18);
      this._chromeRing(ctx, scale * 0.78, -this.t * 0.2, 24);

      // Particle sphere, additive blending
      ctx.globalCompositeOperation = 'lighter';
      const rotY = this.t * 0.5;
      const rotX = Math.sin(this.t * 0.18) * 0.28;
      const cosY = Math.cos(rotY), sinY = Math.sin(rotY);
      const cosX = Math.cos(rotX), sinX = Math.sin(rotX);
      const pulse = this.state === 'thinking'
        ? (0.85 + 0.15 * Math.sin(this.t * 4.2))
        : 1.0;
      const ampBoost = this.state === 'listening' || this.state === 'speaking'
        ? this.amp
        : 0;
      const baseR = scale * 0.50 * pulse * (1 + 0.12 * ampBoost);

      for (let i = 0; i < this.particles.length; i++) {
        const p = this.particles[i];
        // Rotate y, then x
        let x = p.x * cosY - p.z * sinY;
        let z = p.x * sinY + p.z * cosY;
        let y = p.y * cosX - z * sinX;
        z = p.y * sinX + z * cosX;
        // Slight per-particle radial wobble
        const wobble = 1 + 0.04 * Math.sin(this.t * 1.8 + p.phase);
        const px = x * baseR * wobble;
        const py = y * baseR * wobble;
        // Depth-cued alpha and size
        const depth = (z + 1) / 2;        // 0..1
        const a = 0.10 + depth * 0.75;
        const rad = (scale * 0.006) + depth * scale * 0.014;
        const cMix = depth < 0.5
          ? this._lerpColor(c2, c1, depth * 2)
          : this._lerpColor(c1, c0, (depth - 0.5) * 2);
        ctx.fillStyle = this._withAlpha(cMix, a);
        ctx.beginPath(); ctx.arc(px, py, rad, 0, Math.PI * 2); ctx.fill();
      }

      // Spike rim — radial spikes driven by amplitude
      if (this.state === 'listening' || this.state === 'speaking') {
        const SPIKES = 96;
        const spikeBase = baseR + scale * 0.025;
        const spikeMax = scale * 0.18 * Math.max(0.15, this.amp);
        ctx.lineWidth = Math.max(1, scale * 0.006);
        ctx.strokeStyle = this._withAlpha(c0, 0.6);
        ctx.beginPath();
        for (let i = 0; i < SPIKES; i++) {
          const a = (i / SPIKES) * Math.PI * 2;
          const n = 0.5 + 0.5 * Math.sin(this.t * 5 + i * 0.6);
          const len = spikeMax * n;
          const x1 = Math.cos(a) * spikeBase;
          const y1 = Math.sin(a) * spikeBase;
          const x2 = Math.cos(a) * (spikeBase + len);
          const y2 = Math.sin(a) * (spikeBase + len);
          ctx.moveTo(x1, y1); ctx.lineTo(x2, y2);
        }
        ctx.stroke();
      }

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
    let ok = false;
    try {
      const probe = document.createElement('canvas');
      ok = !!(window.THREE && (probe.getContext('webgl2') || probe.getContext('webgl')));
    } catch (e) { ok = false; }
    if (ok) {
      try { return new VoiceOrbGL(canvas); }
      catch (e) { console.warn('[voice] WebGL orb failed, falling back to Canvas-2D:', e); }
    }
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
    }
    async playMp3Bytes(uint8) {
      this._ensureCtx();
      const buf = await this.ctx.decodeAudioData(uint8.buffer.slice(uint8.byteOffset, uint8.byteOffset + uint8.byteLength));
      const src = this.ctx.createBufferSource();
      src.buffer = buf;
      src.connect(this.ctx.destination);
      const startAt = Math.max(this.ctx.currentTime, this.queueEnd);
      src.start(startAt);
      this.queueEnd = startAt + buf.duration;
      this.playing = true;
      return new Promise(res => { src.onended = res; });
    }
    stop() {
      if (this.ctx) {
        try { this.ctx.close(); } catch (e) {}
      }
      this.ctx = null;
      this.queueEnd = 0;
      this.playing = false;
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

  // ---- Quality mode (push-to-talk) ----
  async function startQualityCapture() {
    if (STATE.inflight) return;
    showError('');
    clearTranscript();
    _startLiveSpeech();
    if (!STATE.mic) STATE.mic = new MicCapture();
    const chunks = [];
    STATE.mic.onFrame = (int16) => {
      chunks.push(new Uint8Array(int16.buffer.slice(0)));
    };
    STATE.mic.onAmplitude = (a) => { if (STATE.orb) STATE.orb.setAmplitude(a); };
    try {
      await STATE.mic.start();
    } catch (e) {
      showError(tr('voice_err_no_mic', 'Microphone access denied or unavailable.'));
      setStatus('error');
      _stopLiveSpeech();
      return;
    }
    setStatus('listening');
    STATE._qualityChunks = chunks;
  }

  // Voice needs a chat session to route the turn through (so it gets tools +
  // segmented responses). In the mini popup there's no chat UI to pick one, so
  // auto-create one on first use via the global newSession() — the same call
  // the chat surface makes when none exists. Returns the session id ("" if it
  // couldn't be created, e.g. newSession unavailable).
  async function _ensureVoiceSession() {
    let sid = (typeof S !== 'undefined' && S && S.session && S.session.session_id) || '';
    if (!sid && typeof newSession === 'function') {
      try { await newSession(); } catch (e) { /* fall through to error */ }
      sid = (typeof S !== 'undefined' && S && S.session && S.session.session_id) || '';
    }
    return sid;
  }

  async function stopQualityCaptureAndSend() {
    const chunks = STATE._qualityChunks || [];
    STATE._qualityChunks = null;
    if (STATE.mic) STATE.mic.stop();
    _stopLiveSpeech();
    if (!chunks.length) {
      setStatus('idle');
      return;
    }
    setStatus('thinking');
    // Concat and base64-encode int16 PCM
    let total = 0;
    for (const c of chunks) total += c.length;
    const merged = new Uint8Array(total);
    let off = 0;
    for (const c of chunks) { merged.set(c, off); off += c.length; }
    const b64 = await uint8ToBase64(merged);
    STATE.inflight = true;
    try {
      // The voice quality-turn endpoint now routes through the user's active
      // chat session so the response can include tool calls (Open Chrome,
      // search the web, etc.). The session id is needed so the server knows
      // which chat to inject the user message into.
      const sessionId = await _ensureVoiceSession();
      if (!sessionId) {
        showError(tr('voice_err_no_session', 'Open a chat session first so voice has somewhere to talk.'));
        setStatus('idle');
        return;
      }
      const res = await fetch('api/voice/quality-turn', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          audio_base64: b64,
          sample_rate: 16000,
          session_id: sessionId,
        }),
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        showError(err.error || `Request failed (${res.status})`);
        setStatus('error');
        return;
      }
      // Server streams newline-delimited JSON: one event per line. We read
      // chunks via ReadableStream + TextDecoder and play each text segment
      // the moment it lands instead of waiting for the whole turn. This is
      // what gives the "ack → tool → confirm" cadence its real-time feel.
      if (!STATE.player) STATE.player = new PcmPlayer();
      STATE.player.onAmplitude = (a) => { if (STATE.orb) STATE.orb.setAmplitude(a); };
      const assistantText = [];
      let gotTranscript = false;
      let sawSegment = false;
      const reader = res.body && res.body.getReader ? res.body.getReader() : null;
      if (!reader) {
        showError('Streaming not supported by this browser.');
        setStatus('error');
        return;
      }
      const decoder = new TextDecoder('utf-8');
      let buf = '';
      let aborted = false;
      try {
        while (!aborted) {
          const { done, value } = await reader.read();
          if (value) buf += decoder.decode(value, { stream: true });
          let nl;
          while ((nl = buf.indexOf('\n')) !== -1) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            if (!line.trim()) continue;
            let event = null;
            try { event = JSON.parse(line); } catch (e) { continue; }
            if (!event || !event.type) continue;
            if (event.type === 'transcript') {
              gotTranscript = !!(event.text && event.text.trim());
              setTranscript(event.text || '', 'user');
            } else if (event.type === 'segment') {
              sawSegment = true;
              if (event.kind === 'text') {
                if (event.text) {
                  assistantText.push(event.text);
                  setTranscript(assistantText.join('\n\n'), 'assistant');
                }
                if (event.audio_base64) {
                  setStatus('speaking');
                  try {
                    // Await so the next segment doesn't TTS-overlap the
                    // current one. Server has already moved on to producing
                    // the next segment; the audio just queues until ready.
                    await STATE.player.playMp3Bytes(base64ToUint8(event.audio_base64));
                  } catch (e) { /* ignore decode errors */ }
                }
              } else if (event.kind === 'tool') {
                // Tool started — flip the orb to thinking so the user sees
                // the "...running..." moment between segments. The next
                // text segment will flip it back to speaking.
                setStatus('thinking');
              }
            } else if (event.type === 'error') {
              showError(event.error || 'Stream error');
              setStatus('error');
              aborted = true;
              break;
            } else if (event.type === 'done') {
              aborted = true;
              break;
            }
          }
          if (done) break;
        }
      } catch (e) {
        showError('Stream read failed: ' + (e && e.message || e));
        setStatus('error');
        return;
      } finally {
        try { reader.releaseLock && reader.releaseLock(); } catch (e) {}
      }
      if (!gotTranscript) {
        showError(tr('voice_err_no_speech', "Didn't catch that — try again."));
        setStatus('idle');
        return;
      }
      if (!sawSegment) {
        setStatus('idle');
        return;
      }
      setStatus('idle');
    } catch (e) {
      showError(String(e && e.message || e));
      setStatus('error');
    } finally {
      STATE.inflight = false;
    }
  }

  // ---- Realtime mode (WS streaming) ----
  async function startRealtime() {
    if (STATE.ws && STATE.ws.isOpen()) return;
    showError('');
    clearTranscript();
    if (!STATE.mic) STATE.mic = new MicCapture();
    if (!STATE.player) STATE.player = new PcmPlayer();
    STATE.player.onAmplitude = (a) => { if (STATE.orb) STATE.orb.setAmplitude(a); };
    setStatus('connecting');
    STATE.ws = new RealtimeWS();
    STATE.ws.onText = onRealtimeText;
    STATE.ws.onBinary = onRealtimeBinary;
    STATE.ws.onError = () => { showError(tr('voice_err_ws_failed', 'Realtime connection failed.')); setStatus('error'); };
    STATE.ws.onClose = () => { setStatus('idle'); };
    try {
      await STATE.ws.open();
    } catch (e) {
      showError(tr('voice_err_ws_failed', 'Realtime connection failed.'));
      setStatus('error');
      return;
    }
    try {
      await STATE.mic.start();
    } catch (e) {
      showError(tr('voice_err_no_mic', 'Microphone access denied or unavailable.'));
      setStatus('error');
      STATE.ws.close();
      return;
    }
    // Realtime mode also routes through the user's active chat session so
    // it gets tools + segmented ack-tool-confirm responses. Auto-create one if
    // none exists (e.g. the mini popup) instead of falling back to a tool-less
    // reply.
    const _sid = await _ensureVoiceSession();
    STATE.ws.sendJson({ type: 'begin_turn', sample_rate: 16000, session_id: _sid });
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
      setTranscript(obj.text || '', 'assistant');
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

  // ---- Mode toggle ----
  function setMode(mode) {
    if (mode !== 'quality' && mode !== 'realtime') return;
    STATE.mode = mode;
    const qBtn = $('voiceModeQualityBtn');
    const rBtn = $('voiceModeRealtimeBtn');
    if (qBtn && rBtn) {
      qBtn.classList.toggle('active', mode === 'quality');
      qBtn.setAttribute('aria-selected', mode === 'quality');
      rBtn.classList.toggle('active', mode === 'realtime');
      rBtn.setAttribute('aria-selected', mode === 'realtime');
    }
    const hint = $('voiceModeHint');
    if (hint) {
      const k = mode === 'quality' ? 'voice_mode_hint_quality' : 'voice_mode_hint_realtime';
      hint.textContent = tr(k, mode === 'quality'
        ? 'Push to talk, release to send.'
        : 'Stream your voice live.');
    }
    const pttLabel = $('voicePttLabel');
    if (pttLabel) {
      pttLabel.textContent = mode === 'quality'
        ? tr('voice_btn_ptt_quality', 'Hold to talk')
        : tr('voice_btn_ptt_realtime', 'Tap to start');
    }
    const stopBtn = $('voiceStopBtn');
    if (stopBtn) stopBtn.style.display = (mode === 'realtime') ? '' : 'none';
    // Stop any in-flight session when switching modes.
    if (STATE.ws) stopRealtime();
    if (STATE._qualityChunks) {
      if (STATE.mic) STATE.mic.stop();
      STATE._qualityChunks = null;
    }
    setStatus('idle');
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
    const qBtn = $('voiceModeQualityBtn');
    const rBtn = $('voiceModeRealtimeBtn');
    if (qBtn) qBtn.addEventListener('click', () => setMode('quality'));
    if (rBtn) rBtn.addEventListener('click', () => setMode('realtime'));

    const ptt = $('voicePttBtn');
    if (ptt) {
      // Push-to-talk in Quality mode; toggle in Realtime mode.
      const startEv = ['pointerdown'];
      const endEv = ['pointerup', 'pointercancel', 'pointerleave'];
      ptt.addEventListener('pointerdown', (e) => {
        e.preventDefault();
        if (STATE.mode === 'quality') startQualityCapture();
        else { if (STATE.ws && STATE.ws.isOpen()) stopRealtime(); else startRealtime(); }
      });
      for (const evName of endEv) {
        ptt.addEventListener(evName, (e) => {
          if (STATE.mode === 'quality' && STATE._qualityChunks) {
            stopQualityCaptureAndSend();
          }
        });
      }
      // Keyboard: space-hold = PTT, enter = realtime toggle
      ptt.addEventListener('keydown', (e) => {
        if (e.key === ' ' && STATE.mode === 'quality' && !STATE._qualityChunks) {
          e.preventDefault();
          startQualityCapture();
        }
      });
      ptt.addEventListener('keyup', (e) => {
        if (e.key === ' ' && STATE.mode === 'quality' && STATE._qualityChunks) {
          e.preventDefault();
          stopQualityCaptureAndSend();
        }
      });
    }
    const stopBtn = $('voiceStopBtn');
    if (stopBtn) stopBtn.addEventListener('click', () => {
      if (STATE.mode === 'realtime') stopRealtime();
      else if (STATE._qualityChunks) { if (STATE.mic) STATE.mic.stop(); STATE._qualityChunks = null; setStatus('idle'); }
    });
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
    setMode(STATE.mode);
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
    if (STATE._qualityChunks) {
      if (STATE.mic) STATE.mic.stop();
      STATE._qualityChunks = null;
    }
    setStatus('idle');
  };
})();
