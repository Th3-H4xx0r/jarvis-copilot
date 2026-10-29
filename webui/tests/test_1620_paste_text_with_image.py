"""Composer paste: what lands in the attachment tray for each clipboard mix.

#1620: a rich-text copy (Notes, Word, Slack) carries a rendered preview image
next to its plain text — pasting it must paste the text, not attach the preview.

Paste-to-attach (ChatGPT-style): when there is no real plain text, every file on
the clipboard attaches — a screenshot, "Copy image" from a website (image +
text/html only), or a file copied in Finder (whose only text is its own name).
"""
from tests.test_issue1697_multi_image_paste import _paste_harness

_PNG = "{kind:'file', type:'image/png', getAsFile:()=>new Blob(['png'], {type:'image/png'})}"
_HTML = "{kind:'string', type:'text/html'}"
_PLAIN = "{kind:'string', type:'text/plain'}"


def _named(name: str, mime: str) -> str:
    return (f"{{kind:'file', type:'{mime}', "
            f"getAsFile:()=>new File(['x'], '{name}', {{type:'{mime}'}})}}")


def test_rich_text_with_preview_image_pastes_text_only():
    result = _paste_harness(f"[{_PLAIN}, {_HTML}, {_PNG}]", text="Meeting notes for Tuesday")
    assert result["preventDefaultCount"] == 0
    assert result["pendingCount"] == 0


def test_plain_text_paste_is_left_alone():
    result = _paste_harness(f"[{_PLAIN}]", text="hello")
    assert result["preventDefaultCount"] == 0
    assert result["pendingCount"] == 0


def test_copy_image_from_a_website_attaches_the_image():
    """Browsers put the image plus an <img> text/html item, with no plain text."""
    result = _paste_harness(f"[{_HTML}, {_PNG}]")
    assert result["preventDefaultCount"] == 1
    assert result["pendingNames"] == ["screenshot-1700000000000.png"]


def test_whitespace_only_text_does_not_block_the_image():
    result = _paste_harness(f"[{_PLAIN}, {_PNG}]", text="  \n")
    assert result["pendingNames"] == ["screenshot-1700000000000.png"]


def test_browser_generic_image_name_is_replaced():
    """Chrome names every pasted image image.png — two pastes must not de-dupe."""
    result = _paste_harness(f"[{_named('image.png', 'image/png')}]")
    assert result["pendingNames"] == ["screenshot-1700000000000.png"]


def test_copied_file_attaches_with_its_own_name():
    """A Finder copy carries the file plus its name as plain text."""
    result = _paste_harness(f"[{_PLAIN}, {_named('report.pdf', 'application/pdf')}]",
                            text="report.pdf")
    assert result["preventDefaultCount"] == 1
    assert result["pendingNames"] == ["report.pdf"]


def test_copied_photo_file_keeps_its_name():
    result = _paste_harness(f"[{_named('IMG_1234.jpg', 'image/jpeg')}]")
    assert result["pendingNames"] == ["IMG_1234.jpg"]


def test_status_names_what_was_attached():
    result = _paste_harness(f"[{_PNG}]")
    assert result["lastStatus"] == "Image pasted: screenshot-1700000000000.png"
