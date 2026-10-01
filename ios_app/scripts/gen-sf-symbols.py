#!/usr/bin/env python3
"""Regenerates JarvisCopilot/Copilot/Settings/SFSymbolCatalog.swift from this Mac's SF Symbols
catalogue (CoreGlyphs.bundle): every symbol in Apple's order, with its browse categories and the
iOS version it first shipped in, language variants left out. Run from ios_app/."""
import plistlib

BASE = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/"
OUT = "JarvisCopilot/Copilot/Settings/SFSymbolCatalog.swift"
LANGUAGES = {"ar", "hi", "rtl", "he", "ja", "th", "zh", "bn", "gu", "kn", "ko", "ml", "mni", "mr", "or",
             "pa", "sat", "te", "si", "ta", "el", "ru", "km", "my"}
HIDDEN_CATEGORIES = {"all", "whatsnew", "multicolor", "variable"}


def load(name):
    with open(BASE + name, "rb") as f:
        return plistlib.load(f)


def main():
    order = load("symbol_order.plist")
    availability = load("name_availability.plist")
    years, symbols = availability["year_to_release"], availability["symbols"]
    symbol_categories = load("symbol_categories.plist")
    names = set(order)
    lines = []
    for name in order:
        if name not in symbols:
            continue
        head, _, tail = name.rpartition(".")
        if (tail in LANGUAGES and head in names) or ".zh." in name or name.endswith(".traditional"):
            continue
        categories = ",".join(c for c in symbol_categories.get(name, []) if c not in HIDDEN_CATEGORIES)
        lines.append(f"{name}|{categories}|{years[symbols[name]]['iOS']}")
    browse = [(c["key"], c["icon"]) for c in load("categories.plist") if c["key"] not in HIDDEN_CATEGORIES]
    raw = "\n".join(lines)
    assert '"""' not in raw and "\\" not in raw
    category_lines = "\n".join(f'        ("{key}", "{icon}"),' for key, icon in browse)
    with open(OUT, "w") as f:
        f.write(TEMPLATE.replace("@CATEGORIES@", category_lines).replace("@RAW@", raw))
    print(f"{len(lines)} symbols → {OUT}")


TEMPLATE = '''import Foundation

/// Every SF Symbol the system ships, for the icon pickers — generated from macOS's own
/// catalogue (CoreGlyphs: symbol_order, name_availability, symbol_categories), language
/// variants left out. Each line is `name|categories|first iOS`.
///
/// Regenerate with `python3 scripts/gen-sf-symbols.py` after an SF Symbols update.
enum SFSymbolCatalog {
    struct Symbol: Hashable {
        let name: String
        let categories: [String]
        let minimumOS: OperatingSystemVersion

        static func == (a: Symbol, b: Symbol) -> Bool { a.name == b.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    /// Apple's browse categories, as (key, icon).
    static let categories: [(key: String, icon: String)] = [
@CATEGORIES@
    ]

    /// The symbols this iOS can draw, in Apple's own order.
    static let all: [Symbol] = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return raw.split(separator: "\\n").compactMap { line -> Symbol? in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let version = parts[2].split(separator: ".").compactMap { Int($0) }
            let minimum = OperatingSystemVersion(majorVersion: version.first ?? 13,
                                                 minorVersion: version.count > 1 ? version[1] : 0, patchVersion: 0)
            guard (os.majorVersion, os.minorVersion) >= (minimum.majorVersion, minimum.minorVersion) else { return nil }
            return Symbol(name: String(parts[0]),
                          categories: parts[1].split(separator: ",").map(String.init),
                          minimumOS: minimum)
        }
    }()

    /// Symbols whose name has every word of `query`, in `category` if one is given.
    static func search(_ query: String, category: String? = nil, in symbols: [Symbol] = all) -> [Symbol] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        return symbols.filter { symbol in
            (category.map { symbol.categories.contains($0) } ?? true)
                && words.allSatisfy { symbol.name.contains($0) }
        }
    }

    private static let raw = """
@RAW@
"""
}
'''

if __name__ == "__main__":
    main()
