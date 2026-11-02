import Foundation

/// The block layer of the streaming markdown renderer, ported from
/// `widgets/markdown_stream.dart`.
///
/// Flutter leans on `flutter_markdown_plus`; there is no third-party package
/// here, so the work is split in two:
///
/// * **Blocks** (this file, pure Foundation): headings, fenced code, lists,
///   quotes, rules, standalone images and paragraphs. Deliberately a *line*
///   scanner, not a full CommonMark parser — it has to produce something sane
///   from every prefix of a reply while tokens are still arriving, which a
///   parser that needs a complete document cannot do.
/// * **Inline** styling (bold, italics, inline code, links) — left to
///   `AttributedString(markdown:)` in ``ChatMarkdownText``, which is why a
///   paragraph keeps its source text verbatim here.
///
/// The one rule that matters mid-stream: an unterminated ``` fence is still a
/// code block (``MarkdownBlock/code(language:text:closed:)`` with `closed:
/// false`), never prose, so a half-arrived snippet doesn't flash as styled text
/// and then re-flow when the closing fence lands.

/// One line of a list. `depth` is the nesting level (two spaces of indent per
/// level); `marker` is what the row draws — a bullet, or the author's own number.
struct MarkdownListItem: Equatable, Sendable {
    var marker: String
    var depth: Int
    var text: String
    /// Pictures the item showed (`- Rokid: ![…](…)`), drawn under its text.
    var images: [MarkdownImage] = []
}

/// One picture in a reply: its caption (the markdown alt) and where it lives.
struct MarkdownImage: Equatable, Hashable, Sendable {
    var alt: String
    var source: String

    /// The alt as a caption — the generic "image" a `MEDIA:` line gets isn't one.
    var caption: String { alt == "image" ? "" : alt }
}

enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `closed` is false while the closing fence hasn't arrived — normal
    /// mid-stream, and the cue for the view to keep the block quiet.
    case code(language: String, text: String, closed: Bool)
    case list([MarkdownListItem])
    case quote(String)
    case rule
    /// Pictures shown together: one full width, several as a 2-up grid. An
    /// image anywhere in a line is lifted out of its text and lands here, right
    /// after that text; images with only blank lines between share one gallery.
    case gallery([MarkdownImage])
    /// A pipe table: header row, per-column alignment and body rows. Rows are
    /// padded/truncated to the header's width so the view never indexes past a
    /// short row that's still streaming in.
    case table(MarkdownTable)
    /// A page the agent saved on the server (an absolute `.html` path), shown
    /// live. Only produced by ``MarkdownBlocks/withEmbeds(_:)``.
    case htmlPage(path: String)
    /// A web link on a line of its own, drawn as an iMessage-style preview.
    /// Only produced by ``MarkdownBlocks/withEmbeds(_:)``.
    case linkPreview(url: String)
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }
    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

enum MarkdownBlocks {

    /// Split `text` into renderable blocks. Total: any input, including a
    /// half-written one, yields a usable list.
    static func split(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [MarkdownListItem] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushList() {
            guard !list.isEmpty else { return }
            out.append(.list(list))
            list = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            out.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }
        func addGallery(_ images: [MarkdownImage]) {
            guard !images.isEmpty else { return }
            if case .gallery(let earlier)? = out.last {
                out[out.count - 1] = .gallery(earlier + images)
            } else {
                out.append(.gallery(images))
            }
        }

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let fence = fence(line) {
                flushAll()
                index += 1
                var body: [String] = []
                var closed = false
                while index < lines.count {
                    if isClosingFence(lines[index], fence.marker) { closed = true; index += 1; break }
                    body.append(lines[index])
                    index += 1
                }
                out.append(.code(language: fence.language, text: body.joined(separator: "\n"),
                                 closed: closed))
                continue
            }

            index += 1

            if line.isEmpty { flushAll(); continue }

            if let heading = heading(line) {
                flushAll()
                out.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if isRule(line) { flushAll(); out.append(.rule); continue }

            // Pictures leave their line: the text stays where it was, the
            // pictures go right after it (inside a list item: under it).
            let lifted = line.hasPrefix("|") ? (text: raw, images: []) : liftImages(raw)
            if !lifted.images.isEmpty {
                let rest = lifted.text.trimmingCharacters(in: .whitespaces)
                if var item = listItem(lifted.text) {
                    flushParagraph(); flushQuote()
                    item.images = lifted.images
                    list.append(item)
                } else if rest.hasPrefix(">") {
                    flushParagraph(); flushList()
                    let quoted = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                    if !quoted.isEmpty { quote.append(quoted) }
                    flushQuote()
                    addGallery(lifted.images)
                } else if rest.isEmpty, !list.isEmpty {
                    // A picture on its own line right after a bullet is that bullet's.
                    list[list.count - 1].images += lifted.images
                } else if rest.isEmpty, paragraph.isEmpty, quote.isEmpty,
                          case .list(var items)? = out.last, !items.isEmpty {
                    // …also when a blank line came between them.
                    items[items.count - 1].images += lifted.images
                    out[out.count - 1] = .list(items)
                } else if rest.isEmpty {
                    flushAll()
                    addGallery(lifted.images)
                } else {
                    flushList(); flushQuote()
                    paragraph.append(rest)
                    flushParagraph()
                    addGallery(lifted.images)
                }
                continue
            }

            // A table starts with a header row followed by a delimiter row
            // (`|---|:--:|`). Until the delimiter arrives the header is prose,
            // so a lone pipe-y line mid-stream doesn't flicker into a grid.
            if line.contains("|"), index < lines.count,
               let alignments = tableDelimiter(lines[index]) {
                let header = tableCells(line)
                if !header.isEmpty {
                    flushAll()
                    index += 1
                    var rows: [[String]] = []
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !row.isEmpty, row.contains("|") else { break }
                        var cells = tableCells(row)
                        if cells.count < header.count {
                            cells += Array(repeating: "", count: header.count - cells.count)
                        }
                        rows.append(Array(cells.prefix(header.count)))
                        index += 1
                    }
                    var aligns = alignments
                    if aligns.count < header.count {
                        aligns += Array(repeating: .leading, count: header.count - aligns.count)
                    }
                    out.append(.table(MarkdownTable(header: header,
                                                    alignments: Array(aligns.prefix(header.count)),
                                                    rows: rows)))
                    continue
                }
            }

            if line.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if let item = listItem(raw) {
                flushParagraph(); flushQuote()
                list.append(item)
                continue
            }

            flushList(); flushQuote()
            paragraph.append(line)
        }

        flushAll()
        return out
    }

    // MARK: Chat embeds

    /// The main chat's extras on top of ``split(_:)``, mirroring the web UI's
    /// `renderMd` embeds pre-pass:
    ///
    /// * an absolute `.html` path gets a live ``MarkdownBlock/htmlPage(path:)``
    ///   card — in place of a line that is only the path, otherwise right after
    ///   the block that names it — once per path per reply;
    /// * a paragraph line that is nothing but a web link becomes a
    ///   ``MarkdownBlock/linkPreview(url:)``. A link inside a sentence stays a link.
    static func withEmbeds(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var seen = Set<String>()
        func page(_ path: String) {
            if seen.insert(path).inserted { out.append(.htmlPage(path: path)) }
        }
        for block in blocks {
            switch block {
            case .paragraph(let text):
                var lines: [String] = []
                func flush() {
                    guard !lines.isEmpty else { return }
                    let joined = lines.joined(separator: "\n")
                    out.append(.paragraph(joined))
                    htmlPaths(in: joined).forEach(page)
                    lines = []
                }
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if let url = standaloneLink(trimmed) {
                        flush()
                        out.append(.linkPreview(url: url))
                    } else if let path = htmlPaths(in: trimmed).first,
                              [path, "`\(path)`"].contains(trimmed) {
                        flush()
                        page(path)
                    } else {
                        lines.append(line)
                    }
                }
                flush()
            case .heading(_, let text), .quote(let text):
                out.append(block)
                htmlPaths(in: text).forEach(page)
            case .list(let items):
                out.append(block)
                items.forEach { htmlPaths(in: $0.text).forEach(page) }
            default:
                out.append(block)
            }
        }
        return out
    }

    /// Absolute `.html` paths in `text`, bare or in backticks. Skips URLs
    /// (`https://x/a.html`), `~/` paths and a path inside a longer code span.
    static func htmlPaths(in text: String) -> [String] {
        guard text.contains(".html") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return htmlPathPattern.matches(in: text, range: range).compactMap { match in
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            return Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    private static let htmlPathPattern = try! NSRegularExpression(
        pattern: #"(?:^|[^\w:/.~`(-])(?:`(/[^\s`'"<>()\[\]]+?\.html)`|(/[^\s`'"<>()\[\]]+?\.html)(?![\w/`-]|\.\w))"#)

    /// `https://…`, `<https://…>` or `[label](https://…)` and nothing else.
    private static func standaloneLink(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        for pattern in linkLinePatterns {
            guard let match = pattern.firstMatch(in: line, range: range),
                  let url = Range(match.range(at: match.numberOfRanges - 1), in: line)
            else { continue }
            return String(line[url])
        }
        return nil
    }

    private static let linkLinePatterns = [
        try! NSRegularExpression(pattern: #"^<?(https?://[^\s<>"]+?)>?$"#),
        try! NSRegularExpression(pattern: #"^\[[^\]]+\]\((https?://[^\s)"]+)\)$"#),
    ]

    // MARK: Line classifiers

    private static func fence(_ line: String) -> (marker: String, language: String)? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let info = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            // "``` ```" (an inline code span on its own line) is not a fence.
            guard !info.hasPrefix(String(marker.first!)) else { return nil }
            // Only the language word matters; the rest of the info string is metadata.
            return (marker, info.split(separator: " ").first.map(String.init) ?? "")
        }
        return nil
    }

    private static func isClosingFence(_ raw: String, _ marker: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(marker) else { return false }
        return line.drop(while: { $0 == marker.first! }).isEmpty
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        // CommonMark wants a space after the hashes, so "#hashtag" stays prose.
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text = String(text.dropLast()) }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let squeezed = line.replacingOccurrences(of: " ", with: "")
        guard squeezed.count >= 3 else { return false }
        return ["-", "*", "_"].contains { char in squeezed.allSatisfy { String($0) == char } }
    }

    private static func listItem(_ raw: String) -> MarkdownListItem? {
        // A tab indents as far as four spaces, matching every markdown renderer.
        let expanded = raw.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(indent)
        let depth = min(indent / 2, 6)

        if let bullet = rest.first, "-*+".contains(bullet), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return MarkdownListItem(marker: "•", depth: depth, text: text)
        }

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return MarkdownListItem(marker: "\(digits).", depth: depth, text: text)
    }

    /// Split a table row into cells on unescaped pipes, dropping the outer
    /// pipes' empty ends. `\|` inside a cell is a literal pipe.
    static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for char in line {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "`" { inCode.toggle() }
            if char == "|" && !inCode { cells.append(current); current = "" } else { current.append(char) }
        }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), !trimmed.isEmpty { trimmed.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), !trimmed.isEmpty { trimmed.removeLast() }
        return trimmed
    }

    /// `|---|:---:|--:|` → one alignment per column; nil if the line isn't a
    /// delimiter row (every cell must be dashes with optional colons).
    static func tableDelimiter(_ raw: String) -> [MarkdownTable.Alignment]? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("-"), line.contains("|") || line.contains(":") else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var out: [MarkdownTable.Alignment] = []
        for cell in cells {
            let squeezed = cell.replacingOccurrences(of: " ", with: "")
            guard !squeezed.isEmpty, squeezed.allSatisfy({ $0 == "-" || $0 == ":" }),
                  squeezed.contains("-") else { return nil }
            let left = squeezed.hasPrefix(":"), right = squeezed.hasSuffix(":")
            out.append(left && right ? .center : right ? .trailing : .leading)
        }
        return out
    }

    /// The line with its `![alt](source)` images taken out (inline `code`
    /// keeps them as written), and the images in order.
    static func liftImages(_ line: String) -> (text: String, images: [MarkdownImage]) {
        guard line.contains("![") else { return (line, []) }
        var images: [MarkdownImage] = []
        let parts = line.components(separatedBy: "`")
        let rebuilt = parts.enumerated().map { index, part -> String in
            guard index % 2 == 0, part.contains("![") else { return part }
            let ns = part as NSString
            var kept = ""
            var cursor = 0
            for match in imagePattern.matches(in: part, range: NSRange(location: 0, length: ns.length)) {
                kept += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                images.append(MarkdownImage(alt: ns.substring(with: match.range(at: 1)),
                                            source: ns.substring(with: match.range(at: 2))))
                cursor = match.range.location + match.range.length
            }
            return kept + ns.substring(from: cursor)
        }
        // An odd count means an unclosed backtick: nothing in it was code.
        return images.isEmpty ? (line, []) : (rebuilt.joined(separator: "`"), images)
    }

    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\s]+)\)"#)

    /// Every picture of a reply, in reading order — what the viewer pages through.
    static func images(in blocks: [MarkdownBlock]) -> [MarkdownImage] {
        blocks.flatMap { block -> [MarkdownImage] in
            switch block {
            case .gallery(let images): return images
            case .list(let items): return items.flatMap(\.images)
            default: return []
            }
        }
    }
}
