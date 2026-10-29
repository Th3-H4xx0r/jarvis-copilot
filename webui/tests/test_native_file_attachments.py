"""Native file reading for chat attachments.

A PDF goes to a Claude (Anthropic API) model as a native ``document`` part, so
it reads the text and sees the charts in the same turn without tool calls.
Other providers can't take that part, so they keep the path-based reading.
A small text file's contents go straight into the message for every model.
"""
import base64
from pathlib import Path

from api.routes import _normalize_chat_attachments
from api.streaming import _build_native_multimodal_message, _native_pdf_provider

_PDF = b"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"


def _att(path: Path, mime: str):
    return _normalize_chat_attachments([{
        'name': path.name, 'path': str(path), 'mime': mime,
        'size': path.stat().st_size, 'is_image': mime.startswith('image/'),
    }])


def test_a_pdf_is_a_native_document_on_claude(tmp_path):
    pdf = tmp_path / 'lab.pdf'
    pdf.write_bytes(_PDF)
    result = _build_native_multimodal_message('', 'what is this', _att(pdf, 'application/pdf'),
                                              str(tmp_path), native_pdf=True)
    assert isinstance(result, list)
    doc = result[0]
    assert doc['type'] == 'document'
    assert doc['source']['media_type'] == 'application/pdf'
    assert base64.b64decode(doc['source']['data']) == _PDF
    assert result[-1] == {'type': 'text', 'text': 'what is this'}


def test_a_pdf_stays_a_path_where_the_provider_cannot_take_it(tmp_path):
    pdf = tmp_path / 'lab.pdf'
    pdf.write_bytes(_PDF)
    result = _build_native_multimodal_message('', 'what is this', _att(pdf, 'application/pdf'),
                                              str(tmp_path))
    assert result == 'what is this'


def test_something_named_pdf_that_is_not_one_is_not_sent_as_a_document(tmp_path):
    fake = tmp_path / 'fake.pdf'
    fake.write_bytes(b'not a pdf at all')
    result = _build_native_multimodal_message('', 'hi', _att(fake, 'application/pdf'),
                                              str(tmp_path), native_pdf=True)
    assert result == 'hi'


def test_a_text_file_is_read_into_the_message_for_every_model(tmp_path):
    notes = tmp_path / 'notes.csv'
    notes.write_text('freq,wavelength\n20,0.5\n')
    result = _build_native_multimodal_message('', 'plot this', _att(notes, 'text/csv'), str(tmp_path))
    assert isinstance(result, str)
    assert result.startswith('plot this')
    assert '<attached_file name="notes.csv">\nfreq,wavelength\n20,0.5\n</attached_file>' in result


def test_a_big_or_binary_text_file_is_left_to_the_tools(tmp_path):
    big = tmp_path / 'big.txt'
    big.write_text('x' * (300 * 1024))
    binary = tmp_path / 'data.txt'
    binary.write_bytes(b'\xff\xfe\x00bad')
    for path in (big, binary):
        assert _build_native_multimodal_message('', 'hi', _att(path, 'text/plain'), str(tmp_path)) == 'hi'


def test_files_outside_the_workspace_are_never_read(tmp_path):
    outside = tmp_path / 'outside'
    outside.mkdir()
    secret = outside / 'secret.txt'
    secret.write_text('token')
    ws = tmp_path / 'ws'
    ws.mkdir()
    assert _build_native_multimodal_message('', 'hi', _att(secret, 'text/plain'), str(ws)) == 'hi'


def test_only_anthropic_providers_take_native_pdfs():
    assert _native_pdf_provider('anthropic-api')
    assert _native_pdf_provider('anthropic')
    for other in ('claude-code', 'openrouter', 'celeris', '', None):
        assert not _native_pdf_provider(other)
