"""read_file can open the documents people actually send you.

.docx/.xlsx/.pptx used to hit the binary guard, so an attachment was a file
the agent could describe but not read. They are ZIPs of XML, so this needs no
dependency -- which matters in a tree whose policy is that every dependency is
supply-chain surface.
"""

import json
import zipfile

import pytest

from tools.document_extract import EXTRACTABLE, can_extract, extract
from tools.file_tools import read_file_tool

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    return tmp_path


def _docx(path, *paragraphs):
    with zipfile.ZipFile(path, "w") as z:
        body = "".join(
            f"<w:p>{''.join(f'<w:r><w:t>{run}</w:t></w:r>' for run in p)}</w:p>"
            for p in paragraphs
        )
        z.writestr("word/document.xml",
                   f'<?xml version="1.0"?><w:document xmlns:w="{W}"><w:body>{body}'
                   "</w:body></w:document>")
    return path


def _xlsx(path, shared, rows):
    with zipfile.ZipFile(path, "w") as z:
        sis = "".join(f"<si><t>{v}</t></si>" for v in shared)
        z.writestr("xl/sharedStrings.xml",
                   f'<?xml version="1.0"?><sst xmlns="{S}">{sis}</sst>')
        body = "".join(
            "<row>" + "".join(
                (f'<c t="s"><v>{v[1]}</v></c>' if v[0] == "s" else f"<c><v>{v[1]}</v></c>")
                for v in row) + "</row>"
            for row in rows)
        z.writestr("xl/worksheets/sheet1.xml",
                   f'<?xml version="1.0"?><worksheet xmlns="{S}"><sheetData>{body}'
                   "</sheetData></worksheet>")
    return path


def _pptx(path, *slides):
    with zipfile.ZipFile(path, "w") as z:
        for i, texts in enumerate(slides, 1):
            paras = "".join(f"<a:p><a:r><a:t>{t}</a:t></a:r></a:p>" for t in texts)
            z.writestr(f"ppt/slides/slide{i}.xml",
                       f'<?xml version="1.0"?><root xmlns:a="{A}">{paras}</root>')
    return path


class TestExtraction:
    def test_docx_joins_runs_within_a_paragraph(self, tmp_path):
        """Word splits a sentence across runs on any formatting change."""
        path = _docx(tmp_path / "d.docx", ["Ship the ", "deny floor"])
        text, _ = extract(str(path))
        assert text == "Ship the deny floor"

    def test_docx_keeps_paragraphs_on_separate_lines(self, tmp_path):
        path = _docx(tmp_path / "d.docx", ["One"], ["Two"])
        text, _ = extract(str(path))
        assert text.splitlines() == ["One", "Two"]

    def test_xlsx_resolves_shared_strings(self, tmp_path):
        path = _xlsx(tmp_path / "s.xlsx", ["Name", "Pranav"],
                     [[("s", 0), ("s", 1)], [("n", 42)]])
        text, _ = extract(str(path))
        assert "Name | Pranav" in text
        assert "42" in text

    def test_pptx_labels_each_slide(self, tmp_path):
        path = _pptx(tmp_path / "p.pptx", ["Title"], ["Second"])
        text, _ = extract(str(path))
        assert "## Slide 1" in text and "## Slide 2" in text
        assert "Title" in text and "Second" in text

    def test_unsupported_extension_returns_none(self, tmp_path):
        p = tmp_path / "a.png"
        p.write_bytes(b"\x89PNG")
        assert extract(str(p)) is None

    def test_a_corrupt_archive_returns_none_rather_than_raising(self, tmp_path):
        p = tmp_path / "broken.docx"
        p.write_bytes(b"not a zip at all")
        assert extract(str(p)) is None

    def test_an_empty_document_says_it_found_nothing(self, tmp_path):
        """A thin result must not read as a thin document."""
        path = _docx(tmp_path / "empty.docx")
        text, note = extract(str(path))
        assert text == ""
        assert "No text found" in note

    def test_can_extract_matches_the_supported_set(self):
        assert can_extract("x.docx") and can_extract("X.XLSX")
        assert not can_extract("x.exe")
        assert ".pptx" in EXTRACTABLE


class TestReadFileIntegration:
    def test_read_file_returns_the_text_instead_of_refusing(self, tmp_path):
        path = _docx(tmp_path / "note.docx", ["Quarterly plan"])
        out = json.loads(read_file_tool(str(path)))
        assert "error" not in out
        assert out["content"] == "Quarterly plan"
        assert out["extracted_from"] == ".docx"

    def test_genuinely_binary_files_are_still_refused(self, tmp_path):
        p = tmp_path / "a.exe"
        p.write_bytes(b"MZ\x90\x00")
        out = json.loads(read_file_tool(str(p)))
        assert "error" in out
        assert "binary" in out["error"].lower()

    def test_a_corrupt_document_falls_through_to_the_binary_guard(self, tmp_path):
        """Better a clear refusal than a confident empty read."""
        p = tmp_path / "broken.xlsx"
        p.write_bytes(b"not a zip")
        out = json.loads(read_file_tool(str(p)))
        assert "error" in out
