'use strict';
// node --test webui/static/pc_stats.test.js
//
// PC Stats on the web (pc_stats_core.js): the 12-column grid (a drag or resize snaps to whole
// cells and is refused when it would overlap or leave the grid; new widgets find the first free
// slot), the one-column reading order, and how values read — a reading the PC didn't send says
// "unavailable" with why (never 0), estimated readings carry "est." (but "PC (est.)" isn't
// badged twice), thresholds tint amber/red, and the Agents card's four numbers.
const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('./pc_stats_core.js');

const CATALOG = {
  readings: {
    'cpu.load': { label: 'CPU load', unit: '%', group: 'cpu', estimated: false },
    'cpu.temp': { label: 'CPU temperature', unit: '°C', group: 'cpu', estimated: false },
    'cpu.clock': { label: 'CPU clock', unit: 'MHz', group: 'cpu', estimated: false },
    'gpu.load': { label: 'GPU load', unit: '%', group: 'gpu', estimated: false },
    'ram.used': { label: 'RAM used', unit: 'GB', group: 'memory', estimated: false },
    fps: { label: 'Frame rate', unit: 'fps', group: 'frames', estimated: false },
    'power.ram': { label: 'RAM power', unit: 'W', group: 'power', estimated: true },
    'power.gpu': { label: 'GPU power (model)', unit: 'W', group: 'power', estimated: false },
    'power.total': { label: 'PC (est.)', unit: 'W', group: 'power', estimated: true },
  },
};

const OVERVIEW = [
  { id: 'gpu', x: 0, y: 0, w: 6, h: 4 },
  { id: 'cpu', x: 6, y: 0, w: 3, h: 4 },
  { id: 'frames', x: 9, y: 0, w: 3, h: 4 },
  { id: 'power', x: 0, y: 4, w: 4, h: 4 },
];

// ── grid ────────────────────────────────────────────────────────────────────
test('a drag snaps to the nearest whole cell', () => {
  // 100 px cells, 16 px gaps: a pitch of 116 px. 170 px right ≈ 1.47 cells → 1; 60 px down ≈ 0.5 → 1.
  assert.deepEqual(C.snapMove({ x: 0, y: 4, w: 4, h: 4 }, 170, 60, 100, 60, 16), { x: 1, y: 5, w: 4, h: 4 });
  assert.deepEqual(C.snapMove({ x: 0, y: 4, w: 4, h: 4 }, 40, -20, 100, 60, 16), { x: 0, y: 4, w: 4, h: 4 });
});

test('a drag never leaves the grid', () => {
  assert.deepEqual(C.snapMove({ x: 8, y: 0, w: 4, h: 2 }, 900, -500, 100, 60, 16), { x: 8, y: 0, w: 4, h: 2 });
  assert.deepEqual(C.snapMove({ x: 2, y: 3, w: 4, h: 2 }, -900, 0, 100, 60, 16), { x: 0, y: 3, w: 4, h: 2 });
});

test('a resize snaps, stays at least one cell and inside the 12 columns', () => {
  assert.deepEqual(C.snapResize({ x: 4, y: 0, w: 4, h: 4 }, 232, 76, 100, 60, 16), { x: 4, y: 0, w: 6, h: 5 });
  assert.deepEqual(C.snapResize({ x: 4, y: 0, w: 4, h: 4 }, -2000, -2000, 100, 60, 16), { x: 4, y: 0, w: 1, h: 1 });
  assert.deepEqual(C.snapResize({ x: 10, y: 0, w: 2, h: 2 }, 900, 0, 100, 60, 16), { x: 10, y: 0, w: 2, h: 2 });
});

test('a move onto another widget is refused; onto free space or itself is allowed', () => {
  assert.equal(C.canPlace(OVERVIEW, { id: 'power', x: 2, y: 2, w: 4, h: 4 }), false);
  assert.equal(C.canPlace(OVERVIEW, { id: 'power', x: 4, y: 4, w: 4, h: 4 }), true);
  assert.equal(C.canPlace(OVERVIEW, { id: 'gpu', x: 0, y: 0, w: 6, h: 4 }), true);
  // touching edges is not overlapping
  assert.equal(C.canPlace(OVERVIEW, { id: 'new', x: 0, y: 8, w: 12, h: 1 }), true);
});

test('off-grid placements are refused', () => {
  assert.equal(C.canPlace([], { id: 'a', x: 10, y: 0, w: 3, h: 1 }), false);
  assert.equal(C.canPlace([], { id: 'a', x: -1, y: 0, w: 3, h: 1 }), false);
  assert.equal(C.canPlace([], { id: 'a', x: 0, y: 0, w: 0, h: 1 }), false);
});

test('a new widget goes into the first free slot, else below everything', () => {
  assert.deepEqual(C.autoPlace(OVERVIEW, 4, 4), { x: 4, y: 4 });
  assert.deepEqual(C.autoPlace(OVERVIEW, 12, 2), { x: 0, y: 8 });
  assert.deepEqual(C.autoPlace([], 6, 4), { x: 0, y: 0 });
  assert.deepEqual(C.autoPlace(OVERVIEW, 20, 1), { x: 0, y: 8 });   // wider than the grid: full width
});

test('one column reads top to bottom, then left to right', () => {
  const order = C.reflow([
    { id: 'b', x: 6, y: 0 }, { id: 'd', x: 4, y: 4 }, { id: 'a', x: 0, y: 0 }, { id: 'c', x: 0, y: 4 },
  ]).map((w) => w.id);
  assert.deepEqual(order, ['a', 'b', 'c', 'd']);
});

test('the grid is as tall as its lowest widget', () => {
  assert.equal(C.rows(OVERVIEW), 8);
  assert.equal(C.rows([]), 0);
});

test('new ids and dashboard slugs never collide', () => {
  assert.equal(C.newId('gpu', OVERVIEW), 'gpu-2');
  assert.equal(C.newId('GPU Temp!', OVERVIEW), 'gpu-temp');
  assert.equal(C.slug('My Racing Setup', ['overview']), 'my-racing-setup');
  assert.equal(C.slug('Overview', ['overview', 'overview-2']), 'overview-3');
  assert.equal(C.slug('!!!', []), 'dashboard');
});

// ── values ──────────────────────────────────────────────────────────────────
test('a reading the PC did not send is unavailable, never 0', () => {
  const sample = { r: { 'cpu.load': 0 }, game: null };
  const zero = C.read('cpu.load', { sample, catalog: CATALOG });
  assert.equal(zero.ok, true);
  assert.equal(zero.num, '0');
  const missing = C.read('gpu.load', { sample, catalog: CATALOG });
  assert.equal(missing.ok, false);
  assert.equal(missing.num, 'unavailable');
  assert.notEqual(missing.num, '0');
});

test('unavailable says why', () => {
  const sample = { r: { 'cpu.load': 12 }, game: null };
  assert.equal(C.read('fps', { sample, catalog: CATALOG }).reason, 'no game running');
  assert.equal(C.read('cpu.temp', { sample, catalog: CATALOG, sensorDriver: false }).reason, 'needs the sensor driver');
  assert.equal(C.read('fan.cpu_fan', { sample, catalog: CATALOG, sensorDriver: false }).reason, 'needs the sensor driver');
  assert.equal(C.read('gpu.load', { sample, catalog: CATALOG }).reason, 'not reported by this PC');
  assert.equal(C.read('gpu.load', { sample: null, catalog: CATALOG }).reason, 'no readings yet');
  assert.equal(C.read('fps', { sample: { r: {}, game: 'Minecraft' }, catalog: CATALOG }).reason, 'not reported by this PC');
});

test('values use the widget decimals, else the unit default; big clocks read in GHz', () => {
  assert.deepEqual(C.format(21.43, 'GB'), { num: '21.4', unit: 'GB' });
  assert.deepEqual(C.format(37.6, '%'), { num: '38', unit: '%' });
  assert.deepEqual(C.format(37.6, '%', 1), { num: '37.6', unit: '%' });
  assert.deepEqual(C.format(5400, 'MHz'), { num: '5.40', unit: 'GHz' });
  assert.deepEqual(C.format(5400, 'MHz', 0), { num: '5400', unit: 'MHz' });
  assert.deepEqual(C.format(-0.2, '°C'), { num: '0', unit: '°C' });
  assert.deepEqual(C.format(null, 'W'), { num: '', unit: 'W' });
});

test('fan and temperature names the PC reports get a label and unit', () => {
  assert.deepEqual(C.info('fan.cpu_fan', CATALOG), { label: 'CPU fan', unit: 'rpm', group: 'cooling', estimated: false });
  assert.equal(C.info('temp.vrm', CATALOG).unit, '°C');
  assert.equal(C.info('bogus', CATALOG), null);
});

test('estimated readings carry the badge; "PC (est.)" is not badged twice', () => {
  assert.equal(C.isEstimated('power.ram', [], CATALOG), true);                // by nature
  assert.equal(C.isEstimated('power.gpu', ['power.gpu'], CATALOG), true);     // this sample estimated it
  assert.equal(C.isEstimated('power.gpu', [], CATALOG), false);               // measured
  assert.equal(C.showEst('power.ram', 'RAM power', [], CATALOG), true);
  assert.equal(C.showEst('power.total', 'PC (est.)', [], CATALOG), false);
  assert.equal(C.showEst('power.total', 'Whole PC', [], CATALOG), true);
});

test('a load hero takes its temperature beside the % and out of the meta row', () => {
  const gpu = { kind: 'hero', readings: ['gpu.load'], style: { meta: ['gpu.clock', 'gpu.temp', 'gpu.power'] } };
  assert.deepEqual(C.heroTemp(gpu), { temp: 'gpu.temp', meta: ['gpu.clock', 'gpu.power'] });
  // the same part's temperature wins over another one
  const both = { readings: ['cpu.load'], style: { meta: ['temp.vrm', 'cpu.temp'] } };
  assert.equal(C.heroTemp(both).temp, 'cpu.temp');
  // any temperature will do when the part's own isn't there
  assert.equal(C.heroTemp({ readings: ['gpu.load'], style: { meta: ['temp.vrm'] } }).temp, 'temp.vrm');
  // not a load, or no temperature: unchanged
  assert.deepEqual(C.heroTemp({ readings: ['fps'], style: { meta: ['gpu.temp'] } }), { temp: null, meta: ['gpu.temp'] });
  assert.deepEqual(C.heroTemp({ readings: ['cpu.load'], style: {} }), { temp: null, meta: [] });
});

test('thresholds tint amber then red', () => {
  const style = { warn: 85, crit: 95 };
  assert.equal(C.level(70, style), '');
  assert.equal(C.level(85, style), 'warn');
  assert.equal(C.level(97, style), 'crit');
  assert.equal(C.level(null, style), '');
  assert.equal(C.level(99, {}), '');
});

test('bar fills: % of 100, a pair of its total, watts of the PC total', () => {
  const r = { 'ram.used': 16, 'ram.total': 32, 'power.total': 400, 'power.gpu': 300 };
  assert.equal(C.fraction('cpu.load', 50, r, [], '%'), 0.5);
  assert.equal(C.fraction('ram.used', 16, r, [], 'GB'), 0.5);
  assert.equal(C.fraction('power.gpu', 300, r, [300], 'W'), 0.75);
  assert.equal(C.fraction('power.gpu', 300, {}, [300, 100], 'W'), 0.75);   // no total: share of the bars
  assert.equal(C.fraction('fan.case', 1500, {}, [1500, 6000], 'rpm'), 0.25);
  assert.equal(C.fraction('x', null, r, [], '%'), 0);
  assert.equal(C.fraction('cpu.load', 140, r, [], '%'), 1);
});

// ── the Agents card ─────────────────────────────────────────────────────────
test('the card shows usage with its temperature beside it; a missing one says unavailable', () => {
  const cells = C.summaryCells({ online: true, cpu: 38.2, gpu: 0, cpu_temp: 72.4, gpu_temp: null, hottest: 72.4, watts: null });
  assert.deepEqual(cells.map((c) => c.label), ['CPU', 'GPU', 'PC (est.)']);
  assert.deepEqual(cells.map((c) => c.num), ['38', '0', 'unavailable']);
  assert.deepEqual(cells.map((c) => c.unit), ['%', '%', '']);
  assert.equal(cells[0].temp, '72');
  assert.equal(cells[0].tempUnit, '°C');
  assert.equal(cells[1].temp, undefined);
});

test('offline says when it was last seen; never reported says it is waiting', () => {
  const now = 1_800_000_000;
  assert.equal(C.statusLine({ online: false, at: now - 300 }, now), 'PC offline · last seen 5 min ago');
  assert.equal(C.statusLine({ online: false, at: now - 7200 }, now), 'PC offline · last seen 2 h ago');
  assert.equal(C.statusLine({ online: true, at: now, sample: { game: 'Minecraft' } }, now), 'Online · Playing Minecraft');
  assert.equal(C.statusLine({ online: false, at: null }, now), 'Waiting for the PC’s first reading');
});

// ── charts ──────────────────────────────────────────────────────────────────
test('charts break where the PC was off and clamp to the box', () => {
  const pts = [[0, 50], [10, 60], [20, 70], [500, 40], [510, 200]];
  const p = C.paths(pts, 0, 600, 0, 100, 600, 100, 60);
  assert.equal((p.line.match(/M/g) || []).length, 2);
  assert.ok(!/NaN/.test(p.line + p.area));
  assert.ok(p.line.includes(',0'));          // 200 clamps to the top (y = 0)
  assert.equal(C.paths([], 0, 1, 0, 1, 10, 10, 5).line, '');
});

test('a gap is judged against the series’ own spacing', () => {
  assert.equal(C.medianStep([[0, 1], [10, 1], [20, 1], [500, 1]]), 10);
  assert.equal(C.medianStep([[0, 1]]), 0);
  // hourly points with a 3-hour gap threshold stay one line when the step is 4 h
  const pts = [[0, 1], [14400, 2], [28800, 3]];
  const gap = Math.max(3 * 3600, 3 * C.medianStep(pts));
  assert.equal((C.paths(pts, 0, 28800, 0, 5, 100, 10, gap).line.match(/M/g) || []).length, 1);
});

test('chart scale: % is 0–100, others start at 0 with headroom', () => {
  assert.deepEqual(C.domain([[[0, 30]]], '%'), [0, 100]);
  const [lo, hi] = C.domain([[[0, 100], [1, 200]]], 'W');
  assert.equal(lo, 0);
  assert.ok(hi > 200);
  assert.deepEqual(C.domain([[]], 'W'), [0, 1]);
});

test('live series append only newer samples and keep their window', () => {
  const pts = [[0, 1], [10, 2]];
  C.pushLive(pts, 10, 9, 60);
  assert.equal(pts.length, 2);
  C.pushLive(pts, 70, 3, 60);
  assert.deepEqual(pts, [[10, 2], [70, 3]]);
  C.pushLive(pts, 71, null, 60);
  assert.equal(pts.length, 2);
});

test('money falls back when the currency code is unknown', () => {
  assert.match(C.money(0.31, 'USD'), /0\.31/);
  assert.match(C.money(1.5, 'NOTACODE'), /1\.50 NOTACODE/);
});

// ── Apple look: smoothing, p98 range, gridlines, stats, tints ──────────────
test('charts plot a centred moving average, never the raw spike', () => {
  const pts = [[0, 10], [1, 10], [2, 10], [3, 110], [4, 10], [5, 10], [6, 10]];
  const s = C.smooth(pts, 5);
  assert.equal(s.length, pts.length);
  assert.deepEqual(s.map((p) => p[0]), pts.map((p) => p[0]));   // times kept
  assert.equal(s[3][1], 30);                                      // (10+10+110+10+10)/5
  assert.ok(Math.max(...s.map((p) => p[1])) < 110);
  assert.equal(s[0][1], 10);                                      // edge window: samples 0–2
  assert.equal(s[1][1], 35);                                      // samples 0–3: (10+10+10+110)/4
});

test('smoothing never averages across a gap where the PC was off', () => {
  const pts = [[0, 10], [1, 10], [2, 10], [500, 90], [501, 90], [502, 90]];
  const s = C.smooth(pts, 5, 30);
  assert.deepEqual(s.map((p) => p[1]), [10, 10, 10, 90, 90, 90]);
});

test('the smoothing window is ≈5 at 1 Hz and widens for long series, odd and capped', () => {
  assert.equal(C.smoothWindow(60), 5);
  assert.equal(C.smoothWindow(300), 9);
  assert.equal(C.smoothWindow(2000), 31);
  for (const n of [0, 10, 240, 400, 999]) assert.equal(C.smoothWindow(n) % 2, 1);
});

test('the y range tops out at p98 × 1.15 so one spike cannot flatten the line', () => {
  const pts = [];
  for (let i = 0; i < 100; i++) pts.push([i, 100 + (i % 10)]);   // 100–109
  pts.push([100, 2000]);                                         // one spike
  const [lo, hi] = C.domain([pts], 'W');
  assert.equal(lo, 0);
  assert.ok(hi < 200, `hi ${hi} should ignore the spike`);
  assert.ok(hi >= 109 * 1.15 - 1e-9);
  assert.deepEqual(C.domain([pts], '%'), [0, 100]);
  assert.equal(C.percentile([5, 1, 3], 50), 3);
  assert.equal(C.percentile([], 98), null);
});

test('gridlines are up to three round values inside the range', () => {
  assert.deepEqual(C.gridLines(0, 100), [25, 50, 75]);
  assert.deepEqual(C.gridLines(0, 230), [100, 200]);
  assert.ok(C.gridLines(0, 1).every((v) => v > 0 && v < 1));
  assert.deepEqual(C.gridLines(5, 5), []);
});

test('the stat row reads min, avg and max of the window', () => {
  assert.deepEqual(C.stats([[0, 58], [1, 72], [2, 68]]), { min: 58, avg: 66, max: 72 });
  assert.equal(C.stats([]), null);
});

test('readings take their icon family (no colours: the page uses the app accent)', () => {
  assert.equal(C.family('gpu.load'), 'gpu');
  assert.equal(C.family('cpu.clock'), 'cpu');
  assert.equal(C.family('gpu.temp'), 'temps');
  assert.equal(C.family('temp.vrm'), 'temps');
  assert.equal(C.family('gpu.vram_used'), 'memory');
  assert.equal(C.family('gpu.fan'), 'cooling');
  assert.equal(C.family('fan.*'), 'cooling');
  assert.equal(C.family('fps.low1'), 'frames');
  assert.equal(C.family('power.total'), 'power');
  assert.equal(C.family('net.down'), 'network');
});

// ── dense dashboards: wildcards, dynamic labels, fitting ──────────────────
test('temp.* and fan.* expand to every matching key in the sample, sorted, without repeats', () => {
  const sample = { r: { 'cpu.temp': 70, 'temp.vrm': 60, 'temp.chipset': 50, 'fan.fan_10': 900, 'fan.fan_2': 800,
    'fan.cpu_fan': 1200, 'gpu.fan': 1600 } };
  assert.deepEqual(C.expand(['cpu.temp', 'gpu.temp', 'temp.*'], sample), ['cpu.temp', 'gpu.temp', 'temp.chipset', 'temp.vrm']);
  assert.deepEqual(C.expand(['gpu.fan', 'fan.*'], sample), ['gpu.fan', 'fan.cpu_fan', 'fan.fan_2', 'fan.fan_10']);
  // a key listed explicitly isn't repeated by the wildcard
  assert.deepEqual(C.expand(['fan.fan_2', 'fan.*'], sample), ['fan.fan_2', 'fan.cpu_fan', 'fan.fan_10']);
  // no sample: the wildcard is simply empty
  assert.deepEqual(C.expand(['gpu.fan', 'fan.*'], null), ['gpu.fan']);
  assert.deepEqual(C.expand(['cpu.load'], sample), ['cpu.load']);
});

test('dynamic fans and temperatures read as names, never raw keys', () => {
  assert.equal(C.info('fan.fan_1', {}).label, 'Fan 1');
  assert.equal(C.info('fan.cpu_fan', {}).label, 'CPU fan');
  assert.equal(C.info('temp.vrm_mos', {}).label, 'VRM MOS');
  assert.equal(C.info('temp.2', {}).label, 'Sensor 2');
  assert.equal(C.info('temp.*', {}).unit, '°C');
  for (const k of ['fan.fan_1', 'temp.vrm_mos']) assert.ok(!C.info(k, {}).label.includes('_'));
});

test('a card shows only the rows that fit', () => {
  assert.equal(C.fit(181, 31, 6), 5);
  assert.equal(C.fit(30, 31, 6), 1);
  assert.equal(C.fit(0, 31, 6), 1);
});

// ── Jarvis look: every colour comes from the app's tokens ──────────────────
test('no hard-coded hues in the PC Stats files (only var(--jc-*), white/black, transparent)', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const files = ['pc_stats.css', 'pc_stats.js', 'pc_stats_core.js', 'pc_stats_edit.js'];
  const WHITE_BLACK = /^#(f{3}|f{6}|0{3}|0{6})$/i;
  for (const f of files) {
    // comments may mention colours
    const src = fs.readFileSync(path.join(__dirname, f), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
    for (const m of src.match(/#[0-9a-f]{3,8}\b/gi) || []) {
      if (/^#[0-9a-f]{3}$|^#[0-9a-f]{6}$|^#[0-9a-f]{8}$/i.test(m) && !WHITE_BLACK.test(m)) {
        assert.fail(`${f}: hard-coded colour ${m}`);
      }
    }
    for (const m of src.match(/rgba?\([^)]*\)/gi) || []) {
      const n = m.replace(/\s/g, '');
      assert.ok(/^rgba?\((255,255,255|0,0,0)(,[\d.]+)?\)$/i.test(n), `${f}: hard-coded colour ${m}`);
    }
    assert.ok(!/\b(hsla?|oklch|lab)\(/i.test(src), `${f}: hard-coded colour function`);
  }
});

test('the data takes the metric palette: part colours win for temps in multi-line charts', () => {
  assert.equal(C.metricVar('gpu'), 'var(--jc-metric-gpu)');
  assert.equal(C.metricVar('other'), 'var(--pcs-a)');
  // a single GPU temperature tile is coral (temps); next to the CPU's it becomes the parts' colours
  assert.deepEqual(C.seriesColors(['gpu.temp']), ['var(--jc-metric-temps)']);
  assert.deepEqual(C.seriesColors(['gpu.temp', 'cpu.temp']), ['var(--jc-metric-gpu)', 'var(--jc-metric-cpu)']);
  // same-group lines: the 2nd at 55%, the 3rd at 30%
  assert.deepEqual(C.seriesColors(['net.down', 'net.up']),
    ['var(--jc-metric-network)', 'color-mix(in srgb, var(--jc-metric-network) 55%, transparent)']);
  assert.deepEqual(C.seriesColors(['power.total', 'power.gpu', 'power.cpu'])[2],
    'color-mix(in srgb, var(--jc-metric-power) 30%, transparent)');
  assert.deepEqual(C.seriesColors(['fps', 'gpu.load', 'fan.case']),
    ['var(--jc-metric-frames)', 'var(--jc-metric-gpu)', 'var(--jc-metric-cooling)']);
});

test('the metric palette is defined once, in jarvis.css', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const css = fs.readFileSync(path.join(__dirname, 'jarvis.css'), 'utf8');
  for (const g of ['gpu', 'cpu', 'frames', 'power', 'temps', 'memory', 'network', 'cooling']) {
    assert.match(css, new RegExp('--jc-metric-' + g + ':#[0-9A-Fa-f]{6}'));
  }
});
