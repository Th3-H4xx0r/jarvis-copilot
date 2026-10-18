"""renderMd embeds: bare .html paths become the live HTML viewer, and a link on
a line of its own becomes an iMessage-style preview card."""
import shutil
import subprocess
from pathlib import Path

import pytest

UI_JS_PATH = Path(__file__).parent.parent.resolve() / "static" / "ui.js"
NODE = shutil.which("node")

pytestmark = pytest.mark.skipif(NODE is None, reason="node not on PATH")

_DRIVER_SRC = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
global.window = {};
global.document = { createElement: () => ({ innerHTML: '', textContent: '' }) };
const esc = s => String(s ?? '').replace(/[&<>\"']/g, c => (
  {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const t = k => k;
for (const line of src.split('\n')) {
  if (/^const _[A-Z]+_EXTS=/.test(line)) eval(line.replace(/^const /, 'global.'));
}
function extractFunc(name) {
  const start = src.search(new RegExp('function\\s+' + name + '\\s*\\('));
  if (start < 0) throw new Error(name + ' not found');
  let i = src.indexOf('{', start), depth = 1; i++;
  while (depth > 0 && i < src.length) {
    if (src[i] === '{') depth++; else if (src[i] === '}') depth--;
    i++;
  }
  return src.slice(start, i);
}
eval(extractFunc('_matchBacktickFenceLine'));
eval(extractFunc('_isBacktickFenceClose'));
eval(extractFunc('renderMd'));
let buf = '';
process.stdin.on('data', c => { buf += c; });
process.stdin.on('end', () => { process.stdout.write(renderMd(buf)); });
"""


@pytest.fixture(scope="module")
def render(tmp_path_factory):
    driver = tmp_path_factory.mktemp("embeds") / "driver.js"
    driver.write_text(_DRIVER_SRC, encoding="utf-8")

    def _render(md: str) -> str:
        out = subprocess.run([NODE, str(driver), str(UI_JS_PATH)], input=md,
                             capture_output=True, text=True, timeout=10)
        assert out.returncode == 0, out.stderr
        return out.stdout
    return _render


def test_bare_html_path_becomes_viewer(render):
    html = render("Here it is, sir.\n/root/workspace/costumes/couples_costumes.html")
    assert 'class="html-preview-load"' in html
    assert 'data-path="/root/workspace/costumes/couples_costumes.html"' in html


def test_backticked_path_and_sentence_end_become_viewer(render):
    assert 'data-path="/tmp/a.html"' in render("Saved to `/tmp/a.html`.")
    assert 'data-path="/tmp/b.html"' in render("Saved to /tmp/b.html.")


def test_same_path_twice_makes_one_viewer(render):
    html = render("/tmp/a.html\n\nOpen /tmp/a.html again")
    assert html.count("html-preview-load") == 1


def test_html_paths_that_are_not_server_files_are_left_alone(render):
    html = render("See https://example.com/page.html and `cat /tmp/x.html` and ~/y.html")
    assert "html-preview-load" not in html


def test_html_path_inside_fenced_code_is_left_alone(render):
    html = render("```\nopen /tmp/a.html\n```")
    assert "html-preview-load" not in html


def test_link_on_its_own_line_becomes_preview(render):
    html = render("Here you go:\nhttps://www.amazon.com/dp/B083V5L7V6\nEnjoy")
    assert 'class="link-preview-load" data-url="https://www.amazon.com/dp/B083V5L7V6"' in html
    assert html.count("<a ") == 1  # the placeholder's own fallback link, not re-autolinked


def test_markdown_link_on_its_own_line_keeps_its_label(render):
    html = render("[Mario costume](https://example.com/mario)")
    assert 'data-url="https://example.com/mario"' in html
    assert ">Mario costume</a>" in html


def test_link_inside_a_sentence_gets_no_preview(render):
    html = render("Buy it at https://example.com/x today")
    assert "link-preview-load" not in html
    assert 'href="https://example.com/x"' in html
