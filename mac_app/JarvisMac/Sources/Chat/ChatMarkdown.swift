import Foundation

/// The block layer of the chat's markdown, ported from the phone's
/// MarkdownBlocks: headings, fenced code, lists, quotes, rules, standalone
/// images, tables and paragraphs. A line scanner, not a CommonMark parser — it
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
    }

    /// The reply as blocks, `MEDIA:` lines already turned into images.
    static func blocks(_ text: String) -> [Block] { split(ChatMedia.rewrite(text)) }

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

    /// Bold, italics, `code` and links inside one block.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
