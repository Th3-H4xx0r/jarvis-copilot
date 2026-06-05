"""Behavioural tests for the karaoke word scheduler in static/voice.js.

Drives the ACTUAL pure functions (karaokeWordRanges / karaokeSchedule /
karaokeAdvanceSpoken) via node — extracting each by name and evaluating it —
so the Python and JS can't drift. Mirrors test_renderer_js_behaviour.py.
"""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).parent.parent.resolve()
VOICE_JS = REPO / "static" / "voice.js"
NODE = shutil.which("node")
pytestmark = pytest.mark.skipif(NODE is None, reason="node not on PATH")

_DRIVER = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[1], 'utf8');
function extractFunc(name) {
  const re = new RegExp('function\\s+' + name + '\\s*\\(');
  const s = src.search(re);
  if (s < 0) throw new Error(name + ' not found');
  let i = src.indexOf('{', s), d = 1; i++;
  while (d > 0 && i < src.length) { if (src[i] === '{') d++; else if (src[i] === '}') d--; i++; }
  return src.slice(s, i);
}
eval(extractFunc('karaokeWordRanges'));
eval(extractFunc('karaokeSchedule'));
eval(extractFunc('karaokeAdvanceSpoken'));
const sched = karaokeSchedule(['Hi', 'there', 'world'], 1000);
const out = {
  ranges: karaokeWordRanges('Hi there, world!'),
  sched0: sched[0],
  schedMonotonic: sched.every((v, i) => i === 0 || v >= sched[i - 1]),
  schedLen: sched.length,
  empty: karaokeSchedule([], 1000).length,
  noBackslide: karaokeAdvanceSpoken([0, 300, 600], 350, 2),  // prev=2 -> stays 2
  advance: karaokeAdvanceSpoken([0, 300, 600], 650, 0),       // -> 3
  fromZero: karaokeAdvanceSpoken([0, 300, 600], 0, 0),        // -> 1 (word 0 at 0ms)
};
process.stdout.write(JSON.stringify(out));
"""


def _run():
    p = subprocess.run([NODE, "-e", _DRIVER, str(VOICE_JS)],
                       capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


def test_word_ranges():
    # "Hi"=[0,2], "there,"=[3,9], "world!"=[10,16]
    assert _run()["ranges"] == [[0, 2], [3, 9], [10, 16]]


def test_schedule_starts_at_zero_monotonic_and_lengths():
    o = _run()
    assert o["sched0"] == 0
    assert o["schedMonotonic"] is True
    assert o["schedLen"] == 3
    assert o["empty"] == 0


def test_advance_never_backslides_and_progresses():
    o = _run()
    assert o["noBackslide"] == 2   # never drops below prevSpoken
    assert o["advance"] == 3        # all three words passed by 650ms
    assert o["fromZero"] == 1       # word 0 (start 0) counts at posMs 0
