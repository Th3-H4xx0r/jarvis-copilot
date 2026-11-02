"""Chat images in the web UI's markdown: an image sits under the text it
belongs to (inside its bullet, after its paragraph), images in a row become one
gallery, a local markdown image keeps its caption, and code stays literal."""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

STATIC = Path(__file__).parent.parent.resolve() / "static"
NODE = shutil.which("node")

pytestmark = pytest.mark.skipif(NODE is None, reason="node not on PATH")

_DRIVER_SRC = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
global.window = {};
global.document = { createElement: () => ({ innerHTML: '', textContent: '' }), baseURI: '' };
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
    driver = tmp_path_factory.mktemp("imgs") / "driver.js"
    driver.write_text(_DRIVER_SRC, encoding="utf-8")

    def _render(md: str) -> str:
        out = subprocess.run([NODE, str(driver), str(STATIC / "ui.js")], input=md,
                             capture_output=True, text=True, timeout=10)
        assert out.returncode == 0, out.stderr
        return out.stdout
    return _render


def test_chat_images_node_unit_tests_pass():
    out = subprocess.run([NODE, "--test", str(STATIC / "chat_images.test.js")],
                         capture_output=True, text=True, timeout=30)
    assert out.returncode == 0, out.stdout + out.stderr


def test_list_item_image_goes_under_item(render):
    html = render("- Rokid: MEDIA:/root/m/rokid-a1b2c3_800x600.jpg\n- RayNeo: light")
    m = re.search(r"<li>(.*?)</li>", html, re.S)
    assert m and m.group(1).startswith("Rokid:")
    assert '<div class="chat-gallery" data-n="1">' in m.group(1)
    assert 'aspect-ratio:800/600' in m.group(1)
    assert "MEDIA:" not in html


def test_numbered_list_keeps_values(render):
    html = render("1. One MEDIA:/root/a.jpg\n2. Two MEDIA:/root/b.jpg")
    assert re.search(r'<li value="1">One\s*<div class="chat-gallery"', html), html
    assert re.search(r'<li value="2">Two\s*<div class="chat-gallery"', html), html


def test_image_run_is_one_gallery(render):
    html = render("Photos:\n\nMEDIA:/root/a.jpg\n\nMEDIA:/root/b.jpg\n\nEnd.")
    assert html.count('class="chat-gallery"') == 1
    assert 'data-n="2"' in html
    assert "<p>Photos:</p>" in html and "<p>End.</p>" in html


def test_text_then_image_paragraph_splits(render):
    html = render("Here is the lion. MEDIA:/root/lion.jpg")
    assert re.search(r'<p>Here is the lion\.\s*</p><div class="chat-gallery" data-n="1">', html), html


def test_local_markdown_image_with_caption(render):
    html = render("![Rokid Glasses](/root/.jarviscopilot/webui/media/s/rokid-abcdef_640x480.jpg)")
    assert 'src="api/media?path=%2Froot%2F.jarviscopilot%2Fwebui%2Fmedia%2Fs%2Frokid-abcdef_640x480.jpg"' in html
    assert 'data-caption="Rokid Glasses"' in html
    assert 'class="chat-gallery" data-n="1"' in html


def test_web_markdown_image_joins_gallery(render):
    html = render("![A](https://x/a.jpg)\n![B](https://x/b.png)")
    assert 'data-n="2"' in html and 'data-caption="A"' in html


def test_media_in_code_fence_stays_literal(render):
    html = render("```\nMEDIA:/root/a.jpg\n![x](/root/b.jpg)\n```")
    assert "MEDIA:/root/a.jpg" in html and "chat-gallery" not in html and "<img" not in html


def test_pdf_media_is_not_a_gallery_tile(render):
    html = render("Report: MEDIA:/root/r.pdf")
    assert "chat-gallery" not in html and "pdf-preview-load" in html
