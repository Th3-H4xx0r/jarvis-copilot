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
    var ordered: Bool
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
    /// A line that is *only* an image (`![alt](src)`), so it can render as a
    /// picture. An image inside a sentence stays in the paragraph.
    case image(alt: String, source: String)
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

            if let image = standaloneImage(line) {
                flushAll()
                out.append(.image(alt: image.alt, source: image.source))
                continue
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
            return MarkdownListItem(marker: "•", depth: depth, text: text, ordered: false)
        }

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return MarkdownListItem(marker: "\(digits).", depth: depth, text: text, ordered: true)
    }

    /// `![alt](source)` and nothing else on the line. Kept deliberately strict:
    /// an image mentioned mid-sentence must not tear the sentence in two.
    private static func standaloneImage(_ line: String) -> (alt: String, source: String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let altEnd = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        let source = String(line[altEnd.upperBound..<line.index(before: line.endIndex)])
        guard !source.isEmpty, !alt.contains("]") else { return nil }
        return (alt, source)
    }
}
