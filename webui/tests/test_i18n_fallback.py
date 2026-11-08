"""What the language packs must keep true now that a missing translation falls back to English
(`t()` reads `_locale[key] ?? LOCALES.en[key]`): a language only lists keys it actually
translates, so what can break is a key with no English text."""
import pathlib
import re

STATIC = pathlib.Path(__file__).resolve().parents[1] / "static"
I18N = (STATIC / "i18n.js").read_text(encoding="utf-8")
_BLOCK = re.compile(r"^  (?:'([\w-]+)'|(\w+)): \{\n(.*?)^  \},?$", re.M | re.S)
_ENTRY = re.compile(r"^ +(\w+):\s*(.+)$", re.M)


def _blocks():
    return {(m.group(1) or m.group(2)): m.group(3) for m in _BLOCK.finditer(I18N)}


def _entries(body):
    return dict(_ENTRY.findall(body))


def test_every_key_the_ui_asks_for_has_english_text():
    """`t()` hands back the key itself when nothing matches, so a `t('x') || 'fallback'` never
    falls back: English showed "cron_view_full_output". (`data-i18n` elements keep their HTML
    text instead, so only script lookups count.)"""
    en = _entries(_blocks()["en"])
    asked = set()
    for f in STATIC.glob("*.js"):
        if f.name != "i18n.js":
            asked |= set(re.findall(r"\bt\(\s*['\"]([a-z][a-z0-9_]*[a-z0-9])['\"]", f.read_text(encoding="utf-8")))
    missing = sorted(k for k in asked if k not in en)
    assert not missing, f"keys with no English text (they'd render as the raw key): {missing}"
