// JarvisCopilot — Devices tab.
//
// Pulls paired-device records from /api/devices and renders:
//   - sidebar list (#devicesList)        : compact rows w/ name, online dot
//   - main pane    (#devicesMainContent) : detailed cards w/ revoke / logout
//
// Pairing-from-UI: clicking the "+" button POSTs /api/devices/pair/start,
// shows a modal with the code + URL, polls /api/auth/pair/status until
// claimed/expired/cancelled.

let _devicesData = [];
let _devicesPollTimer = null;
let _devicesPairModalEl = null;
let _devicesPairPollTimer = null;
let _devicesPairCurrentCode = null;
// CF Access service token for the current pairing session (when tunneled), so
// the QR/deep-link can carry it to a tunnel-first device. Cleared between runs.
let _devicesPairCfAccess = null;
const _DEVICES_LIVE_REFRESH_MS = 10000;

function _devEsc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function _devFmtAge(ts) {
  if (!ts) return '—';
  const ms = Date.now() - (Number(ts) * 1000);
  if (ms < 0) return 'just now';
  const s = Math.floor(ms / 1000);
  if (s < 60) return s + 's ago';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m / 60);
  if (h < 24) return h + 'h ago';
  const d = Math.floor(h / 24);
  return d + 'd ago';
}

function _devFmtUserAgent(ua) {
  if (!ua) return '';
  // Trim to a short label — browser/OS hints if we can identify them.
  const u = ua.toLowerCase();
  let browser = 'Browser';
  if (u.includes('firefox/')) browser = 'Firefox';
  else if (u.includes('edg/')) browser = 'Edge';
  else if (u.includes('chrome/')) browser = 'Chrome';
  else if (u.includes('safari/') && !u.includes('chrome/')) browser = 'Safari';
  let os = '';
  if (u.includes('iphone') || u.includes('ipad')) os = 'iOS';
  else if (u.includes('android')) os = 'Android';
  else if (u.includes('mac os')) os = 'macOS';
  else if (u.includes('windows')) os = 'Windows';
  else if (u.includes('linux')) os = 'Linux';
  return os ? `${browser} · ${os}` : browser;
}

async function loadDevices(force) {
  const listEl = document.getElementById('devicesList');
  const mainEl = document.getElementById('devicesMainContent');
  try {
    const res = await fetch('/api/devices', { credentials: 'same-origin' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const data = await res.json();
    _devicesData = (data && data.devices) || [];
    _renderDevicesSidebar();
    _renderDevicesMain();
  } catch (e) {
    if (listEl) listEl.innerHTML = `<div style="padding:12px;color:var(--danger,#e94560);font-size:12px">Failed to load devices: ${_devEsc(e.message)}</div>`;
    if (mainEl) mainEl.innerHTML = `<div style="color:var(--danger,#e94560);font-size:13px">Failed to load devices.</div>`;
  }

  if (force && _devicesPollTimer) clearInterval(_devicesPollTimer);
  if (!_devicesPollTimer) {
    _devicesPollTimer = setInterval(() => {
      if (typeof _currentPanel !== 'undefined' && _currentPanel === 'devices') {
        loadDevices();
      }
    }, _DEVICES_LIVE_REFRESH_MS);
  }
}

function _renderDevicesSidebar() {
  const el = document.getElementById('devicesList');
  if (!el) return;
  if (!_devicesData.length) {
    el.innerHTML = `<div style="padding:18px 12px;color:var(--muted);font-size:12px;text-align:center;line-height:1.5">No devices paired yet.<br><button class="btn primary" style="margin-top:12px;padding:6px 14px;font-size:12px" onclick="startPairingFromUI()">Pair a device</button></div>`;
    return;
  }
  const rows = _devicesData.map(d => {
    const dot = d.online
      ? '<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:#7ae597;box-shadow:0 0 6px rgba(122,229,151,.6);flex-shrink:0"></span>'
      : '<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:rgba(255,255,255,.15);flex-shrink:0"></span>';
    const skillsBadge = (d.skills && d.skills.length)
      ? `<span style="margin-left:auto;font-size:10px;background:rgba(124,185,255,.15);color:#7cb9ff;padding:2px 6px;border-radius:8px">${d.skills.length} skills</span>`
      : '';
    return `<div class="device-row" data-id="${_devEsc(d.id)}" style="display:flex;align-items:center;gap:8px;padding:8px 10px;border-radius:8px;cursor:pointer;font-size:13px">
      ${dot}
      <div style="flex:1;min-width:0;overflow:hidden">
        <div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${_devEsc(d.name || 'device')}</div>
        <div style="font-size:10px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${_devEsc(d.ip || '—')} · ${_devEsc(_devFmtAge(d.paired_at))}</div>
      </div>
      ${skillsBadge}
    </div>`;
  });
  el.innerHTML = rows.join('');
}

function _renderDevicesMain() {
  const el = document.getElementById('devicesMainContent');
  if (!el) return;
  if (!_devicesData.length) {
    el.innerHTML = `
      <div style="max-width:540px;margin:24px auto;text-align:center">
        <div style="font-size:48px;margin-bottom:12px;opacity:.4">📱</div>
        <h2 style="font-size:18px;margin-bottom:8px">No devices paired</h2>
        <p style="color:var(--muted);font-size:13px;line-height:1.6;margin-bottom:18px">Pair a phone, tablet, or another machine to give it access to this server.</p>
        <button class="btn primary" onclick="startPairingFromUI()">Pair a new device</button>
      </div>`;
    return;
  }
  const cards = _devicesData.map(d => {
    const skillsHtml = (d.skills && d.skills.length)
      ? `<div style="margin-top:10px"><div style="font-size:11px;color:var(--muted);margin-bottom:4px">Exposed skills (${d.skills.length})</div>
          <div style="display:flex;flex-wrap:wrap;gap:6px">
            ${d.skills.map(s => `<span title="${_devEsc(s.description || '')}" style="font-size:11px;background:rgba(124,185,255,.15);color:#7cb9ff;padding:3px 8px;border-radius:8px;font-family:ui-monospace,Menlo,monospace">${_devEsc(s.name)}</span>`).join('')}
          </div></div>`
      : '';
    const onlineBadge = d.online
      ? `<span style="font-size:11px;background:rgba(122,229,151,.15);color:#7ae597;padding:2px 8px;border-radius:8px">● online</span>`
      : `<span style="font-size:11px;background:rgba(255,255,255,.05);color:var(--muted);padding:2px 8px;border-radius:8px">offline</span>`;
    return `<div class="device-card" data-id="${_devEsc(d.id)}" data-name="${_devEsc(d.name)}" style="background:var(--card-bg,rgba(255,255,255,.03));border:1px solid var(--border,rgba(255,255,255,.08));border-radius:12px;padding:14px 16px;margin-bottom:12px">
      <div style="display:flex;align-items:center;gap:10px;margin-bottom:6px">
        <div style="font-size:14px;font-weight:600">${_devEsc(d.name || 'device')}</div>
        ${onlineBadge}
        <div style="margin-left:auto;display:flex;gap:6px">
          <button class="btn secondary device-logout-btn" style="padding:4px 10px;font-size:11px">Log out</button>
          <button class="btn device-revoke-btn" style="padding:4px 10px;font-size:11px;background:rgba(233,69,96,.15);color:#ff7a8a;border:1px solid rgba(233,69,96,.3)">Revoke</button>
        </div>
      </div>
      <div style="font-size:12px;color:var(--muted);display:grid;grid-template-columns:auto 1fr;column-gap:14px;row-gap:3px;line-height:1.6">
        <span>IP</span>          <span style="font-family:ui-monospace,Menlo,monospace">${_devEsc(d.ip || '—')}</span>
        <span>Paired</span>      <span>${_devEsc(_devFmtAge(d.paired_at))}</span>
        <span>Client</span>      <span>${_devEsc(_devFmtUserAgent(d.user_agent))}</span>
        <span>Device ID</span>   <span style="font-family:ui-monospace,Menlo,monospace;opacity:.7">${_devEsc((d.id || '').slice(0, 12))}</span>
      </div>
      ${skillsHtml}
    </div>`;
  });
  el.innerHTML = `
    <div style="max-width:720px;margin:0 auto">
      <div style="display:flex;align-items:center;margin-bottom:14px">
        <div style="font-size:12px;color:var(--muted)">${_devicesData.length} device${_devicesData.length === 1 ? '' : 's'}</div>
        <button class="btn primary" style="margin-left:auto;padding:6px 14px;font-size:12px" onclick="startPairingFromUI()">+ Pair new device</button>
      </div>
      ${cards.join('')}
    </div>`;
}

function selectDevice(id) {
  // Scroll the corresponding card into view in the main area.
  const card = document.querySelector(`#devicesMainContent .device-card[data-id="${CSS.escape(id)}"]`)
    || [...document.querySelectorAll('#devicesMainContent .device-card')]
        .find(c => c.innerHTML.includes(id.slice(0, 12)));
  if (card) card.scrollIntoView({ behavior: 'smooth', block: 'center' });
  document.querySelectorAll('#devicesList .device-row').forEach(r => {
    r.style.background = (r.dataset.id === id) ? 'rgba(255,255,255,.05)' : '';
  });
}

async function revokeDevice(id, name) {
  if (!confirm(`Revoke pairing for "${name || 'device'}"?\nThe device will be logged out and removed from the list.`)) return;
  try {
    const res = await fetch('/api/devices/' + encodeURIComponent(id), {
      method: 'DELETE',
      credentials: 'same-origin',
      headers: { 'X-Requested-With': 'fetch' },
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    await loadDevices(true);
  } catch (e) {
    alert('Failed to revoke device: ' + e.message);
  }
}

async function logoutDevice(id, name) {
  if (!confirm(`Log "${name || 'device'}" out?\nThe device stays paired but will need to re-authenticate.`)) return;
  try {
    const res = await fetch('/api/devices/' + encodeURIComponent(id) + '/logout', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'X-Requested-With': 'fetch', 'Content-Type': 'application/json' },
      body: '{}',
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    await loadDevices(true);
  } catch (e) {
    alert('Failed to log out device: ' + e.message);
  }
}

// ── Pair-from-UI modal ────────────────────────────────────────────────────

async function startPairingFromUI() {
  try {
    const res = await fetch('/api/devices/pair/start', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'fetch' },
      body: '{"ttl":600}',
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const info = await res.json();
    _devicesPairCurrentCode = info.code;
    _devicesPairCfAccess = (info.cf_access && info.cf_access.client_id) ? info.cf_access : null;
    _openPairModal(info.code, info.expires_at);
    _startPairPolling(info.code);
  } catch (e) {
    alert('Failed to start pairing: ' + e.message);
  }
}

function _pairUrl() {
  // Same scheme + host the page itself is on, with the /pair path.
  const loc = window.location;
  return loc.protocol + '//' + loc.host + '/pair';
}

function _pairDeepLink(code) {
  // jarviscopilot://pair?server=<urlencoded>&code=<code>
  // The mobile app registers this scheme and pre-fills its Pair page. Kept SHORT
  // so the tiny QR encoder (~84-byte cap) can render it — the CF Access service
  // token does NOT fit here (id+secret are >100 bytes), so a tunnel-first device
  // enters it manually in the app's "Cloudflare service token" field instead.
  const loc = window.location;
  const serverUrl = loc.protocol + '//' + loc.host;
  return 'jarviscopilot://pair?server=' + encodeURIComponent(serverUrl) +
         '&code=' + encodeURIComponent(code);
}

// Tiny QR generator (numeric-byte mode, alphanumeric input). Adapted
// from qrcodegen MIT-licensed reference; trimmed to the minimum we need
// to render a 21×21 to 41×41 module bitmap for short URLs. ~3KB minified.
// Kept inline so we don't ship a CDN dependency just for the pair modal.
function _renderQRSvg(text, opts) {
  opts = opts || {};
  const size = opts.size || 200;
  const bg = opts.bg || '#ffffff';
  const fg = opts.fg || '#000000';
  let modules;
  try {
    modules = _qrEncode(text);
  } catch (e) {
    return '<div style="font-size:11px;color:#ff7a8a">QR encode failed: ' + _devEsc(e.message) + '</div>';
  }
  const n = modules.length;
  const cell = size / n;
  let rects = '';
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      if (modules[y][x]) {
        rects += `<rect x="${(x * cell).toFixed(2)}" y="${(y * cell).toFixed(2)}" width="${cell.toFixed(2)}" height="${cell.toFixed(2)}" fill="${fg}"/>`;
      }
    }
  }
  return `<svg viewBox="0 0 ${size} ${size}" width="${size}" height="${size}" style="background:${bg};border-radius:8px;padding:8px;box-sizing:content-box" xmlns="http://www.w3.org/2000/svg">${rects}</svg>`;
}

// Minimal QR encoder — byte mode, EC level M, smallest version that fits.
// Returns a 2D array of 0/1 modules. Sufficient for the deep-link URLs
// we generate (≤ ~80 chars, fits in version 5).
//
// We deliberately cap supported versions at v1..v5 because v6+ requires
// block interleaving in Reed-Solomon, which this single-block
// implementation doesn't do. The pair deep-link is always short enough
// to stay within v5 capacity (84 bytes at EC-M).
function _qrEncode(text) {
  const bytes = new TextEncoder().encode(text);
  // Byte-mode capacity (in payload bytes) at EC level M for v1..v5.
  // Source: ISO/IEC 18004 Table 7.
  const cap = [14, 26, 42, 62, 84];
  let version = -1;
  for (let v = 0; v < cap.length; v++) {
    if (bytes.length <= cap[v]) { version = v + 1; break; }
  }
  if (version < 0) throw new Error('payload too long (>' + cap[cap.length - 1] + ' bytes)');
  // Build data bit-stream: mode indicator (4 bits = 0100), char count
  // (8 bits at v1..v9), then bytes.
  const bitsArr = [];
  const pushBits = (val, n) => {
    for (let i = n - 1; i >= 0; i--) bitsArr.push((val >> i) & 1);
  };
  pushBits(0b0100, 4);
  pushBits(bytes.length, 8);
  for (const b of bytes) pushBits(b, 8);
  // Data codeword counts at EC-M, v1..v5 (single-block, no interleaving).
  // dataCw + ecCw == total codewords per ISO/IEC 18004 Table 9.
  const dataCw = [16, 28, 44, 64, 86][version - 1];
  const ecCw   = [10, 16, 26, 36, 48][version - 1];
  const totalCw = dataCw + ecCw;
  const maxBits = dataCw * 8;
  if (bitsArr.length > maxBits) throw new Error('payload too long after framing');
  // Terminator + pad to byte boundary, then alternate pad bytes.
  for (let i = 0; i < 4 && bitsArr.length < maxBits; i++) bitsArr.push(0);
  while (bitsArr.length % 8) bitsArr.push(0);
  const padBytes = [0xEC, 0x11];
  let pi = 0;
  while (bitsArr.length / 8 < dataCw) { pushBits(padBytes[pi % 2], 8); pi++; }
  // Pack to bytes.
  const data = new Uint8Array(dataCw);
  for (let i = 0; i < dataCw; i++) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | bitsArr[i * 8 + j];
    data[i] = b;
  }
  // RS over GF(256).
  const ec = _rsEncode(data, ecCw);
  const finalCw = new Uint8Array(totalCw);
  finalCw.set(data, 0);
  finalCw.set(ec, dataCw);
  // Build module grid.
  const n = 17 + version * 4;
  const M = Array.from({length: n}, () => new Array(n).fill(null));
  const reserve = Array.from({length: n}, () => new Array(n).fill(false));
  const placeFinder = (r, c) => {
    for (let dy = -1; dy <= 7; dy++) {
      for (let dx = -1; dx <= 7; dx++) {
        const y = r + dy, x = c + dx;
        if (y < 0 || y >= n || x < 0 || x >= n) continue;
        const onBorder = dy === -1 || dy === 7 || dx === -1 || dx === 7;
        const onOuter = dy === 0 || dy === 6 || dx === 0 || dx === 6;
        const onInner = dy >= 2 && dy <= 4 && dx >= 2 && dx <= 4;
        let v;
        if (onBorder) v = 0;
        else if (onOuter || onInner) v = 1;
        else v = 0;
        M[y][x] = v;
        reserve[y][x] = true;
      }
    }
  };
  placeFinder(0, 0);
  placeFinder(0, n - 7);
  placeFinder(n - 7, 0);
  // Timing patterns.
  for (let i = 8; i < n - 8; i++) {
    if (M[6][i] === null) { M[6][i] = (i % 2 === 0) ? 1 : 0; reserve[6][i] = true; }
    if (M[i][6] === null) { M[i][6] = (i % 2 === 0) ? 1 : 0; reserve[i][6] = true; }
  }
  // Alignment patterns (v2..v10).
  const alignCenters = [
    [], [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
    [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
  ][version];
  if (alignCenters) {
    for (const r of alignCenters) {
      for (const c of alignCenters) {
        if (reserve[r][c]) continue;
        for (let dy = -2; dy <= 2; dy++) {
          for (let dx = -2; dx <= 2; dx++) {
            const y = r + dy, x = c + dx;
            const onOuter = dy === -2 || dy === 2 || dx === -2 || dx === 2;
            const center = dy === 0 && dx === 0;
            M[y][x] = (onOuter || center) ? 1 : 0;
            reserve[y][x] = true;
          }
        }
      }
    }
  }
  // Dark module + format-info reservation.
  M[n - 8][8] = 1; reserve[n - 8][8] = true;
  const reserveFormat = () => {
    for (let i = 0; i < 9; i++) { if (M[8][i] === null) { M[8][i] = 0; reserve[8][i] = true; } }
    for (let i = 0; i < 8; i++) { if (M[i][8] === null) { M[i][8] = 0; reserve[i][8] = true; } }
    for (let i = 0; i < 8; i++) { if (M[8][n - 1 - i] === null) { M[8][n - 1 - i] = 0; reserve[8][n - 1 - i] = true; } }
    for (let i = 0; i < 7; i++) { if (M[n - 1 - i][8] === null) { M[n - 1 - i][8] = 0; reserve[n - 1 - i][8] = true; } }
  };
  reserveFormat();
  // Place data bits (interleaved bytes, column pairs right→left, zig-zag).
  let bitIdx = 0;
  let upward = true;
  for (let colRight = n - 1; colRight > 0; colRight -= 2) {
    if (colRight === 6) colRight = 5;
    for (let i = 0; i < n; i++) {
      const y = upward ? (n - 1 - i) : i;
      for (let j = 0; j < 2; j++) {
        const x = colRight - j;
        if (M[y][x] !== null) continue;
        let bit = 0;
        if (bitIdx < finalCw.length * 8) {
          const byteIdx = bitIdx >> 3;
          const bitOff = 7 - (bitIdx & 7);
          bit = (finalCw[byteIdx] >> bitOff) & 1;
          bitIdx++;
        }
        // Mask pattern 0: (y+x) % 2 === 0
        if ((y + x) % 2 === 0) bit ^= 1;
        M[y][x] = bit;
      }
    }
    upward = !upward;
  }
  // Format info — EC-M (0b00) + mask 0 (0b000) = 5 bits: 00000.
  // BCH(15,5) generator: 0b10100110111. Then XOR'd with 0b101010000010010.
  const fmtBits = (() => {
    const fmt = 0b00000; // EC-M(00) + mask(000)
    let bch = fmt << 10;
    const gen = 0b10100110111;
    for (let i = 14; i >= 10; i--) {
      if ((bch >> i) & 1) bch ^= gen << (i - 10);
    }
    return ((fmt << 10) | bch) ^ 0b101010000010010;
  })();
  const getFmtBit = (i) => (fmtBits >> i) & 1;
  for (let i = 0; i <= 5; i++) M[8][i] = getFmtBit(i);
  M[8][7] = getFmtBit(6);
  M[8][8] = getFmtBit(7);
  M[7][8] = getFmtBit(8);
  for (let i = 9; i < 15; i++) M[14 - i][8] = getFmtBit(i);
  for (let i = 0; i < 7; i++) M[n - 1 - i][8] = getFmtBit(i);
  M[n - 8][8] = 1;
  for (let i = 7; i < 15; i++) M[8][n - 15 + i] = getFmtBit(i);
  return M;
}

// Reed-Solomon encode over GF(256), polynomial 0x11d.
function _rsEncode(data, ecLen) {
  // Build log/antilog tables once and cache.
  if (!_rsEncode._gfReady) {
    const log = new Uint8Array(256), exp = new Uint8Array(512);
    let x = 1;
    for (let i = 0; i < 255; i++) {
      exp[i] = x;
      log[x] = i;
      x = (x << 1) ^ (x & 0x80 ? 0x11d : 0);
      x &= 0xff;
    }
    for (let i = 255; i < 512; i++) exp[i] = exp[i - 255];
    _rsEncode._log = log;
    _rsEncode._exp = exp;
    _rsEncode._gfReady = true;
  }
  const log = _rsEncode._log, exp = _rsEncode._exp;
  // Generator polynomial of degree ecLen.
  let gen = [1];
  for (let i = 0; i < ecLen; i++) {
    const next = new Array(gen.length + 1).fill(0);
    for (let j = 0; j < gen.length; j++) {
      next[j] ^= gen[j];
      if (gen[j] !== 0) next[j + 1] ^= exp[(log[gen[j]] + i) % 255];
    }
    gen = next;
  }
  const buf = new Uint8Array(data.length + ecLen);
  buf.set(data, 0);
  for (let i = 0; i < data.length; i++) {
    const coef = buf[i];
    if (coef === 0) continue;
    const lc = log[coef];
    for (let j = 0; j < gen.length; j++) {
      if (gen[j] !== 0) buf[i + j] ^= exp[(log[gen[j]] + lc) % 255];
    }
  }
  return buf.slice(data.length);
}

// When the server is behind a Cloudflare tunnel, the device must send the CF
// Access service token on its pair request (it 302s to SSO otherwise). The token
// is too big for the QR, so show it here for the user to paste into the device's
// "Cloudflare service token" field. Empty string when no token is configured.
function _pairCfTokenBlock() {
  const cf = _devicesPairCfAccess;
  if (!cf || !cf.client_id || !cf.client_secret) return '';
  const fld = (label, val) =>
    `<div style="margin-bottom:6px">
       <div style="color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.05em;margin-bottom:3px">${label}</div>
       <div style="display:flex;gap:6px;align-items:center">
         <code style="flex:1;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.08);border-radius:8px;padding:7px 10px;font-size:11px;word-break:break-all;text-align:left">${_devEsc(val)}</code>
         <button type="button" onclick="_pairCopy(this,'${_devEsc(val).replace(/'/g, "\\'")}')" style="background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);border-radius:8px;color:var(--text,#fff);font-size:11px;padding:7px 10px;cursor:pointer;white-space:nowrap">Copy</button>
       </div>
     </div>`;
  return `
    <div style="background:rgba(240,179,65,.06);border:1px solid rgba(240,179,65,.25);border-radius:12px;padding:12px;margin-bottom:14px;text-align:left">
      <div style="font-size:12px;font-weight:600;color:#f0b341;margin-bottom:8px">Cloudflare Access — paste into the device’s “service token” field</div>
      <div style="color:var(--muted);font-size:11px;line-height:1.5;margin-bottom:10px">This server is behind a Cloudflare tunnel, so the device needs these to connect (it can’t do browser login). Enter them in the app’s pair screen before pairing.</div>
      <div style="color:#f0b341;font-size:11px;line-height:1.5;margin-bottom:10px">⚠ One-time setup: this token must also be <b>allowed</b> in your Access policy, or pairing gets redirected to login (HTTP 302). In Cloudflare: <b>Zero Trust → Access → Applications →</b> your app <b>→ Policies →</b> add an <b>Include → Service Token →</b> this token.</div>
      ${fld('Client ID', cf.client_id)}
      ${fld('Client Secret', cf.client_secret)}
    </div>`;
}

// expose a copy helper for the inline buttons
window._pairCopy = function (btn, val) {
  try {
    navigator.clipboard.writeText(val);
    const old = btn.textContent;
    btn.textContent = 'Copied';
    setTimeout(() => { btn.textContent = old; }, 1200);
  } catch (e) { /* clipboard blocked — user can select the code manually */ }
};

function _openPairModal(code, expiresAt) {
  _closePairModal();
  const wrap = document.createElement('div');
  wrap.id = 'pair-modal';
  wrap.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.6);display:flex;align-items:center;justify-content:center;z-index:9999;backdrop-filter:blur(4px)';
  wrap.addEventListener('click', ev => { if (ev.target === wrap) _cancelPair(); });
  wrap.innerHTML = `
    <div style="background:var(--card-bg,#14203a);border:1px solid var(--border,rgba(255,255,255,.08));border-radius:18px;padding:28px;max-width:420px;width:calc(100% - 32px);box-shadow:0 20px 60px rgba(0,0,0,.45);position:relative">
      <button onclick="_cancelPair()" style="position:absolute;top:12px;right:12px;background:none;border:none;color:var(--muted);font-size:22px;cursor:pointer;width:28px;height:28px;border-radius:8px">×</button>
      <div style="text-align:center">
        <div style="width:56px;height:56px;border-radius:14px;background:linear-gradient(145deg,#f0b341,#e0552b);display:flex;align-items:center;justify-content:center;font-weight:800;font-size:22px;color:#fff;margin:0 auto 14px">JC</div>
        <h2 style="font-size:18px;margin-bottom:8px">Pair a new device</h2>
        <p style="color:var(--muted);font-size:13px;margin-bottom:14px;line-height:1.5">Scan with the JarvisCopilot mobile app:</p>
        <div style="display:flex;justify-content:center;margin-bottom:14px">${_renderQRSvg(_pairDeepLink(code), {size: 188, bg: '#ffffff', fg: '#0a0e1a'})}</div>
        <p style="color:var(--muted);font-size:12px;margin-bottom:10px;line-height:1.5">Or open this URL on a browser:</p>
        <div style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);border-radius:10px;padding:8px 12px;margin-bottom:14px;font-family:ui-monospace,Menlo,monospace;font-size:12px;word-break:break-all;text-align:center">${_devEsc(_pairUrl())}</div>
        <p style="color:var(--muted);font-size:13px;margin-bottom:8px">Then enter this code:</p>
        <div id="pair-code-display" style="font-family:ui-monospace,Menlo,monospace;font-size:32px;font-weight:800;letter-spacing:6px;color:#f0b341;background:rgba(240,179,65,.08);border:1px dashed rgba(240,179,65,.3);border-radius:12px;padding:14px;margin-bottom:14px">${_devEsc(code)}</div>
        ${_pairCfTokenBlock()}
        <div id="pair-status" style="font-size:13px;color:var(--muted);min-height:22px">
          <span style="display:inline-block;width:10px;height:10px;border:2px solid #f0b341;border-top-color:transparent;border-radius:50%;animation:pair-spin .9s linear infinite;margin-right:6px;vertical-align:-1px"></span>
          Waiting for device... <span id="pair-countdown"></span>
        </div>
      </div>
    </div>
    <style>@keyframes pair-spin{to{transform:rotate(360deg)}}</style>`;
  document.body.appendChild(wrap);
  _devicesPairModalEl = wrap;
  _updatePairCountdown(expiresAt);
}

function _closePairModal() {
  if (_devicesPairPollTimer) { clearInterval(_devicesPairPollTimer); _devicesPairPollTimer = null; }
  if (_devicesPairModalEl && _devicesPairModalEl.parentNode) _devicesPairModalEl.parentNode.removeChild(_devicesPairModalEl);
  _devicesPairModalEl = null;
}

let _pairCountdownTimer = null;
function _updatePairCountdown(expiresAt) {
  if (_pairCountdownTimer) clearInterval(_pairCountdownTimer);
  const tick = () => {
    const el = document.getElementById('pair-countdown');
    if (!el) { clearInterval(_pairCountdownTimer); return; }
    const remaining = Math.max(0, Math.floor(expiresAt - (Date.now() / 1000)));
    const m = Math.floor(remaining / 60), s = remaining % 60;
    el.textContent = `(${m}:${s.toString().padStart(2, '0')})`;
    if (remaining <= 0) clearInterval(_pairCountdownTimer);
  };
  tick();
  _pairCountdownTimer = setInterval(tick, 1000);
}

function _startPairPolling(code) {
  if (_devicesPairPollTimer) clearInterval(_devicesPairPollTimer);
  _devicesPairPollTimer = setInterval(async () => {
    try {
      const res = await fetch('/api/auth/pair/status?code=' + encodeURIComponent(code), { credentials: 'same-origin' });
      if (!res.ok) return;
      const state = await res.json();
      if (state.status === 'claimed') {
        clearInterval(_devicesPairPollTimer);
        const statusEl = document.getElementById('pair-status');
        if (statusEl) statusEl.innerHTML = `<span style="color:#7ae597">✓ Paired with ${_devEsc(state.device_name || 'device')}</span>`;
        setTimeout(() => { _closePairModal(); loadDevices(true); }, 1500);
      } else if (state.status === 'expired' || state.status === 'unknown') {
        clearInterval(_devicesPairPollTimer);
        const statusEl = document.getElementById('pair-status');
        if (statusEl) statusEl.innerHTML = `<span style="color:#ff9c5a">⌛ Code expired without a pairing.</span>`;
      }
    } catch (e) { /* ignore transient errors */ }
  }, 1000);
}

function _cancelPair() {
  const code = _devicesPairCurrentCode;
  _closePairModal();
  if (code) {
    fetch('/api/devices/pair/cancel', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'fetch' },
      body: JSON.stringify({ code }),
    }).catch(() => {});
  }
}

// ── Event delegation ──────────────────────────────────────────────────────
// The card / row markup is regenerated by render*() every refresh, so we
// can't bind handlers per-button — they'd disappear on the next innerHTML
// swap. Using inline onclick="…(name)" was the previous approach but
// broke when device names contained apostrophes ("Pranav's iPhone") —
// the HTML-escaped &#39; closed the JS string mid-attribute and the whole
// row failed to parse, leaving Revoke / Log out non-functional. Wiring
// once at script load via delegation avoids the quoting problem entirely.
document.addEventListener('click', ev => {
  const target = ev.target;
  if (!(target instanceof Element)) return;

  // Revoke / Log out buttons inside a .device-card.
  const card = target.closest('.device-card');
  if (card) {
    const id = card.dataset.id || '';
    const name = card.dataset.name || '';
    if (!id) return;
    if (target.classList.contains('device-revoke-btn')) {
      ev.preventDefault();
      revokeDevice(id, name);
      return;
    }
    if (target.classList.contains('device-logout-btn')) {
      ev.preventDefault();
      logoutDevice(id, name);
      return;
    }
  }

  // Sidebar row click → scroll the matching card into view.
  const row = target.closest('#devicesList .device-row');
  if (row && row.dataset.id) {
    selectDevice(row.dataset.id);
  }
});
