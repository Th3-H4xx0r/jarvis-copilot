import Foundation

/// The block layer of the chat's markdown, ported from the phone's
/// MarkdownBlocks: headings, fenced code, lists, quotes, rules, standalone
/// images, tables and paragraphs, plus the main chat's embeds (a page the agent
/// saved, a link on its own line). A line scanner, not a CommonMark parser — it
/// has to make sense of every prefix of a reply while tokens are arriving (an
/// unterminated fence is still code). Inline styling is left to
/// `AttributedString(markdown:)` in the view.
enum ChatMarkdown {
    struct ListItem: Equatable {
        var marker: String
        var depth: Int
        var text: String
    }

    struct Table: Equatable {
        var header: [String]
        var rows: [[String]]
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(language: String, text: String)
        case list([ListItem])
        case quote(String)
        case rule
        /// A line that is only `![alt](src)` — drawn as the picture.
        case image(alt: String, source: String)
        case table(Table)
        /// A page the agent saved on the server (an absolute `.html` path),
        /// shown live. Only made by `withEmbeds`.
        case htmlPage(path: String)
        /// A web link on a line of its own, drawn as a preview card. Only made
        /// by `withEmbeds`.
        case linkPreview(url: String)
    }

    /// The reply as blocks, `MEDIA:` lines already turned into images and
    /// pages and links into their cards. Parsed once per distinct text (the
    /// phone's ChatMarkdownCache): every open of the island and every token of
    /// a streaming reply re-renders the turns.
    static func blocks(_ text: String) -> [Block] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let blocks = withEmbeds(split(ChatMedia.rewrite(text)))
        blockCache.setObject(Box(blocks), forKey: key)
        return blocks
    }

    // MARK: embeds

    /// The phone's (and the web's) embeds pass over `split`:
    ///
    /// * an absolute `.html` path gets a live `.htmlPage` card — in place of a
    ///   line that is only the path, otherwise right after the block that
    ///   names it — once per path per reply;
    /// * a paragraph line that is nothing but a web link becomes a
    ///   `.linkPreview`. A link inside a sentence stays a link.
    ///
    /// Code blocks are left alone: a path or link in a fence is code.
    static func withEmbeds(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
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
                    } else if let path = htmlPaths(in: trimmed).first, [path, "`\(path)`"].contains(trimmed) {
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

    /// Absolute `.html` paths in `text`, bare or in backticks — the web's
    /// regex. Skips URLs (`https://x/a.html`), `~/` paths and a path inside a
    /// longer code span.
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
    static func standaloneLink(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        for pattern in linkLinePatterns {
            guard let match = pattern.firstMatch(in: line, range: range),
                  let url = Range(match.range(at: match.numberOfRanges - 1), in: line) else { continue }
            return String(line[url])
        }
        return nil
    }

    private static let linkLinePatterns = [
        try! NSRegularExpression(pattern: #"^<?(https?://[^\s<>"]+?)>?$"#),
        try! NSRegularExpression(pattern: #"^\[[^\]]+\]\((https?://[^\s)"]+)\)$"#),
    ]

    private final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    // NSCache is internally synchronised and evicts under memory pressure.
    nonisolated(unsafe) private static let blockCache: NSCache<NSString, Box<[Block]>> = {
        let cache = NSCache<NSString, Box<[Block]>>()
        cache.countLimit = 256
        return cache
    }()

    nonisolated(unsafe) private static let inlineCache: NSCache<NSString, Box<AttributedString>> = {
        let cache = NSCache<NSString, Box<AttributedString>>()
        cache.countLimit = 1_024
        return cache
    }()

    static func split(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
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

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let fence = fence(line) {
                flushAll()
                index += 1
                var body: [String] = []
                while index < lines.count {
                    if isClosingFence(lines[index], fence.marker) { index += 1; break }
                    body.append(lines[index])
                    index += 1
                }
                out.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }

            index += 1
            if line.isEmpty { flushAll(); continue }

            if let h = heading(line) { flushAll(); out.append(.heading(level: h.level, text: h.text)); continue }
            if isRule(line) { flushAll(); out.append(.rule); continue }
            if let image = standaloneImage(line) {
                flushAll()
                out.append(.image(alt: image.alt, source: image.source))
                continue
            }

            // A header row followed by a delimiter row (`|---|:--:|`) starts a table.
            if line.contains("|"), index < lines.count, isTableDelimiter(lines[index]) {
                let header = tableCells(line)
                if !header.isEmpty {
                    flushAll()
                    index += 1
                    var rows: [[String]] = []
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !row.isEmpty, row.contains("|") else { break }
                        var cells = tableCells(row)
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        index += 1
                    }
                    out.append(.table(Table(header: header, rows: rows)))
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

    /// Bold, italics, `code` and links inside one block, parsed once per text.
    static func inline(_ s: String) -> AttributedString {
        let key = s as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let value = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        inlineCache.setObject(Box(value), forKey: key)
        return value
    }

    // MARK: line classifiers

    private static func fence(_ line: String) -> (marker: String, language: String)? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let info = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            guard !info.hasPrefix(String(marker.first!)) else { return nil }
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

    private static func listItem(_ raw: String) -> ListItem? {
        let expanded = raw.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(indent)
        let depth = min(indent / 2, 6)
        if let bullet = rest.first, "-*+".contains(bullet), rest.dropFirst().first == " " {
            return ListItem(marker: "•", depth: depth, text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let p = after.first, p == "." || p == ")", after.dropFirst().first == " " else { return nil }
        return ListItem(marker: "\(digits).", depth: depth, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

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
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|"), !trimmed.isEmpty { trimmed.removeFirst() }
        if t.hasSuffix("|"), !trimmed.isEmpty { trimmed.removeLast() }
        return trimmed
    }

    private static func isTableDelimiter(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("-"), line.contains("|") || line.contains(":") else { return false }
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let s = cell.replacingOccurrences(of: " ", with: "")
            return !s.isEmpty && s.contains("-") && s.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// `![alt](source)` and nothing else on the line.
    private static func standaloneImage(_ line: String) -> (alt: String, source: String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let altEnd = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        let source = String(line[altEnd.upperBound..<line.index(before: line.endIndex)])
        guard !source.isEmpty, !alt.contains("]") else { return nil }
        return (alt, source)
    }
}
