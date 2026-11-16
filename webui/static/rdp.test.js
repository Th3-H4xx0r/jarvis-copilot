'use strict';
// node --test webui/static/rdp.test.js
//
// Remote Desktop on the web (rdp_core.js): the connect flow (checking → warn → approving →
// connecting → connected → ended | error) with his messages for each refusal, the 2 GB upload
// limit, and the Mac's Windows App launch (.rdp file and rdp:// URI) with readiness and warnings.
const test = require('node:test');
const assert = require('node:assert/strict');
const R = require('./rdp_core.js');

const NAME = 'pranav-computer';
const STATUS = {
  device_id: 'pc-1', edition: 'Windows 11 Pro', rdp_enabled: true, firewall_scoped: true,
  username: 'MicrosoftAccount\\krish@example.com', tailscale_ip: '100.119.223.124', idle_s: 900,
  locked: true, game: null, remote_session: false, has_password: true,
};

function start() { return R.flow(R.initial(NAME), { type: 'start' }); }

test('flow: asleep shows Wake', () => {
  const s = R.flow(start(), { type: 'created', response: { error: 'pranav-computer is asleep', code: 'asleep' } });
  assert.equal(s.phase, 'error');
  assert.equal(s.code, 'asleep');
  assert.equal(s.message, 'pranav-computer is asleep');
  assert.equal(s.action, 'wake');
  // offline / not set up / no password / Home: their own words, no Wake
  const np = R.flow(start(), { type: 'created', response: { code: 'no_password' } });
  assert.equal(np.message, 'Save your Windows password in Jarvis on the PC first (Settings → PC power)');
  assert.equal(np.action, undefined);
  assert.match(R.flow(start(), { type: 'created', response: { code: 'edition' } }).message, /Windows 11 Pro/);
  assert.match(R.flow(start(), { type: 'created', response: { code: 'not_ready' } }).message, /isn’t set up/);
});

test('flow: warn then confirm goes approving', () => {
  let s = start();
  assert.equal(s.phase, 'checking');
  s = R.flow(s, { type: 'created', response: { warn: 'game', game_name: 'Call of Duty' } });
  assert.equal(s.phase, 'warn');
  assert.equal(s.warn, 'game');
  assert.equal(R.warnText(s), 'pranav-computer is in a game (Call of Duty). Connecting signs the PC’s screen out; the game keeps running.');
  s = R.flow(s, { type: 'confirm' });
  assert.equal(s.phase, 'checking');
  assert.equal(s.confirm, true);
  s = R.flow(s, { type: 'created', response: { session: { id: 'sid-1', state: 'approving', expires_at: 100 } } });
  assert.equal(s.phase, 'approving');
  assert.equal(s.sessionId, 'sid-1');
  // the in-use warning reads differently; Cancel ends without connecting
  const inUse = R.flow(start(), { type: 'created', response: { warn: 'in_use' } });
  assert.equal(R.warnText(inUse), 'Someone is using pranav-computer. Connecting signs the PC’s screen out.');
  assert.equal(R.flow(inUse, { type: 'cancel' }).phase, 'ended');
});

test('flow: approval timeout ends with message', () => {
  let s = R.flow(start(), { type: 'created', response: { session: { id: 'sid-1', state: 'approving' } } });
  assert.equal(R.flow(s, { type: 'polled', session: { state: 'approving' } }).phase, 'approving');
  const t = R.flow(s, { type: 'timeout' });
  assert.equal(t.phase, 'error');
  assert.equal(t.message, 'No answer on your iPhone in 60 seconds');
  // the server can cancel too (denied / expired): its words win
  const denied = R.flow(s, { type: 'polled', session: { state: 'cancelled', error: 'Not allowed' } });
  assert.equal(denied.phase, 'error');
  assert.equal(denied.message, 'Not allowed');
  // approved → connecting → connected → ended
  s = R.flow(s, { type: 'polled', session: { state: 'approved' } });
  assert.equal(s.phase, 'connecting');
  s = R.flow(s, { type: 'tunnel_open' });
  assert.equal(s.phase, 'connected');
  assert.equal(R.flow(s, { type: 'ended' }).phase, 'ended');
});

test('flow: password refused message', () => {
  let s = R.flow(start(), { type: 'created', response: { session: { id: 'sid-1', state: 'approving' } } });
  s = R.flow(R.flow(s, { type: 'polled', session: { state: 'approved' } }), { type: 'tunnel_open' });
  const e = R.flow(s, { type: 'tunnel_error', message: R.PASSWORD_REFUSED, status: 769 });
  assert.equal(e.phase, 'error');
  assert.equal(e.code, 'password');
  assert.equal(e.message, 'Windows refused the saved password — update it in Jarvis on the PC (Settings → PC power)');
  // any auth status maps the same, whatever guacd's words
  assert.equal(R.flow(s, { type: 'tunnel_error', message: 'Authentication failure', status: 0x0301 }).code, 'password');
  assert.equal(R.flow(s, { type: 'tunnel_error', message: 'Server busy', status: 0x0201 }).message, 'Server busy');
  // a tunnel that never opened (0x0207 from the browser's WebSocket) is not a password problem
  const connecting = R.flow(R.flow(start(), { type: 'created', response: { session: { id: 'x' } } }),
    { type: 'polled', session: { state: 'approved' } });
  const drop = R.flow(connecting, { type: 'tunnel_error', message: '', status: 0x0207 });
  assert.equal(drop.code, 'tunnel');
  assert.equal(drop.message, 'Couldn’t reach the Remote Desktop gateway on the server');
});

test('upload refuses files over 2 GB before sending', () => {
  assert.equal(R.MAX_UPLOAD, 2 * 1024 ** 3);
  assert.equal(R.checkUpload({ name: 'a.zip', size: 10 }), null);
  assert.equal(R.checkUpload({ name: 'b.iso', size: 2 * 1024 ** 3 }), null);
  assert.equal(R.checkUpload({ name: 'big.iso', size: 2 * 1024 ** 3 + 1 }), 'big.iso is over 2 GB — send it another way');
});

test('the guac tunnel URL carries the session and the size', () => {
  assert.equal(R.tunnelPath('sid-1'), 'api/rdp/guac/sid-1');
  assert.equal(R.connectQuery(1600.4, 900.6, 2), 'w=1600&h=901&dpi=192');
});

// ── the Mac: Microsoft Windows App ──────────────────────────────────────────
test('Mac: the .rdp file has every line', () => {
  const lines = R.rdpFile(STATUS).split('\r\n').filter(Boolean);
  assert.deepEqual(lines, [
    'full address:s:100.119.223.124',
    'username:s:MicrosoftAccount\\krish@example.com',
    'prompt for credentials:i:0',
    'redirectclipboard:i:1',
    'audiomode:i:0',
    'drivestoredirect:s:*',
    'dynamic resolution:i:1',
    'screen mode id:i:2',
    'authentication level:i:2',
  ]);
});

test('Mac: the rdp:// URI encodes spaces, the username and the type colon', () => {
  const uri = R.rdpUri(STATUS);
  assert.ok(uri.startsWith('rdp://full%20address=s%3A100.119.223.124&'));
  assert.ok(!uri.includes(' '));
  assert.ok(uri.includes('&username=s%3AMicrosoftAccount%5Ckrish%40example.com'));
  assert.ok(uri.includes('&prompt%20for%20credentials=i%3A0'));
  assert.ok(uri.includes('&screen%20mode%20id=i%3A2'));
  assert.equal(uri.split('&').length, 9);
  // a parseable URL: no bare "host:port"-looking colon after the scheme (macOS rejected that form)
  assert.ok(!/^rdp:\/\/[^&]*=s:/.test(uri));
  assert.doesNotThrow(() => new URL(uri));
});

test('Mac: not ready reads like the iPhone; warnings before opening Windows App', () => {
  assert.equal(R.readiness(STATUS, NAME), null);
  assert.equal(R.readiness(null, NAME).code, 'offline');
  assert.equal(R.readiness({ ...STATUS, edition: 'Windows 11 Home' }, NAME).code, 'edition');
  assert.equal(R.readiness({ ...STATUS, rdp_enabled: false }, NAME).code, 'not_ready');
  assert.equal(R.readiness({ ...STATUS, tailscale_ip: '' }, NAME).code, 'not_ready');
  // Windows App asks for the password itself: no saved password is fine on the Mac
  assert.equal(R.readiness({ ...STATUS, has_password: false }, NAME), null);
  assert.equal(R.warnFor(STATUS), null);
  assert.deepEqual(R.warnFor({ ...STATUS, game: 'cod.exe', game_name: 'Call of Duty' }), { warn: 'game', game_name: 'Call of Duty' });
  assert.deepEqual(R.warnFor({ ...STATUS, idle_s: 30, locked: false }), { warn: 'in_use' });
  assert.equal(R.warnFor({ ...STATUS, idle_s: 30, locked: true }), null);
});

test('only a real Mac opens Windows App (an iPad says Macintosh too)', () => {
  assert.equal(R.isMac({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 0 }), true);
  assert.equal(R.isMac({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 5 }), false);
  assert.equal(R.isMac({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', maxTouchPoints: 0 }), false);
  assert.equal(R.isMac({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)', maxTouchPoints: 5 }), false);
});
