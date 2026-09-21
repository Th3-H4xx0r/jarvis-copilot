"""Read the text out of Office documents, with nothing but the standard library.

``read_file`` refused .docx/.xlsx/.pptx as binary, so an attachment someone
sent you was a file the agent could describe but not open. Every one of those
formats is a ZIP of XML, so the text comes out with ``zipfile`` and
``ElementTree`` -- no new dependency, which matters in a tree whose own policy
is that every dependency is supply-chain surface.

This is text extraction, not fidelity: styling, images, formulas and exact
layout are gone. It answers "what does this say", and says so when the answer
is likely to be incomplete.
"""

from __future__ import annotations

import logging
import zipfile
from pathlib import Path
from typing import List, Optional, Tuple
from xml.etree import ElementTree

logger = logging.getLogger(__name__)

# Extensions this module can turn into text. Anything else stays binary.
EXTRACTABLE = {".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp"}

_W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
_A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
_S = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
_ODF_TEXT = "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}"

MAX_CELLS = 20000


def can_extract(path: str) -> bool:
    return Path(path).suffix.lower() in EXTRACTABLE


def _xml(archive: zipfile.ZipFile, name: str):
    try:
        return ElementTree.fromstring(archive.read(name))
    except (KeyError, ElementTree.ParseError, OSError):
        return None


def _docx(archive: zipfile.ZipFile) -> List[str]:
    root = _xml(archive, "word/document.xml")
    if root is None:
        return []
    return ["".join(node.text or "" for node in para.iter(f"{_W}t"))
            for para in root.iter(f"{_W}p")]


def _pptx(archive: zipfile.ZipFile) -> List[str]:
    slides = sorted(n for n in archive.namelist()
                    if n.startswith("ppt/slides/slide") and n.endswith(".xml"))
    lines: List[str] = []
    for index, name in enumerate(slides, 1):
        root = _xml(archive, name)
        if root is None:
            continue
        lines.append(f"## Slide {index}")
        for para in root.iter(f"{_A}p"):
            text = "".join(node.text or "" for node in para.iter(f"{_A}t"))
            if text.strip():
                lines.append(text)
        lines.append("")
    return lines


def _xlsx(archive: zipfile.ZipFile) -> Tuple[List[str], bool]:
    """Sheets as pipe-delimited rows. Returns ``(lines, truncated)``."""
    shared: List[str] = []
    root = _xml(archive, "xl/sharedStrings.xml")
    if root is not None:
        for item in root.iter(f"{_S}si"):
            shared.append("".join(node.text or "" for node in item.iter(f"{_S}t")))

    sheets = sorted(n for n in archive.namelist()
                    if n.startswith("xl/worksheets/sheet") and n.endswith(".xml"))
    lines: List[str] = []
    cells_seen = 0
    truncated = False
    for index, name in enumerate(sheets, 1):
        sheet = _xml(archive, name)
        if sheet is None:
            continue
        lines.append(f"## Sheet {index}")
        for row in sheet.iter(f"{_S}row"):
            values = []
            for cell in row.iter(f"{_S}c"):
                cells_seen += 1
                if cells_seen > MAX_CELLS:
                    truncated = True
                    break
                value_node = cell.find(f"{_S}v")
                raw = value_node.text if value_node is not None else None
                if raw is None:
                    inline = cell.find(f"{_S}is")
                    raw = ("".join(n.text or "" for n in inline.iter(f"{_S}t"))
                           if inline is not None else "")
                elif cell.get("t") == "s":
                    try:
                        raw = shared[int(raw)]
                    except (ValueError, IndexError):
                        raw = ""
                values.append((raw or "").replace("\n", " "))
            if truncated:
                break
            if any(v.strip() for v in values):
                lines.append(" | ".join(values))
        lines.append("")
        if truncated:
            break
    return lines, truncated


def _odf(archive: zipfile.ZipFile) -> List[str]:
    root = _xml(archive, "content.xml")
    if root is None:
        return []
    return ["".join(node.itertext()) for node in root.iter(f"{_ODF_TEXT}p")]


def extract(path: str) -> Optional[Tuple[str, str]]:
    """``(text, note)`` for a supported document, or None if we cannot read it.

    ``note`` names a caveat worth surfacing (a truncated sheet, a file that
    yielded nothing) so a thin result is never mistaken for a thin document.
    """
    p = Path(path)
    suffix = p.suffix.lower()
    if suffix not in EXTRACTABLE:
        return None

    try:
        with zipfile.ZipFile(p) as archive:
            truncated = False
            if suffix == ".docx":
                lines = _docx(archive)
            elif suffix == ".pptx":
                lines = _pptx(archive)
            elif suffix == ".xlsx":
                lines, truncated = _xlsx(archive)
            else:
                lines = _odf(archive)
    except (zipfile.BadZipFile, OSError) as exc:
        logger.debug("Could not extract %s: %s", path, exc)
        return None

    text = "\n".join(lines).strip()
    note = ""
    if truncated:
        note = (f"Stopped after {MAX_CELLS:,} cells — the spreadsheet is larger "
                "than this; use a script for the full contents.")
    elif not text:
        note = ("No text found. This document may be scanned images or "
                "entirely non-text content.")
    return text, note
