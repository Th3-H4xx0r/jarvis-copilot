// node --test webui/static/pc_device.test.js — the Devices panel's PC card (pc_device.js).
const test = require('node:test');
const assert = require('node:assert');
const P = require('./pc_device.js');

const pc = { device_id: 'pc-1', name: 'Pranav-COMPUTER', os: 'windows', state: 'awake' };
const parts = (effect) => Object.fromEntries(['top', 'rear', 'bottom', 'cooler', 'strip']
  .map((p) => [p, { effect, color: '#22d3ee', speed: 5 }]));
const lighting = (over = {}) => Object.assign({
  device_id: 'pc-1', online: true, state: { on: true, brightness: 65, parts: parts('rainbow') },
  map: { segments: [{ part: 'top' }] }, coverage: { top: null, rear: 'top', bottom: 'missing', cooler: 'missing', strip: 'missing' },
  looks: [{ name: 'Gaming', brightness: 80 }], live: { engine: 'running' },
}, over);
const specs = { cpu: { name: 'Intel(R) Core(TM) i7-14700F', cores: 20, threads: 28 }, gpus: [{ name: 'NVIDIA GeForce RTX 5070', vram_mb: 12227 }],
  board: { maker: 'ASRock', product: 'B760M-C' }, memory: { total_mb: 32768, modules: [{ maker: 'Team Group Inc', part: 'UD5-6400', size_mb: 16384, mhz: 6400 }] } };

test('no PC: no card', () => {
  assert.strictEqual(P.cardHtml({ pc: null }), '');
});

test('the card shows the model picture, controls slot, lighting and specs', () => {
  const html = P.cardHtml({ pc, lighting: lighting(), specs, powerOn: true, controlsHtml: '<div id="ctl"></div>' });
  assert.match(html, /static\/img\/pc\/pc-model\.png/);
  assert.match(html, /id="ctl"/);
  assert.match(html, /data-power="pc-lighting"/);
  assert.match(html, /Rainbow/);
  assert.match(html, /B760M-C/);
  assert.match(html, /UD5-6400/);
});

test('offline PC: lighting controls are disabled with the reason', () => {
  const html = P.cardHtml({ pc, lighting: lighting({ online: false }), specs, powerOn: true });
  assert.match(html, /asleep or offline/);
  assert.doesNotMatch(html, /data-pcd="color"/);
});

test('PC Lighting off: no lighting panel', () => {
  const html = P.cardHtml({ pc, lighting: null, specs, powerOn: false });
  assert.doesNotMatch(html, /pcd-lighting/);
});

test('not set up: points to the iPhone for calibration', () => {
  const html = P.cardHtml({ pc, lighting: lighting({ map: { segments: [] } }), specs, powerOn: true });
  assert.match(html, /Finish setting up lighting on your iPhone/);
});

test('specs missing: says to update Jarvis on the PC', () => {
  const html = P.cardHtml({ pc, lighting: lighting(), specs: null, powerOn: true });
  assert.match(html, /Update Jarvis on the PC/);
});

test('shared part gets a note and the lights label is Mixed when parts differ', () => {
  const l = lighting();
  l.state.parts.strip.effect = 'static';
  assert.strictEqual(P.lightsLabel(l), 'Mixed');
  const html = P.cardHtml({ pc, lighting: lighting(), specs, powerOn: true, part: 'rear' });
  assert.match(html, /share lights with top fans/);
});
